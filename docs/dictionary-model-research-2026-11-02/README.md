# Dictionary and language-model research — 2 November 2026

The current 30k vocabulary is usable but its modern coverage is incomplete. A new source-count table, two vocabulary challengers, a rebuilt dictionary pack, and five trained architecture challengers are available. **The experiments do not yet demonstrate a better replacement for the existing keyboard.** The production dictionary, neural vocabulary, and installed neural model were not replaced.

## What was validated

The production neural list has 30,000 ordinary words plus four special tokens and is paired with its trained output layer. The full pack contains 114,283 stored forms. The original vocabulary manifest's dictionary hash still matches the current pack. The 30k list was selected without a chat corpus; its scores are smoothed, weighted frequency estimates, not observed counts.

The new audit processed **186,283,349 deduplicated training word tokens**: 95,098,800 SODA, 12,295,767 Tatoeba, and 78,888,782 WikiText tokens. A separate FrequencyWords subtitle list contributes 690,516,097 counted tokens. The audit retains document-level train/validation/test assignment and globally deduplicates normalized sentences across those three text sources. Later copies are omitted; corpus order is therefore part of the reproducible policy.

There are **53,201 full-pack entries with weight at most 1**. Some come from a vocabulary union with weak or absent frequency evidence. These should remain distinguishable from genuinely observed rare words. The 112,323-row [unigram table](unigrams.tsv.gz) contains observed training counts and document counts per source, original subtitle counts, a labelled fractional subtitle-apostrophe estimate, the old pack weight, and a separately labelled pooled rate per million. Adding source counts is not a claim about a population's messaging frequency.

SODA is synthetic conversation, not a sample of human keyboard usage; its dataset card identifies machine-generated data and CC BY 4.0. Tatoeba's dump is dated 2026, but it is a sentence bank rather than a current usage survey. The subtitle and WikiText evidence is substantially older. [SODA dataset card](https://huggingface.co/datasets/allenai/soda)

## Vocabulary coverage

Selection uses training counts only. MASC remains an external reporting set and did not decide vocabulary admission. It is an older, document-separated evaluation, not a modern or user-separated messaging benchmark.

| Vocabulary | MASC token coverage | SODA validation | Tatoeba validation | WikiText validation |
|---|---:|---:|---:|---:|
| Original 30k | 95.863% | 99.100% | 97.916% | 93.345% |
| Candidate 30k | 95.900% | 99.219% | 97.899% | 93.924% |
| Candidate 60k | 97.486% | 99.396% | 98.596% | 96.006% |

The 30k challenger swaps 2,860 words. Its gain on MASC is just 0.037 percentage points, and Tatoeba coverage falls slightly. Arithmetic pooling also admits more names and entities than the previous geometric rule. This is a candidate to review, not an approved replacement. Inspect [every addition/removal with source evidence](vocabulary-changes.tsv).

The editorial modern-term diagnostic contains 161 unique probes: the original list includes 65 and the challenger 74. **These probes overlap the admission policy and are not an independent accuracy measurement.** Examples newly covered by the model list include covid, WhatsApp and TikTok. The candidate pack adds 13 evidenced forms, including TikTok, Reddit, Airbnb, Uber and smartwatch. Case is normalized to lowercase.

Important gaps remain: the observed text has only eight occurrences of chatgpt, three of llm, one of passkey, and none of openai. Screenshot is in the full lexicon but still misses the model's 30k cutoff. UPI is also below that cutoff. Inventing high counts for these would hide the data problem. Digit-bearing or hyphenated brands additionally need an explicit runtime tokenization policy.

The original NSS paper uses a limited neural word vocabulary with a larger unigram lexicon, distributing unknown-word probability through the fallback. Its 30k figure is an engineering choice, not proof that 30k is optimal for this product. [NSS paper](https://aclanthology.org/2024.emnlp-industry.93/)

## Dictionary pack experiment

The candidate pack contains 114,296 forms and is 28,312,535 bytes, versus 28,311,910 bytes for the current pack. Numeric word IDs and the trie were rebuilt. All existing logical bigram/trigram counts, context denominators, and sentence-starter counts were verified identical. New binary unigram weights are calibrated estimates on the original total-mass scale, rounded with floor 1; the TSV preserves the actual observed counts separately.

A fresh C++ benchmark was built from the current native source. Both packs ran on the same 1,278-case deterministic subset of the repository's held target-word split. This is screening on an existing benchmark, not a new blind test. Higher numbers below are better, including preservation of clean input.

| Set | Cases | Current pack | Candidate pack | Metric |
|---|---:|---:|---:|---|
| apos | 36 | 36 | 36 | correct committed text |
| clean | 200 | 198 | 199 | correct committed text |
| ecps | 200 | 186 | 184 | correct committed text |
| ecps_ok | 200 | 200 | 199 | correct committed text |
| hard | 42 | 36 | 36 | correct committed text |
| nw | 200 | 40 | 40 | next-word top 3 |
| realword | 200 | 91 | 90 | correct committed text |
| syn | 200 | 169 | 170 | correct committed text |

The results are mixed: real misspellings lose two correct cases, real-word errors lose one, synthetic typos gain one, and clean-input gains/losses offset. No tested category establishes a statistically reliable gain. **Do not install the reweighted pack on this evidence.** Latency in this replay is not an acceptance measurement because training ran concurrently. [Detailed paired changes](decoder-comparison.json)

## Models actually trained

A train-only **6,000-piece SentencePiece unigram tokenizer** was trained, with fixed special IDs, canonical text and required ASCII characters. The five from-scratch arms saw the same 250,005 original-word sequence, with no truncation; the two adaptation arms each saw 500,012 original words. Confirm exact counts in the JSON rather than treating these rounded budgets as corpus size. The raw training mix targets 50% SODA, 25% Tatoeba and 25% WikiText words. FrequencyWords supplies counts only; it is not a sequence-training corpus.

SentencePiece provides unigram and BPE tokenizers; here the unigram variant was exercised. Subword word scores include the probability of ending a word, rather than rewarding short piece strings without a boundary. [SentencePiece implementation](https://github.com/google/sentencepiece)

The diagnostic below gives every model the same 160 contexts, 40 per source including external MASC, and up to 32 word candidates including the target. Nearby spellings and common words supply distractors. **The target is injected, so this measures language ranking, not beam recall or end-to-end correction.** It is too small for model promotion. Existing baselines have vastly more training than the new pilot models; the table does not establish an architecture ranking at convergence.

| Model | Parameters | Tokens | New original words | Selected step | Candidate top 1 | MRR |
|---|---:|---|---:|---:|---:|---:|
| baseline-generic | 3,362,638 | word | existing checkpoint | — | 55.00% | 0.657 |
| baseline-chat | 3,362,638 | word | existing checkpoint | — | 54.37% | 0.657 |
| word-cifg | 2,065,716 | word | 250,005 | 1512 | 32.50% | 0.467 |
| word-gru | 2,213,940 | word | 250,005 | 1512 | 36.25% | 0.480 |
| sp-lstm | 804,208 | sp | 250,005 | 1512 | 38.75% | 0.501 |
| sp-gru | 878,448 | sp | 250,005 | 1512 | 35.63% | 0.492 |
| sp-transformer | 934,896 | sp | 250,005 | 1512 | 36.88% | 0.494 |
| warm-chat | 3,362,638 | word | 500,012 | 0 | 54.37% | 0.657 |
| warm-chat-control | 3,362,638 | word | 500,012 | 0 | 54.37% | 0.657 |

Both adaptation runs selected **step 0**, their starting checkpoint, on validation. Additional training did not produce a better selected checkpoint. The revised-vocabulary starting model ties the old chat baseline on this ranking diagnostic. No claim of improved fine-tuned weights is supported.

Token perplexity across different tokenizers is deliberately not used to pick a winner. The JSON also records original-word-normalized loss, but subword loss follows a deterministic segmentation path and does not marginalize over all segmentations. The current open-set unknown bucket further limits direct word/subword likelihood comparisons. The shared candidate-ranking task is the common diagnostic.

The Python subword scorer recomputes a candidate batch and currently takes roughly 33–37 ms at p95, versus roughly 1–2 ms for word-model scoring on this CPU. Prefix caching and native integration differ, so these are implementation timings, not intrinsic architecture costs or iPhone predictions. The current C++ word-LM runtime does not directly accept SentencePiece tokens or the Transformer state.

Five new models pass full-sequence versus streaming-state checks, with maximum feature drift below 1.5e-6. A trained word-GRU was quantized to a 2,767,184-byte NSS export and passed the native harness on **220 reference scores**, maximum absolute error **0.000136226**. This proves export/runtime agreement; it does not prove typing quality. [Native parity evidence](native-gru-parity.log)

Training samples have zero exact-sentence overlap with sampled validation/test sets or the entire external MASC sentence set. This does not establish user or author separation. [Split check](split-overlap.json)

## Modern data download

A downloader is implemented that resolves a FineWeb revision, chooses a bounded 2025-26 crawl shard, streams it to a temporary file, checks length and available LFS SHA-256, and records source provenance. FineWeb documents 2025 crawl configurations. The dataset license and underlying web-content rights must remain separate metadata fields. [FineWeb dataset card](https://huggingface.co/datasets/HuggingFaceFW/fineweb)

The actual download attempt failed at DNS resolution in this execution environment. **No new modern dataset was downloaded or used**, and no cloud GPU was rented. [Recorded failure](modern-download.json)

## Next training plan

1. **Acquire current evidence before enlarging the model.** Run the pinned downloader with network access, initially one shard under 3 GB. Add an independently licensed contemporary conversational source when verified. Keep crawl time, provenance, domains and raw counts. Reserve modern evaluation documents before vocabulary selection, tokenizer training or counting. Deduplicate within and across sources, and check external evaluation overlap.
2. **Rebuild frequencies and review the 30k cutoff.** Add modern per-source counts and document diversity to the existing ledger. Keep editorial boosts in their own columns. Compare the old geometric admission policy, the new arithmetic policy, and a capped mixture that limits synthetic names/entities. Test 30k, 45k and 60k, plus a conservative lexicon-only expansion. Keep protected names, Indian English and chat terms in separate evaluation slices. Do not force all trending terms into 30k at invented frequencies.
3. **Run a staged architecture comparison.** First screen at 10 million identical original words per arm, then train the best two to at least the existing model's budget, with three seeds. Compare NSS-style 96-wide projected CIFG/LSTM and projected GRU; compare 4k/6k/8k SentencePiece LSTM/GRU and a small sliding-window Transformer. Start with a fixed prospective mix of 40% SODA, 30% modern web, 20% Tatoeba and 10% WikiText, then tune only on validation. The current bounded pilot needs full-corpus sharded/memory-mapped preprocessing before such runs; repeating its 105k sampled sentences is not equivalent to acquiring a large corpus.
4. **Evaluate surface words and corrections.** Use the same complete-word boundary convention, fixed candidate sets and then the actual spatial decoder. Measure candidate-oracle recall, corrections, false corrections, next-word top 1/3, names and modern/OOV coverage. Use fresh document/user-separated data where metadata permits. Report grouped paired confidence intervals; demand a reliable correction gain without a material increase in false corrections. No cross-tokenizer perplexity shortcuts.
5. **Integrate only the winning path.** The word-level recurrent models can use the existing quantized C++ kernel. Subword models need a lexical-prefix/piece continuation graph and cached context state; the Transformer also needs a fixed-window cache and runtime kernel. Preserve the vocabulary/tokenizer/checkpoint/pack hashes as one bundle. Recheck native parity after int8 conversion and calibrate unknown-word mass using the selected corpus.
6. **Measure on physical iPhones before promotion.** Record p50/p95/p99 decoding latency, cold start, peak/sustained memory and extension behavior under pressure. Compare 30k/60k output-layer costs and full bundle size. Promote only after quality and device gates pass; preserve the current pack/model as the rollback artifact.

A full GPU run still needs a provider/account and an explicit spending limit. No paid compute or upload of private recordings was authorized or performed.

## Artifacts and reproduction

- [Audit, input hashes, coverage, modern diagnostic](audit.json)
- [30k challenger](vocabulary-30000.tsv), [60k challenger](vocabulary-60000.tsv), [source-separated unigrams](unigrams.tsv.gz)
- [Model metrics and training histories](model-results.json), [candidate ranking](candidate-ranking.json), [candidate cases](candidate-cases.json)
- [Artifact validation](validation.json), [five unit tests](tests.log), [GRU export manifest](word-gru.manifest.json)

Code and exact commands: [research tools README](../../tools/nss/research_2026_11_02/README.md). Binary packs, PyTorch checkpoints, raw sentence samples and tokenizer files remain under tools/.cache/dictionary-research-2026-11-02. That cache is an experimental workspace, not an Xcode resource. See the artifact manifest for exact paths and hashes.
