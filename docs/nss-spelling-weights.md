# NSS spelling weight experiments, 22 November 2026

Two weight edits improved autocorrect on the project's held real-misspelling benchmark. Both remain experimental. The native decoder, dictionary, product rules and commit thresholds were identical within each comparison.

## Model edits

Both programs use the existing NSS checkpoint, Claude’s NumPy model reader and Claude’s long-word prior of 0.4 per letter beyond seven. The experiment adapts the upstream method of writing interpretable weight changes and evaluating them on a tuning split. [Weight-space programming repository](https://github.com/csinva/weight-space-programming-autoresearch)

- **Spelling** changes 17,400 output biases. It adds weight for adjacent vowels and doubled letters and gives some contractions a bonus when their apostrophe-free form is absent from the ledger. All bonuses taper to zero at 100 occurrences per million. Trials on the tuning split included a dictionary-to-training frequency adjustment, broader contraction bonuses and changes to the start-token embedding. The retained formula scored 49.99 versus 48.43 with rules off and 70.96 versus 70.52 with rules on, with equal tune next-word accuracy.
- **Isolated words** changes 3,293 output biases. It adds up to 2 to long words with no other emittable dictionary word within one insertion, deletion, substitution or adjacent transposition. This follow-up was designed after the first candidate’s held false-correction result. Its scores on the same held cases are exploratory.

The input model SHA-256 starts with `d1cecea11a18`. Both outputs are 3,922,400 bytes and regenerate byte-for-byte. From the repository root, run either command with Python 3.11 and NumPy.

```sh
python3.11 tools/nss/wsp/spelling_prior.py keyboard/nss-english.nsslm /tmp/wsp-spelling.nsslm
python3.11 tools/nss/wsp/isolated_prior.py keyboard/nss-english.nsslm /tmp/wsp-isolated.nsslm
```

## Native benchmarks

Each checkpoint went through Claude’s full `performance_tests.py` twice, once in the tuning build with `KB_nssRules=0` and once in the release build with production defaults. All six runs used the same source and corpus snapshot, copied to a private experiment directory. The paired percentages below come from the runs’ JSONL records. An asterisk on a candidate marks a difference from the shipped model with exact paired McNemar p < 0.05. Significance is per metric.

| Metric | Cases | Raw shipped | Raw spelling | Raw isolated | Production shipped | Production spelling | Production isolated |
|---|---:|---:|---:|---:|---:|---:|---:|
| ECPS real misspellings fixed | 9622 | 75.81% | 78.52%* | 76.54%* | 90.63% | 91.03%* | 90.80%* |
| ECPS target in top 3 | 9622 | 91.78% | 91.50%* | 91.66%* | 95.58% | 95.48% | 95.57% |
| ECPS left uncorrected ↓ | 9622 | 12.99% | 10.34%* | 12.34%* | 2.69% | 2.35%* | 2.63%* |
| ext_aspell fixed | 237 | 25.32% | 28.69%* | 25.32% | 53.16% | 55.70%* | 54.01% |
| ext_birkbeck fixed | 15136 | 16.42% | 18.54%* | 17.10%* | 32.56% | 34.86%* | 33.25%* |
| ext_holbrook fixed | 450 | 32.67% | 32.67% | 32.67% | 43.78% | 44.00% | 43.78% |
| ext_wikipedia fixed | 1100 | 46.82% | 53.18%* | 48.27%* | 81.55% | 82.36%* | 81.64% |
| ext_birkbeck in top 3 | 15136 | 45.98% | 47.26%* | 46.49%* | 55.79% | 56.86%* | 56.14%* |
| ext_wikipedia in top 3 | 1100 | 85.09% | 85.36% | 85.00% | 91.09% | 91.00% | 91.09% |
| Synthetic typos fixed | 5606 | 90.78% | 91.47%* | 90.88% | 91.92% | 92.10%* | 91.96% |
| Synthetic target in top 3 | 5606 | 97.02% | 96.77%* | 96.91%* | 96.56% | 96.22%* | 96.49% |
| Contractions restored in sentences | 3493 | 44.86% | 44.86% | 44.86% | 85.23% | 85.20% | 85.23% |
| GUARD contractions restored | 80 | 73.75% | 75.00% | 72.50% | 96.25% | 96.25% | 96.25% |
| GUARD plain word changed in sentences ↓ | 1335 | 8.76% | 8.76% | 8.76% | 10.49% | 10.49% | 10.49% |
| GUARD false corrections, ECPS correct ↓ | 9522 | 0.64% | 0.64% | 0.64% | 0.48% | 0.58%* | 0.49% |
| GUARD false corrections, MacKenzie clean ↓ | 1083 | 0.09% | 0.09% | 0.09% | 0.65% | 0.65% | 0.65% |
| GUARD hard valid words changed ↓ | 95 | 10.53% | 10.53% | 10.53% | 11.58% | 11.58% | 11.58% |
| GUARD unknown names changed ↓ | 292 | 36.99% | 36.99% | 36.99% | 49.32% | 49.32% | 49.66% |
| GUARD rare dictionary words changed ↓ | 1457 | 7.62% | 8.17%* | 7.69% | 11.12% | 11.74%* | 11.19% |
| GUARD Tenglish words changed ↓ | 870 | 9.89% | 9.89% | 9.89% | 12.76% | 13.10% | 12.76% |
| GUARD correct plurals stripped ↓ | 1236 | 0.00% | 0.00% | 0.00% | 0.08% | 0.16% | 0.08% |
| GUARD real-word errors fixed | 708 | 56.36% | 56.50% | 56.36% | 57.49% | 57.49% | 57.49% |

## Prediction and independent checks

| Check | Shipped | Spelling | Isolated |
|---|---:|---:|---:|
| Held next word in top 3, native decoder, 1,083 cases | 20.31% | 19.67% | 19.76% |
| Keystroke savings on those cases | 49.67% | 49.37% | 49.23% |
| Tatoeba / WikiText / MASC test word perplexity, lower is better | 66.0 / 162.2 / 283.2 | 71.9 / 187.3 / 317.3 | 67.0 / 165.8 / 288.2 |
| Release decode latency p50 / p95 / p99, ms | 7.08 / 9.12 / 10.16 | 7.20 / 9.39 / 10.13 | 7.11 / 9.11 / 10.27 |
| Independently generated typos fixed, out of 1,200 | 1,104 | 1,112 | 1,104 |
| Clean counterparts preserved, out of 1,200 | 1,197 | 1,193 | 1,197 |

Latency was measured on this Mac with all other study decodes finished. Each model ran twice over the same 500 held ECPS words in forward and reverse model order.

The independent check used 400 distinct words from each of the three NSS test corpora, excluded targets in the autocorrect benchmark, and retained words of six or more letters. It alternated single deletions and adjacent transpositions, supplied up to six preceding words, and ran the release decoder without touch samples. This measures a narrower task than ordinary keyboard use.

Both edited models passed the native language-model parity test on all 220 reference scores against regenerated goldens. Claude’s original seven-test WSP suite passed six checks. Its original broad length/apostrophe checkpoint failed the next-word guardrail assertion. The spelling checkpoint and the shipped checkpoint tied on the shared fixtures at 115/132 committed typing targets and 44/60 glide top-one targets.

## Decision

Keep the shipped checkpoint as the app default. The spelling candidate recovered a net 261 more real misspellings in raw mode and 39 more with production rules. It also changed eight additional correct rare words in raw mode. With production rules it changed nine additional correct ECPS words and nine additional correct rare words. Both production false-correction increases were significant. The isolated candidate gave back much of the autocorrect gain and lost six held next-word hits with zero gains (p = 0.031). The spelling candidate gained two next-word hits and lost nine (p = 0.065).

### Default eligibility audit

A freshly compiled release decoder replayed all 12,062 held cases from the three decisive checks for the shipped model and each candidate. Corrections, suggestion lists, next-word ranks and keystroke counts matched the archived outputs wherever those fields were recorded. The project's scorer fails a guardrail when the paired result gets worse with McNemar p < 0.05.

| Candidate | Failed production check | Shipped → candidate | Cases worsened / improved | Exact paired p |
|---|---|---:|---:|---:|
| Spelling | Correct ECPS words changed | 46 → 55 of 9,522 | 9 / 0 | 0.00391 |
| Spelling | Correct rare dictionary words changed | 162 → 171 of 1,457 | 9 / 0 | 0.00391 |
| Isolated | Intended next word in the top three | 220 → 214 of 1,083 | 6 / 0 | 0.03125 |

For example, the spelling candidate changed *announcers* to *announcer* and *appearance* to *appearances* on inputs the shipped model preserved. Neither candidate qualifies as the default under these checks.

## Reproduction

The paired benchmark records are in the local ignored directory `tools/evaluation/autocorrect/results/performance-tests/`. The following commands print every benchmark metric with its paired significance test. The `wsp-spelling-study/` subdirectory contains the run reports, tuning scores, independent inputs and secondary-check outputs.

```sh
cd tools/nss/wsp
python3.11 official.py wsp-study-raw-base wsp-study-raw-spelling wsp-study-raw-isolated
python3.11 official.py wsp-study-release-base wsp-study-release-spelling wsp-study-release-isolated
```
