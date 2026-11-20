#!/usr/bin/env python3

import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from verify_release_artifacts import is_neural_artifact

SCRIPT = ROOT / "verify_release_artifacts.py"

def write_bundle(root: Path) -> None:
    """A minimal English extension: the binary, its resources and the NSS word model."""
    for name, payload in (("demo_keyboard", b"binary"), ("emoji.bin", b"emoji"),
                          ("english_layout.kbpack", b"layout"), ("langdata.bin", b"english"),
                          ("langdata.kbmodern", b"policies"),
                          ("nss-english.nsslm", b"model"), ("safety.kbguard", b"safety"),
                          ("tenglish_guard.bin", b"guard")):
        (root / name).write_bytes(payload)

def audit(root: Path, *flags: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(root), "--output", str(root / "audit.json"), *flags],
        check=False, capture_output=True, text=True,
    )

class ReleaseArtifactVerifierTests(unittest.TestCase):
    def test_recognizes_compiled_and_source_model_containers(self) -> None:
        self.assertTrue(is_neural_artifact("Rescorer.mlmodelc/model.mil"))
        self.assertTrue(is_neural_artifact("Internal.mlpackage/Data/com.apple.CoreML/model.mlmodel"))
        self.assertTrue(is_neural_artifact("artifacts/finetune.pt"))
        self.assertTrue(is_neural_artifact("tokenizer.bin"))
        self.assertTrue(is_neural_artifact("spm.model"))
        self.assertTrue(is_neural_artifact("weights/model.safetensors"))
        self.assertTrue(is_neural_artifact("nss-english.nsslm"))

    def test_allows_normal_keyboard_resources(self) -> None:
        self.assertFalse(is_neural_artifact("langdata.bin"))
        self.assertFalse(is_neural_artifact("emoji.bin"))
        self.assertFalse(is_neural_artifact("english_layout.kbpack"))
        self.assertFalse(is_neural_artifact("demo_keyboard"))

    def test_requires_english_resources_and_word_model(self) -> None:
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            write_bundle(root)
            valid = audit(root, "--allow-neural")
            self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)
            self.assertEqual(json.loads((root / "audit.json").read_text())["gateBytes"], 25_000_000)

            unflagged = audit(root)
            self.assertNotEqual(unflagged.returncode, 0)
            self.assertIn("unapproved neural model", unflagged.stdout + unflagged.stderr)

            for name in ("english_layout.kbpack", "nss-english.nsslm"):
                payload = (root / name).read_bytes()
                (root / name).unlink()
                missing = audit(root, "--allow-neural")
                self.assertNotEqual(missing.returncode, 0)
                self.assertIn(f"{name} is missing", missing.stdout + missing.stderr)
                (root / name).write_bytes(payload)

    def test_language_pack_budget(self) -> None:
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            write_bundle(root)
            with (root / "langdata.bin").open("wb") as handle:
                handle.truncate(10_000_001)
            too_big = audit(root, "--allow-neural")
            self.assertNotEqual(too_big.returncode, 0)
            self.assertIn("langdata.bin exceeds 10,000,000 bytes", too_big.stdout + too_big.stderr)

    def test_rejects_enabled_klipy_without_key_and_filter_review(self) -> None:
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            write_bundle(root)
            with (root / "Info.plist").open("wb") as handle:
                plistlib.dump({"KLIPYMediaEnabled": True, "KLIPYAPIKey": "",
                               "KLIPYContentFilterApproved": False}, handle)
            result = audit(root, "--allow-neural")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("empty API key", result.stdout + result.stderr)
            self.assertIn("Partner Panel", result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
