#!/usr/bin/env python3
"""Build keyboard/langdata.bin (KBLM v7) and keyboard/langdata.kbmodern from the unigram ledger.

Inputs
  tools/data/nss/unigram-v1/unigrams.tsv   every word form with its stored weight (the ledger
                                           of the unigram-v1 estimate; see its manifest.json)
  tools/vocabulary/modern_catalog.json     reviewed spelling policies for modern vocabulary

Outputs
  langdata.bin       words ordered by (-weight, word), the order the ledger was estimated in
  langdata.kbmodern  KBMODERN v1 spelling policies bound to that exact dictionary:
                       header   magic 'KBMODERN', version 1 u32, wordCount u32, policies u32,
                                contexts u32 (always 0), SHA-256 of langdata.bin
                       policy   (wordID u32, flags u32) x policies, ascending wordID
                                flag 1 = preserve the typed spelling (never autocorrect it away)
                                flag 2 = never commit this word automatically
                       trailer  SHA-256 of everything before it

  build_unigram_pack.py [--ledger TSV] [--output langdata.bin] [--check]

--check rebuilds into a temporary directory and fails unless both outputs match the files
already in place.
"""
from __future__ import annotations
import argparse, csv, hashlib, json, struct, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import build_language_data as builder

LEDGER = ROOT / "tools/data/nss/unigram-v1/unigrams.tsv"
CATALOG = Path(__file__).with_name("modern_catalog.json")
OUTPUT = ROOT / "keyboard/langdata.bin"

def ledger(path: Path) -> list[tuple[str, int]]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = [(row["word"], int(row["stored_weight"])) for row in csv.DictReader(handle, delimiter="\t")]
    if len({word for word, _ in rows}) != len(rows):
        raise ValueError("duplicate word in the ledger")
    if any(not word or weight < 0 or weight > 0xFFFFFFFF for word, weight in rows):
        raise ValueError("invalid ledger row")
    return sorted(rows, key=lambda row: (-row[1], row[0]))

def policies(vocab: list[tuple[str, int]], catalog: Path = CATALOG) -> list[tuple[int, int]]:
    ids = {word: index for index, (word, _) in enumerate(vocab)}
    document = json.loads(catalog.read_text())
    if document["schema_version"] != 1:
        raise ValueError("unsupported catalog version")
    records = []
    for row in document["entries"]:
        if row["preserve"] and row["autocorrect"]:
            raise ValueError(f"a preserved spelling cannot be an automatic replacement: {row['word']}")
        flags = int(row["preserve"]) | (int(not row["autocorrect"]) << 1)
        if flags and row["word"] in ids:
            records.append((ids[row["word"]], flags))
    return sorted(records)

def sidecar(pack: bytes, words: int, records: list[tuple[int, int]]) -> bytes:
    data = struct.pack("<8s4I32s", b"KBMODERN", 1, words, len(records), 0, hashlib.sha256(pack).digest())
    data += b"".join(struct.pack("<2I", *record) for record in records)
    return data + hashlib.sha256(data).digest()

def build(ledger_path: Path, output: Path) -> dict:
    vocab = ledger(ledger_path)
    builder.write_bin(vocab, output=output)
    pack = output.read_bytes()
    records = policies(vocab)
    side = sidecar(pack, len(vocab), records)
    output.with_suffix(".kbmodern").write_bytes(side)
    return {"words": len(vocab), "policies": len(records), "pack_bytes": len(pack),
            "pack_sha256": hashlib.sha256(pack).hexdigest(), "sidecar_bytes": len(side),
            "sidecar_sha256": hashlib.sha256(side).hexdigest(),
            "ledger_sha256": hashlib.sha256(ledger_path.read_bytes()).hexdigest(),
            "catalog_sha256": hashlib.sha256(CATALOG.read_bytes()).hexdigest()}

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ledger", type=Path, default=LEDGER)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not args.check:
        print(json.dumps(build(args.ledger, args.output), indent=2))
        return
    with tempfile.TemporaryDirectory() as directory:
        candidate = Path(directory) / "langdata.bin"
        build(args.ledger, candidate)
        for built, installed in ((candidate, args.output),
                                 (candidate.with_suffix(".kbmodern"), args.output.with_suffix(".kbmodern"))):
            if not installed.exists() or built.read_bytes() != installed.read_bytes():
                raise SystemExit(f"stale artifact: {installed} does not match the ledger and catalog")
    print("langdata.bin and langdata.kbmodern match the ledger and catalog")

if __name__ == "__main__":
    main()
