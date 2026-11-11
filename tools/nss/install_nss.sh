#!/bin/sh
set -eu

# Production English is CIFG NSS + unigram only. Research n-gram runs use the host
# benchmark; missing inputs must fail the build instead of shipping a fallback.
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ "${NSS_ENABLED:-YES}" != "YES" ]; then
    echo "error: NSS is required for the English extension"
    exit 1
fi
model="${NSS_MODEL:-}"
dictionary_dir="${NSS_DICTIONARY_DIR:-${SRCROOT}/tools/data/nss/unigram-v1}"
if [ -z "$model" ] || [ ! -f "$model" ]; then
    echo "error: NSS_MODEL must name the paired CIFG model"
    exit 1
fi
if [ ! -f "${dictionary_dir}/bundle.sha256" ] || [ ! -f "${dictionary_dir}/model.sha256" ]; then
    echo "error: missing generated unigram checksums; run tools/vocabulary/build_unigram.py"
    exit 1
fi
(cd "$dictionary_dir" && /usr/bin/shasum -a 256 -c bundle.sha256)
expected_model=$(cat "${dictionary_dir}/model.sha256")
actual_model=$(/usr/bin/shasum -a 256 "$model" | /usr/bin/awk '{print $1}')
if [ "$actual_model" != "$expected_model" ]; then
    echo "error: CIFG model does not match the unigram build manifest"
    exit 1
fi
mkdir -p "$resources"
# These are declared Xcode outputs, with no duplicate Copy Resources owner.
cp -f "$model" "${resources}/nss-english.nsslm"
cp -f "${dictionary_dir}/english-unigram.bin" "${resources}/langdata.bin"
cp -f "${dictionary_dir}/english-unigram.kbmodern" "${resources}/langdata.kbmodern"
echo "note: installed paired CIFG model, unigram dictionary, and preservation policy"
