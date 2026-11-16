"""build_datasets.py on a small synthetic recording: joins, labels and tables."""
import csv, json, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_datasets

DAY = "2026-11-13T10:00:00Z"

def event(kind, uptime, process="kb", **fields):
    base = {"schema": 3, "id": f"{process}-{kind}-{uptime}", "time": DAY, "uptime": uptime, "process": process,
            "session": 1, "word": 0, "layout": 1, "kind": kind, "model": "nss", "language": "english", "build": "2"}
    base.update(fields)
    return base

def glide(uptime, word, text, outcome="committed"):
    return event("glide", uptime, word=word, text=text, confidence=1.5, durationMs=400,
                 candidateEvidence=[{"word": text, "spatialCost": 0.2, "source": "glide"}],
                 glide={"path": [[10, 20, 0, 9], [40, 22, 16.7, 9.5], [80, 30, 33.3, 10]], "startKey": text[:1] if text else None,
                        "outcome": outcome, "source": "preview", "previews": 3, "liftToInsertMs": 2.0})

def recording():
    geometry = {"width": 390, "height": 216, "xPitch": 39, "yPitch": 54, "keys": [{"label": "q", "x": 3, "y": 4, "w": 33, "h": 42}],
                "page": "letters", "profile": "phone", "screenWidth": 390, "screenHeight": 844, "screenScale": 3}
    strokes = [{"key": "t", "dx": 0.1, "dy": -0.2, "intervalMs": None}, {"key": "e", "dx": 0.3, "dy": 0.1, "intervalMs": 120},
               {"key": "h", "dx": -0.4, "dy": 0.2, "intervalMs": 140}]
    return [
        event("header", 1, header={"install": "install-A", "appVersion": "1.0", "build": "2", "device": "iPhone15,2",
                                   "system": "18.1", "locale": "en_IN"}),
        event("layout", 2, geometry=geometry),
        event("layout", 2.5, geometry=geometry),
        event("key", 3, word=1, text="t"), event("key", 3.12, word=1, text="e", intervalMs=120),
        event("key", 3.26, word=1, text="h", intervalMs=140),
        event("autocorrection", 3.5, word=1, text="teh", replacement="the", confidence=2.5,
              candidateEvidence=[{"word": "the", "score": -3.0, "spatialCost": 1.0, "source": "fuzzyLexicon"}]),
        event("commit", 3.51, word=1, text="the", typed="teh", keystrokes=strokes, durationMs=510, backspaces=0,
              evidence="automatic-unverified"),
        event("correction-accepted", 4.2, word=2, relatedWord=1, text="teh", replacement="the", sinceMs=700),
        event("autocorrection", 5, word=2, text="rizz", replacement="rise", confidence=0.4),
        event("commit", 5.01, word=2, text="rise", typed="rizz", evidence="automatic-unverified"),
        event("undo", 5.6, word=3, relatedWord=2, text="rise", replacement="rizz", evidence="explicit-autocorrect-undo", sinceMs=600),
        event("commit", 6, word=3, text="rizz", typed="rizz", evidence="literal-unverified"),
        event("autocorrection", 7, word=4, text="wat", replacement="what", confidence=1.1),
        event("commit", 7.01, word=4, text="what", typed="wat", evidence="automatic-unverified"),
        event("correction-accepted", 7.4, word=5, relatedWord=4, text="wat", replacement="what", sinceMs=400),
        event("manual-replacement", 9, word=5, relatedWord=4, text="what", replacement="wat", evidence="manual-autocorrect-undo"),
        event("key-fix", 9.5, word=5, text="q", replacement="w", dx=0.3, dy=0.0),
        glide(10, 6, "hello"), event("commit", 10.01, word=6, text="hello", evidence="glide-unverified"),
        glide(11, 7, "tome"), event("commit", 11.01, word=7, text="tome", evidence="glide-unverified"),
        event("glide-selection", 11.8, word=8, relatedWord=7, text="tome", replacement="time", evidence="explicit-selection"),
        glide(12, 8, "pit"), event("commit", 12.01, word=8, text="pit", evidence="glide-unverified"),
        event("undo", 12.5, word=9, relatedWord=8, text="pit", replacement="", evidence="explicit-retraction"),
        glide(13, 9, "", outcome="rejected"),
        event("prompt-shown", 20, process="app", session=0, prompt={"id": "p1", "target": "lowkey", "mode": "glide"}),
        glide(21, 10, "lonely"), event("commit", 21.01, word=10, text="lonely", evidence="glide-unverified"),
        event("prompt-done", 23, process="app", session=0, evidence="skipped",
              prompt={"id": "p1", "target": "lowkey", "mode": "glide", "result": "lonely "}),
        {"kind": "diagnostics", "schema": 3, "install": "install-A", "time": DAY, "snapshot": {"wordsCommitted": 9}},
    ]

class DatasetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        (root / "in" / "nested").mkdir(parents=True)
        lines = [json.dumps(e) for e in recording()]
        (root / "in" / "nested" / "chunk-1.jsonl").write_text("\n".join(lines) + "\n")
        (root / "in" / "export.jsonl").write_text("\n".join(lines[:12]) + "\nnot json\n")
        ledger = root / "ledger.tsv"
        ledger.write_text("word\tstored_weight\nthe\t9\nhello\t5\nwhat\t4\ntime\t4\nrise\t3\ntome\t1\npit\t1\nlonely\t1\n")
        self.out = root / "out"
        self.summary = build_datasets.build(root / "in", self.out, ledger)

    def tearDown(self):
        self.temp.cleanup()

    def table(self, name):
        with (self.out / name).open(newline="") as handle:
            return list(csv.DictReader(handle, delimiter="\t"))

    def test_summary_and_deduplication(self):
        self.assertEqual(self.summary["installs"], ["install-A"])
        self.assertEqual(self.summary["events_by_kind"]["autocorrection"], 3)
        self.assertEqual(self.summary["committed_words"], 8)
        self.assertEqual(self.summary["diagnostics_snapshots"], 1)
        self.assertEqual(self.summary["practice_prompts"], 1)

    def test_words(self):
        words = {row["word"]: row for row in self.table("word_frequency.tsv")}
        self.assertEqual(words["rizz"]["in_dictionary"], "0")
        self.assertEqual((words["hello"]["glided"], words["the"]["tapped"]), ("1", "1"))
        self.assertEqual([row["word"] for row in self.table("oov_words.tsv")], ["rizz"])
        self.assertIn(("the", "rise"), {(row["previous"], row["word"]) for row in self.table("bigrams.tsv")})
        speed = self.table("speed.tsv")[0]
        self.assertEqual(speed["median_interkey_ms"], "130.0")

    def test_autocorrect_outcomes(self):
        rows = {row["typed"]: row for row in self.table("autocorrect.tsv")}
        self.assertEqual((rows["teh"]["outcome"], rows["teh"]["since_ms"], rows["teh"]["margin"]), ("accepted", "700", "2.5"))
        self.assertEqual(json.loads(rows["teh"]["keystrokes"])[2]["key"], "h")
        self.assertEqual(rows["teh"]["mean_interkey_ms"], "130.0")
        self.assertEqual((rows["rizz"]["outcome"], rows["rizz"]["since_ms"]), ("undone-backspace", "600"))
        self.assertEqual(rows["wat"]["outcome"], "undone-by-hand")
        self.assertEqual(self.table("key_fixes.tsv")[0]["meant"], "w")

    def test_glide_labels(self):
        glides = [json.loads(line) for line in (self.out / "glides.jsonl").read_text().splitlines()]
        by_word = {g["committed"]: g for g in glides}
        self.assertEqual((by_word["hello"]["label"], by_word["hello"]["label_source"]), ("hello", "unverified"))
        self.assertEqual((by_word["tome"]["label"], by_word["tome"]["label_source"]), ("time", "selection"))
        self.assertEqual((by_word["pit"]["label"], by_word["pit"]["label_source"]), (None, "retracted"))
        self.assertEqual((by_word["lonely"]["label"], by_word["lonely"]["label_source"]), ("lowkey", "prompt"))
        self.assertEqual(by_word[None]["label_source"], "rejected")
        self.assertEqual(len(by_word["hello"]["path"]), 3)
        self.assertEqual(self.summary["glide_labels"], {"prompt": 1, "rejected": 1, "retracted": 1, "selection": 1, "unverified": 1})
        self.assertEqual(len((self.out / "layouts.jsonl").read_text().splitlines()), 1)

if __name__ == "__main__":
    unittest.main()
