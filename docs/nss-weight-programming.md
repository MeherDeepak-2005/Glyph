# NSS weight programming (iWSP)

Hand-written, closed-form edits to the NSS word model's weights, following the interpretable
weight-space programming loop of csinva/weight-space-programming-autoresearch: no training, one
validation score per attempt (tune half), every attempt logged and snapshotted, the held half used
once as the hidden test. Tools and protocol: `tools/nss/wsp/` (`program.md`).

## Result (22 Nov 2026)

Edited model: `tools/nss/artifacts/wsp-length-apostrophe.nsslm` = shipped `keyboard/nss-english.nsslm`
with two output-bias edits (`nss_weights.py`, `gamma=0.3, center=5, beta=2`). Same size, same
architecture, same runtime; only 30,004 fp32 bias values change. **Not shipped**: keyboard/ still
bundles the old model.

1. **Length prior**: every word's output bias gets 0.3 × (letters − 5). Misspelled words are long
   ones; the model alone left 9.2-letter targets as typed and committed 4.4-letter words in place
   of names and Tenglish.
2. **Apostrophe prior**: +2 to the bias of every word spelled with an apostrophe (don't, i'm). People
   leave the apostrophe out on a phone; the model learned from text that has it.

### Official performance tests, rules off (held half, `performance_tests.py --env KB_nssRules=0`)

Runs `prod-2026-11-22-0217` (shipped weights) and `prod-2026-11-22-0220` (edited), `KB_NSS` set to each
model; table from `tools/nss/wsp/official.py`. * = paired McNemar p < 0.05.

| Metric (held) | Shipped | Edited | Δ |
|---|---|---|---|
| ECPS real misspellings fixed | 75.81% | 80.13% | +4.32* |
| ECPS left uncorrected ↓ | 12.99% | 10.18% | −2.81* |
| ECPS target in top 3 | 91.78% | 91.99% | +0.21 |
| Aspell / Birkbeck / Holbrook / Wikipedia fixed | 25.32 / 16.42 / 32.67 / 46.82% | 28.27 / 18.44 / 33.33 / 53.09% | +2.95* / +2.02* / +0.67 / +6.27* |
| Synthetic typos fixed | 90.78% | 91.63% | +0.86* |
| Synthetic target in top 3 | 97.02% | 96.40% | **−0.62*** |
| Contractions restored in sentences | 44.86% | 75.32% | +30.46* |
| GUARD contractions restored | 73.75% | 86.25% | +12.50* |
| GUARD plain word changed in sentences ↓ | 8.76% | 9.44% | **+0.67* fail** |
| GUARD false corrections, ECPS correct / MacKenzie clean ↓ | 0.64 / 0.09% | 0.67 / 0.18% | +0.03 / +0.09 |
| GUARD unknown names changed ↓ | 36.99% | 36.99% | 0 |
| GUARD rare dictionary words changed ↓ | 7.62% | 8.03% | +0.41 |
| GUARD Tenglish words changed ↓ | 9.89% | 9.66% | −0.23 |
| GUARD real-word errors fixed | 56.36% | 56.92% | +0.56 |
| GUARD hard valid words changed / plurals stripped ↓ | 10.53 / 0% | 10.53 / 0% | 0 |

The plain-word guardrail fail is the apostrophe prior's cost (its → it's); the apostrophe *rule* failed
the same guardrail by +1.80 (docs/nss-rules.md). With `beta=1.5`
(`wsp-length-apostrophe-b1.5.nsslm`, run `prod-2026-11-22-0222`) no guardrail fails: ECPS +4.24*,
contractions +19.78*, plain words +0.37 (n.s.). That variant was picked **after** seeing the held
half, so it is not a clean hidden-test result.

### Costs not in the performance tests

| Model | tatoeba / wikitext / masc perplexity | next word in top 3 (held nw, model only) |
|---|---|---|
| shipped | 65.7 / 158.8 / 285.3 | 20.31% |
| edited (β 2) | 87.3 / 207.3 / 370.9 | 16.71% |
| edited (β 1.5) | 83.2 / 203.3 / 357.3 | 17.08% |
| length prior only (β 0) | — | 18.93% |

The priors are typing knowledge written into P(word), so the model is a worse plain language
model, and the same distribution feeds the empty-word prediction strip. Before shipping, decide
whether a −3.6 pt next-word top-3 is acceptable or whether prediction should read unedited weights.

## What was tried (tune half, `tools/nss/wsp/results/overall_results.csv`)

| Edit | Finding |
|---|---|
| Temperature τ (projection × τ, recurrent gate columns ÷ τ, output bias × τ: logits × τ exactly) | τ 0.7 lifts ECPS +6 pt but names changed +14 pt: it makes Space more eager, not better. At matched guardrails ≤ +0.5 accuracy. Rejected. |
| `<unk>` logit shift | Moves the typed-literal price and the unigram floor together; +1 cuts real-word fixes (rare typed words get a higher floor). Rejected. |
| Length prior, linear | Pareto gain: γ 0.3, centre 5 = +3.1 accuracy, no guardrail fail. **Kept.** Centre and `<unk>` shift are the same knob. |
| Length prior, hinge (only letters beyond the centre) | More eager (names +), worse than linear. Rejected. |
| Apostrophe prior β | +0.5..+2 adds contractions with no tune fail; β ≥ 3 fails plain words and rare words. **Kept at 2** (held: fails plain words, see above). |

Tune-half score: accuracy mean of 7 fix rates − 0.5 × guardrail/top-3 points lost − 10 per official
guardrail significantly worse. Shipped 48.43 → edited 54.33.

## Fast tests

`tools/nss/wsp/fasteval.py` replays the rules-off decoder in numpy on cached candidates (one C++
dump, `dump.py`): about 4 s per model per half, 100.00% / 99.99% commit agreement with the C++
decoder on the shipped weights (tune / held), within 0.13 pt of a real decode for the edited model
(`verify.py`). `test_wsp.py` (7 tests, ~20 s) checks the file round trip, C++ goldens, the edits and
the benchmark gain. Dumping needs the tuning build, which records the search's candidates
(`DecodeOutput::complete/ranked`, `KB_TUNING` only) and `IOSBench` `KB_DUMP=2`.

## Default-model checks (22 Nov 2026): not adopted

Run before replacing `keyboard/nss-english.nsslm`; the shipped model stays.

- **Performance tests as the app ships (rules on, release build)**, runs `prod-2026-11-22-0246`
  (shipped) vs `-0249` (edited): ECPS fixed 90.63 → 91.52%*, Birkbeck +2.09*, contractions
  85.23 → 99.54%*, but two guardrails fail: plain word changed in sentences 10.49 → 14.53%* (the
  apostrophe prior stacks on the apostrophe rule: its → it's) and false corrections of correct ECPS
  words 0.48 → 0.60%*; synthetic target in top 3 −0.62*.
- **Prediction (real decoder, 1,083 held next-word rows)**: next word in top 3 20.31 → 16.71%,
  keystroke savings 49.67 → 47.83%.
- **Native tests**: everything passes except EngineTests' recorded decode/glide goldens (164 visible
  changes; with re-recorded goldens every engine test passes). Shared-engine fixtures: glide top-1
  44 → 43/60 (keyboard → keyboards), typing 113 → 112/132 (alot → allot, not "a lot"); the strip
  shows more apostrophe forms (teh: the, there's, they're).
- Goldens for the edited model: `tools/nss/artifacts/wsp-length-apostrophe.goldens.json`
  (`regolden.py`, reproduces the shipped goldens to 5.5e-5). Shipped files backed up as
  `tools/nss/artifacts/nss-english-pre-wsp.*`.

Next step if weight edits are pursued for the default: search with the rules on (re-dump without
`KB_nssRules=0`) and without the apostrophe prior, and keep next-word top 3 as a guardrail.
- **Latency (Mac, ABBA x3, 1,000 held ECPS words, release harness)**: per-word p50 7.68 → 7.52 ms,
  p99 11.49 → 10.94 ms, startup 98 → 96 ms, footprint at end 22.0 → 22.8 MB (same file size; noise).
- **Release build** (simulator, `NSS_MODEL=<candidate>`): builds; `verify_release_artifacts.py
  --allow-neural` passes (extension 15.8 / 25 MB).
- **Simulator unit tests** (`keyboardTests`, iPhone 17 / iOS 27): 95 tests, the same 4 fail with the
  shipped and the candidate model (contractionTyposAndIdFollowTheNSSRanking `id` → "i",
  recoveryFindsClearWithoutCallbacksAndStops, emojiAtlasRoundTripAndRender,
  suggestionPassThroughBoundaryDoesNotMoveKeyGeometry): no failure is caused by the candidate.
  SevereTypoBenchmark reads keyboard/ directly, so it only saw the shipped model.
- **Device**: not run (iPhone unavailable: locked or disconnected).

## Search with the product rules on (22 Nov 2026): no edit adopted

Cache `tools/nss/wsp/cache/rules.npz` (`dump.py --rules on`): fasteval replays the rules' commit logic
(first-letter cost, split margin, same-sound allowance) and matches the C++ decoder on 100.00% of
tune and held cases. Next word in top 3 (nothing typed) is now a guardrail. Log:
`tools/nss/wsp/results/rules_on_results.csv` (~400 attempts).

- Linear length prior: γ 0.1 gains at most +0.13 accuracy; γ ≥ 0.2 fails next word in top 3.
  The rules already price what it encoded.
- Temperature and `<unk>` shifts: no gain at matched guardrails (as with the rules off).
- Best (pre-registered on tune): long-word prior, bias += 0.4 × max(0, letters − 7)
  (`tools/nss/artifacts/wsp-long-words.nsslm`). Tune: accuracy 70.52 → 71.04, no fail. **Held**:
  ECPS fixed 90.63 → 90.99% (+43/−8*), Birkbeck 32.56 → 34.10%*, left uncorrected 2.69 → 2.49%*,
  but GUARD false corrections of correct ECPS words 0.48 → 0.55% (+6/−0, p = 0.031, **fail**:
  concoction → conviction, devastate → devastated, facilitates → facilitated, flowing → following),
  next word in top 3 20.31 → 19.48% (p = 0.064), synthetic target in top 3 −0.18*.

Conclusion: with the rules on, none of these closed-form output-bias edits beats the shipped
weights without a guardrail cost; the shipped model stays the default. Further gains need either
retraining or edits that use context (the recurrent weights), not per-word priors.
