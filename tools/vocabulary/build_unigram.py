#!/usr/bin/env python3
"""Build a broad KBLM v6 unigram lexicon for the existing CIFG Neural Search Space.

No neural vocabulary edits, n-grams, phrase tables, or invented observed counts.
The complete additions list and count ledger are generated from source data.
"""
from __future__ import annotations
import argparse
import bz2
from collections import Counter
import csv
import gzip
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import struct
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import build_language_data as writer
from verify_language_data import Pack
from vocabulary.build_modern import catalog, atomic

WORD = re.compile(r"[a-z]+(?:'[a-z]+)*\Z")
EMITTABLE = re.compile(r"[a-z']+\Z") # Match native NeuralLexicon::letters exactly.
SOURCES = ("subtitle", "tatoeba", "wikitext")
SCALE = 1_000_000_000  # quantization scale, NOT a corpus size
FLOOR = 1             # explicit smoothing mass; runtime uses stored frequency + 1
CORPUS = ROOT / "tools/.cache/rigorous-2026-11-02/corpus"
MODEL_VOCAB = ROOT / "tools/data/nss/english-nss-vocab-30k.tsv"
PINNED_COUNTS = "94ba52d72743f7f7697cd0f51400d29689d6318ec73b41784df7d54eb6249464"

def sha(path):
    return writer.sha256(Path(path))

def allowed(word):
    return bool(WORD.fullmatch(word)) and 2 <= len(word) <= 32 and word not in writer.EXCLUDE

def pack_words(path):
    words, weights = Pack(path).vocabulary()
    return dict(zip((w.decode("utf8") for w in words), weights))

def source_data(corpus):
    manifest = json.loads((corpus / "corpus.json").read_text())
    writer.require_hash(corpus / "counts.tsv.gz", PINNED_COUNTS)
    if manifest["counts_sha256"] != PINNED_COUNTS:
        raise ValueError("corpus/count manifest mismatch")
    counts = {}
    with gzip.open(corpus / "counts.tsv.gz", "rt") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            counts[row["word"]] = {k: int(v) for k, v in row.items() if k != "word"}
    path = writer.CACHE / "en_full.txt"
    writer.require_hash(path, writer.DICT_SHA256)
    subtitle = Counter()
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            subtitle[parts[0]] += int(parts[1])
    return manifest, counts, subtitle

def split_counts(corpus, split):
    # A read-only connection prevents evaluation from altering the frozen split.
    db = sqlite3.connect(f"file:{corpus / 'corpus.sqlite'}?mode=ro", uri=True)
    counts = {s: Counter() for s in ("tatoeba", "wikitext")}
    try:
        for source, text in db.execute(
                "SELECT source,text FROM sentences WHERE split=? AND source IN ('tatoeba','wikitext')",
                (split,)):
            counts[source].update(text.split())
    finally:
        db.close()
    return counts

def fit_mixture(rates, words, neural, valid):
    """Fit on validation OOV conditional likelihood, matching NSS's <unk> allocation."""
    oov = np.array([w not in neural and bool(EMITTABLE.fullmatch(w)) for w in words])
    index = {w: i for i, w in enumerate(words)}
    validation = []
    for source, counts in valid.items():
        targets = [(index[w], n) for w, n in counts.items() if w in index and oov[index[w]]]
        validation.append((source, np.array([i for i, _ in targets], dtype=np.int64),
                           np.array([n for _, n in targets], dtype=np.float64)))
    trials = []
    best = None
    # A fixed grid registered in code before accessing test. No typing cases tune this.
    for sub in range(11):
        for tat in range(11 - sub):
            weights = np.array([sub, tat, 10 - sub - tat], dtype=float) / 10
            mass = FLOOR + SCALE * (weights @ rates)
            probability = mass / mass[oov].sum()
            loss = {}
            for source, ids, n in validation:
                if not len(ids): raise ValueError("validation has no in-lexicon neural-OOV words")
                loss[source] = float(-(n @ np.log(probability[ids])) / n.sum())
            macro = sum(loss.values()) / len(loss)
            trial = {"weights": dict(zip(SOURCES, map(float, weights))),
                     "neural_oov_validation_nll": loss, "macro_nll": macro}
            trials.append(trial)
            if best is None or macro < best[0] - 1e-12:
                best = (macro, weights, trial)
    return best[1], trials, best[2]

def lexical_metrics(counts, vocabulary, weights, neural):
    """Coverage and common-support likelihood; uncovered tokens stay visible."""
    emittable = {w for w in vocabulary if EMITTABLE.fullmatch(w)}
    mass = sum(weights[w] + 1 for w in emittable if w not in neural)
    result = {}
    for source, rows in counts.items():
        total = sum(rows.values())
        seen = sum(n for w, n in rows.items() if w in emittable)
        outside = sum(n for w, n in rows.items() if w not in neural)
        supported = [(w, n) for w, n in rows.items() if w in emittable and w not in neural]
        tokens = sum(n for _, n in supported)
        nll = sum(-n * np.log((weights[w] + 1) / mass) for w, n in supported)
        result[source] = {"tokens": total, "covered_tokens": seen,
                          "coverage": seen / total, "neural_oov_tokens": outside,
                          "covered_neural_oov_tokens": tokens,
                          "neural_oov_coverage": tokens / max(1, outside),
                          "supported_neural_oov_nll": float(nll / max(1, tokens))}
    return result

def policy_sidecar(path, vocab):
    ids = {w: i for i, (w, _) in enumerate(vocab)}
    # Policy only: no prefix boosts (flag 4), no reviewed context continuations.
    records = sorted((ids[w], int(r["preserve"]) | (int(not r["autocorrect"]) << 1))
                     for w, r in catalog().items() if w in ids and (r["preserve"] or not r["autocorrect"]))
    data = struct.pack("<8s4I32s", b"KBMODERN", 1, len(vocab), len(records), 0,
                       bytes.fromhex(sha(path)))
    data += b"".join(struct.pack("<2I", *r) for r in records)
    atomic(path.with_suffix(".kbmodern"), data + hashlib.sha256(data).digest())

def write_pack(path, weights):
    vocab = sorted(weights.items(), key=lambda x: (-x[1], x[0]))
    writer.write_bin(vocab, {}, {}, [], output=path, version=6, max_bytes=32_000_000)
    policy_sidecar(path, vocab)

def build(baseline, out, corpus=CORPUS):
    out.mkdir(parents=True, exist_ok=True)
    if baseline.resolve() == (out / "english-unigram.bin").resolve():
        raise ValueError("baseline must remain separate from output")
    old = pack_words(baseline)
    tiers = writer.load_esdb_tiers()
    # Include spelling authority's rare forms for recognition; do not label them observed.
    additions = {w for w in tiers if allowed(w)} - old.keys()
    words = sorted(old.keys() | additions)
    source_manifest, counts, subtitles = source_data(corpus)
    print(f"Loaded {len(words):,} forms; {len(additions):,} added. Fitting unigram mixture.", flush=True)
    neural_manifest = json.loads((ROOT / "keyboard/nss-english.manifest.json").read_text())
    writer.require_hash(ROOT / "keyboard/nss-english.nsslm", neural_manifest["sha256"])
    writer.require_hash(MODEL_VOCAB, neural_manifest["vocabulary_sha256"])
    with MODEL_VOCAB.open() as f:
        neural = {r["word"] for r in csv.DictReader(f, delimiter="\t") if int(r["id"]) >= 4}
    missing_neural = neural - set(words)
    if missing_neural: raise ValueError(f"{len(missing_neural)} neural output words missing")
    totals = {"subtitle": sum(subtitles.values()),
              **{s: sum(r.get(s + "_count", 0) for r in counts.values()) for s in SOURCES[1:]}}
    rates = np.array([[subtitles[w] / totals["subtitle"] for w in words],
                     *[[counts.get(w, {}).get(s + "_count", 0) / totals[s] for w in words]
                       for s in SOURCES[1:]]])
    valid = split_counts(corpus, "valid")
    mix, trials, selected = fit_mixture(rates, words, neural, valid)
    estimate = mix @ rates
    # Store estimated mass; NeuralLexicon adds the explicit single smoothing count.
    weights = {w: min(0xffffffff, int(round(SCALE * p))) for w, p in zip(words, estimate)}
    candidate = out / "english-unigram.bin"
    write_pack(candidate, weights)
    write_pack(out / "baseline-unigram.bin", old)
    all_mass = sum(weights[w] + 1 for w in words if EMITTABLE.fullmatch(w))
    added_observed = sum(subtitles[w] + sum(counts.get(w, {}).get(s + "_count", 0) for s in SOURCES[1:]) > 0
                         for w in additions)
    fields = ["word", "added", "esdb_tier", "old_weight", "subtitle_observed_count",
              "tatoeba_train_count", "tatoeba_train_docs", "wikitext_train_count", "wikitext_train_docs",
              "soda_train_count_not_used", "estimated_probability", "stored_weight",
              "smoothing_mass", "nss_emittable", "neural_output_word"]
    with (out / "unigrams.tsv").open("w") as ledger, (out / "ADDED_WORDS.tsv").open("w") as added:
        writers = [csv.writer(f, delimiter="\t", lineterminator="\n") for f in (ledger, added)]
        for f in writers: f.writerow(fields)
        for w in words:
            r = counts.get(w, {})
            row = [w, int(w in additions), tiers.get(w, ""), old.get(w, ""),
                   subtitles[w], r.get("tatoeba_count", 0), r.get("tatoeba_docs", 0),
                   r.get("wikitext_count", 0), r.get("wikitext_docs", 0), r.get("soda_count", 0),
                   format((weights[w] + 1) / all_mass, ".12g") if EMITTABLE.fullmatch(w) else "",
                   weights[w], FLOOR, int(bool(EMITTABLE.fullmatch(w))), int(w in neural)]
            writers[0].writerow(row)
            if w in additions: writers[1].writerow(row)
    # The user-facing list is always generated by set difference, never hand maintained.
    (out / "ADDED_WORDS.txt").write_text("\n".join(sorted(additions)) + "\n")
    common = {w for w in old if EMITTABLE.fullmatch(w) and w not in neural}
    common_counts = {s: Counter({w: n for w, n in c.items() if w in common}) for s, c in valid.items()}
    report = {
        "schema_version": 1, "status": "candidate; device and native-speaker acceptance pending",
        "baseline_words": len(old), "words": len(words), "added_words": len(additions),
        "removed_words": 0, "added_with_human_source_occurrences": added_observed,
        "added_without_measured_human_usage": len(additions) - added_observed,
        "new_word_admission": "Pinned ESDB tiers 60/70; 2-32 lower-case ASCII letters with interior apostrophes; existing contraction exclusions. No arbitrary size cap. All baseline forms retained.",
        "frequency_estimation": "Exact observed subtitle/Tatoeba/WikiText counts kept separate. Validation fits a source mixture for neural-OOV conditional likelihood. Stored weights are quantized estimates, not observed counts. Every ASCII word receives one explicit smoothing mass.",
        "synthetic_soda": "Counts recorded for audit only; not used for admission, weights or validation selection.",
        "quantization_scale": SCALE, "smoothing_mass": FLOOR, "source_totals": totals,
        "selected": selected, "trials": trials,
        "validation": {"baseline": lexical_metrics(valid, old, old, neural),
                       "candidate": lexical_metrics(valid, weights, weights, neural),
                       "common_support_baseline": lexical_metrics(common_counts, old, old, neural),
                       "common_support_candidate": lexical_metrics(common_counts, weights, weights, neural)},
        "ngrams": {"bigrams": 0, "trigrams": 0, "starters": 0, "phrase_contexts": 0},
        "policies": "Preserve/no-auto-replacement only; no suggestion boosts.",
        "baseline_sha256": sha(baseline), "model_sha256": neural_manifest["sha256"],
        "builder_sha256": sha(__file__), "validation_database_sha256": sha(corpus / "corpus.sqlite"),
        "model_vocabulary_sha256": sha(MODEL_VOCAB), "model_output_layer_changed": False,
        "inputs": {str(p.relative_to(ROOT)): sha(p) for p in [
            writer.ESDB, writer.CACHE / "en_full.txt", corpus / "counts.tsv.gz",
            corpus / "corpus.json", ROOT / "tools/vocabulary/modern_catalog.json"]},
        "split_limitations": source_manifest["limitations"],
        "test_used_for_selection": False,
        "limitations": [
            "Word forms include inflections and possessives, not this many distinct headwords.",
            "The historical ESDB snapshot is American English and folds source casing/accents to ASCII; it is not an unmodified regional spelling catalog.",
            "No fresh representative Indian-English or contemporary human-chat frequency corpus is available.",
            "Unobserved forms have smoothing weights, not empirically measured frequencies.",
            "Existing non-ASCII and hyphenated forms are retained but remain unsupported by the NSS ASCII graph.",
            "Existing baseline lexical noise is retained for compatibility.",
            "Large spelling coverage alone does not establish better correction or prediction."
        ]
    }
    # Build-time packaging inputs. The installer validates before copying any resource.
    (out / "bundle.sha256").write_text("".join(
        f"{sha(out / name)}  {name}\n"
        for name in ("english-unigram.bin", "english-unigram.kbmodern")))
    (out / "model.sha256").write_text(neural_manifest["sha256"] + "\n")
    with (out / "MODERN_COVERAGE.tsv").open("w") as f:
        table = csv.writer(f, delimiter="\t", lineterminator="\n")
        table.writerow(["word", "register", "region", "present", "protected", "neural_output_word",
                        "human_observed_count", "stored_weight"])
        for w, r in sorted(catalog().items()):
            observed = subtitles[w] + sum(counts.get(w, {}).get(s + "_count", 0) for s in SOURCES[1:])
            table.writerow([w,r["register"],r["region"],int(w in weights),int(r["preserve"]),
                            int(w in neural),observed,weights.get(w,"")])
    (out / "NOTICE.txt").write_text(
        "Generated NSS unigram derivative. No definitions or example sentences are included.\n"
        "ESDB: Kevin Atkinson and contributors; pinned revision " + writer.ESDB_COMMIT + ".\n"
        "Source: https://github.com/en-wl/wordlist\n"
        "The historical American-English snapshot folds uppercase and accents to ASCII.\n"
        "Existing British/Indian and other regional forms are retained from the baseline.\n"
        "FrequencyWords: Hermit Dave; English 2018, commit " + writer.DICT_COMMIT + "; CC BY-SA 4.0.\n"
        "Source: https://github.com/hermitdave/FrequencyWords\n"
        "Tatoeba: sentence contributors; English export 2026-10-20, CC BY 2.0 France (subset CC0).\n"
        "Source: https://tatoeba.org/en/downloads\n"
        "WikiText-103: Stephen Merity et al.; Wikipedia contributors; CC BY-SA 3.0.\n"
        "Source: https://huggingface.co/datasets/Salesforce/wikitext\n"
        "Baseline project/CoreV4 spellings and editorial spelling policies are retained.\n"
        "Raw per-source counts and derived mixture weights are distinguished in the ledger.\n"
        "SODA synthetic counts are audit metadata only, not used to estimate probabilities.\n"
        "Source-specific notices and transformations: ../../../../THIRD_PARTY_NOTICES.md\n\n"
        + (ROOT / "tools/vocabulary/ESDB_COPYRIGHT.md").read_text())
    report["artifacts"] = {p.name: {"bytes": p.stat().st_size, "sha256": sha(p)}
                           for p in sorted(out.iterdir()) if p.is_file() and p.suffix in (".bin", ".kbmodern", ".tsv", ".txt")}
    atomic(out / "manifest.json", (json.dumps(report, indent=2) + "\n").encode())
    (out / "SUMMARY.md").write_text(
        "# Generated NSS unigram dictionary\n\n"
        f"{len(words):,} word forms; {len(additions):,} additions; no removals.\n\n"
        f"{added_observed:,} additions have measured occurrences in the human-source inputs; "
        f"{len(additions)-added_observed:,} have no such observations and use explicit smoothing.\n\n"
        "All additions are in [ADDED_WORDS.txt](ADDED_WORDS.txt). "
        "Per-word source counts and weights are in [ADDED_WORDS.tsv](ADDED_WORDS.tsv); "
        "the complete model ledger is [unigrams.tsv](unigrams.tsv).\n\n"
        f"Pack size: {candidate.stat().st_size:,} bytes. "
        "Zero bigrams, trigrams, starter rows and phrase contexts. "
        "The CIFG model and its output vocabulary are unchanged.\n\n"
        "Frequency estimates are calibrated on validation, not invented word counts. "
        "SODA synthetic dialogue counts are excluded from the frequency model. "
        "See manifest.json for exact source hashes, mixture trials and limitations.\n")
    print(json.dumps({k: report[k] for k in ("words", "added_words", "added_with_human_source_occurrences", "selected")}), flush=True)
    return report

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=ROOT / "keyboard/langdata.bin")
    parser.add_argument("--out", type=Path, default=ROOT / "tools/data/nss/unigram-v1")
    parser.add_argument("--corpus", type=Path, default=CORPUS)
    args = parser.parse_args()
    build(args.baseline, args.out, args.corpus)

if __name__ == "__main__":
    main()
