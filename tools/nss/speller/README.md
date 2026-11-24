# Learned speller (prototype)

A Brill–Moore style spelling error model. It learns multi-letter rewrites (`^ph→^f`, `ica→aca`, with 0–2 letters
of context) from misspelling pairs, then runs a best-first search over a dictionary trie for the cheapest
rewrites of a typed non-word. Its candidates are added to the NSS decoder's candidates, and the shipped commit
rule is replayed with `tools/nss/wsp/fasteval.py`. Python only; nothing here runs in the keyboard.

The results and the not-adopted decision are in `docs/nss-rules.md` ("Learned speller, prototype").

| File | What it does |
|---|---|
| `speller.py` | Training (`train`) and the trie search (`Speller.candidates`) |
| `oracle_ceiling.py` | Step 0: the ceiling if a speller proposed the true target at cost c |
| `step1.py` | Step 1: candidates, calibration on tune half B, and the held report |
| `step1_gates.py` | Gating variants (2+ edits, skip capitalised words, confident top candidate only) |
| `annotate.cpp`, `build_annotate.sh` | Engine lookup values for each (typed, candidate) pair |
| `latency.py` | Search time per word and table sizes |
| `oov_count.py` | How many failures have their target outside the NSS vocabulary |

## Running

Everything generated goes into `cache/`, which git ignores (about 1 GB).

```sh
# 1. dump the rules-on decoder candidates, with target fields (tuning build of IOSBench), and pack them
python3 ../wsp/dump.py --rules on --out cache/oracle.jsonl
python3 ../wsp/cache_build.py cache/oracle.jsonl
# 2. build the annotate tool
./build_annotate.sh
# 3. experiments
python3 oracle_ceiling.py                          # Step 0 table
python3 step1.py candidates                        # speller candidates, cached in cache/step1/
python3 step1_gates.py                             # calibrate the gates on tune half B
python3 step1_gates.py held confident 0.25 1.0 8   # held report for the chosen setting
python3 latency.py
```

Training pairs are the tune half of ECPS and the four external lists (Aspell, Birkbeck, Holbrook, Wikipedia).
Rules are learned on tune half A; the cost scale and gate are chosen on tune half B. The held half is used only
for the final report.

## Speed (Python, M1, held half, 2,000 typed non-words)

| | p50 | p90 | p99 |
|---|---|---|---|
| search time | 22.6 ms | 68.6 ms | 110 ms |
| trie nodes expanded | 2,422 | 11,663 | 17,380 |

26,013 rules (12,092 typed chunks). Time grows with word length: 5 ms p50 at 4–5 letters, 52 ms at 10–11.
