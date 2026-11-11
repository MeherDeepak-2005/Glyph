> Historical implementation report. Production NSS now selects the broader unigram-only pack; phrase boosts are disabled in NSS-only mode. See [current work](../unigram-v1/README.md).

# Modern English vocabulary implementation — 9 November 2026

The bundled dictionary now has 114,288 forms, five more than the starting pack.
The 400-entry catalog consolidates existing curated sources and an editorial review
of modern, regional and everyday forms. It does not represent 400 new words or
independent native-speaker certification.

## Behavior

60 slang/texting spellings are protected on commit and excluded as automatic
replacement targets. Prefix completions and manual typo choices remain available.
Ordinary words with casual senses (ate, cooked, based, mid, slay, aura) retain their
ordinary correction permissions. 50 original phrase contexts supplement both neural
and n-gram suggestions, capped at eight retrieved continuations. Ambiguous contexts
such as "that's no" require two preceding words. Display scores never enter automatic
correction scores. Empty-context starter suggestions receive no modern additions.

New spellings: brainrot, jugaad, pookie, ragebait, skibidi.
Sources and editorial decisions are in the catalog; no external definitions/examples
were copied. Independent regional review is still pending.

## Artifact and compatibility

KBLM remains v6. All 114,283 previous spellings, frequencies, bigram/trigram
counts, denominators and starters are preserved by logical word identity.
Numeric IDs and trie nodes are rebuilt together. Dictionary growth is 299 bytes;
the KBMODERN sidecar is 1,368 bytes: total growth **1,667 bytes**.

The sidecar contains a 56-byte header (magic, version, dictionary word count, policy
count, context count, dictionary SHA-256), sorted 8-byte policy rows, 16-byte context
rows and a 32-byte SHA-256 footer over its preceding bytes. IDs refer to the paired
dictionary. Invalid, missing, mismatched or corrupted metadata falls back to existing
behavior. Load it before publishing the immutable dictionary to decoder queues.
All normal/neural/raw decoding paths apply protection and display rules.

Neural weights and model vocabulary are unchanged. Five words add 2,505 fallback
unigram mass. Pack-dependent test references were updated: 127 shared-engine numeric
records changed, with zero visible suggestion/correction changes before sidecar loading.
Neural fallback mass/count goldens reflect the five additions; neural-score reference
drift is below the existing 0.002 tolerance.

## Validation

- 12 portable native suites passed, including 308 modern-policy decode checks across
  normal/neural/raw modes, corruption/mismatch rejection, cancellation, reset,
  backspace-style prefix changes and safety filtering.
- 20 Python tests passed, including deterministic rebuilding and catalog exports.
- The Swift-facing policy API typechecks against the iPhoneOS SDK.
- The standard dictionary build reproduces both bundled artifacts byte-for-byte.
- 1,047 original synthetic regression cases, split by target or phrase context into
  development and held subsets before evaluation.
- All 240 protected spelling cases pass in both tiers (previously 208 n-gram, 217 NSS).
- Completion/typo suggestion success: 155 → 176 / 200 n-gram; 105 → 139 / 200 NSS.
- Phrase continuation success: 8 → 200 / 200 n-gram; 4 → 200 / 200 NSS.
  These cases deliberately exercise the authored table and are **not independent
  natural-message accuracy measurements**. No population-quality claim is made.
- 59,062 existing main cases, 9,712 contraction cases, 33,503 external spelling cases
  and 3,578 keep-input cases compared. Clean-word false corrections and contraction
  outcomes are unchanged. Main typo successes move 17,834 → 17,831; external Birkbeck
  successes move 12,335 → 12,336. Detailed deltas are retained.
- Physical-iPhone p95 latency/peak-memory gate (≤5% increase), simulator UI parity,
  commit punctuation/UI flows and signed full-extension release validation remain
  pending. CoreSimulator is unavailable and the full iOS build encounters an
  environment-level SwiftUI macro-server failure. No release-readiness claim is made.

See build.json, preservation.json, behavior-results.json, guardrail-summary.json,
guardrail-deltas.json and validation-status.json for evidence.

## Reproduction and maintenance

Edit modern_catalog.json and modern_contexts.json, then run:

    python3 -B tools/vocabulary/build_modern.py --export-legacy
    python3 -B tools/build_language_data.py --output /tmp/candidate.bin
    python3 -B -m unittest tools.vocabulary.test_modern
    cmake -S native -B /tmp/keyboard-native -DCMAKE_BUILD_TYPE=Release
    cmake --build /tmp/keyboard-native
    ctest --test-dir /tmp/keyboard-native --output-on-failure

The ordinary builder includes the modern layer after rebuilding legacy evidence.
Legacy TSVs are generated compatibility exports, not independent sources of truth.
After changes, update their project-input hashes in the expansion manifest and
update ARTIFACTS.json with both pack and sidecar hashes. Commit/release the pair
atomically. Existing distribution rights and safety policy remain applicable.

A monthly editorial review should lower stale display priorities while preserving
recognition. No automation, casual-mode setting, broad Hinglish support or model
retraining was added.

Rollback: restore the previous dictionary and remove the new sidecar (or restore its
matching predecessor). The baseline dictionary SHA-256 is
9db0760697014aecdf540d1828cd523156bcf87a2ed04f2afaa724ac24cd8ea6.
It remains available in repository history and was saved under
/private/tmp/keyboard-modern-v1/baseline.bin during validation. Never mix sidecar
IDs from different packs.
