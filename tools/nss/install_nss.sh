#!/bin/sh
set -eu

resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ "${NSS_ENABLED:-YES}" != "YES" ]; then
    rm -f "${resources}/nss-english.nsslm"
    echo "warning: NSS word model not bundled (NSS_ENABLED=NO); the English decoder needs it"
    exit 0
fi

model="${NSS_MODEL:-}"
if [ -z "$model" ] || [ ! -f "$model" ]; then
    echo "error: NSS_MODEL does not name an .nsslm file; the English decoder has no other language model"
    exit 1
fi

mkdir -p "$resources"
cp -f "$model" "${resources}/nss-english.nsslm"
echo "note: installed the NSS word model ($(wc -c < "$model" | tr -d ' ') bytes)"
