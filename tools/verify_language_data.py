#!/usr/bin/env python3
"""Compare two langdata packs by logical content, independent of file format.

The content is the vocabulary, its frequencies and the spelling trie. KBLM v7
(tools/build_language_data.py) holds nothing else. Older packs (v4-v6, in the git
history) also held bigram/trigram tables and sentence starters; those sections are
skipped, so a v7 pack can be checked against the v6 pack it replaced.
"""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

MAGIC = 0x4B424C4D
EMPTY32 = 0xFFFFFFFF
EMPTY16 = 0xFFFF
# Default --max-bytes per candidate version; v7 is tools/build_language_data.py LANGDATA_CAP.
SIZE_CAPS = {6: 20_000_000, 7: 8_000_000}


class Pack:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        magic, self.version, self.words = struct.unpack_from("<3I", self.data, 0)
        if magic != MAGIC or self.version not in (4, 5, 6, 7):
            raise ValueError(f"{path}: expected langdata v4-v7")
        if self.version == 7:
            self.trie_nodes = struct.unpack_from("<I", self.data, 12)[0]
            self.freq_base = 16
            self.node_size = 14
            self.offsets_base = self.freq_base + 4 * self.words
            self.trie_base = self.offsets_base + 4 * (self.words + 1)
            self.blob_base = self.trie_base + self.node_size * self.trie_nodes
        else:
            _, _, _, bi_contexts, bi_entries, tri_contexts, tri_entries, self.trie_nodes, starters = \
                struct.unpack_from("<9I", self.data, 0)
            compact = self.version == 5
            entry_size = 6 if compact else 8
            self.freq_base = 36
            self.node_size = 12 if compact else 14
            self.offsets_base = self.freq_base + 4 * self.words
            self.trie_base = self.offsets_base + 4 * (self.words + 1) \
                + (12 if compact else 16) * bi_contexts + entry_size * bi_entries \
                + (12 if compact else 20) * tri_contexts + entry_size * tri_entries
            self.blob_base = self.trie_base + self.node_size * self.trie_nodes \
                + (6 if compact else 8) * starters
        if self.blob_base > len(self.data):
            raise ValueError(f"{path}: truncated section table")

    def vocabulary(self):
        frequencies = struct.unpack_from(f"<{self.words}I", self.data, self.freq_base)
        offsets = struct.unpack_from(f"<{self.words + 1}I", self.data, self.offsets_base)
        words = tuple(self.data[self.blob_base + offsets[i]:self.blob_base + offsets[i + 1]]
                      for i in range(self.words))
        return words, frequencies

    def trie(self):
        records = []
        for index in range(self.trie_nodes):
            offset = self.trie_base + self.node_size * index
            if self.version == 5:
                label, children, first, word, maximum = struct.unpack_from(
                    "<BBIHI", self.data, offset)
                word = EMPTY32 if word == EMPTY16 else word
            else:
                label, children, first, word, maximum = struct.unpack_from(
                    "<BBIII", self.data, offset)
            records.append((label, children, first, word, maximum))
        return tuple(records)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-bytes", type=int)
    args = parser.parse_args()
    old, new = Pack(args.reference), Pack(args.candidate)
    cap = args.max_bytes if args.max_bytes is not None else SIZE_CAPS.get(new.version, 11_000_000)
    checks = {
        "vocabulary/frequencies": old.vocabulary() == new.vocabulary(),
        "trie": old.trie() == new.trie(),
        "candidate size": len(new.data) <= cap,
    }
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        raise SystemExit("language-data verification failed: " + ", ".join(failures))
    print(f"verified v{old.version} -> v{new.version}: vocabulary, frequencies and trie identical")
    print(f"size: {len(old.data):,} -> {len(new.data):,} bytes "
          f"({(1 - len(new.data) / len(old.data)) * 100:.1f}% smaller)")
    print(f"sha256: {digest(args.candidate)}")


if __name__ == "__main__":
    main()
