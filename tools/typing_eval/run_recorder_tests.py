#!/usr/bin/env python3
"""Compile and run the production typing recorder on macOS, without the Simulator."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='typing-recorder-') as temp:
    executable = Path(temp) / 'tests'
    storage = Path(temp) / 'storage'
    storage.mkdir()
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(Path(temp) / 'cache'),
                    str(root / 'keyboard/Shared/KBTypingRecorder.swift'),
                    str(root / 'tools/typing_eval/test_recorder.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(storage)], check=True)
