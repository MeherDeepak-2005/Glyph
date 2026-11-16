#!/usr/bin/env python3
"""Move a model's goldens to a new dictionary without retraining or re-exporting the model.

  rebase_goldens.py OLD_LANGDATA NEW_LANGDATA MODEL.nsslm [MODEL.nsslm ...]

The goldens beside each model (MODEL.goldens.json, written by nss/export.py) hold reference
scores from the trained weights. Only the <unk> fallback depends on the dictionary:

    log P(w | ctx) = log P(<unk> | ctx) + log pi + log u(w) - log oov_mass       for w outside V

so a new dictionary changes oov_mass, oov_words and the scores of words outside the model's
vocabulary by  [log u_new(w) - log oov_mass_new] - [log u_old(w) - log oov_mass_old],  and
nothing else. The old values are recomputed first and must equal the stored ones, so a
dictionary that is not the one the goldens were made with is refused. Pure Python.
"""
from __future__ import annotations
import json, math, re, struct, sys
from pathlib import Path

EMITTABLE = re.compile(r"[a-z']+")

def lexicon(path: Path) -> dict[str, int]:
    data = path.read_bytes()
    magic, version, count, nodes = struct.unpack_from("<4I", data, 0)
    if magic != 0x4B424C4D or version != 7:
        raise SystemExit(f"{path}: expected langdata v7")
    frequencies = struct.unpack_from(f"<{count}I", data, 16)
    offsets = struct.unpack_from(f"<{count + 1}I", data, 16 + 4 * count)
    blob = 16 + 4 * count + 4 * (count + 1) + 14 * nodes
    table: dict[str, int] = {}
    for i in range(count):
        word = data[blob + offsets[i]:blob + offsets[i + 1]].decode("utf-8")
        if EMITTABLE.fullmatch(word):
            table[word] = max(table.get(word, 0), frequencies[i])
    return table

def vocabulary(path: Path) -> set[str]:
    """The model's output words (ids 4 and up; 0-3 are pad, unk, bos, eos)."""
    data = path.read_bytes()
    (records,) = struct.unpack_from("<I", data, 64)
    for index in range(records):
        section, kind, rows, _, offset, _ = struct.unpack_from("<4I2Q", data, 256 + 32 * index)
        if section == 100 and kind == 3:
            lengths = struct.unpack_from(f"<{rows + 1}I", data, offset)
            blob = offset + 4 * (rows + 1)
            return {data[blob + lengths[i]:blob + lengths[i + 1]].decode("utf-8") for i in range(4, rows)}
    raise SystemExit(f"{path}: no vocabulary section")

def policy(table: dict[str, int], vocab: set[str]) -> tuple[float, int]:
    masses = [frequency + 1.0 for word, frequency in table.items() if word not in vocab]
    return float(sum(masses)), len(masses)

def main() -> None:
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    old, new = lexicon(Path(sys.argv[1])), lexicon(Path(sys.argv[2]))
    for model in map(Path, sys.argv[3:]):
        goldens_path = model.with_suffix(".goldens.json")
        goldens = json.loads(goldens_path.read_text())
        vocab = vocabulary(model)
        old_mass, old_words = policy(old, vocab)
        if (old_mass, old_words) != (float(goldens["oov_mass"]), int(goldens["oov_words"])):
            raise SystemExit(f"{goldens_path}: not made with {sys.argv[1]} "
                             f"(stored {goldens['oov_mass']}/{goldens['oov_words']}, computed {old_mass}/{old_words})")
        new_mass, new_words = policy(new, vocab)

        def shift(word: str) -> float:
            if word in vocab:
                return 0.0
            mass = lambda table: table[word] + 1.0 if word in table else 0.5
            return (math.log(mass(new)) - math.log(new_mass)) - (math.log(mass(old)) - math.log(old_mass))

        moved = 0
        for case in goldens["cases"]:
            for word in case["scores"]:
                case["scores"][word] += shift(word); moved += word not in vocab
            for phrase in case["extend"]:
                case["extend"][phrase] += sum(shift(word) for word in phrase.split())
        goldens["oov_mass"], goldens["oov_words"] = new_mass, new_words
        goldens_path.write_text(json.dumps(goldens, indent=1) + "\n")
        print(f"{goldens_path.name}: oov_words {old_words} -> {new_words}, oov_mass {old_mass:.0f} -> {new_mass:.0f}, "
              f"{moved} out-of-vocabulary scores moved")

if __name__ == "__main__":
    main()
