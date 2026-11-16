#!/usr/bin/env python3
"""Audit a built keyboard extension and emit a reproducible size manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
from pathlib import Path

LANGDATA_CAP = 10_000_000
NO_NEURAL_EXTENSION_CAP = 14_000_000
NEURAL_EXTENSION_CAP = 25_000_000
NEURAL_CONTAINER_SUFFIXES = (
    ".mlmodelc", ".mlpackage", ".mlmodel", ".pt", ".pth", ".ckpt",
    ".safetensors", ".onnx", ".tflite", ".nsslm",
)
NEURAL_RESOURCE_NAMES = {
    "tokenizer.bin", "tokenizer.json", "tokenizer.model",
    "spm.model", "spm.vocab", "sentencepiece.model", "pytorch_model.bin",
}
REQUIRED_RELEASE_RESOURCES = {
    "emoji.bin", "english_layout.kbpack", "langdata.bin", "langdata.kbmodern", "nss-english.nsslm",
    "safety.kbguard",
}
RESOURCE_CAPS = {"langdata.bin": LANGDATA_CAP}

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

def is_neural_artifact(relative_path: str) -> bool:
    parts = tuple(part.lower() for part in Path(relative_path).parts)
    return any(part.endswith(NEURAL_CONTAINER_SUFFIXES) for part in parts) \
        or bool(parts and parts[-1] in NEURAL_RESOURCE_NAMES)

def plist_bool(value) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in {"1", "yes", "true"}

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("appex", type=Path)
    parser.add_argument("--output", type=Path, default=Path("BuildArtifactManifest.json"))
    parser.add_argument("--allow-neural", action="store_true")
    args = parser.parse_args()
    if not args.appex.is_dir():
        raise SystemExit(f"extension bundle not found: {args.appex}")

    files = sorted(path for path in args.appex.rglob("*") if path.is_file())
    records = [{
        "path": str(path.relative_to(args.appex)),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    } for path in files]
    total = sum(record["bytes"] for record in records)
    by_name = {Path(record["path"]).name: record for record in records}
    neural = [record for record in records if is_neural_artifact(record["path"])]
    cap = NEURAL_EXTENSION_CAP if args.allow_neural else NO_NEURAL_EXTENSION_CAP
    failures = []
    for name in sorted(REQUIRED_RELEASE_RESOURCES - set(by_name)):
        failures.append(f"{name} is missing")
    for name, byte_cap in RESOURCE_CAPS.items():
        record = by_name.get(name)
        if record is not None and record["bytes"] > byte_cap:
            failures.append(f"{name} exceeds {byte_cap:,} bytes")

    if neural and not args.allow_neural:
        failures.append("Release contains an unapproved neural model/tokenizer")

    info_path = args.appex / "Info.plist"
    if info_path.exists():
        try:
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            if plist_bool(info.get("KLIPYMediaEnabled")):
                key = str(info.get("KLIPYAPIKey") or "").strip()
                if not key or "$(" in key:
                    failures.append("KLIPY media is enabled with an empty API key")
                if not plist_bool(info.get("KLIPYContentFilterApproved")):
                    failures.append("KLIPY media is enabled without approved Partner Panel filtering")
        except (OSError, plistlib.InvalidFileException) as error:
            failures.append(f"invalid extension Info.plist: {error}")
    if total > cap:
        failures.append(f"extension is {total:,} bytes; cap is {cap:,}")

    manifest = {
        "schemaVersion": 1,
        "bundle": args.appex.name,
        "totalBytes": total,
        "gateBytes": cap,
        "neuralArtifactsAllowed": args.allow_neural,
        "gatePassed": not failures,
        "failures": failures,
        "files": records,
    }
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"extension: {total:,} / {cap:,} bytes")
    print(f"manifest: {args.output}")
    if failures:
        raise SystemExit("release artifact verification failed: " + "; ".join(failures))

if __name__ == "__main__":
    main()
