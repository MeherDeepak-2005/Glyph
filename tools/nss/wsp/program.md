# autoresearch: weight-space programming on the NSS word model

Adapted from csinva/weight-space-programming-autoresearch (`experiments/evolve/program.md`,
interpretable weight-space programming, iWSP). An agent improves the keyboard's NSS language
model by **writing edits to its weights in code**. The model is never trained.

## Setup (once per shipped model)

```
cd tools/nss/wsp
python3 dump.py                          # rules-off C++ decode of every case, both halves (~3.5 min)
python3.11 cache_build.py cache/base.jsonl  # compact arrays for fasteval (~30 s)
python3.11 -m unittest test_wsp -v       # ~30 s: format, goldens, rescoring == C++ decoder
```

Use `python3.11` (it has numpy). `cache/` is git-ignored and must be rebuilt when the shipped
model, `langdata.bin`, the channel costs or the commit rule change.

## What you CAN do

- Edit `nss_weights.py`: `write_weights(model, **params)` gets the shipped weights as numpy arrays
  (`nsslm.Model`: embedding, gates, gate_bias, projection, output_bias) and may set any of them by
  formula: constants, word lists, dictionary counts, hand-built circuits.
- Change `model_shorthand_name`, `model_description`, `PARAMS`.

## What you CANNOT do

- Any training: gradient, optimizer, fitting loop, backprop.
- Derive a weight from the benchmark cases (corpus/*.tsv) or look at the held half's score while searching.
- Touch the decoder, the rules (`NssRules.hpp`), the channel costs or the commit margins: the test is
  the neural engine alone (`KB_nssRules=0`).

## The loop

1. One idea per edit in `nss_weights.py`.
2. `python3.11 run.py [k=v ...] [--grid k=a,b,c ...]`: scores the tune half (~4 s per model), appends
   to `results/overall_results.csv`, snapshots the program to `lib/<name>.py`, writes the model to
   `cache/models/<name>.nsslm`.
3. Score = mean of 7 fix rates (ECPS, synthetic, Aspell, Birkbeck, Holbrook, Wikipedia,
   contractions) − 0.5 × points lost on any guardrail or top-3 rate − 10 per official guardrail
   significantly worse than the shipped weights (paired McNemar p < 0.05, as performance_tests.py).
4. Every few winners, `python3.11 verify.py --split tune cache/models/<name>.nsslm` runs the real C++
   decoder on the tune half (~90 s): the rescoring keeps each case's candidate list fixed, so check
   it still matches when the edit is large.
5. Interpretability: all else equal, fewer and more readable edits win.

## Final test (once)

- `python3.11 fasteval.py <shipped> <edited> --split held` (seconds), then
- `python3 performance_tests.py --env KB_nssRules=0` with `KB_NSS=<model>` for the shipped and the
  edited model (official before/after; restore docs/performance-tests.md afterwards),
- `python3.11 perplexity.py <shipped> <edited>`: what the edit costs the model as a language model.

Record results in docs/nss-weight-programming.md.
