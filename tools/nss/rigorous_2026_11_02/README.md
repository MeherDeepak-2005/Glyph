# Rigorous dictionary/model experiments — 2 November 2026

This is active research. A better production model has not yet been demonstrated. See protocol.json for registered budgets and readiness.py for evidence gates. The previous 250k-word pilot is not an architecture comparison against a model trained on roughly 130M tokens.

## Completed preparation

- Full cached corpora were processed, with document splits before counts/tokenizers, global exact sentence/document deduplication and holdout precedence. MASC exact matches are excluded from new training. The retained training corpus contains 185,845,175 words, not just the earlier 105k-sentence sample.
- The screening plan contains 10,000,015 original words in 894,250 unique sentences, sampled without replacement. Source proportions by words: SODA 50%, Tatoeba 25%, WikiText 25%. Modern mixtures switch to 40%/15%/15%/30% FineWeb after a verified modern corpus is prepared.
- Counts preserve every observed source occurrence in the retained training corpus. Runtime pooled_ppm weights are source-mixture estimates; subtitle apostrophe mapping is also an estimate. Neither is described as raw counts.
- Vocabulary weights were tuned on validation only over a registered grid, independently for 30k/45k/60k sizes. Capitalization, rare forms, apostrophes and morphology have review tables. Capitalization includes names, brands and legitimate adjectives; it does not justify automatic deletion.
- Broad lexical admission proposed 4,861 additions, many names/entities. The paired 30k pack preserves all shipped forms and adds only its 783 required model words, excluding 4,078 other proposals. Every logical bigram/trigram count and denominator is unchanged. The pack grows by 28,638 bytes.

## Running experiments

Ten 10M-word arms: repository reference CIFG 96/670/96; smaller word CIFG/LSTM/GRU; SentencePiece unigram and BPE LSTM/GRU/Transformer. All use the same raw sentence plan and batch ordering. A separate 60-process-CPU-second checkpoint supports a matched-training-compute comparison; validation, tokenizer fitting and checkpoint IO are outside that clock. These are screening runs, not converged architecture winners.

Initial/best/last checkpoints, optimizer/RNG state, dataset/vocabulary hashes, learning curves and gradient norms are retained. Tiny-subset convergence and causal/streaming/BOS-reset tests must pass. Loss uses exact, memory-bounded full softmax. Per-model result.json files are authoritative when concurrent workers update the summary index.

A controlled adaptation sweep compares original-vocabulary and remapped checkpoints on the same unique 1M-word subset at learning rates 1e-5, 5e-5 and 2e-4. The first rate selected step 1,397 rather than initialization for both arms: original-vocabulary validation token NLL 4.22936 → 4.22463, remapped-vocabulary 4.26579 → 4.26086. Compare each to its own initialization; the two vocabularies have different target mappings. Multiple changes from the old pilot remain confounded, so this does not establish one causal fix or better decoder quality.

## Decoder evidence so far

Frozen native validation covers 4,642 cases from 1,173 documents: 512 SODA, 512 Tatoeba and all 149 available WikiText validation articles. Actual counts and domain results are reported; the sample is not balanced by pretending more articles exist. Errors/taps are synthetic and identical across models. Targets are never inserted into candidate generation. Metrics include committed correctness, correction precision/recall, false corrections, candidate recall and top-1/3, with paired cluster bootstrap intervals.

Against the shipped n-gram pack, the revised unigram pack changed clean false corrections from 21/1,173 to 12/1,173. The paired rate difference is -0.767 percentage points, 95% bootstrap interval [-1.449, -0.171]. Overall committed correctness changed by -0.029 points with an interval spanning zero. These validation-tuned results do not justify release.

The existing chat checkpoint (not newly trained here) improved top-3 against the shipped neural baseline by 1.379 points on this cohort; its committed-correctness interval spans zero. A separate full replay covers all 52,080 retained cases across every available legacy suite. Legacy tests have prior exposure and are diagnostic, never a fresh modern final test.

An intermediate trained reference checkpoint was quantized and passed 220 C++ reference-score checks: maximum absolute error 0.000044674. The Python/native export path is exercised before the sweep completes. This does not cover native subword integration or physical-device performance.

## Reproduce / resume

Run from the repository root with the existing ml environment. All outputs below are ignored research cache; no resource installation occurs.

    python tools/nss/rigorous_2026_11_02/corpus.py prepare --out tools/.cache/rigorous-2026-11-02/corpus
    python tools/nss/rigorous_2026_11_02/run_screen.py --data tools/.cache/rigorous-2026-11-02
    python tools/nss/rigorous_2026_11_02/adaptation.py --data tools/.cache/rigorous-2026-11-02
    python tools/nss/rigorous_2026_11_02/validate_native.py --data tools/.cache/rigorous-2026-11-02
    python tools/nss/rigorous_2026_11_02/legacy_full.py --data tools/.cache/rigorous-2026-11-02
    python tools/nss/rigorous_2026_11_02/test_pipeline.py
    python tools/nss/rigorous_2026_11_02/readiness.py --data tools/.cache/rigorous-2026-11-02 --out docs/rigorous-model-research-2026-11-02/readiness.json

Do not restart corpus preparation over existing outputs. Training resumes last checkpoints only when the run identity matches. Completed arms are reused. Job PIDs/logs are recorded in cache/jobs.json; cache/status.json describes the coordinator. Python/package versions are in environment.json.

## Modern data and remaining work

Python DNS fails in this sandbox, and the elevated terminal runner cannot start. Manual download is requested for one public 2.15 GB FineWeb 2025-26 shard pinned to commit 9bb295ddab0e05d785b879661af7260fed5140fc. modern-shard.json records its published SHA256. import_modern.py checks the Parquet header/footer, full hash and schema before writing a success manifest. No modern file has entered these results yet.

    python tools/nss/rigorous_2026_11_02/import_modern.py --file tools/.cache/rigorous-2026-11-02/modern/000_00000.parquet

Prepare a new corpus/output directory when incorporating modern data; keep this cached-data experiment as an ablation. Before a modern test is called fresh, exclude prior training/evaluation exact overlaps and audit near duplicates. Cached corpora lack user IDs; their split unit is the available dialogue/article/text document. Exact dedup does not certify absence of paraphrases or near duplicates.

Subwords still require actual tokenizer/word-boundary search integration and native parity; word-format export explicitly rejects them. Their token perplexity cannot be compared with word models or between unigram and BPE. Python scoring time cannot establish iPhone latency. Full selection refuses missing decoder evaluations; full_runs.py then trains two eligible finalists at 130M raw words each, seeds 731/732/733, from full-source epoch plans. Repeated full-corpus epochs are recorded, not mislabeled new unique text. Subword full-shard support remains pending if a subword finalist is chosen.

The final test must be fresh, run once, and meet registered quality limits. Physical iPhone trials must establish p50/p95, memory, resource size and false-correction acceptance. These stages remain incomplete. readiness.py returns a failing promotion gate while any evidence is missing. No paid compute was authorized or used.

Primary references: [NSS paper](https://aclanthology.org/2024.emnlp-industry.93/), [SentencePiece](https://github.com/google/sentencepiece), [SODA card](https://huggingface.co/datasets/allenai/soda), [WikiText card](https://huggingface.co/datasets/Salesforce/wikitext), [Tatoeba terms](https://tatoeba.org/en/terms_of_use), [FineWeb shard metadata](https://huggingface.co/datasets/HuggingFaceFW/fineweb/blob/main/data/CC-MAIN-2025-26/000_00000.parquet).
