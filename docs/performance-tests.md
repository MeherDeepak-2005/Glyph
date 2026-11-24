# Performance tests

"Performance tests" is the name for the keyboard's accuracy and latency benchmark:
`tools/evaluation/autocorrect/performance_tests.py`. It decodes the benchmark's held half
(ECPS real misspellings, MacKenzie synthetic typos, the Aspell/Birkbeck/Holbrook/Wikipedia
misspelling lists, contractions in sentences, and the guardrail sets) on every core, measures
typing latency, and scores prod against two fixed references: the dev branch's n-gram setup
(1 Nov 2026) and CoreV4 (14 Nov 2026, with engxx.abn). Results and reports are in
`tools/evaluation/autocorrect/results/performance-tests/` (git-ignored).

```
cd tools/evaluation/autocorrect
python3 performance_tests.py                       # prod as the app ships it
python3 performance_tests.py --env KB_nssRules=0   # the neural engine alone (see docs/nss-rules.md)
python3 performance_tests.py report prod-<stamp>   # re-score a stored run
```

## Latest standing (prod-2026-11-16-0415)

Held half; prod = `prod-2026-11-16-0415` (taps where a set has them), Dev (n-gram) = dev branch n-gram tier with its rules (`dev-ngram-2026-11-01`, taps), CoreV4 = iOS harness with engxx.abn (`corev4-engxx-2026-11-14`, no taps). Each row is scored on the cases every listed system decoded. Δ = prod minus that system, in points; * = paired McNemar p < 0.05; ↓ = lower is better.

### Real misspellings

| Metric | n | Prod (NSS) | Dev (n-gram) | CoreV4 | Δ vs Dev | Δ vs CoreV4 |
|---|---|---|---|---|---|---|
| ECPS real misspellings fixed | 9622 | 90.63% | 90.69% | 89.77% | -0.06 | +0.85* |
| ECPS target in top 3 | 9622 | 95.58% | 95.04% | 95.27% | +0.54* | +0.31 |
| ECPS left uncorrected ↓ | 9622 | 2.69% | 2.34% | 0.78% | +0.35* | +1.91* |

### External misspelling lists

| Metric | n | Prod (NSS) | Dev (n-gram) | CoreV4 | Δ vs Dev | Δ vs CoreV4 |
|---|---|---|---|---|---|---|
| ext_aspell fixed | 237 | 53.16% | 58.23% | 57.38% | -5.06 | -4.22 |
| ext_birkbeck fixed | 15136 | 32.56% | 42.63% | 41.20% | -10.08* | -8.64* |
| ext_holbrook fixed | 450 | 43.78% | 48.67% | 44.44% | -4.89* | -0.67 |
| ext_wikipedia fixed | 1100 | 81.55% | 80.64% | 85.45% | +0.91 | -3.91* |
| ext_birkbeck in top 3 | 15136 | 55.79% | 60.78% | 58.40% | -4.98* | -2.61* |
| ext_wikipedia in top 3 | 1100 | 91.09% | 92.82% | 94.91% | -1.73* | -3.82* |

### Generated typos

| Metric | n | Prod (NSS) | Dev (n-gram) | CoreV4 | Δ vs Dev | Δ vs CoreV4 |
|---|---|---|---|---|---|---|
| Synthetic typos fixed | 5606 | 91.92% | 89.32% | 79.36% | +2.60* | +12.56* |
| Synthetic target in top 3 | 5606 | 96.56% | 93.56% | 89.55% | +3.00* | +7.01* |
| Synthetic first letter wrong fixed | 977 | 80.96% | 76.25% | 64.89% | +4.71* | +16.07* |
| syn omission fixed | 827 | 83.68% | 80.77% | 73.88% | +2.90* | +9.79* |
| syn insertion fixed | 1083 | 95.29% | 94.09% | 84.86% | +1.20 | +10.43* |
| syn sub_adjacent fixed | 1078 | 92.49% | 87.94% | 72.63% | +4.55* | +19.85* |
| syn double fixed | 1083 | 98.89% | 97.60% | 88.46% | +1.29* | +10.43* |
| syn transposition fixed | 1021 | 97.75% | 96.38% | 88.93% | +1.37* | +8.81* |
| syn two_errors fixed | 514 | 70.62% | 64.40% | 52.53% | +6.23* | +18.09* |

### Contractions

| Metric | n | Prod (NSS) | Dev (n-gram) | CoreV4 | Δ vs Dev | Δ vs CoreV4 |
|---|---|---|---|---|---|---|
| Contractions restored in sentences | 3493 | 85.23% | 76.24% | 17.58% | +8.99* | +67.65* |
| GUARD contractions restored | 80 | 96.25% | 97.50% | 61.25% | -1.25 | +35.00* |
| GUARD plain word changed in sentences ↓ | 1335 | 10.49% | 13.78% | 0.00% | -3.30* | +10.49* |

### Guardrails (lower is better unless marked)

| Metric | n | Prod (NSS) | Dev (n-gram) | CoreV4 | Δ vs Dev | Δ vs CoreV4 |
|---|---|---|---|---|---|---|
| GUARD false corrections, ECPS correct ↓ | 9522 | 0.48% | 0.42% | 0.88% | +0.06 | -0.40* |
| GUARD false corrections, MacKenzie clean ↓ | 1083 | 0.65% | 0.46% | 0.46% | +0.18 | +0.18 |
| GUARD hard valid words changed ↓ | 95 | 11.58% | 22.11% | 45.26% | -10.53* | -33.68* |
| GUARD unknown names changed ↓ | 292 | 49.32% | 74.32% | 80.82% | -25.00* | -31.51* |
| GUARD rare dictionary words changed ↓ | 1457 | 11.12% | 39.19% | 41.94% | -28.07* | -30.82* |
| GUARD Tenglish words changed ↓ | 870 | 12.76% | — | — | — | — |
| GUARD correct plurals stripped ↓ | 1236 | 0.08% | 0.08% | 0.00% | +0.00 | +0.08 |
| GUARD real-word errors fixed | 708 | 57.49% | 44.21% | 0.00% | +13.28* | +57.49* |

### Typing latency

Per word, the same 1,000 held ECPS words. Prod measured alone just now; the references from their stored runs (also one process, but different days and builds; CoreV4 without taps).

| System | p50 ms | p95 ms | p99 ms |
|---|---|---|---|
| Prod (NSS) | 8.53 | 13.29 | 16.88 |
| Dev (n-gram) | 0.93 | 6.32 | 8.47 |
| CoreV4 | 9.87 | 20.27 | 23.68 |

