#!/usr/bin/env python3
"""Compile and run the production Foundation recorder on macOS without Simulator."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='typing-recorder-') as temp:
    executable = Path(temp) / 'tests'
    storage = Path(temp) / 'storage'
    storage.mkdir()
    # Compile the actual production host-edit plan, without unrelated language-pack dependencies.
    source = (root / 'keyboard/Engine/TeluguComposer.swift').read_text()
    host_plan = Path(temp) / 'HostEdit.swift'
    host_plan.write_text(source.split('/// Validates Telugu scalar transitions')[0])
    diagnostics = (root / 'keyboard/Shared/KBDiagnostics.swift').read_text()
    probe = diagnostics[diagnostics.index('static func cpuUsagePercent()'):diagnostics.index('// MARK: Extension side')]
    cpu_source = Path(temp) / 'CPUProbe.swift'
    cpu_source.write_text('import Foundation\nimport Darwin\nenum CPUProbe {\n' + probe + '\n}\n')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(Path(temp) / 'cache'),
                    str(root / 'keyboard/Shared/KBTypingRecorder.swift'),
                    str(root / 'tools/typing_eval/test_recorder.swift'),
                    str(root / 'tools/typing_eval/test_host_edits.swift'), str(host_plan),
                    str(root / 'tools/typing_eval/test_cpu_probe.swift'), str(cpu_source), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(storage)], check=True)
