# Dictionary/model research: active run

The experiment is still running; no improved production model is claimed.

- Retained training corpus: 185,845,175 words with source-separated observed counts.
- Matched screening plan: 10,000,015 words, 894,250 unique sentences, ten word/unigram/BPE architectures.
- Revised dictionary validation: 21 → 12 false corrections on 1,173 clean cases; overall correction-accuracy interval includes zero.
- First 1M-word adaptation controls select trained checkpoints, with small within-vocabulary validation-loss gains. This is not decoder-improvement evidence.
- Native intermediate recurrent export: 220 parity checks passed, maximum error 0.000044674.
- Full legacy diagnostic: 52,080 cases. Modern ingestion, native subword integration, three-seed full training, a fresh final test and physical iPhone acceptance remain pending.

Methods, caveats and exact commands are in tools/nss/rigorous_2026_11_02/README.md. The point-in-time readiness.json lists every missing gate. Live progress and job PIDs are in tools/.cache/rigorous-2026-11-02/status.json and jobs.json; per-model checkpoint/result files are authoritative. No production model/dictionary was replaced and no paid cloud compute was used.
