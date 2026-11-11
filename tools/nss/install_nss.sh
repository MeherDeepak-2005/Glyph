#!/bin/sh
set -eu

# Word-level neural search space LM (tools/nss): the English decoder's only language
# model, bundled in every build unless NSS_ENABLED=NO (Config/Extension.xcconfig).
# KeyboardEngine.shared maps it at startup.
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ "${NSS_ENABLED:-YES}" != "YES" ]; then
    # An ordinary build may reuse a directory from an earlier internal build.
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
# cp writes the declared output in place; ditto stages a temp file the script sandbox denies.
cp -f "$model" "${resources}/nss-english.nsslm"
echo "note: installed the NSS word model ($(wc -c < "$model" | tr -d ' ') bytes)"
