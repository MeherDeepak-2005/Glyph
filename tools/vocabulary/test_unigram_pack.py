"""The shipped dictionary and its policy sidecar are exactly what the ledger and catalog build."""
import hashlib, json, struct, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_unigram_pack as pack  # noqa: E402


class UnigramPackTests(unittest.TestCase):
    def test_ledger_order_and_manifest(self):
        vocab = pack.ledger(pack.LEDGER)
        manifest = json.loads((pack.LEDGER.parent / "manifest.json").read_text())
        self.assertEqual(len(vocab), manifest["words"])
        self.assertEqual(vocab, sorted(vocab, key=lambda row: (-row[1], row[0])))
        self.assertEqual(vocab[0][0], "the")

    def test_committed_artifacts_match_the_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            built = Path(directory) / "langdata.bin"
            report = pack.build(pack.LEDGER, built)
            self.assertEqual(built.read_bytes(), pack.OUTPUT.read_bytes())
            self.assertEqual(built.with_suffix(".kbmodern").read_bytes(), pack.OUTPUT.with_suffix(".kbmodern").read_bytes())
            self.assertEqual(report["words"], 187462)

    def test_sidecar_is_bound_to_the_pack(self):
        data = pack.OUTPUT.read_bytes()
        side = pack.OUTPUT.with_suffix(".kbmodern").read_bytes()
        magic, version, words, count, contexts, digest = struct.unpack("<8s4I32s", side[:56])
        self.assertEqual((magic, version, contexts), (b"KBMODERN", 1, 0))
        self.assertEqual(words, struct.unpack("<I", data[8:12])[0])
        self.assertEqual(digest, hashlib.sha256(data).digest())
        self.assertEqual(side[-32:], hashlib.sha256(side[:-32]).digest())
        self.assertEqual(len(side), 56 + 8 * count + 32)
        records = [struct.unpack("<2I", side[56 + 8 * i:64 + 8 * i]) for i in range(count)]
        self.assertEqual(records, sorted(records))
        self.assertTrue(all(flags in (2, 3) and word < words for word, flags in records))

    def test_policies_cover_the_catalog(self):
        vocab = pack.ledger(pack.LEDGER)
        words = {vocab[word][0] for word, flags in pack.policies(vocab) if flags & 1}
        for word in ("rizz", "delulu", "pookie", "ngl", "lowkey"):
            self.assertIn(word, words)
        self.assertNotIn("the", words)


if __name__ == "__main__":
    unittest.main()
