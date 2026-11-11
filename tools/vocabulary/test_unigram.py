"""Unigram build invariants and generated-report consistency."""
import csv
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
import numpy as np
from tools.vocabulary import build_unigram as b
from verify_language_data import Pack

class UnigramTests(unittest.TestCase):
    def test_admission_boundaries(self):
        for word in ("realword", "word's"):
            self.assertTrue(b.allowed(word))
        for word in ("two words", "a", "'word", "word'", "word''s", "a2b", "Don't", "dont", "a"*33):
            self.assertFalse(b.allowed(word))

    def test_mixture_uses_oov_conditionals(self):
        words = ["known", "rareone", "raretwo"]
        # Source 0 puts its OOV probability on the observed validation target.
        rates = np.array([[.99,.01,0],[.99,0,.01],[.99,0,.01]])
        weights, trials, _ = b.fit_mixture(rates, words, {"known"},
            {"tatoeba":{"known":1000,"rareone":20}, "wikitext":{"rareone":10}})
        self.assertEqual(len(trials), 66)
        self.assertEqual(list(weights), [1,0,0])

    def test_roundtrip_zero_and_large_weights(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.bin"
            b.write_pack(path, {"rareone":0, "common":100_000_000})
            self.assertEqual(b.pack_words(path), {"rareone":0,"common":100_000_000})
            p = Pack(path)
            self.assertEqual((p.bi_entries,p.tri_entries,p.starters),(0,0,0))

class GeneratedUnigramTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = b.ROOT / "tools/data/nss/unigram-v1"
        cls.report = json.loads((cls.folder / "manifest.json").read_text())
        cls.new = b.pack_words(cls.folder / "english-unigram.bin")
        cls.old = b.pack_words(cls.folder / "baseline-unigram.bin")

    def test_complete_generated_addition_list(self):
        added = set(self.new) - self.old.keys()
        lines = (self.folder / "ADDED_WORDS.txt").read_text().splitlines()
        self.assertEqual(lines, sorted(added))
        self.assertEqual(len(added), self.report["added_words"])
        self.assertFalse(self.old.keys() - self.new.keys())
        with (self.folder / "ADDED_WORDS.tsv").open() as f:
            self.assertEqual({r["word"] for r in csv.DictReader(f,delimiter="\t")},added)

    def test_ledger_matches_pack_and_measured_counts(self):
        with (self.folder / "unigrams.tsv").open() as f:
            rows = list(csv.DictReader(f, delimiter="\t"))
        self.assertEqual({r["word"]:int(r["stored_weight"]) for r in rows}, self.new)
        self.assertAlmostEqual(sum(float(r["estimated_probability"]) for r in rows if r["estimated_probability"]),1,places=8)
        observed = [r for r in rows if r["added"]=="1" and
                    sum(int(r[k]) for k in ("subtitle_observed_count","tatoeba_train_count","wikitext_train_count"))>0]
        self.assertEqual(len(observed),self.report["added_with_human_source_occurrences"])
        for r in rows:
            if sum(int(r[k]) for k in ("subtitle_observed_count","tatoeba_train_count","wikitext_train_count"))==0:
                self.assertEqual(int(r["stored_weight"]),0)
        self.assertNotIn("soda", self.report["selected"]["weights"])

    def test_hashes_and_model_pairing(self):
        for name, entry in self.report["artifacts"].items():
            self.assertEqual(b.sha(self.folder/name),entry["sha256"])
        self.assertEqual(b.sha(b.ROOT/"keyboard/nss-english.nsslm"),self.report["model_sha256"])
        with b.MODEL_VOCAB.open() as f:
            model = {r["word"] for r in csv.DictReader(f,delimiter="\t") if int(r["id"])>=4}
        self.assertFalse(model-self.new.keys())
        self.assertFalse(self.report["model_output_layer_changed"])

    def test_policy_only_and_no_ngram_tables(self):
        for stem in ("english-unigram","baseline-unigram"):
            path=self.folder/(stem+".bin")
            pack=Pack(path)
            self.assertEqual((pack.version,pack.bi_contexts,pack.bi_entries,pack.tri_contexts,pack.tri_entries,pack.starters),(6,0,0,0,0,0))
            data=path.with_suffix(".kbmodern").read_bytes()
            magic,version,words,policies,contexts,digest=struct.unpack_from("<8s4I32s",data)
            self.assertEqual((magic,version,words,contexts),(b"KBMODERN",1,pack.words,0))
            self.assertEqual(digest,hashlib.sha256(path.read_bytes()).digest())
            self.assertEqual(data[-32:],hashlib.sha256(data[:-32]).digest())
            for i in range(policies):
                word,flags=struct.unpack_from("<2I",data,56+8*i)
                self.assertLess(word,pack.words)
                self.assertEqual(flags & 4,0) # No prefix or contextual suggestion boosts.


class InstallerTests(unittest.TestCase):
    def test_paired_bundle_and_fail_closed(self):
        import os
        import shutil
        import subprocess
        folder=b.ROOT/"tools/data/nss/unigram-v1"
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp); inputs=tmp/"inputs"; inputs.mkdir()
            for name in ("english-unigram.bin","english-unigram.kbmodern","bundle.sha256","model.sha256"):
                shutil.copyfile(folder/name,inputs/name)
            env=dict(os.environ,SRCROOT=str(b.ROOT),TARGET_BUILD_DIR=str(tmp),
                     UNLOCALIZED_RESOURCES_FOLDER_PATH="test.appex",NSS_ENABLED="YES",
                     NSS_MODEL=str(b.ROOT/"keyboard/nss-english.nsslm"),NSS_DICTIONARY_DIR=str(inputs))
            command=["/bin/sh",str(b.ROOT/"tools/nss/install_nss.sh")]
            result=subprocess.run(command,env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(b.sha(tmp/"test.appex/langdata.bin"),b.sha(folder/"english-unigram.bin"))
            self.assertEqual(b.sha(tmp/"test.appex/langdata.kbmodern"),b.sha(folder/"english-unigram.kbmodern"))
            env["NSS_MODEL"]=str(tmp/"missing.nsslm")
            self.assertNotEqual(subprocess.run(command,env=env,capture_output=True).returncode,0)
            env["NSS_MODEL"]=str(b.ROOT/"keyboard/nss-english.nsslm")
            with (inputs/"english-unigram.kbmodern").open("ab") as f:f.write(b"corrupt")
            self.assertNotEqual(subprocess.run(command,env=env,capture_output=True).returncode,0)

if __name__ == "__main__":
    unittest.main()
