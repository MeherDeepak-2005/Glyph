# NSS product rules

The production decoder is the NSS (neural search space) engine. On its own it prices every typing
edit by key distance alone ("raw NSS"). The **product rules** replace some of those prices with
spelling-aware ones taken from the old n-gram tier. This file records which rules are on, what each
one was measured to gain or cost, and what was tried and rejected. **A rule listed here as tested
does not need re-testing** unless the model, vocabulary, channel weight or commit rule changes.

- Code: `native/DecoderCore/include/NssRules.hpp` (all rules, one file). Used by
  `NeuralFstSearch` (`src/NeuralFst.cpp`: substitution, insertion, deletion) and
  `EngineSession::decode` (`src/Engine.cpp`: first letter).
- **Engine-only measurement:** `nssRules 0` turns every rule off, which is the neural engine's raw channel.
  `nssRule<Name> 0` turns one rule off. In a tuning build (`evaluate.py build --bin rules --tuning`)
  these are environment variables: `KB_nssRules=0`, `KB_nssRuleVowelSwap=0`, and so on. App builds
  compile the defaults in as constants.
- Tests: `tools/evaluation/autocorrect/ablate.py` (see "How to test a rule" below).

## Rules in production

| Rule (switch) | What it prices | Cost | Decision |
|---|---|---|---|
| Vowel swap (`nssRuleVowelSwap`) | a vowel typed for another vowel (definately, seperate) | 1.5 (`vowelSubstitutionCost`), not key distance | **On** |
| Apostrophe (`nssRuleApostrophe`) | a word's apostrophe left out (thats, youd, cant) | 0.4 (`apostropheSkipCost`), not a 1.1 deletion | **On** |
| Doubled letters (`nssRuleDoubledLetters`) | a doubled letter typed once (tomorow, posess) / a letter typed twice (untill) | 0.3 / 0.6 (`doubledDeletionCost` / `doubledInsertionCost`), not 1.1 / 1.6 | **On** |
| Sound-alike consonants (`nssRuleSoundAlike`, phonetics) | c for k, c for s, s for z (concider) | 0.9 (`soundAlikeSubstitutionCost`), not key distance | **On** (16 Nov) |
| Same-sound commit (`nssRuleSameSound`, phonetics) | Space commits a word that spells the same sounds as a typed non-word of 4+ letters (`nssSpellingSkeleton`: ph/f, ck/k, soft c, z/s, vowels, doubled letters) | commit allowance +1.5 (`nssSameSoundMargin`) when that word leads the next by 1.0 (`nssSameSoundGap`) | **On** (16 Nov) |
| Touch (`nssRuleTouch`) | a tap is priced against the key it landed on: an off-centre tap on the right key costs nothing | relative key distance at `touchSigma` 0.7 | **On** (16 Nov) |
| Split margin (`nssRuleSplitMargin`) | a two-word correction (missing space) must beat the typed text by 3 (`nssSplitMargin`), else the best single word competes | — | **On** (16 Nov) |
| Frequency prior (`nssRuleFrequency`) | 0.1 × ln(dictionary count + 1) added to each word's score | — | **Off: rejected** (16 Nov) |
| First-letter change (`nssRuleFirstLetter`) | a candidate whose first letter differs from the typed one (tounge: tongue, not younger) | `firstLetterPenalty`: 0.35 / 0.2 for 3 / 4 letters; from 5 letters 0.75 if the first two letters are swapped, 1.5 if the first letter is missing, 1.0 for a neighbouring key, otherwise 2.0 | **On** |

Swapped neighbouring letters ("misplaced letters", tihs -> this) were already in raw NSS at the n-gram tier's cost
(`transpositionCost` 0.65), so there was nothing to add.

## Measurements (15 Nov 2026)

Setup: the benchmark's **held half** (51,094 decodes), simulated taps where a set has them
(`*.taps.tsv`; contraction and Tenglish sets without taps), shipped model `keyboard/nss-english.nsslm`,
`langdata.bin` KBLM v7, commit rule `nssRawCommitMargin` 2 / `nssCapitalizedCommitMargin` 0 /
`nssTypedUnknown` on. The rule costs are the n-gram tier's values (tuned on that tier's tune half,
27 Oct–1 Nov); they were not re-tuned for NSS. "*" means significant (paired McNemar p < 0.05); a guardrail
"fails" when it is significantly worse.

### Each rule alone, against raw NSS (percentage points)

| Metric (held) | Raw NSS | +Vowel swap | +Apostrophe | +Doubled letters | +First letter |
|---|---|---|---|---|---|
| ECPS real misspellings fixed | 75.81% | **+3.66*** | **+1.39*** | **+3.91*** | **+1.25*** |
| ECPS target in top 3 | 91.78% | +1.23* | +0.70* | +0.61* | +0.96* |
| Synthetic typos fixed | 90.78% | −0.12* | −0.07 | +0.71* | −1.16* |
| Aspell / Birkbeck / Holbrook / Wikipedia fixed | 25.3 / 16.4 / 32.7 / 46.8% | +5.5* / +3.0* / +2.2* / +4.6* | 0 / 0 / −0.2 / 0 | +9.7* / +2.3* / +2.0 / +8.9* | −0.4 / +0.2* / +0.7 / −0.3 |
| Contractions restored in sentences | 44.86% | −0.34* | **+40.42*** | 0 | +0.09 |
| GUARD contractions restored (apos set) | 73.75% | −1.25 | **+17.50*** | 0 | 0 |
| GUARD correct ECPS words changed | 0.64% | +0.01 | 0 | +0.02 | **−0.32*** |
| GUARD unknown names changed | 36.99% | +2.40 fail | 0 | +2.74 fail | **−2.40*** |
| GUARD rare dictionary words changed | 7.62% | +0.27 | 0 | +0.62 fail | **−0.96*** |
| GUARD Tenglish words changed | 9.89% | +0.23 | 0 | +3.56 fail | **−1.38*** |
| GUARD plain word changed in sentences (its/ill/were…) | 8.76% | 0 | +1.80 fail | 0 | −0.07 |
| GUARD real-word errors fixed | 56.36% | −0.42 | 0 | +0.42 | −4.24 fail |

### Each rule's share of the full set (all rules on, minus that one)

How much each rule adds on top of the other three. This is the number to quote for "what this rule is worth".

| Metric (held) | All rules | Vowel swap adds | Apostrophe adds | Doubled letters adds | First letter adds |
|---|---|---|---|---|---|
| ECPS real misspellings fixed | 85.80% | **+3.69*** | **+1.38*** | **+3.75*** | **+0.96*** |
| Synthetic typos fixed | 89.94% | −0.16* | −0.05 | +0.55* | −1.39* |
| Wikipedia misspellings fixed | 60.09% | +4.64* | 0 | +8.91* | −0.27 |
| Birkbeck misspellings fixed | 21.76% | +2.87* | −0.01 | +2.27* | +0.07 |
| Contractions restored in sentences | 85.23% | 0 | **+40.65*** | −0.03 | 0 |
| GUARD correct ECPS words changed | 0.35% | +0.01 | 0 | +0.01 | **−0.33*** |
| GUARD unknown names changed | 39.38% | +2.05* | 0 | +3.08* | **−3.08*** |
| GUARD rare dictionary words changed | 7.55% | +0.41* | 0 | +0.62* | **−1.10*** |
| GUARD Tenglish words changed | 12.99% | +0.92* | 0 | +3.79* | **−0.80*** |
| GUARD plain word changed in sentences | 10.49% | 0 | +1.80* | 0 | −0.07 |
| GUARD real-word errors fixed | 52.12% | −0.42 | 0 | +0.42 | −4.24* |

### All four rules against raw NSS

ECPS real misspellings fixed **75.81 → 85.80% (+10.0 points)**, target in top 3 91.78 → 94.87%.
External lists: Aspell 25.3 → 40.1%, Birkbeck 16.4 → 21.8%, Holbrook 32.7 → 38.0%, Wikipedia
46.8 → 60.1%. Contractions in sentences 44.9 → 85.2%, apostrophe guard set 73.8 → 92.5%.
Costs: synthetic typos −0.84 points, unknown names changed +2.4 points (not significant), Tenglish words changed
9.9 → 13.0%, plain its/ill/were changed in sentences 8.8 → 10.5%, real-word errors fixed 56.4 → 52.1%.
For comparison, the n-gram tier with all its rules (`performance-tests/dev-ngram-2026-11-01`, same held half, with taps) fixed 90.69% of ECPS.

**Latency** (`ablate.py latency`: 1,500 held ECPS words with taps, 3 interleaved rounds, one process at a time, M1, tuning
build): raw NSS p50 / p95 / p99 7.14 / 9.69 / 11.03 ms, all rules 7.40 / 9.80 / 11.06 ms (+3.6% / +1.1% / +0.3%),
inside the harness's 10% latency budget.

### Why each rule is on

- **Vowel swap:** misspellings are mostly sound spellings (definately, seperate, sentance). Raw NSS charged
  a/i by key distance (about 3.4 for definately -> definitely, so it stayed as typed); it now costs 1.5. It is
  the second-largest gain, at the price of about 2 points more unknown names changed.
- **Apostrophe:** with a deletion's cost (1.1), the model's preference for the bare word (that, you,
  there) beat that's / you'd / they're. At 0.4 it restores 40 points more contractions in real sentences.
  The cost is 1.8 points more plain its/ill/were turned into contractions. The n-gram tier accepted this
  trade too (13.8%).
- **Doubled letters:** the largest gain on real misspellings (+3.75) and on the Wikipedia/Aspell lists (+9).
  It changes more Tenglish (+3.8 points) and names (+3.1). The first-letter rule offsets most of the names and
  rare-word cost.
- **First-letter change:** kept for real misspellings (+0.96), and because it is the only rule that
  *protects* words: correct words changed are halved, and fewer names, rare words and Tenglish words are changed.
  Its price is generated typos with a wrong first letter (−1.4 points) and real-word errors (−4.2 points).
  Real misspellings and word protection were judged to outweigh generated typos.

## Phonetic rules (16 Nov 2026)

Same setup. Measured on top of the four rules above (run `rule-tests-2026-11-16/base`, which matches the 15 Nov
`all` run decode for decode). Values are the n-gram tier's, not re-tuned.

| Metric (held) | Four rules | +Sound-alike | +Same-sound | +Both (shipped) |
|---|---|---|---|---|
| ECPS real misspellings fixed | 85.80% | +0.04 | **+1.08*** | **+1.11*** |
| Aspell / Birkbeck / Holbrook / Wikipedia fixed | 40.1 / 21.8 / 38.0 / 60.1% | +1.3 / +0.8* / +0.2 / +2.1* | +2.5* / +2.5* / +0.9 / +6.6* | **+3.8* / +3.4* / +1.1 / +8.7*** |
| Synthetic typos fixed | 89.94% | −0.05 | +0.11* | +0.04 |
| GUARD unknown names changed | 39.38% | +0.68 | +2.05 fail | +2.74 fail |
| GUARD rare dictionary words changed | 7.55% | +0.14 | +0.34 | +0.48 fail |
| GUARD Tenglish, correct words, contractions, real-word errors | — | 0 | 0 | 0 |

- **Sound-alike:** the gains are on the external lists (Wikipedia +2.1), and no guardrail fails.
- **Same-sound commit:** closes part of prod's largest gap (misspellings left as typed: 7.08 -> 5.77% with
  both rules) and adds +6.6 on Wikipedia. The cost is about 6 more of 292 unknown names changed; Tenglish is unchanged.
- **Latency** (2,000 held ECPS words, 3 rounds, alone): raw 7.17 / 9.92 / 11.18 ms, four rules
  7.43 / 9.96 / 11.04, six rules 7.57 / 10.02 / 11.10 (p50 / p95 / p99; +5.6% / +1.0% / −0.7% against raw).
  A smaller first sample showed p99 +17%. That was noise: it did not repeat on the larger sample.

## The dev branch's remaining rules (16 Nov 2026)

Measured on top of the six rules above, same setup (runs in `rule-tests-2026-11-16/dev-rules-*`).

| Metric (held) | Six rules | +Touch | +Frequency prior | +Split margin | +All three |
|---|---|---|---|---|---|
| ECPS real misspellings fixed | 86.92% | **+3.61*** | +0.80* | +0.16* | +3.93* |
| Synthetic typos fixed | 89.98% | **+1.87*** | +0.39* | +0.04 | +2.00* |
| Aspell / Birkbeck / Holbrook / Wikipedia fixed | 43.9 / 25.1 / 39.1 / 68.8% | **+9.3* / +7.3* / +4.2* / +12.6*** | +1.3 / +1.5* / +0.9 / +3.6* | 0 / +0.1* / +0.2 / 0 | +9.7* / +8.9* / +4.9* / +13.5* |
| GUARD real-word errors fixed | 52.12% | +5.37* | +0.99 | 0 | +6.78* |
| Contractions restored in sentences | 85.23% | 0 | **−2.98*** | 0 | −2.98* |
| GUARD correct ECPS words changed | 0.35% | +0.18 fail | 0 | −0.03 | +0.22 fail |
| GUARD unknown names changed | 42.12% | +8.90 fail | +4.11 fail | **−1.37** | +12.33 fail |
| GUARD rare dictionary words changed | 8.03% | +4.46 fail | +1.30 fail | **−0.55*** | +4.32 fail |
| GUARD Tenglish words changed | 12.99% | 0 | **+1.38 fail** | −0.23 | +1.15 fail |

- **Touch: on.** This was the biggest single gain. Raw NSS charged an off-centre tap on the right key, which is why prod
  scored worse with taps (75.8%) than without (80.1%). Names and rare words changed rise (42 -> 51%, 8 -> 12.5%),
  but they stay far below dev's (74% / 39%) and CoreV4's (81% / 42%). Tenglish is unchanged.
- **Split margin: on.** It fixes slightly more misspellings and changes slightly fewer names, rare words and Tenglish words; it costs nothing.
  It also stops a fresh-context name being split (ahmet is no longer "a letter").
- **Frequency prior: off.** Its gains are small (+0.8), it costs 3 points of contractions, and it changes more Tenglish words.

With the eight rules on (performance tests `prod-2026-11-16-0027`): ECPS fixed **90.63%** (dev 90.69%, CoreV4 89.77%),
p50 / p95 / p99 7.88 / 10.09 / 11.02 ms.

### Every dev-branch rule and where it stands in prod

| Dev rule | Prod |
|---|---|
| Vowel swap, apostrophe, doubled letters, first-letter penalty, sound-alike, same-sound commit, touch cost, split margin | ported, on (this file) |
| Frequency prior (`nssFrequencyWeight` 0.1) | ported, off (rejected above) |
| Typed unknown text scored by P(<unk>) (`nssUnknownLiteral`) | already in prod: `nssTypedUnknown` |
| Non-word commit margin (`nssOovMarginShift`) and capital-name margin (`nssCapitalMargin` 3) | already in prod, re-tuned for NSS: `nssRawCommitMargin` 2, `nssCapitalizedCommitMargin` 0 (15 Nov) |
| Contraction commit (Space commits the contraction the strip ranks first) | already prod's behaviour: Space commits the best word |
| Transposition 0.65, a neighbouring key before the word (`extraLeadingKeyCost` 1.6), vowel at the first letter | already equal in prod's raw channel (transposition and insertion costs; the vowel rule applies at every letter) |
| Real-word gate (channel weight 1, margin 5) | not ported: prod already fixes more real-word errors (57.5% vs 44.2%) and changes fewer correct words |
| N-gram rescoring (`nssNgramWeight` 0.25) | not portable: it is the n-gram language model, which the prod scope excludes |
| Candidate recovery (`nssRecovery`: trie first-letter passes, broad recovery, context injection) and the blocked-typo rule | not portable as a rule: that candidate-generation code (CandidateGeneration, IncrementalSearch) is not on prod |
| Word patches ("id" rule, kept opening quote) | not ported: patches for single words (id -> I'd now comes from the apostrophe rule) |

## Not adopted / not tried

- The n-gram tier's other decision rules (n-gram rescoring, lenient recovery) do not apply: there is no
  n-gram model in prod.

## Learned speller, prototype (23 Nov 2026): not adopted

The question was whether a second candidate generator could find the words the joint search misses. The search
prices only single-letter edits, so its fix rate falls with edit distance. On the shipped model, Birkbeck held
cases are fixed 80.7% at one edit, 26.8% at two, 2.5% at three and 0% at four or more.

**Ceiling (oracle).** The true target was added as a candidate at spelling cost c (plus the first-letter cost) for
every typed non-word. The commit rule was then replayed with `fasteval.Bench`, rules on, with taps; the replay
matches the C++ decoder on 100% of commits. `IOSBench` `KB_DUMP=2` now writes the target's lookup values as `"tg"`.

| Held, fixed % | Now | c = 0.5 | c = 1 | c = 1.5 | c = 2 | c = 3 |
|---|---|---|---|---|---|---|
| ECPS | 90.6 | 96.6 | 95.3 | 93.5 | 92.7 | 90.8 |
| Synthetic | 91.9 | 98.0 | 95.8 | 94.1 | 93.0 | 92.0 |
| Birkbeck | 32.6 | 92.2 | 86.5 | 79.4 | 63.3 | 33.4 |
| Holbrook | 43.8 | 91.3 | 81.1 | 69.1 | 59.6 | 44.7 |
| Wikipedia | 81.5 | 94.8 | 92.6 | 89.3 | 84.6 | 81.5 |

**Prototype.** A Brill–Moore error model: aligned (typed, word) pairs give chunk rewrites with 0–2 letters of
context and word-edge marks (`^ph→^f`, `ica→aca`), each costing −ln P(chunk typed this way). A best-first
search over the 185k-word dictionary trie returns the eight cheapest words. Those words joined the complete
candidates at cost a × cost + b (plus the first-letter cost) for typed non-words only.
- **Data:** rules came from the tune halves of ECPS, Aspell, Birkbeck, Holbrook and Wikipedia. Splits are by target
  word, so no held target is seen.
- **Calibration:** a, b, top-k and the gate (none, two-or-more edits only, skip capitalised words mid-sentence,
  confident top candidate only) were chosen on a second, target-disjoint half of tune. Rules were learned on the
  other half.
- **Result:** the chosen setting was confident top candidate, a 0.25, b 1.0.

| Held | Now | Speller | Δ | Rules without Birkbeck | Δ |
|---|---|---|---|---|---|
| ECPS fixed | 90.63 | 91.30 | +0.68* | 91.26 | +0.63* |
| Birkbeck fixed | 32.56 | 35.06 | +2.50* | 34.16 | +1.61* |
| Aspell fixed | 53.16 | 54.85 | +1.69 | 54.85 | +1.69 |
| Holbrook fixed | 43.78 | 45.11 | +1.33 | 44.44 | +0.67 |
| Wikipedia fixed | 81.55 | 83.27 | +1.73* | 83.36 | +1.82* |
| ECPS left uncorrected ↓ | 2.69 | 2.32 | −0.37* | 2.34 | −0.35* |
| GUARD unknown names changed ↓ | 49.32 | 53.08 | **+3.77\* fail** | 52.40 | **+3.08\* fail** |
| Other guardrails | | | ±0.3, none significant | | |

**Why it fell short of the ceiling.** The speller is confident where the search already succeeds. For Birkbeck
tune cases at speller cost ≤ 2, 1,494 were already fixed and 117 were newly fixed. Of the cases the search
misses, 2,732 were not found by the speller and 1,702 cost more than 2.5. The speller's cost for a typed name's
nearest word (median 4.0) overlaps its cost for real Birkbeck targets (median 5.0), so the bias b must stay near
1 to protect names and rare words. Cheaper settings reach about +6 points mean accuracy on tune, but fail the
names, rare-word and Tenglish guardrails.

**What would change the result:** a speller much sharper on 3+ edit errors (more and different training data,
pronunciation-based matching, or a learned character model), together with a signal that separates intended
unknown words from misspellings. The prototype and how to rerun it are in `tools/nss/speller/` (README there).

**Speed.** The Python search takes 22.6 ms p50 and 110 ms p99 per typed non-word (M1), expanding 2,422 trie nodes at
p50 and 17,380 at p99. It would run only once per word, on Space, and only when the typed text is not a dictionary
word. A C++ port on the existing packed lexicon trie would add about 26k rules (under 1 MB) and is estimated at
about 1–5 ms per such word. That is an estimate from the node counts, not a measurement.

## How to test a rule

```
cd tools/evaluation/autocorrect
python3 evaluate.py build --bin rules --tuning
# each configuration runs on every core at once (held half, ~7 CPU-minutes per configuration on an M1)
python3 ablate.py run x-raw=nssRules=0 x-new=nssRules=1,nssRuleNew=1,...
python3 evaluate.py score x-new --vs x-raw
python3 ablate.py latency raw=nssRules=0 all=nssRules=1      # uncontended latency
python3 evaluate.py golden --write                           # then sh native/tests/run.sh
```

Six configurations take about 7 minutes on 8 workers (the phonetic test, with four configurations, took 5 min 8 s). Both scripts now hold
`caffeinate` while they run: without it a background job's workers were idled (12 min 38 s for four configurations on 15 Nov).
Rule-test runs are stored in `results/performance-tests/rule-tests-<date>/`; the prod standing is in
[performance-tests.md](performance-tests.md).
Add a new rule as a `KB_TUNABLE(nssRule…)` in NssRules.hpp, measure it alone and as all-but-one,
and add its row to the tables above.
