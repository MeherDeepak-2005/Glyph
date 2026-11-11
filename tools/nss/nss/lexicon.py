"""The keyboard lexicon (keyboard/langdata.bin) and the <unk> fallback distribution.

Gboard's NSS decoder reaches lexicon words outside the model vocabulary through an
epsilon arc weighted P(<unk>|context) into a unigram state over the whole lexicon. Here:

    P(w | context) = P(<unk> | context) * P(w | <unk>)                    for w not in V
    P(w | <unk>)   = pi * u(w) / sum(u(w') for emittable lexicon w' not in V)

u(w) is the dictionary's unigram mass (pack frequency + 1; 0.5 for a word with no pack
entry, as the engine's UnigramModel counts text outside the dictionary), and pi is the
share of <unk> training tokens that are emittable lexicon words. The remaining 1 - pi
belongs to text the lexicon cannot emit (names, foreign words), which the keyboard
leaves as typed.
"""

from __future__ import annotations

import math
import re
import struct
from dataclasses import dataclass
from pathlib import Path

from . import DEFAULT_LANGDATA
from .vocab import Vocabulary, sha256

EMITTABLE = re.compile(r"[a-z']+")
MAGIC = 0x4B424C4D
UNKNOWN_MASS = 0.5


def read_pack(path: Path) -> tuple[list[str], list[int]]:
    """Stored forms and unigram frequencies of a KBLM v7 pack (tools/build_language_data.py)."""
    data = Path(path).read_bytes()
    magic, version, count, trie_nodes = struct.unpack_from("<4I", data, 0)
    if magic != MAGIC or version != 7:
        raise ValueError(f"{path}: expected langdata v7")
    freq_base = 16
    offsets_base = freq_base + 4 * count
    blob = offsets_base + 4 * (count + 1) + 14 * trie_nodes
    frequencies = struct.unpack_from(f"<{count}I", data, freq_base)
    offsets = struct.unpack_from(f"<{count + 1}I", data, offsets_base)
    words = [data[blob + offsets[i]:blob + offsets[i + 1]].decode("utf-8") for i in range(count)]
    return words, list(frequencies)


@dataclass
class Lexicon:
    frequency: dict[str, int]
    sha256: str

    @classmethod
    def load(cls, path: Path = DEFAULT_LANGDATA) -> "Lexicon":
        words, frequencies = read_pack(path)
        table: dict[str, int] = {}
        for word, frequency in zip(words, frequencies):
            if EMITTABLE.fullmatch(word):
                table[word] = max(table.get(word, 0), frequency)
        return cls(table, sha256(path))

    def __contains__(self, word: str) -> bool:
        return word in self.frequency

    def unigram_mass(self, word: str) -> float:
        found = self.frequency.get(word)
        return UNKNOWN_MASS if found is None else found + 1.0


@dataclass
class UnkPolicy:
    """Everything the runtime needs to spread P(<unk>|context) over lexicon words."""
    lexicon_share: float          # pi
    oov_mass: float               # sum of u(w) over emittable lexicon words outside V
    oov_words: int

    def log_word_given_unk(self, mass: float) -> float:
        return math.log(self.lexicon_share) + math.log(mass) - math.log(self.oov_mass)

    @classmethod
    def build(cls, lexicon: Lexicon, vocabulary: Vocabulary, lexicon_share: float) -> "UnkPolicy":
        if not 0 < lexicon_share <= 1:
            raise ValueError("lexicon share of <unk> must be in (0, 1]")
        masses = [lexicon.unigram_mass(word) for word in lexicon.frequency if vocabulary.exact(word) == 1]
        return cls(lexicon_share, float(sum(masses)), len(masses))
