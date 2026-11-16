#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/../../.." && pwd)"
device="$1"; name="$2"; shift 2
corpora=("$@"); [ ${#corpora[@]} -gt 0 ] || corpora=(cases.taps.tsv ext-cases.taps.tsv keep-cases.taps.tsv keystrokes.tsv)
app=com.meherdeepak.glyph; derived="${DERIVED:-$repo/tmp/device-bench-derived}"
copy() { xcrun devicectl device copy "$@" --device "$device" --domain-type appDataContainer --domain-identifier "$app" >/dev/null; }
xcodebuild -project "$repo/keyboard.xcodeproj" -scheme keyboard -configuration Debug \
  -destination "id=$device" -derivedDataPath "$derived" -allowProvisioningUpdates \
  GCC_OPTIMIZATION_LEVEL=s build-for-testing -quiet
xcrun devicectl device install app --device "$device" "$derived/Build/Products/Debug-iphoneos/keyboard.app" >/dev/null
for f in "$repo/keyboard/langdata.bin" "$repo/keyboard/safety.kbguard" "$repo/keyboard/nss-english.nsslm"; do copy to --source "$f" --destination "Documents/bench/in/$(basename "$f")"; done
for c in "${corpora[@]}"; do copy to --source "$here/corpus/$c" --destination "Documents/bench/in/$c"; done
xcodebuild -project "$repo/keyboard.xcodeproj" -scheme keyboard -configuration Debug \
  -destination "id=$device" -derivedDataPath "$derived" GCC_OPTIMIZATION_LEVEL=s \
  test-without-building -only-testing:keyboardTests/DeviceBenchmark 2>&1 | grep -E "device-bench|error:|Test Case|Restarting" || true
for c in "${corpora[@]}"; do
  stem="${c%.tsv}"
  case "$stem" in cases*) out="$name.jsonl";; keystrokes) out="$name-keys.jsonl";; *) out="$name.${stem%%-*}.jsonl";; esac
  copy from --source "Documents/bench/out/$stem.jsonl" --destination "$here/results/$out"
  echo "$here/results/$out"
done
