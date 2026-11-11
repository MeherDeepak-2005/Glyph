# Dictionary/model research tools

Measured findings and next steps: [report](../../../docs/dictionary-model-research-2026-11-02/README.md).

These tools write isolated research outputs. They do not install a pack, modify Xcode resources or promote a model. The current 30k vocabulary remains paired with its original output layer. Versions from the completed run are in [environment.json](environment.json). Python 3.11 with torch, numpy, sentencepiece and pyarrow was used; local GPU access was unavailable.

Run from the repository root with the existing ml environment activated:

```sh
conda activate ml
KB_RESEARCH_DATA=tools/.cache/dictionary-research-2026-11-02
KB_RESEARCH_TOOLS=tools/nss/research_2026_11_02
python "$KB_RESEARCH_TOOLS/audit_dictionary.py" --out "$KB_RESEARCH_DATA"
python "$KB_RESEARCH_TOOLS/build_candidate_pack.py" --counts "$KB_RESEARCH_DATA/unigrams.tsv" --out "$KB_RESEARCH_DATA/langdata-candidate.bin"
python "$KB_RESEARCH_TOOLS/verify_research.py" --data "$KB_RESEARCH_DATA"
python "$KB_RESEARCH_TOOLS/check_splits.py"
python "$KB_RESEARCH_TOOLS/test_research.py"
```

The audit is deterministic, with source order SODA, Tatoeba, WikiText; the first normalized sentence owns duplicates. Source counts use training documents only. Raw subtitle counts and fractional apostrophe-mapped estimates are separate columns. Modern-term probes overlap admission policy and are not an independent test set.

Train-only SentencePiece and five equal-word-budget architectures, plus revised-vocabulary adaptation:

```sh
python "$KB_RESEARCH_TOOLS/train_challengers.py" --data "$KB_RESEARCH_DATA" --out "$KB_RESEARCH_DATA/runs" --words 250000 --warm-words 500000 --eval-sentences 120
python "$KB_RESEARCH_TOOLS/train_challengers.py" --data "$KB_RESEARCH_DATA" --out "$KB_RESEARCH_DATA/runs-control" --words 250000 --warm-words 500000 --eval-sentences 120 --arms warm-chat-control
python "$KB_RESEARCH_TOOLS/merge_control.py" "$KB_RESEARCH_DATA/runs/results.json" "$KB_RESEARCH_DATA/runs-control/results.json"
python "$KB_RESEARCH_TOOLS/evaluate_candidates.py" --data "$KB_RESEARCH_DATA" --runs "$KB_RESEARCH_DATA/runs" --out "$KB_RESEARCH_DATA/candidate-ranking.json" --per-source 40
```

Completed arms are skipped. Use a fresh output directory for another budget. This bounded pilot samples about 105k unique sentences; increasing its budget repeats that pool and does not replace full-corpus preprocessing. Candidate ranking injects the target, so it does not measure beam survival. Cross-tokenizer perplexities are not comparable.

Both 500k-word adaptations selected step 0. Their best checkpoints contain the starting weights, not improved fine-tuned models. Five from-scratch best checkpoints contain trained weights. The final script also saves unselected last checkpoints on subsequent runs; the original adaptations retained their curves and selected initialization.

Production-path dictionary benchmark:

```sh
python tools/evaluation/autocorrect/evaluate.py build --bin dictionary-research-2026-11-02
python "$KB_RESEARCH_TOOLS/evaluate_dictionary.py" --data "$KB_RESEARCH_DATA"
python "$KB_RESEARCH_TOOLS/summarize_decoder.py"
```

Quantized word-GRU export and native C++ parity (Mac/Xcode tools required):

```sh
python "$KB_RESEARCH_TOOLS/export_recurrent.py" --checkpoint "$KB_RESEARCH_DATA/runs/word-gru.best.pt" --pack "$KB_RESEARCH_DATA/langdata-candidate.bin" --data "$KB_RESEARCH_DATA" --out "$KB_RESEARCH_DATA/word-gru.nsslm"
python "$KB_RESEARCH_TOOLS/build_parity.py"
"$KB_RESEARCH_DATA/neural-parity" "$KB_RESEARCH_DATA/word-gru.nsslm" "$KB_RESEARCH_DATA/word-gru.goldens.json" "$KB_RESEARCH_DATA/langdata-candidate.bin"
```

Subword checkpoints cannot be exported as word-level NSS models. They need piece-to-word search and runtime integration.

The optional modern-corpus downloader records failures and successes, pins the upstream commit and checks shard size and available LFS hashes. The recorded attempt failed DNS; no new web data entered these results.

```sh
python "$KB_RESEARCH_TOOLS/fetch_modern.py" --out "$KB_RESEARCH_DATA/fineweb-2025" --max-gb 3
```

Inspect the manifest before integrating a downloaded shard. The current audit does not automatically ingest FineWeb: add its reader, source-specific count columns, pinned provenance and split policy first. Full-corpus sharded preprocessing must precede the large GPU stage. These tools do not configure paid resources or cloud jobs.
