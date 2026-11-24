# Research data: from the testers' phones to tables

The beta's opt-in Typing Research (app: Privacy › Typing Research) records typing and Glide in
the keyboard extension and uploads it from the app. Format: [docs/typing-recorder.md](../../docs/typing-recorder.md).

```
keyboard extension ── events ──▶ App Group: typing-recordings/current.jsonl
                                            └─ sealed at 1 MiB ─▶ outbox/<time>-<id>.jsonl
app (opened, left, practice done, background refresh)
   └─ each chunk: zlib ▶ HPKE to the research public key ▶ CloudKit public DB, record TypingChunk
you
   └─ pull.py ▶ chunks.swift open ▶ build_datasets.py ▶ tables
```

## One-time setup

1. **Keys.** `swift tools/research/chunks.swift keys` was run once: the public key is
   `keyboard/App/research-public-key.txt` (in git, bundled with the app); the private key is
   `Config/research-private-key.txt` (**not** in git). Back the private key up somewhere safe.
   Without it no uploaded chunk can be read; anyone who has it can read every tester's typing.
2. **CloudKit container.** In Xcode, target `keyboard` › Signing & Capabilities › iCloud: tick
   CloudKit and the container `iCloud.com.keypointtech.glyph` (create it if it is not listed).
   The entitlements file already names it.
3. **Schema.** Import `cloudkit-schema.ckdb` into the Development environment (CloudKit Console ›
   Schema › Import, or `xcrun cktool import-schema`), run a Debug build once and upload a chunk
   to check it, then **Deploy Schema Changes to Production**. TestFlight builds use Production:
   without the deployed schema every upload fails.
4. **Reading.** Chunks are world-readable ciphertext; only the private key opens them. To download
   in bulk, create a server-to-server key (CloudKit Console › Tokens & Keys) for `pull.py`.

## Routine

```sh
python3 tools/research/pull.py --key-id KEY_ID --key-file eckey.pem --out ~/glyph-research
swift tools/research/chunks.swift open Config/research-private-key.txt ~/glyph-research/opened ~/glyph-research/sealed/*.grc
python3 tools/research/build_datasets.py ~/glyph-research/opened ~/glyph-research/tables
```

A tester's shared export (`export.jsonl`) is already plain: put it in the `opened` folder.
`build_datasets.py --help` lists the tables; `glides.jsonl` + `layouts.jsonl` are the Glide
training set, `autocorrect.tsv` the correction/undo study, `words.tsv` every tapped word with its
candidates and whether the user kept it or backspaced it (and what they typed instead), `word_frequency.tsv` and
`oov_words.tsv` the vocabulary.

## Tests

```sh
python3 -m unittest tools/research/test_build_datasets.py
python3 tools/typing_eval/run_recorder_tests.py     # the recorder itself, compiled for macOS
```

`pull.py` has not been run against a live container yet (it needs the container and a
server-to-server key); `chunks.swift` and `build_datasets.py` are tested.

## Keep the data safe

These files are other people's messages. Keep the opened chunks and tables off shared drives and
out of git, and delete a tester's data when they ask (their nickname or install ID is in each
chunk's header; delete their `TypingChunk` records in the CloudKit Console).
