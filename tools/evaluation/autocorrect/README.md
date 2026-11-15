# Autocorrect benchmark (shared C++ engine vs CoreV4)

Measures autocorrection, suggestions and prediction of `native/DecoderCore` (the NSS word
model over `keyboard/langdata.bin`) on the same 61,775 requests as the 27 Oct 2026 CoreV4
comparison (`CoreV4/analysis/autocorrect-comparison-2026-10-27`), plus four public
misspelling lists.

## Data

| Path | What |
|---|---|
| `corpus/cases.tsv`, `cases-meta.json` | ECPS real misspellings (CoreV4's data), MacKenzie synthetic typos, clean words, hard words, contractions, prediction. Built by `make_corpus.py` (needs a CoreV4 checkout, `COREV4=`). |
| `external/*.dat` → `corpus/ext-cases.*` | Birkbeck, Holbrook, Aspell, Wikipedia lists from https://www.dcs.bbk.ac.uk/~ROGER/corpora.html, filtered by `make_external.py`. **Held-out only.** |
| `corpus/*.taps.tsv` | The same rows with simulated touches (`make_taps.py`). |
| `corpus/keystrokes.tsv` | 4,000 real misspellings typed one letter at a time (typing latency). |
| `corpus/contraction-cases.*` | its/ill/were/hows… typed without the apostrophe in real Tatoeba sentences, meant as the contraction or the plain word (`make_contractions.py`). Split by sentence. |

`corpus/`, `external/`, `results/` and `bin/` are not committed.

Every set is split in half by a hash of the target word. **Tune on `tune`, report `held`.**

## Commands

```
python3 evaluate.py build [--bin NAME] [--tuning]   # --tuning: constants read from KB_<name>
python3 evaluate.py run NAME [--bin NAME] [--quick] [--taps]
python3 evaluate.py score NAME [--vs baseline] [--split held|tune|all]
python3 evaluate.py golden [--write]                # regenerate decode and Glide goldens, print visible changes
python3 evaluate.py core                            # CoreV4 on the external lists
python3 score_runs.py REF RUN [RUN ...]             # several runs against one reference
python3 ablate.py run NAME=ENV ... [--jobs N]       # NSS product rules: configurations x shards on every core (held half)
python3 ablate.py latency NAME=ENV ...              # uncontended typing latency per configuration
python3 context_report.py BASE RUN [RUN ...]        # rows with left context, by context length
python3 tune.py --bin ios-tune [--grid JSON] [--start JSON]   # coordinate search, tune half
python3 latency_tradeoff.py BIN '{"deletionCost": 1.1}' ...   # typing latency + accuracy
tools/evaluation/autocorrect/device_bench.sh DEVICE NAME   # same corpora on a connected iPhone
```

Runs decode with the word model in `KB_NSS` (default `keyboard/nss-english.nsslm`);
`IOSBench.cpp` lists the `KB_NSS_*` variants of the graph it reads.

`score` exits 1 when a guardrail gets worse (paired McNemar p < 0.05): false corrections,
hard words, plurals, real-word errors, contractions, prediction, keystroke savings, latency.
Its latency rows compare against whatever machine load the reference run had; for latency
decisions use `latency_tradeoff.py` or the keystroke test on an idle machine, alternating builds.

## Earlier results: the n-gram decoder (held-out half)

Measured on the n-gram decoder this branch no longer has; the CoreV4 column is the
fixed reference. NSS results: [`docs/nss-paper/COMPARISON.md`](../../../docs/nss-paper/COMPARISON.md).

| | 27 Oct before | 27 Oct after | 31 Oct | CoreV4 |
|---|---|---|---|---|
| ECPS real misspellings fixed | 79.6% | 83.6% | 89.3% | 88.0% |
| ECPS target in top 3 | 89.4% | 92.5% | 94.8% | 93.6% |
| ECPS left uncorrected | | 3.0% | 3.1% | 0.8% |
| Synthetic typos fixed | 78.9% | 85.8% | 88.7% | 81.0% |
| Synthetic in top 3 | 85.5% | 92.2% | 93.5% | 90.5% |
| Wikipedia fixed (top 3) | 68.4% | 71.8% (90.3%) | 79.2% (92.8%) | 83.6% (94.3%) |
| Birkbeck / Holbrook / Aspell fixed | 35.5 / 35.8 / 48.1% | 41.3 / 39.8 / 54.4% | 40.2 / 45.3 / 54.4% | 38.6 / 38.4 / 54.4% |
| False corrections (ECPS correct words) | 0.70% | 0.58% | 0.45% | 0.88% |
| Unknown names changed (make_keep.py) | 81.7%* | 81.2% | 75.0% | 80.1% |
| Rare dictionary words changed | 57.0%* | 49.1% | 39.1% | 42.3% |
| Unknown slang changed (n = 8) | | 100% | 100% | 87.5% |
| Real-word errors fixed | 42.4% | 44.6% | 44.2% | 0.3% |
| Typing p50 / p95 / p99, letters 5+ (ms) | 0.66 / 3.24 / 3.58 | 0.67 / 3.88 / 5.38 | 0.73 / 4.05 / 5.80 | |
| Typo request p50 / p95 / p99 (ms) | | 0.44 / 5.21 / 6.28 | 0.50 / 5.73 / 6.97 | |

\* all rows, not the held half.
