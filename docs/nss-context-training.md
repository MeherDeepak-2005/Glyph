# Training NSS for autocorrect and next-word prediction

The two experimental checkpoints use the shipped one-layer CIFG-LSTM and its existing iOS kernel. Each model is 3,922,400 bytes. The combined checkpoint uses two supervised calibration steps. The contraction-only checkpoint isolates the effect of the second step.

1. **Protect next-word predictions.** Start with the earlier long-word bias proposal for 3,293 dictionary words without single-edit neighbors. For each proposed increase, fit the largest allowed increase using the gap to the third-ranked word in clean training contexts. Retain a 0.75-logit margin. The fit saw 72,007 distinct contexts from the Tatoeba and WikiText training shards and retained positive increases for 2,971 words.
2. **Learn contraction embeddings.** Fit a separate regularized linear regression for each eligible contraction. Positive examples are contexts where the contraction actually occurs. Negative examples are contexts of its stem and a background sample. Training penalizes movement near the third prediction slot. Centering the features at the start-of-sentence state limits the change on empty input. This adjusted 37 tied embedding rows and their output biases.

Both stages use train-split text and the shipped vocabulary. We selected contraction strength 1 from 0.5, 1, and 2 on the autocorrect tuning split. The product rules and decoder parameters were fixed across comparisons.

## Other training runs

The optional `train.confusion_weight` setting in `nss.train` adds a conditional cross-entropy over one-edit spelling neighbors of contextual targets. The normal language-model objective still uses the full vocabulary. For large batches, the auxiliary loss samples up to 512 positions per step.

Two CPU fine-tunes started at the exact shipped training checkpoint and saw the same shuffled examples, with 25% sentence truncation, 480 updates, batch 24 and BPTT 12. With auxiliary weight 0.3, the release tuning split's mean of seven correction rates was 69.98%, versus 69.99% for the matched short-context control and 70.52% for the shipped model. Next-word top-three accuracy was 35.40%, 35.46% and 36.75%, respectively. Both fine-tunes failed the tune next-word and rare-word guardrails. Re-exporting the original weights with the current corpus’s unknown-word share also failed the rare-word guardrail by itself. The two retained checkpoints preserve the shipped unknown-word policy.

## Reproduce the candidates

From `tools/nss/`, use Python 3.11 with NumPy for calibration. The optional end-to-end fine-tune uses the project's PyTorch environment.

```sh
python3.11 fit_prediction_caps.py ../../keyboard/nss-english.nsslm artifacts/wsp-isolated.nsslm /tmp/nss-capped.nsslm
python3.11 train_contraction_rows.py /tmp/nss-capped.nsslm /tmp/context-calibrated.nsslm
python3.11 train_contraction_rows.py ../../keyboard/nss-english.nsslm /tmp/context-contractions.nsslm

python -m nss.train --config configs/cifg-context-spelling.json --init runs/cifg-lstm-96x670/best.pt --out runs/context-spelling --device cpu
```

## Native results

The autocorrect benchmark ran through `performance_tests.py` with release defaults and separately with `KB_nssRules=0` in a tuning build. Rates use the same case IDs within each row. An asterisk marks a paired exact McNemar p < 0.05 against shipped on that row.

| Metric | Cases | Raw shipped | Raw combined | Release shipped | Release combined |
|---|---:|---:|---:|---:|---:|
| ECPS real misspellings fixed | 9622 | 75.81% | 76.38%* | 90.63% | 90.79%* |
| ECPS left uncorrected | 9622 | 12.99% | 12.47%* | 2.69% | 2.64% |
| ECPS target in top 3 | 9622 | 91.78% | 91.76% | 95.58% | 95.58% |
| ext_aspell fixed | 237 | 25.32% | 25.32% | 53.16% | 53.16% |
| ext_birkbeck fixed | 15136 | 16.42% | 16.85%* | 32.56% | 32.98%* |
| ext_holbrook fixed | 450 | 32.67% | 32.67% | 43.78% | 43.78% |
| ext_wikipedia fixed | 1100 | 46.82% | 47.91%* | 81.55% | 81.64% |
| Synthetic typos fixed | 5606 | 90.78% | 90.81% | 91.92% | 91.90% |
| Synthetic target in top 3 | 5606 | 97.02% | 96.99% | 96.56% | 96.56% |
| Contractions restored in sentences | 3493 | 44.86% | 47.29%* | 85.23% | 85.34% |
| GUARD false corrections, ECPS correct | 9522 | 0.64% | 0.63% | 0.48% | 0.50% |
| GUARD rare dictionary words changed | 1457 | 7.62% | 7.69% | 11.12% | 11.12% |
| GUARD unknown names changed | 292 | 36.99% | 36.99% | 49.32% | 49.66% |
| GUARD Tenglish words changed | 870 | 9.89% | 9.89% | 12.76% | 12.76% |
| GUARD real-word errors fixed | 708 | 56.36% | 56.36% | 57.49% | 57.49% |
| GUARD plain word changed in sentences | 1335 | 8.76% | 8.76% | 10.49% | 10.49% |

The combined model fixed a net 55 additional ECPS cases with rules disabled and 16 with rules enabled. In release it also changed two additional correct ECPS words and one additional unknown name. Neither difference was significant. No paired autocorrect guardrail failed in either configuration. The contraction-only model gained 85 raw contraction restorations and four in release. Its release ECPS gain was five cases (p = 0.0625).

## Prediction, transfer and Glide

| Evaluation | Shipped | Combined |
|---|---:|---:|
| Held next-word top-three hits | 220/1,083 | 220/1,083 |
| Keystroke savings | 49.67% | 49.56% |
| Separate test-corpus study, apostrophes restored | 913/1,200 | 919/1,200 |
| Matched plain words preserved | 1,193/1,200 | 1,193/1,200 |
| Separate single-edit long-word typos fixed | 1,104/1,200 | 1,104/1,200 |
| Matched clean long words preserved | 1,197/1,200 | 1,197/1,200 |
| Shared typing fixture targets committed | 115/132 | 115/132 |
| Shared Glide targets ranked first | 44/60 | 43/60 |
| Word perplexity on Tatoeba / WikiText / MASC | 66.0 / 162.2 / 283.2 | 66.4 / 162.7 / 284.3 |

The separate contraction study sampled 400 omitted apostrophes and 400 plain-word cases per source from the Tatoeba, WikiText and MASC test shards. It excluded duplicate context/typed/target triples and matches to the standing benchmark. The model gained seven contraction restorations and lost one (paired p = 0.0703). The independent long-word sample showed no changed outcomes. The standing benchmark has been used in earlier experiments, so the reported gains need confirmation on fresh real typing data.

The combined model retained the same held next-word hits case by case. The lower keystroke savings reflects later prefixes. On one noisy Glide path the first suggestion for *information* became *unfortunately*. The contraction-only variant retained all baseline typing and Glide fixture successes and the original next-word hits and keystroke savings.

## Release checks and disposition

On the same 1,000 held ECPS words, two interleaved release-decoder runs per model measured p50 / p95 / p99 of 7.238 / 9.405 / 10.663 ms for shipped and 7.291 / 9.443 / 10.878 ms for combined. On 500 held next-word cases, interleaved per-keystroke p95 was 2.144 versus 2.141 ms. Both latency comparisons were on the development Mac. Keystroke savings and timing met the repository thresholds.

All 29 NSS Python tests passed. The combined candidate passed the native suite using candidate-specific goldens regenerated in a private copy. The model parity test matched 220 scores to a maximum absolute error of 0.000356. The separate typing and Glide comparison above uses the original fixture targets. An unsigned Release iOS build bundled the exact candidate SHA-256 and passed the extension audit at 14,525,265 of 25,000,000 bytes.

The combined checkpoint passes the standing autocorrect, next-word, keystroke-savings and latency guardrails. It is a candidate for a typing beta. The shared Glide regression and the limited independent transfer evidence weigh against replacing the app default in this experiment. Physical-device and live-user outcomes remain unmeasured. The contraction-only checkpoint is available for a narrower comparison.

Paired records, independent test cases, logs and build audit results are in the local ignored directory `tools/evaluation/autocorrect/results/performance-tests/nss-context-training/`. The neighboring JSONL files can be re-scored with the existing harness.

```sh
cd tools/nss/wsp
python3.11 official.py wsp-study-release-base context-calibrated-release context-contractions-release
python3.11 official.py wsp-study-raw-base context-calibrated-raw context-contractions-raw
```
