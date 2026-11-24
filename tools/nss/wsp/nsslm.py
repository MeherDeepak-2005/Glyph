"""Read, run and write the runtime's `.nsslm` word model in numpy (no torch).

The file layout is documented in tools/nss/nss/export.py. `Model` holds every section as
float arrays (int8 matrices are dequantized: q * row scale), so weight programs edit plain
numpy arrays; `save` quantizes them back to int8 per row exactly as export.py does.
Only the shipped family is supported: one CIFG-LSTM layer with a projection and a tied
embedding/output matrix (an untied OUTPUT section is read and written when present).
"""
from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

HEADER = "<4s10I4IfIf"
HEADER_BYTES, RECORD_BYTES, ALIGN = 256, 32, 64
INT8, FLOAT32, VOCABULARY = 1, 2, 3
EMBEDDING, OUTPUT, OUTPUT_BIAS, GATES, GATE_BIAS, PROJECTION, VOCAB = 1, 2, 3, 10, 11, 12, 100
FLAG_CIFG, FLAG_TIED, FLAG_PROJECTION = 1, 2, 4
PAD, UNK, BOS, EOS = 0, 1, 2, 3


def quantize(matrix: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    matrix = np.asarray(matrix, np.float32)
    scales = np.abs(matrix).max(1) / 127.0
    scales[scales == 0] = 1.0
    q = np.clip(np.rint(matrix / scales[:, None]), -127, 127).astype(np.int8)
    return q, scales.astype(np.float32)


def requantize(matrix: np.ndarray) -> np.ndarray:
    q, s = quantize(matrix)
    return q.astype(np.float32) * s[:, None]


@dataclass
class Model:
    header: tuple
    raw_header: bytes
    words: list[str]
    embedding: np.ndarray
    output_bias: np.ndarray
    gates: np.ndarray
    gate_bias: np.ndarray
    projection: np.ndarray
    output: np.ndarray | None = None
    index: dict[str, int] = field(default_factory=dict)

    @property
    def hidden(self) -> int: return self.header[6]
    @property
    def unk_share(self) -> float: return self.header[15]
    @property
    def out_matrix(self) -> np.ndarray: return self.embedding if self.output is None else self.output

    def copy(self) -> "Model":
        return Model(self.header, self.raw_header, self.words, self.embedding.copy(), self.output_bias.copy(), self.gates.copy(),
                     self.gate_bias.copy(), self.projection.copy(), None if self.output is None else self.output.copy(), self.index)

    def context_id(self, word: str) -> int:
        if not word.strip("'"): return -1
        lower = word.lower()
        if (i := self.index.get(lower)) is not None: return i
        stripped = lower.strip("'")
        return UNK if stripped == lower else self.index.get(stripped, UNK)

    def step(self, tokens: np.ndarray, h: np.ndarray, c: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """One CIFG-LSTM step for a batch: tokens [B], h [B, 96], c [B, 670] -> (h', c'); h' is also the features."""
        x = np.concatenate([self.embedding[tokens], h], 1)
        g = x @ self.gates.T + self.gate_bias
        n = self.hidden
        f = 1 / (1 + np.exp(-g[:, :n]))
        c = f * c + (1 - f) * np.tanh(g[:, n:2 * n])
        m = (1 / (1 + np.exp(-g[:, 2 * n:]))) * np.tanh(c)
        return m @ self.projection.T, c

    def features(self, contexts: list[tuple[int, ...]]) -> np.ndarray:
        """Features after <s> and each context id, for a batch of id tuples (all from a fresh <s> state)."""
        b = len(contexts)
        h = np.zeros((b, self.projection.shape[0]), np.float32); c = np.zeros((b, self.hidden), np.float32)
        h, c = self.step(np.full(b, BOS), h, c)
        lengths = np.array([len(x) for x in contexts])
        for t in range(int(lengths.max(initial=0))):
            live = np.nonzero(lengths > t)[0]
            tokens = np.array([contexts[i][t] for i in live])
            h2, c2 = self.step(tokens, h[live], c[live])
            h[live], c[live] = h2, c2
        return h

    def log_softmax_parts(self, features: np.ndarray, chunk: int = 1024) -> tuple[np.ndarray, np.ndarray]:
        """Per-row log normalizer over the whole vocabulary and log P(<unk>), on every core."""
        from concurrent.futures import ThreadPoolExecutor
        out = np.ascontiguousarray(self.out_matrix.T, np.float32); bias = self.output_bias.astype(np.float32)
        bias[[PAD, BOS, EOS]] = -np.inf
        norm = np.empty(len(features), np.float64)
        features = np.ascontiguousarray(features, np.float32)

        def block(k):
            z = features[k:k + chunk] @ out
            z += bias
            top = z.max(1, keepdims=True)
            z -= top
            np.exp(z, out=z)
            norm[k:k + chunk] = top[:, 0] + np.log(z.sum(1, dtype=np.float64))
        with ThreadPoolExecutor(8) as pool: list(pool.map(block, range(0, len(features), chunk)))
        unk = (features @ out[:, UNK] + bias[UNK]) - norm
        return norm, unk

    def gather_log_probs(self, features: np.ndarray, norm: np.ndarray, rows: np.ndarray, ids: np.ndarray) -> np.ndarray:
        """log P(ids | features[rows]) for flat (row, id) pairs."""
        out = self.out_matrix
        logits = np.einsum('ij,ij->i', features[rows], out[ids]) + self.output_bias[ids]
        return logits - norm[rows]


def load(path: str | Path) -> Model:
    data = Path(path).read_bytes()
    header = struct.unpack_from(HEADER, data, 0)
    if header[0] != b"NSLM" or header[2] != 1 or not header[3] & FLAG_CIFG:
        raise ValueError("only CIFG-LSTM .nsslm files are supported")
    sections = {}
    for k in range(header[16]):
        sid, kind, rows, cols, offset, size = struct.unpack_from("<4I2Q", data, HEADER_BYTES + RECORD_BYTES * k)
        if kind == INT8:
            q = np.frombuffer(data, np.int8, rows * cols, offset).reshape(rows, cols)
            start = offset + rows * cols; start += -start % 4
            scale = np.frombuffer(data, np.float32, rows, start)
            sections[sid] = (q.astype(np.float32) * scale[:, None])
        elif kind == FLOAT32:
            sections[sid] = np.frombuffer(data, np.float32, rows * cols, offset).reshape(rows, cols).copy()
        else:
            offsets = np.frombuffer(data, np.uint32, rows + 1, offset)
            blob = data[offset + 4 * (rows + 1):offset + size]
            sections[sid] = [blob[offsets[i]:offsets[i + 1]].decode() for i in range(rows)]
    words = sections[VOCAB]
    return Model(header, data[:HEADER_BYTES], words, sections[EMBEDDING], sections[OUTPUT_BIAS][0], sections[GATES],
                 sections[GATE_BIAS][0], sections[PROJECTION], sections.get(OUTPUT), {w: i for i, w in enumerate(words)})


def save(model: Model, path: str | Path) -> str:
    """Write `model` in the runtime layout (int8 per-row matrices, fp32 biases); returns its sha256."""
    flags = model.header[3]
    tied = model.output is None
    flags = (flags | FLAG_TIED) if tied else (flags & ~FLAG_TIED)
    sections = [(EMBEDDING, INT8, model.embedding)]
    if not tied: sections.append((OUTPUT, INT8, model.output))
    sections += [(OUTPUT_BIAS, FLOAT32, model.output_bias[None]), (GATES, INT8, model.gates),
                 (GATE_BIAS, FLOAT32, model.gate_bias[None]), (PROJECTION, INT8, model.projection)]
    blob = b"".join(w.encode() for w in model.words)
    lengths = np.cumsum([0] + [len(w.encode()) for w in model.words]).astype(np.uint32)
    body, records = bytearray(), []
    start = HEADER_BYTES + RECORD_BYTES * (len(sections) + 1); start += -start % ALIGN
    pad = lambda n: body.extend(b"\0" * (-len(body) % n))
    for sid, kind, array in sections:
        pad(ALIGN); offset = start + len(body); rows, cols = array.shape
        if kind == INT8:
            q, s = quantize(array); body.extend(q.tobytes()); pad(4); body.extend(s.tobytes())
        else:
            body.extend(np.ascontiguousarray(array, np.float32).tobytes())
        records.append((sid, kind, rows, cols, offset, start + len(body) - offset))
    pad(ALIGN); offset = start + len(body)
    body.extend(lengths.tobytes()); body.extend(blob)
    records.append((VOCAB, VOCABULARY, len(model.words), 0, offset, start + len(body) - offset))
    h = list(model.header); h[3] = flags; h[16] = len(records)
    header = bytearray(model.raw_header)
    struct.pack_into(HEADER, header, 0, *h)
    table = b"".join(struct.pack("<4I2Q", *r) for r in records)
    payload = bytes(header) + table
    payload += b"\0" * (start - len(payload)) + bytes(body)
    Path(path).write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()
