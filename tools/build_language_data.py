#!/usr/bin/env python3
"""Build the bundled English dictionary for the keyboard extension.

Produces keyboard/langdata.bin: ONE little-endian binary the extension memory-maps at
launch, holding the vocabulary, its unigram frequencies and the spelling trie. There is
no n-gram table: the neural search space (keyboard/nss-english.nsslm, tools/nss) is the
only language model, and it reads this file as its lexicon and unigram fallback.

Layout (KBLM v7; all fields u32 LE unless noted; native/DecoderCore/include/PackedLexicon.hpp):

  header   magic 'KBLM', version=7, W, trieNodes
  freq     u32 x W                     word frequencies, id = index
  offsets  u32 x (W+1)                 byte offsets into blob, per id
  trie     (label u8, childCount u8, firstChild u32, wordID u32, maxFreq u32)
           x trieNodes - 14 B packed. BFS order, node 0 = root (label 0);
           children contiguous from firstChild, sorted by label byte;
           wordID 0xFFFFFFFF = not a word; maxFreq = max frequency in the
           node's subtree, so a reader can walk it best-first.
  blob     utf8 word bytes

Word IDs follow descending frequency, ties by spelling.

Release inputs are deliberately immutable and checksum-verified:
  - Vocabulary validity: ESDB v2 size 60, plus frequency-gated size 70
    (MIT-like/BSD-compatible combined work).
  - Vocabulary frequency: hermitdave/FrequencyWords at a pinned Git commit
    (CC BY-SA 4.0).
  - Contractions: interior-apostrophe words counted in the vendored 41,502-sentence
    Tatoeba English CC0 snapshot dated 2026-07-18, scaled onto the frequency list.
  - Expansion: the reviewed additions of tools/data/english-expansion-v1 (ESDB, WordNet,
    project terms).
  - CoreV4 stored forms, each with a conservative prior of 1.

See ARTIFACTS.json and THIRD_PARTY_NOTICES.md for provenance and licensing.
"""

import argparse
import bz2
import hashlib
import json
import re
import struct
import sys
import urllib.request
from collections import Counter, deque
from pathlib import Path

DICT_COMMIT = "525f9b560de45753a5ea01069454e72e9aa541c6"
DICT_URL = (
    "https://raw.githubusercontent.com/hermitdave/FrequencyWords/"
    f"{DICT_COMMIT}/content/2018/en/en_full.txt"
)
DICT_SHA256 = "7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506"
TATOEBA_SHA256 = "14f975533e2f15257f674d6099b95cf6b2c3458a8baf7496935081ad862f4b91"
ESDB_COMMIT = "1e5b7d3a72f47a71da5d28686c1dd4b397178485"
ESDB_SHA256 = "b24c7392b4aec4adfea0b9322f80f86ab14a3ce13b74825ba2453af38c49ec28"

VERSION = 7
DICT_SIZE = 60_000
MIN_WORD_FREQ = 5          # drop one-off OCR/subtitle junk from the long tail
ESDB70_MIN_FREQ = 50       # size-70 entries require independent frequency evidence
CONTRACTIONS_KEEP = 500    # corpus-harvested interior-apostrophe words merged into vocab
CONTRACTIONS_MIN = 2       # the CC0 snapshot is intentionally small and curated
EMPTY = 0xFFFFFFFF         # trie node without a word (word ids are < 2**31)

# Informal apostrophe-less forms frequent in the subtitle corpus. If these ship
# as vocabulary words the engine can never correct them (dictionary words are
# never corrected) - stock corrects dont->don't, im->I'm, so we must too. Real
# words that merely look like these (ill, id, its, hell, well, shed...) stay.
EXCLUDE = {
    "im", "dont", "cant", "wont", "aint", "didnt", "doesnt", "isnt", "wasnt",
    "arent", "werent", "wouldnt", "couldnt", "shouldnt", "havent", "hasnt",
    "hadnt", "youre", "theyre", "youve", "weve", "theyve", "youll", "youd",
    "whats", "thats", "heres", "theres", "wheres", "hes", "shes", "lets",
}

WORD = re.compile(r"^[a-z']+$")
TOKEN = re.compile(r"[a-z']+")
ROOT = Path(__file__).resolve().parent
CACHE = ROOT / ".cache"
CORPUS = ROOT / "data" / "tatoeba-eng-cc0-2026-07-18.tsv.bz2"
ESDB = ROOT / "data" / "esdb-v2-en-60-70-2026-07-20.tsv.bz2"
SUPPLEMENTAL = ROOT / "data" / "english_supplemental.tsv"
OUT = ROOT.parent / "keyboard" / "langdata.bin"
EXPANSION_MANIFEST = ROOT / "data" / "english-expansion-v1.manifest.json"
COREV4_MANIFEST = ROOT / "data" / "corev4" / "english" / "manifest.json"
LANGDATA_CAP = 8_000_000


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require_hash(path: Path, expected: str) -> Path:
    actual = sha256(path)
    if actual != expected:
        sys.exit(f"checksum mismatch for {path}: expected {expected}, got {actual}")
    return path


def fetch(url: str, cache_name: str, expected_sha256: str) -> Path:
    CACHE.mkdir(exist_ok=True)
    path = CACHE / cache_name
    if not path.exists():
        print(f"downloading {url} ...", flush=True)
        urllib.request.urlretrieve(url, path)
    return require_hash(path, expected_sha256)


def corpus_sentences():
    """Yield normalized word tokens from the pinned four-column Tatoeba export."""
    require_hash(CORPUS, TATOEBA_SHA256)
    with bz2.open(CORPUS, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            fields = line.rstrip("\n").split("\t", 3)
            if len(fields) < 3 or fields[1] != "eng":
                continue
            text = fields[2].lower().replace("’", "'").replace("‘", "'").replace("`", "'")
            tokens = [t.strip("'") for t in TOKEN.findall(text)]
            tokens = [t for t in tokens if t]
            if tokens:
                yield tokens[:128]


def load_esdb_tiers() -> dict[str, int]:
    """Load the pinned ESDB validity tiers without retaining upstream metadata."""
    require_hash(ESDB, ESDB_SHA256)
    result: dict[str, int] = {}
    with bz2.open(ESDB, "rt", encoding="utf-8", errors="strict") as handle:
        for line_number, raw in enumerate(handle, 1):
            if raw.startswith("#") or not raw.strip():
                continue
            fields = raw.rstrip("\n").split("\t")
            if len(fields) != 2 or fields[1] not in {"60", "70"} \
                    or not WORD.fullmatch(fields[0]):
                sys.exit(f"invalid ESDB snapshot row {line_number}")
            result[fields[0]] = int(fields[1])
    if not result:
        sys.exit("ESDB snapshot is empty")
    return result


def build_vocab() -> list[tuple[str, int]]:
    vocab: list[tuple[str, int]] = []
    seen: set[str] = set()
    esdb_tiers = load_esdb_tiers()
    for line in fetch(DICT_URL, "en_full.txt", DICT_SHA256).read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) != 2 or not parts[1].isdigit():
            continue
        w, freq = parts[0], int(parts[1])
        if freq < MIN_WORD_FREQ or not WORD.match(w):
            continue
        if len(w) == 1 and w not in ("a", "i"):
            continue                     # stray single letters aren't words
        tier = esdb_tiers.get(w)
        if tier is None or (tier == 70 and freq < ESDB70_MIN_FREQ):
            continue
        if w in EXCLUDE or w.startswith("'") or w.endswith("'") or w in seen:
            continue
        seen.add(w)
        vocab.append((w, min(freq, 0xFFFFFFFF)))
        if len(vocab) >= DICT_SIZE:
            break
    if SUPPLEMENTAL.exists():
        for line in SUPPLEMENTAL.read_text(encoding="utf-8").splitlines():
            line = line.partition("#")[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2 or not parts[1].isdigit():
                sys.exit(f"invalid supplemental vocabulary row: {line!r}")
            word, freq = parts[0].lower(), int(parts[1])
            if not WORD.fullmatch(word) or word.startswith("'") or word.endswith("'"):
                sys.exit(f"invalid supplemental word: {word!r}")
            if word not in seen:
                seen.add(word)
                vocab.append((word, min(freq, 0xFFFFFFFF)))
    return vocab


def build_trie(vocab) -> list[list[int]]:
    """Static trie over the vocab, serialized as BFS records (see header doc)."""

    class N:
        __slots__ = ("kids", "wid")

        def __init__(self):
            self.kids: dict[int, N] = {}
            self.wid = EMPTY

    root = N()
    for i, (w, _) in enumerate(vocab):
        node = root
        for b in w.encode():
            nxt = node.kids.get(b)
            if nxt is None:
                nxt = N()
                node.kids[b] = nxt
            node = nxt
        node.wid = i

    # Subtree max frequency, post-order (explicit stack - no recursion limits).
    maxfreq: dict[int, int] = {}
    stack: list[tuple[N, bool]] = [(root, False)]
    while stack:
        node, done = stack.pop()
        if done:
            m = vocab[node.wid][1] if node.wid != EMPTY else 0
            for c in node.kids.values():
                m = max(m, maxfreq[id(c)])
            maxfreq[id(node)] = m
        else:
            stack.append((node, True))
            for c in node.kids.values():
                stack.append((c, False))

    # BFS serialization: each node's children form one contiguous, label-sorted
    # block, so the reader walks [firstChild, firstChild+childCount).
    records: list[list[int]] = [[0, 0, 0, root.wid, maxfreq[id(root)]]]
    queue = deque([(0, root)])
    while queue:
        idx, node = queue.popleft()
        kids = sorted(node.kids.items())
        records[idx][1] = len(kids)
        records[idx][2] = len(records) if kids else 0
        for label, child in kids:
            ci = len(records)
            records.append([label, 0, 0, child.wid, maxfreq[id(child)]])
            queue.append((ci, child))
    return records


def write_bin(vocab, *, output=None, max_bytes=LANGDATA_CAP) -> None:
    output = Path(output) if output is not None else OUT
    if len(vocab) > 0x7fffffff:
        raise ValueError("word IDs exceed signed runtime ID range")

    blob = bytearray()
    offsets = [0]
    for w, _ in vocab:
        blob += w.encode()
        offsets.append(len(blob))
    trie = build_trie(vocab)

    # Reject an oversized candidate BEFORE replacing the installed artifact.
    expected_bytes = 16 + 4 * len(vocab) + 4 * len(offsets) + 14 * len(trie) + len(blob)
    if expected_bytes > max_bytes:
        raise ValueError(f"language pack exceeds {max_bytes:,} byte cap: {expected_bytes:,}")
    temporary = output.with_suffix(output.suffix + ".tmp")
    try:
        with temporary.open("wb") as f:
            f.write(struct.pack("<4I", 0x4B424C4D, VERSION, len(vocab), len(trie)))
            f.write(struct.pack(f"<{len(vocab)}I", *(c for _, c in vocab)))
            f.write(struct.pack(f"<{len(offsets)}I", *offsets))
            for label, child_count, first_child, word_id, max_freq in trie:
                f.write(struct.pack("<BBIII", label, child_count, first_child, word_id, max_freq))
            f.write(blob)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    mb = output.stat().st_size / 1e6
    print(f"wrote {output} ({mb:.1f} MB): {len(vocab)} words, {len(trie)} trie nodes")


def merge_contractions(vocab: list[tuple[str, int]]) -> list[tuple[str, int]]:
    """The FrequencyWords source strips apostrophes, so the vocab ships with ZERO
    contractions - autocorrect can't produce "don't" and glide can't decode "what's"
    (EXCLUDE removed the apostrophe-less forms expecting the real ones to exist).
    Harvest interior-apostrophe tokens from our own corpus, scale their counts onto
    the vocab's frequency scale (via anchor words present in both), and merge."""
    if not CORPUS.exists():
        sys.exit(f"missing immutable corpus snapshot: {CORPUS}")
    pat = re.compile(r"^[a-z]+'[a-z]+$")
    counts: Counter = Counter()
    anchors = {"you": 0, "the": 0, "and": 0, "that": 0}
    print("harvesting contractions from corpus ...", flush=True)
    for tokens in corpus_sentences():
        for tok in tokens:
            if tok in anchors:
                anchors[tok] += 1
            elif "'" in tok and pat.match(tok):
                counts[tok] += 1
    vfreq = dict(vocab)
    ratios = [vfreq[w] / c for w, c in anchors.items() if c > 0 and w in vfreq]
    scale = sum(ratios) / len(ratios) if ratios else 1.0
    merged_freq = dict(vfreq)
    added: list[tuple[str, int]] = []
    upgraded = 0
    for word, count in counts.most_common(CONTRACTIONS_KEEP):
        if count < CONTRACTIONS_MIN:
            continue
        estimated = min(max(1, int(count * scale)), 0xFFFFFFFF)
        if word in merged_freq:
            if estimated > merged_freq[word]:
                merged_freq[word] = estimated
                upgraded += 1
        else:
            merged_freq[word] = estimated
            added.append((word, estimated))
    merged = sorted(merged_freq.items(), key=lambda e: (-e[1], e[0]))
    top = ", ".join(w for w, _ in added[:8])
    print(f"contractions: +{len(added)} merged, {upgraded} reweighted "
          f"(scale x{scale:.0f}) [{top} ...]")
    return merged


def load_expansion(manifest_path: Path):
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1 or manifest.get("release_eligible") is not True:
        raise ValueError("expansion manifest is incompatible or not release eligible")
    if set(manifest.get("sources", {})) != {"esdb", "wordnet", "masc", "frequency"} \
            or any(source.get("release_eligible") is not True for source in manifest["sources"].values()):
        raise ValueError("unapproved expansion source")
    record = manifest["artifacts"]["vocabulary"]
    path = (ROOT.parent / record["path"]).resolve()
    if not path.is_relative_to(ROOT.parent.resolve()):
        raise ValueError("expansion artifact outside repository")
    require_hash(path, record["sha256"])
    if path.stat().st_size != record["bytes"]:
        raise ValueError("expansion size mismatch")
    with bz2.open(path, "rt", encoding="utf-8") as handle:
        vocabulary = json.load(handle)
    if vocabulary.get("schema_version") != 1:
        raise ValueError("unsupported expansion snapshot")
    for record in manifest["project_inputs"]:
        path = (ROOT.parent / record["path"]).resolve()
        if not path.is_relative_to(ROOT.parent.resolve()):
            raise ValueError("project input outside repository")
        require_hash(path, record["sha256"])
    if manifest["additional_words"] != len(vocabulary["entries"]) \
            or manifest["baseline_words"] != vocabulary["baseline_words"]:
        raise ValueError("manifest vocabulary counts disagree")
    return manifest, vocabulary


def merge_expansion(vocab, snapshot):
    if snapshot["baseline_words"] != len(vocab):
        raise ValueError("expansion was prepared for a different baseline")
    merged = dict(vocab)
    if len(merged) != len(vocab):
        raise ValueError("duplicate baseline word")
    for entry in snapshot["entries"]:
        word, frequency = entry["word"], entry["frequency_prior"]
        if not WORD.fullmatch(word) or word.startswith("'") or word.endswith("'") \
                or word in EXCLUDE or len(word) < 2 or len(word) > 32 \
                or type(frequency) is not int or not 1 <= frequency <= 20_000 \
                or word in merged or not entry.get("sources") \
                or not set(entry["sources"]) <= {"esdb", "wordnet", "project"}:
            raise ValueError(f"invalid or duplicate expansion entry: {word}")
        merged[word] = frequency
    # Glide and key-target readers assume ID order follows frequency: rebuild ALL IDs.
    return sorted(merged.items(), key=lambda entry: (-entry[1], entry[0]))


def merge_corev4(vocab):
    """Admit CoreV4 stored forms with a conservative prior of 1 (not an observed count),
    keeping every existing weight."""
    manifest = json.loads(COREV4_MANIFEST.read_text())
    record = next(x for x in manifest["exports"] if x["path"] == "english-all.txt")
    source = require_hash(COREV4_MANIFEST.parent / record["path"], record["sha256"])
    forms = source.read_text().splitlines()
    if len(forms) != record["forms"] or len(set(forms)) != len(forms):
        raise ValueError("invalid CoreV4 vocabulary count/duplicates")
    merged = dict(vocab)
    excluded = []
    for word in forms:
        if not word or "\x00" in word:
            raise ValueError("invalid CoreV4 stored spelling")
        if word in EXCLUDE:
            excluded.append(word)
        else:
            merged.setdefault(word, 1)
    expanded = sorted(merged.items(), key=lambda entry: (-entry[1], entry[0]))
    print(f"CoreV4: +{len(expanded)-len(vocab)} forms; {len(excluded)} existing contraction-policy exclusions; new prior=1")
    return expanded


def build_vocabulary(manifest_path: Path = EXPANSION_MANIFEST) -> list[tuple[str, int]]:
    vocab = merge_contractions(build_vocab())
    manifest, vocabulary = load_expansion(manifest_path)
    vocab = merge_expansion(vocab, vocabulary)
    print(f"expansion: +{manifest['additional_words']} forms from pinned open sources")
    return merge_corev4(vocab)


def main():
    parser = argparse.ArgumentParser(description="Build the checksum-verified English KBLM v7 dictionary")
    parser.add_argument("--output", type=Path, default=OUT)
    parser.add_argument("--manifest", type=Path, default=EXPANSION_MANIFEST)
    args = parser.parse_args()
    if not args.output.parent.is_dir():
        parser.error(f"output folder does not exist: {args.output.parent}")
    write_bin(build_vocabulary(args.manifest), output=args.output)


if __name__ == "__main__":
    main()
