#!/usr/bin/env python3
"""Build the Roman Telugu (Tenglish) guard: unigram frequencies of romanized Telugu words.

English decoding consults this list so a Telugu word typed in Roman letters is kept as
typed instead of being autocorrected or offered spelling corrections. It is a unigram
list only: no context model, no Telugu script output.

Two steps:

  extract  Count romanized Telugu words and write the reviewable
           sources/te-IN/tenglish-guard-unigrams.tsv. Needs downloaded datasets; see
           sources/te-IN/TENGLISH_GUARD_SOURCES.md for every URL and checksum.
  compile  Compile that TSV to keyboard/tenglish_guard.bin, the KBTD v1 trie that
           TeluguLexicon already reads (word IDs in frequency order, no n-grams).

Counting. There is no large corpus of typed Tenglish, so Telugu-script word
frequencies are projected onto their attested Roman spellings:
  count(roman) = sum over Telugu words t of perMillion(t) * P(roman | t)
perMillion(t) averages news (IndicCorp v2), Wikipedia (Dakshina) and conversation
(OpenSubtitles, a chat sample), so chat words such as nuvvu and cheppu are not
outweighed by encyclopedic text.
P(roman | t) comes from native-speaker romanizations (the Dakshina training lexicon), the
Aksharantar pairs and word-aligned machine romanizations of CulturaX Telugu (chat-style
spellings such as chala, kuda, ledhu), mined and machine pairs at half weight. Dakshina's
romanized sentences are kept for evaluation.

English collisions. A word is left out when the English decoder should keep owning it:
  - English is the likelier reading: it is an English word and not ENGLISH_BIAS times as
    frequent as Telugu (may, hot, drop, gym). Projected Telugu counts favour English
    spellings (a loanword's spellings collapse onto them, mined pairs hold translations),
    so English needs only 1/8 of the Telugu count; peru (Telugu "name", 42x) stays;
  - its Telugu word is an English loanword, one with a common English spelling
    (commitee and cinima are English misspellings of committee and cinema; kaar is car);
  - it is one keyboard slip (neighbouring key, missing, extra or doubled letter, swapped
    pair) from a common English word, one of at least SLIP_COMMON_ENGLISH per million,
    however frequent it is as Telugu (ki -> i, oc -> of, bigg -> big), or from an English
    word that is more than 1/SLIP_RATE times as frequent (ti -> to);
  - it is an attested English misspelling (Birkbeck, Holbrook, Aspell, Wikipedia lists)
    of an English word that is more frequent than it is as Telugu (bal for ball).
"""

from __future__ import annotations

import argparse
import bz2
import collections
import csv
import gzip
import hashlib
import json
import re
import struct
import sys
import unicodedata
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
sys.path.insert(0, str(ROOT))

import build_telugu_pack as telugu  # noqa: E402

DEFAULT_TSV = ROOT / "sources/te-IN/tenglish-guard-unigrams.tsv"
DEFAULT_BIN = REPO / "keyboard/tenglish_guard.bin"
DEFAULT_INDICCORP = REPO / "tools/data/indiccorpv2-te-stratified-2026-07-20.txt.bz2"
DEFAULT_TENGLISH_LEXICON = REPO / "keyboard/tenglish_lexicon.bin"
DEFAULT_CORE = ROOT / "sources/te-IN/tenglish-core-reviewed.tsv"
DEFAULT_ENGLISH = REPO / "tools/data/nss/unigram-v1/unigrams.tsv"

ROMAN = re.compile(r"^[a-z]{2,24}$")
# Each source's share of a Telugu word's romanizations. Aksharantar's IndicCorp rows are
# model-mined, one per word, and CulturaX was romanized by machine; the others were typed
# or reviewed by people.
MINED_WEIGHT = 0.5
CORE_WEIGHT = 3.0
# Machine-romanized word pairs seen fewer times, or making up less of the Telugu word's
# occurrences, are alignment noise (articlee for ee).
MACHINE_MIN_COUNT = 3
MACHINE_MIN_SHARE = 0.05
# Machine spellings that are English words this frequent (per million) are dropped: the
# machine writes some Telugu words as English look-alikes (low for lo).
MACHINE_ENGLISH_CEILING = 10.0
# Spellings the list cannot hold (one letter: e for ee) keep their share under this key.
UNUSABLE = ""
# A spelling English also uses must be this many times as frequent as Telugu to be listed.
ENGLISH_BIAS = 8.0
# Probability that a typist aiming at an English word produces one particular slip.
SLIP_RATE = 0.01
# English words rarer than this (per million) are not considered slip targets.
SLIP_TARGET_FLOOR = 1.0
# Per-million counts of Telugu and English come from different corpora, and English is the
# keyboard's language: no spelling one slip from an English word this common is listed,
# however frequent it is as Telugu (ki for i, oc for of, bigg for big).
SLIP_COMMON_ENGLISH = 200.0
# An English spelling at least this long and this frequent (per million) marks a loanword.
# Mined Aksharantar rows sometimes pair a word with its translation (kosam, "choose"), so
# the English spelling must also carry this share of the word's romanizations.
LOANWORD_MIN_LENGTH = 5
LOANWORD_ENGLISH_FLOOR = 1.0
LOANWORD_MIN_SHARE = 0.15
# A shorter English spelling marks a loanword when it is this frequent (per million) and
# the word's commonest spelling (car, talk); short Telugu spellings often collide with
# rarer English words (ante, adi, anna) or take a minority English spelling (me for mee).
LOANWORD_SHORT_ENGLISH_FLOOR = 100.0
DEFAULT_MAX_WORDS = 20_000
DEFAULT_MIN_PER_MILLION = 1.0
# Letter rows and the x position of each row's first key centre, in key widths.
QWERTY = (("qwertyuiop", 0.5), ("asdfghjkl", 1.0), ("zxcvbnm", 2.0))
HEADER = ["roman", "per_million", "telugu"]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def roman(value: str) -> str | None:
    value = unicodedata.normalize("NFKC", value).strip().lower()
    return value if ROMAN.fullmatch(value) else None


def open_text(path: Path):
    opener = {".bz2": bz2.open, ".gz": gzip.open}.get(path.suffix, open)
    return opener(path, "rt", encoding="utf-8")


def native_frequencies(genres: list[list[Path]]) -> dict[str, float]:
    """Per-million frequency of each Telugu word; each genre (a list of files) weighs the same."""
    frequencies: dict[str, float] = collections.defaultdict(float)
    for paths in genres:
        counts: collections.Counter[str] = collections.Counter()
        for path in paths:
            with open_text(path) as handle:
                for line in handle:
                    counts.update(telugu.tokenize_telugu(line))
        total = sum(counts.values())
        for word, count in counts.items():
            frequencies[word] += 1e6 * count / total / len(genres)
    return frequencies


def machine_romanized_pairs(path: Path) -> collections.Counter:
    """Word pairs from a CSV of Telugu text and its machine romanization (columns `text`
    and `text_romanized_azure`), aligned word by word on lines with equal word counts."""
    csv.field_size_limit(1 << 30)
    seen: collections.Counter = collections.Counter()
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            for native_line, roman_line in zip(row["text"].split("\n"),
                                               row["text_romanized_azure"].split("\n")):
                native_words, roman_words = native_line.split(), roman_line.split()
                if len(native_words) != len(roman_words):
                    continue
                for native, latin in zip(native_words, roman_words):
                    native = "".join(c for c in native if "\u0c00" <= c <= "\u0c7f" or c in "\u200c\u200d")
                    latin = "".join(c for c in latin if c.isascii() and c.isalpha())
                    if native and latin:
                        seen[native, latin] += 1
    return seen


def romanizations(dakshina: Path, aksharantar: Path, lexicon: Path, core: Path,
                  machine: Path, english: dict[str, float]) -> dict[str, collections.Counter]:
    """Weighted Roman spellings of each Telugu word. Spellings the list cannot hold (one
    letter: e for ee) are kept under UNUSABLE so they still take their share."""
    pairs: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)

    def add(native: str, latin: str, weight: float) -> None:
        native_word = telugu.normalize_telugu_word(native)
        if not native_word or not latin.isascii() or not latin.isalpha():
            return
        pairs[native_word][roman(latin) or UNUSABLE] += weight

    # Training split only: Dakshina's dev/test lexicons and romanized sentences stay
    # evaluation data.
    with (dakshina / "lexicons/te.translit.sampled.train.tsv").open(encoding="utf-8") as handle:
        for line in handle:
            native, latin, attestations = line.rstrip("\n").split("\t")
            add(native, latin, float(attestations))
    with zipfile.ZipFile(aksharantar) as archive, archive.open("tel_train.json") as handle:
        for line in handle:
            row = json.loads(line)
            add(row["native word"], row["english word"] or "",
                MINED_WEIGHT if row["source"] == "IndicCorp" else 1.0)
    data = lexicon.read_bytes()
    _, _, keys, _, key_offset, variant_offset, blob_offset, _ = struct.unpack_from("<4s7I", data)
    for index in range(keys):
        start, length, count, first = struct.unpack_from("<IHHI", data, key_offset + index * 12)
        latin = data[blob_offset + start:blob_offset + start + length].decode()
        for variant in range(count):
            native_start, native_length, _, _ = struct.unpack_from(
                "<IHHf", data, variant_offset + (first + variant) * 12)
            add(data[blob_offset + native_start:blob_offset + native_start + native_length].decode(),
                latin, 1.0)
    with core.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            if row["review_status"] == "approved":
                add(row["native"], row["roman"], CORE_WEIGHT)
    # One vote per distinct pair, like a mined Aksharantar row, so a frequent word's
    # machine spelling does not drown the spellings people typed.
    machine_pairs = machine_romanized_pairs(machine)
    occurrences: collections.Counter = collections.Counter()
    for (native, _), count in machine_pairs.items():
        occurrences[native] += count
    for (native, latin), count in machine_pairs.items():
        if count >= MACHINE_MIN_COUNT and count >= MACHINE_MIN_SHARE * occurrences[native] \
                and english.get(latin.lower(), 0.0) < MACHINE_ENGLISH_CEILING:
            add(native, latin, MINED_WEIGHT)
    return pairs


def english_frequencies(path: Path) -> dict[str, float]:
    csv.field_size_limit(1 << 30)
    frequencies: dict[str, float] = {}
    with path.open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            # Contractions count for their apostrophe-less spelling too: ive is "i've".
            word = row["word"].lower().replace("’", "'").replace("'", "")
            if not word.isascii() or not word.isalpha():
                continue
            try:
                probability = float(row["estimated_probability"] or 0)
            except ValueError:
                continue
            frequencies[word] = max(frequencies.get(word, 0.0), probability * 1e6)
    return frequencies


def edit_distance(a: str, b: str) -> int:
    """Edits between a and b; swapping two neighbouring letters counts as one (dose, does)."""
    rows = [list(range(len(b) + 1))]
    for i in range(1, len(a) + 1):
        row = [i]
        for j in range(1, len(b) + 1):
            cost = min(rows[i - 1][j] + 1, row[j - 1] + 1, rows[i - 1][j - 1] + (a[i - 1] != b[j - 1]))
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                cost = min(cost, rows[i - 2][j - 2] + 1)
            row.append(cost)
        rows.append(row)
    return rows[-1][-1]


def misspellings(paths: list[Path]) -> dict[str, set[str]]:
    """Birkbeck-format lists: `$correct` lines followed by its misspellings.

    Only spelling errors are kept: at most a third of the intended word's letters edited.
    The lists also hold children's guesses (na for "you") that no typist produces.
    """
    targets: dict[str, set[str]] = collections.defaultdict(set)
    for path in paths:
        correct = None
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                if line.startswith("$"):
                    correct = line[1:].lower().replace("_", " ")
                elif correct:
                    wrong = line.split()[0].lower()
                    if edit_distance(wrong, correct) <= max(1, len(correct) // 3):
                        targets[wrong].add(correct)
    return targets


def neighbours() -> dict[str, set[str]]:
    centre = {key: (row, start + column) for row, (keys, start) in enumerate(QWERTY)
              for column, key in enumerate(keys)}
    return {key: {other for other, (r, x) in centre.items()
                  if other != key and abs(r - row) <= 1 and abs(x - column) <= 1.0}
            for key, (row, column) in centre.items()}


def slips(word: str, adjacent: dict[str, set[str]]) -> set[str]:
    """Strings one keyboard slip away from `word`."""
    out: set[str] = set()
    for index, key in enumerate(word):
        near = adjacent.get(key, set())
        for other in near:
            out.add(word[:index] + other + word[index + 1:])
        out.add(word[:index] + word[index + 1:])
        if index + 1 < len(word):
            out.add(word[:index] + word[index + 1] + key + word[index + 2:])
        for other in near | {key}:
            out.add(word[:index] + other + word[index:])
    out.discard(word)
    return out


def select(projected: dict[str, float], best_native: dict[str, str],
           loanwords: set[str], english: dict[str, float],
           misspelled: dict[str, set[str]], max_words: int,
           min_per_million: float) -> tuple[list[tuple[str, float, str]], dict]:
    candidates = {word: value for word, value in projected.items() if value >= min_per_million}
    adjacent = neighbours()
    slip_source: dict[str, float] = {}
    for word, frequency in english.items():
        if frequency < SLIP_TARGET_FLOOR:
            continue
        for slip in slips(word, adjacent):
            if slip in candidates and frequency > slip_source.get(slip, 0.0):
                slip_source[slip] = frequency
    reasons: collections.Counter[str] = collections.Counter()
    kept: list[tuple[str, float, str]] = []
    for word, value in sorted(candidates.items(), key=lambda item: (-item[1], item[0])):
        if ENGLISH_BIAS * english.get(word, 0.0) >= value:
            reason = "english_reading_likelier"
        elif best_native[word] in loanwords:
            reason = "english_loanword"
        elif slip_source.get(word, 0.0) >= SLIP_COMMON_ENGLISH \
                or SLIP_RATE * slip_source.get(word, 0.0) > value:
            reason = "english_slip_likelier"
        elif any(phrase_frequency(target, english) > value
                 for target in misspelled.get(word, ())):
            reason = "attested_english_misspelling"
        else:
            kept.append((word, value, best_native[word]))
            continue
        reasons[reason] += 1
    reasons["over_size_cap"] = max(0, len(kept) - max_words)
    return kept[:max_words], dict(reasons)


def phrase_frequency(text: str, english: dict[str, float]) -> float:
    """A word's frequency, or for a phrase (noone for "no one") its rarest word's."""
    return min(english.get(word.replace("'", ""), 0.0) for word in text.split())


def english_loanwords(pairs: dict[str, collections.Counter],
                      english: dict[str, float]) -> set[str]:
    """Telugu words written for an English one: an attested spelling is a common English word.

    Their other spellings (commitee, cinima, kaar, staap) are English misspellings the
    decoder should fix.
    """
    loanwords = set()
    for native, spellings in pairs.items():
        total = sum(spellings.values())
        commonest = max(spellings.values())
        if any(english.get(latin, 0.0) >= LOANWORD_ENGLISH_FLOOR
               and weight >= LOANWORD_MIN_SHARE * total
               if len(latin) >= LOANWORD_MIN_LENGTH
               else english.get(latin, 0.0) >= LOANWORD_SHORT_ENGLISH_FLOOR and weight == commonest
               for latin, weight in spellings.items()):
            loanwords.add(native)
    return loanwords


def extract(args: argparse.Namespace) -> None:
    frequencies = native_frequencies([
        [args.indiccorp],
        [args.dakshina / "native_script_wikipedia/te.wiki-filt.train.text.shuf.txt.gz"],
        args.conversation])
    english = english_frequencies(args.english)
    pairs = romanizations(args.dakshina, args.aksharantar_zip, args.tenglish_lexicon, args.core,
                          args.machine_romanized, english)
    projected: dict[str, float] = collections.defaultdict(float)
    contribution: dict[str, tuple[float, str]] = {}
    for native, spellings in pairs.items():
        frequency = frequencies.get(native, 0.0)
        if not frequency:
            continue
        total = sum(spellings.values())
        for latin, weight in spellings.items():
            if latin == UNUSABLE:
                continue
            share = frequency * weight / total
            projected[latin] += share
            if share > contribution.get(latin, (0.0, ""))[0]:
                contribution[latin] = (share, native)
    # Rounded as written to the TSV, so the TSV order is the compiled word order.
    projected = {word: round(value, 3) for word, value in projected.items()}
    kept, reasons = select(projected, {word: native for word, (_, native) in contribution.items()},
                           english_loanwords(pairs, english), english,
                           misspellings(args.misspellings), args.max_words, args.min_per_million)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="") as handle:
        handle.write("\t".join(HEADER) + "\n")
        for word, value, native in kept:
            handle.write(f"{word}\t{value:.3f}\t{native}\n")
    print(json.dumps({"kept": len(kept), "excluded": reasons}, sort_keys=True))


def read_tsv(path: Path) -> list[tuple[str, float]]:
    rows: list[tuple[str, float]] = []
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle, delimiter="\t")
        if next(reader) != HEADER:
            raise ValueError(f"{path}: expected header {HEADER}")
        for line, fields in enumerate(reader, start=2):
            word = roman(fields[0])
            if word is None or word != fields[0]:
                raise ValueError(f"{path}:{line}: not a lowercase Roman word: {fields[0]!r}")
            rows.append((word, float(fields[1])))
    if len({word for word, _ in rows}) != len(rows):
        raise ValueError(f"{path}: duplicate words")
    return rows


def compile_guard(args: argparse.Namespace) -> dict:
    rows = read_tsv(args.input)
    rows.sort(key=lambda row: (-row[1], row[0]))   # word ID = frequency rank
    words = [word for word, _ in rows]
    stats = telugu.write_telugu_data(args.output, words, dict(rows), [])
    return {"word_count": stats["word_count"], "trie_node_count": stats["trie_node_count"],
            "bytes": args.output.stat().st_size, "sha256": sha256(args.output)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    extract_parser = commands.add_parser("extract")
    extract_parser.add_argument("--dakshina", type=Path, required=True,
                                help="dakshina_dataset_v1.0/te directory")
    extract_parser.add_argument("--aksharantar-zip", type=Path, required=True, help="Aksharantar tel.zip")
    extract_parser.add_argument("--misspellings", type=Path, nargs="+", required=True,
                                help="Birkbeck-format English misspelling lists")
    extract_parser.add_argument("--machine-romanized", type=Path, required=True,
                                help="CulturaX Telugu with Azure romanization (CSV)")
    extract_parser.add_argument("--conversation", type=Path, nargs="+", required=True,
                                help="conversational Telugu-script text (OpenSubtitles, chat)")
    extract_parser.add_argument("--indiccorp", type=Path, default=DEFAULT_INDICCORP)
    extract_parser.add_argument("--tenglish-lexicon", type=Path, default=DEFAULT_TENGLISH_LEXICON)
    extract_parser.add_argument("--core", type=Path, default=DEFAULT_CORE)
    extract_parser.add_argument("--english", type=Path, default=DEFAULT_ENGLISH)
    extract_parser.add_argument("--max-words", type=int, default=DEFAULT_MAX_WORDS)
    extract_parser.add_argument("--min-per-million", type=float, default=DEFAULT_MIN_PER_MILLION)
    extract_parser.add_argument("--output", type=Path, default=DEFAULT_TSV)
    compile_parser = commands.add_parser("compile")
    compile_parser.add_argument("--input", type=Path, default=DEFAULT_TSV)
    compile_parser.add_argument("--output", type=Path, default=DEFAULT_BIN)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "extract":
        extract(args)
    else:
        print(json.dumps(compile_guard(args), sort_keys=True))


if __name__ == "__main__":
    main()
