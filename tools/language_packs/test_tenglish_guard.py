import argparse
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module

guard_builder = load("build_tenglish_guard", "build_tenglish_guard.py")

# Words a review found one keyboard slip from an English word of 200 or more per million
# (oc for of, burt for but) that people did not type often enough or at all, and English
# loanwords spelled with a slip.
REVIEWED_ENGLISH_SLIPS = (
    "yea oc sar ru burt wasn lett ene shere stree oo maan cree ur ipl bigg haard lok "
    "mem bok samme neee yoo loney ul bir orr cine gst ey ruun iar laya paark ciity "
    "ity daya needa bitt baack eta pak tr aam ara trai gurl secons seema bead boks "
    "rel musi nera aak lokk pari jd tek livin phine haalf caar wal ree vit kear "
    "swatch taalk tema yee vare dier pok tej paart jook galf qute secon cadre rann "
    "baad"
).split()
# Mined or machine-romanized only, each one slip from a common English word.
MINED_ENGLISH_SLIPS = "yea burt shere stree cree oo ipl ene sar ru oc gst phine".split()
REVIEWED_LOANWORDS = "bigg haard ciity baack gurl caar taalk paart jook lokk".split()
# Frequent Telugu words that are also one slip from a common English word (oka, ki, lo).
FREQUENT_TELUGU_SLIPS = "oka aa lo mee na aame ki nee em inti intlo edo".split()

class TenglishGuardTests(unittest.TestCase):
    def test_shipped_guard_is_compiled_from_source(self):
        with tempfile.TemporaryDirectory() as value:
            output = Path(value) / "tenglish_guard.bin"
            guard_builder.compile_guard(argparse.Namespace(
                input=guard_builder.DEFAULT_TSV, output=output))
            self.assertEqual(output.read_bytes(), guard_builder.DEFAULT_BIN.read_bytes())

    def test_words_are_ordered_by_frequency(self):
        rows = guard_builder.read_tsv(guard_builder.DEFAULT_TSV)
        self.assertEqual(rows, sorted(rows, key=lambda row: (-row[1], row[0])))
        words = {word for word, _ in rows}
        self.assertTrue({"nenu", "meeru", "ledu", "ela", "enti"} <= words)
        self.assertFalse({"the", "may", "teh", "cinema", "commitee"} & words)

    def test_reviewed_english_slips_and_loanwords_are_not_listed(self):
        words = {word for word, _ in guard_builder.read_tsv(guard_builder.DEFAULT_TSV)}
        self.assertEqual(len(REVIEWED_ENGLISH_SLIPS), 83)
        self.assertEqual(set(REVIEWED_ENGLISH_SLIPS) & words, set())
        self.assertEqual(set(MINED_ENGLISH_SLIPS) & words, set())
        self.assertEqual(set(REVIEWED_LOANWORDS) & words, set())
        self.assertEqual(set(FREQUENT_TELUGU_SLIPS) - words, set())

    def test_slips_cover_neighbouring_keys_and_dropped_letters(self):
        slips = guard_builder.slips("to", guard_builder.neighbours())
        self.assertTrue({"ti", "yo", "t", "ot", "tto", "tpo"} <= slips)
        self.assertNotIn("to", slips)
        self.assertNotIn("tm", slips)

    def test_english_keeps_its_words_slips_misspellings_and_loanwords(self):
        projected = {"nenu": 500.0, "may": 40.0, "ti": 100.0, "gata": 20.0,
                     "sinima": 300.0, "kuda": 50.0, "oc": 1282.0, "ki": 840.0,
                     "baack": 15.0, "burt": 305.0, "edo": 68.0}
        native = {word: word.upper() for word in projected}
        english = {"may": 900.0, "to": 30_000.0, "great": 400.0, "menu": 16.0,
                   "of": 18_334.0, "i": 23_695.0, "back": 1349.0, "but": 2896.0,
                   "do": 6376.0}
        # People typed edo (a Telugu word) and baack (a rare spelling of the loanword back);
        # oc and burt are mined spellings; ki is on the reviewed allowlist.
        typed = {"nenu", "kuda", "baack", "edo"}
        kept, reasons = guard_builder.select(
            projected, native, {"SINIMA"}, typed, {"ki"}, english, {"gata": {"great"}},
            max_words=10, min_per_million=1.0)
        self.assertEqual([word for word, _, _ in kept], ["ki", "nenu", "edo", "kuda"])
        self.assertEqual(reasons, {
            "english_reading_likelier": 1, "english_loanword": 1,
            "english_slip_likelier": 4, "attested_english_misspelling": 1,
            "over_size_cap": 0})

    def test_loanwords_need_a_common_english_spelling_with_real_weight(self):
        import collections
        pairs = {
            "CINEMA": collections.Counter({"cinema": 8, "sinima": 2}),
            "KOSAM": collections.Counter({"kosam": 95, "choose": 5}),
            "ANNA": collections.Counter({"anna": 10}),
            "CAR": collections.Counter({"car": 4, "kaar": 2}),
            "MEE": collections.Counter({"mee": 3, "me": 1}),
        }
        english = {"cinema": 30.0, "choose": 300.0, "anna": 60.0, "car": 664.0, "me": 5487.0}
        self.assertEqual(guard_builder.english_loanwords(pairs, english), {"CINEMA", "CAR"})

    def test_misspelling_lists_keep_only_spelling_errors(self):
        with tempfile.TemporaryDirectory() as value:
            path = Path(value) / "missp.dat"
            path.write_text("$committee\ncommitee\n$you\nna\n", encoding="utf-8")
            self.assertEqual(guard_builder.misspellings([path]), {"commitee": {"committee"}})


if __name__ == "__main__":
    unittest.main()
