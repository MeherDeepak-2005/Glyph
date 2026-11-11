#!/usr/bin/env python3

import hashlib
import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from verify_release_artifacts import is_neural_artifact


def write_modern_metadata(root: Path) -> None:
    pack_path = root / "langdata.bin"
    pack = pack_path.read_bytes()
    if len(pack) < 12:
        pack = struct.pack("<4sII", b"KBLM", 6, 1)
        pack_path.write_bytes(pack)
    header = struct.pack("<8s4I32s", b"KBMODERN", 1,
                         struct.unpack_from("<I", pack, 8)[0], 0, 0,
                         hashlib.sha256(pack).digest())
    (root / "langdata.kbmodern").write_bytes(header + hashlib.sha256(header).digest())


class ReleaseArtifactVerifierTests(unittest.TestCase):
    def test_recognizes_compiled_and_source_model_containers(self) -> None:
        self.assertTrue(is_neural_artifact("Rescorer.mlmodelc/model.mil"))
        self.assertTrue(is_neural_artifact("Internal.mlpackage/Data/com.apple.CoreML/model.mlmodel"))
        self.assertTrue(is_neural_artifact("artifacts/finetune.pt"))
        self.assertTrue(is_neural_artifact("tokenizer.bin"))
        self.assertTrue(is_neural_artifact("spm.model"))
        self.assertTrue(is_neural_artifact("weights/model.safetensors"))

    def test_allows_normal_keyboard_resources(self) -> None:
        self.assertFalse(is_neural_artifact("langdata.bin"))
        self.assertFalse(is_neural_artifact("emoji.bin"))
        self.assertFalse(is_neural_artifact("demo_keyboard"))

    def test_requires_hash_matched_telugu_pack(self) -> None:
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)

            def write(name: str, payload: bytes) -> dict:
                path = root / name
                path.write_bytes(payload)
                return {"path": name, "bytes": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest()}

            write("demo_keyboard", b"binary")
            write("emoji.bin", b"emoji")
            write("langdata.bin", b"english")
            write_modern_metadata(root)
            write("safety.kbguard", b"safety")
            layout = write("telugu_layout.kbpack", b"layout")
            language = write("telugu_langdata.bin", b"telugu")
            transliteration = write("tenglish_lexicon.bin", b"tenglish")
            manifest = {
                "artifacts": {
                    "layout": layout,
                    "language_model": language,
                    "transliteration_lexicon": transliteration,
                },
                "provenance": [{"name": "fixture", "research_only": False,
                                "release_eligible": True}],
            }
            (root / "telugu_pack_manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8")
            script = Path(__file__).with_name("verify_release_artifacts.py")
            output = root / "audit.json"
            valid = subprocess.run(
                [sys.executable, str(script), str(root), "--output", str(output)],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)

            # Full-vocabulary budgets are explicit; legacy gates stay enforced.
            with (root / "langdata.bin").open("wb") as handle:
                handle.truncate(11_000_001)
            write_modern_metadata(root)
            base = [sys.executable, str(script), str(root), "--output", str(output)]
            legacy = subprocess.run(base, capture_output=True, text=True)
            self.assertNotEqual(legacy.returncode, 0)
            expanded = subprocess.run(base + ["--corev4"], capture_output=True, text=True)
            self.assertEqual(expanded.returncode, 0, expanded.stdout + expanded.stderr)
            self.assertEqual(json.loads(output.read_text())["gateBytes"], 24_000_000)
            with (root / "langdata.bin").open("wb") as handle:
                handle.truncate(20_000_001)
            write_modern_metadata(root)
            too_big = subprocess.run(base + ["--corev4"], capture_output=True, text=True)
            self.assertNotEqual(too_big.returncode, 0)
            self.assertIn("langdata.bin exceeds 20,000,000 bytes", too_big.stderr)
            (root / "langdata.bin").write_bytes(b"english")
            write_modern_metadata(root)

            (root / "tenglish_lexicon.bin").unlink()
            invalid = subprocess.run(
                [sys.executable, str(script), str(root), "--output", str(output)],
                check=False, capture_output=True, text=True,
            )
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("tenglish_lexicon.bin is missing",
                          invalid.stdout + invalid.stderr)

    def test_rejects_enabled_klipy_without_key_and_filter_review(self) -> None:
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)

            def write(name: str, payload: bytes) -> dict:
                (root / name).write_bytes(payload)
                return {"path": name, "bytes": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest()}

            write("demo_keyboard", b"binary")
            write("emoji.bin", b"emoji")
            write("langdata.bin", b"english")
            write_modern_metadata(root)
            write("safety.kbguard", b"safety")
            layout = write("telugu_layout.kbpack", b"layout")
            language = write("telugu_langdata.bin", b"telugu")
            transliteration = write("tenglish_lexicon.bin", b"tenglish")
            (root / "telugu_pack_manifest.json").write_text(json.dumps({
                "artifacts": {"layout": layout, "language_model": language,
                              "transliteration_lexicon": transliteration},
                "provenance": [{"name": "fixture", "research_only": False,
                                "release_eligible": True}],
            }), encoding="utf-8")
            with (root / "Info.plist").open("wb") as handle:
                plistlib.dump({"KLIPYMediaEnabled": True, "KLIPYAPIKey": "",
                               "KLIPYContentFilterApproved": False}, handle)
            script = Path(__file__).with_name("verify_release_artifacts.py")
            output = root / "audit.json"
            result = subprocess.run(
                [sys.executable, str(script), str(root), "--output", str(output)],
                check=False, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("empty API key", result.stdout + result.stderr)
            self.assertIn("Partner Panel", result.stdout + result.stderr)

    def test_rejects_research_only_language_sources(self) -> None:
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)

            def write(name: str, payload: bytes) -> dict:
                (root / name).write_bytes(payload)
                return {"path": name, "bytes": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest()}

            write("demo_keyboard", b"binary")
            write("emoji.bin", b"emoji")
            write("langdata.bin", b"english")
            write_modern_metadata(root)
            write("safety.kbguard", b"safety")
            layout = write("telugu_layout.kbpack", b"layout")
            language = write("telugu_langdata.bin", b"telugu")
            transliteration = write("tenglish_lexicon.bin", b"tenglish")
            manifest = {
                "artifacts": {"layout": layout, "language_model": language,
                              "transliteration_lexicon": transliteration},
                "provenance": [{"name": "unapproved corpus", "research_only": True,
                                "release_eligible": False}],
            }
            (root / "telugu_pack_manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8")
            script = Path(__file__).with_name("verify_release_artifacts.py")
            result = subprocess.run(
                [sys.executable, str(script), str(root), "--output", str(root / "audit.json")],
                check=False, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not release-eligible", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
