import importlib.util
import tempfile
import unittest
from pathlib import Path

def load(name: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module

LANGUAGE_DATA = load("build_language_data")
Pack = load("verify_language_data").Pack

class EnglishVocabularySourceTests(unittest.TestCase):
    def test_esdb_snapshot_has_expected_tiers_and_coverage(self):
        tiers = LANGUAGE_DATA.load_esdb_tiers()
        self.assertGreaterEqual(sum(value == 60 for value in tiers.values()), 100_000)
        self.assertGreaterEqual(sum(value == 70 for value in tiers.values()), 50_000)
        self.assertEqual(tiers["haptic"], 60)

    def test_every_automatic_frequency_word_is_esdb_validated(self):
        tiers = LANGUAGE_DATA.load_esdb_tiers()
        supplemental = {
            line.partition("#")[0].split()[0].lower()
            for line in LANGUAGE_DATA.SUPPLEMENTAL.read_text(encoding="utf-8").splitlines()
            if line.partition("#")[0].strip()
        }
        vocab = LANGUAGE_DATA.build_vocab()
        self.assertGreaterEqual(len(vocab), 60_000)
        for word, _ in vocab:
            self.assertTrue(word in tiers or word in supplemental, word)

class PackLayoutTests(unittest.TestCase):
    def test_v7_round_trip(self):
        vocab = [("the", 100), ("then", 40), ("they", 40), ("a", 7)]
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "pack.bin"
            LANGUAGE_DATA.write_bin(vocab, output=path)
            pack = Pack(path)
        self.assertEqual((pack.version, pack.words), (7, len(vocab)))
        words, frequencies = pack.vocabulary()
        self.assertEqual([word.decode() for word in words], [word for word, _ in vocab])
        self.assertEqual(list(frequencies), [frequency for _, frequency in vocab])
        trie = pack.trie()

        def node(word):
            index = 0
            for byte in word.encode():
                _, count, first, _, _ = trie[index]
                index = next(child for child in range(first, first + count) if trie[child][0] == byte)
            return trie[index]

        for word_id, (word, _) in enumerate(vocab):
            self.assertEqual(node(word)[3], word_id)
        self.assertEqual(node("th")[3], LANGUAGE_DATA.EMPTY)
        self.assertEqual(node("th")[4], 100)
        self.assertEqual(node("then")[4], 40)

    def test_committed_pack_is_v7(self):
        pack = Pack(LANGUAGE_DATA.OUT)
        self.assertEqual(pack.version, 7)
        self.assertGreater(pack.words, 100_000)

if __name__ == "__main__":
    unittest.main()
