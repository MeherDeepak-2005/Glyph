import importlib.util
import json
import sys
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

latin_builder = load("build_latin_layout", "build_latin_layout.py")

class LatinLayoutTests(unittest.TestCase):
    SOURCE = ROOT / "sources/en-US/qwerty.json"
    PACK = ROOT.parent.parent / "keyboard/english_layout.kbpack"

    def source(self) -> dict:
        return json.loads(self.SOURCE.read_text(encoding="utf-8"))

    def test_shipped_pack_is_compiled_from_source(self):
        import plistlib
        compiled = latin_builder.compile_document(self.source())
        self.assertEqual(plistlib.loads(self.PACK.read_bytes()), compiled,
                         "rebuild keyboard/english_layout.kbpack with build_latin_layout.py")

    def test_grid_matches_the_decoders(self):
        grid = latin_builder.compile_document(self.source())["letterGrid"]
        self.assertEqual(grid["rows"], ["qwertyuiop", "asdfghjkl", "zxcvbnm"])
        self.assertEqual(grid["rowOffsets"], [0.0, 0.5, 1.5])

    def test_rejects_broken_layouts(self):
        def broken(change):
            document = self.source()
            change(document)
            with self.assertRaises(latin_builder.LayoutError):
                latin_builder.compile_document(document)
        letters = lambda d: next(p for p in d["pages"] if p["id"] == "letters")
        broken(lambda d: letters(d)["rows"][0].remove("q"))
        broken(lambda d: letters(d)["rows"][0].append("w"))
        broken(lambda d: d["letterGrid"].update(rowOffsets=[0.0, 0.5]))
        broken(lambda d: letters(d)["bottomRow"].pop())
        broken(lambda d: letters(d)["rows"][1].append({"control": "warp"}))
        broken(lambda d: letters(d)["rows"][1].append({"key": "x", "width": "huge"}))
        broken(lambda d: letters(d)["rows"][1].append({"control": "page", "target": "emoji", "label": "e"}))
        broken(lambda d: d["fieldExtras"].update(phone=["+"]))
        broken(lambda d: d["alternatives"].update(e=["e\u0301"]))

if __name__ == "__main__":
    unittest.main()
