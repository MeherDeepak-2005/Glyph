#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/kb-native-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
langdata="$repo_root/keyboard/langdata.bin"
model="$repo_root/keyboard/nss-english.nsslm"
# ASan/UBSan catch unsafe accesses and arithmetic in malformed/truncated fixtures.
build() {
  "${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -g \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I "$repo_root/native/tests" "$repo_root/native/DecoderCore/src/"*.cpp \
    "$repo_root/native/tests/$1" -o "$work_dir/$2"
}
build PackedLexiconTests.cpp packed-tests
"$work_dir/packed-tests" "$langdata"

build EngineTests.cpp engine-tests
"$work_dir/engine-tests" "$langdata" "$model" "$repo_root" "$repo_root/tools/evaluation/fixtures/shared-engine"

build NeuralLanguageModelTests.cpp nss-tests
# Tiny random models cover each NSS kernel; the trained model too.
for fixture in "$repo_root/native/tests/fixtures/nss/"*.nsslm "$model"; do
  [ -f "$fixture" ] || continue
  "$work_dir/nss-tests" "$fixture" "${fixture%.nsslm}.goldens.json" "$langdata"
done

build NeuralFstTests.cpp nss-fst-tests
"$work_dir/nss-fst-tests" "$model" "$langdata"

build RawDecoderTests.cpp raw-decoder-tests
"$work_dir/raw-decoder-tests" "$model" "$langdata"

build ModernVocabularyTests.cpp modern-vocabulary-tests
"$work_dir/modern-vocabulary-tests" "$langdata" "${langdata%.bin}.kbmodern" "$model"
