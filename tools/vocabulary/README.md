# English vocabulary expansion

This offline pipeline extends `keyboard/langdata.bin` (KBLM v7: the words, their
unigram frequencies and the spelling trie). English tap decoding, completions, Glide
and the NSS word model's lexicon fallback see the same expanded vocabulary. No network
download happens inside the keyboard. Personal learning, decoder thresholds and neural
artifacts are unchanged.

## Rebuild the committed pack

Use Python 3.12 or newer. From the repository root:

```sh
python3 -B tools/build_language_data.py
python3 -B -m unittest tools/test_build_language_data.py tools/vocabulary/test_pipeline.py
```

The builder verifies the committed compressed snapshots, manifest and curated
inputs, then writes the pack atomically. Its existing pinned FrequencyWords cache
may need downloading on a fresh machine. Use `--output /existing/folder/candidate.bin`
to build a candidate first; the default builds the 114,283-word full CoreV4 union.
`tools/verify_language_data.py keyboard/langdata.bin candidate.bin` checks that two
packs hold the same vocabulary, frequencies and trie (it also reads the v4-v6 packs in
the git history).

## Recreate source snapshots

```sh
python3 -B tools/vocabulary/fetch_sources.py
python3 -B tools/vocabulary/import_sources.py
python3 -B tools/build_language_data.py --output /tmp/candidate-english.bin
```

Fetching verifies SHA-256 hashes, streams to temporary files and never overwrites a
mismatched source. The importer runs the pinned ESDB source's database builder in an
isolated temporary directory and removes that directory when finished. Expect about
35 MB of compressed downloads; transfer time varies by connection, and source
preparation takes approximately a minute on this development machine. The pinned
upstream URLs and terms are in `fetch_sources.py` and the snapshot manifest.

Review `curated_terms.tsv` and the selected snapshot before shipping. Curated weights
are explicitly **editorial priors**, not empirical counts or native-speaker
certification. Changing the curated file requires regenerating snapshots. Update the
English entry in `ARTIFACTS.json`, its checksums and the exact word-count regression
expectation after accepting a newly generated pack. Preserve historical
benchmark/audit evidence under a different filename.

## Admission policy

- Preserve every baseline surface form and unigram weight.
- Admit at most 4,000 additional forms, without filling slots just to meet a quota.
- Automatically admit lowercased, ASCII, 3–32-character ESDB/WordNet forms only with
  independent usage evidence. ESDB size-60 forms need at least 100 FrequencyWords
  occurrences; other forms need 500, or five MASC training occurrences across three
  documents. Cap new automatic unigram priors at 20,000.
- Curated 2–32-character ASCII forms use explicit weights of 1–5,000. Do not strip
  accents, punctuation or digits to invent alternative word forms. Existing
  intentional exclusions (`dont`, `im`, `youre`, `cant`) stay excluded.
- Export US, British `-ise` and `-ize`, Canadian and Australian ESDB size-60/70 forms.
  ESDB `--nosuggest` flags, uppercase source-only names and unsupported forms are not
  automatically admitted. Name priorities remain small and explicit.
- Split MASC by hashed document family before vocabulary selection or counting.
  De-duplicate identical token sequences across splits. This is not an author-held-out
  evaluation; the text-only input lacks reliable author metadata.
- URLs, digit/Unicode/compound tokens, lines and documents create hard boundaries.
  Never delete an unsupported token and join the remaining neighbours.
- MASC training counts are admission evidence only. Held-out text is **not** a
  runtime pack resource.
- Regenerate all numeric IDs, retain frequency ordering, and reject packs above
  8,000,000 bytes (`LANGDATA_CAP`).

Existing runtime safety filtering remains authoritative. This phase does not add
locale/register-specific runtime ranking or promise tone awareness; provenance
metadata is offline. Additional vocabulary can create competing correction candidates,
so regression checks are required after every accepted snapshot.

## Validation and cleanup

Membership and frequency checks are not decoder recall. After accepting a snapshot,
run the decoder tests (`native/tests`), the autocorrect benchmark
(`tools/evaluation/autocorrect`) and the iOS tests, including all five contexts of
`coeevitjkn → correction`; physical iPhone latency and RAM remain separate acceptance
measurements.

After preserving evidence:

```sh
python3 -B tools/vocabulary/fetch_sources.py --cleanup
```

Cleanup removes only recognized, hash-matched download files and an empty download
cache. It refuses to remove edited files or unrelated files. Keep the small committed
snapshots, curated inputs, copyright notice and manifests: they are required for
reproducibility. Temporary candidate packs can be removed after validation.

## Deferred sources and capabilities

COCA/GloWbE embedded commercial rights, NUS SMS terms and BNC2014 research-only terms
have not been cleared and are excluded. Kaikki, wordfreq, Gutenberg, PMC and GeoNames
remain optional adapters needing their own filtering/attribution and evaluation.
The full research report is `ENGLISH_VOCABULARY_COVERAGE_REPORT.md`.
Accented, hyphenated, digit-bearing and single-letter texting forms require a separate
English tokenization/display policy; this expansion does not silently rewrite them.

Check the **complete arm64 iPhone extension**, not just the dictionary, using
`tools/verify_release_artifacts.py /path/to/demo_keyboard.appex --allow-neural --output /tmp/bundle-audit.json`.
Its budgets are 8,000,000 bytes for the language pack and 25,000,000 bytes for the
extension with the NSS word model. A universal simulator executable includes x86_64
and arm64 and is not the iPhone shipping-size measurement. Final signing and
provisioning can add bytes; verify the distribution archive as well.

## CoreV4 English union

Original dictionaries and their matching context files live in
`tools/data/corev4/english/raw`; checksummed extracted stored spellings and
provenance are beside them. They are offline inputs; only the rebuilt
`keyboard/langdata.bin` is bundled, and it takes the stored spellings only. New forms
have prior 1, existing frequencies are retained, and `cant`, `im`, `lets`, `wont`
remain excluded by the existing contraction policy. Original copies retain those
forms. Accented/punctuated forms are admitted for exact membership; this does not add
new input normalization or geometric typing rules. Full procedures and limits:
`docs/corev4-import/IMPORT-RESULTS.txt`.

```sh
python3 tools/vocabulary/verify_corev4_import.py
```

## Neural search space vocabulary

The NSS model predicts over a fixed word vocabulary, like Gboard's 30k-word NSS
model; lexicon words outside it are scored as P(`<unk>`|context) × unigram
probability. Without federated counting, `build_nss_vocab.py` ranks the emittable
`[a-z']` words of `keyboard/langdata.bin` by a register-weighted mix of
FrequencyWords (0.45), an optional messaging corpus (0.20), Tatoeba (0.20) and
WikiText-103 (0.15) — a weighted geometric mean, so one corpus's spike such as
Tatoeba's "tom" cannot dominate — keeps words seen in at least two sources (or frequent in
conversation), always keeps a short forced list (contractions, numbers, days,
months, chat forms, plus any `--include` list for terms the pinned 2016–2020
corpora predate, such as "covid"), and writes the top 30,000 after four special
tokens.

```sh
python3 -B tools/vocabulary/build_nss_vocab.py                  # all pinned sources
python3 -B tools/vocabulary/build_nss_vocab.py --chat chat.txt  # add a messaging corpus
python3 -B -m unittest tools/vocabulary/test_build_nss_vocab.py
```

Outputs land in `tools/data/nss/`: the vocabulary TSV, a manifest with input
hashes, weights and coverage (per source and on the MASC held-out split), and a
review file listing the cutoff band and rule-admitted words. A model export must
record the vocabulary SHA-256; the vocabulary and the output layer are a pair.
