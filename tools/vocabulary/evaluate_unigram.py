#!/usr/bin/env python3
"""Evaluate the generated unigram model with a fixed CIFG model, no n-gram scoring."""
import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from vocabulary.build_unigram import CORPUS, MODEL_VOCAB, WORD, EMITTABLE, lexical_metrics, pack_words, sha, split_counts

def prepare(out, corpus=CORPUS):
    out.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(f"file:{corpus / 'corpus.sqlite'}?mode=ro", uri=True)
    rows, meta, seen, documents = [], {}, set(), Counter()
    # Fixed hash order, at most one target per document. No dictionary-dependent selection.
    for source in ("tatoeba", "wikitext"):
        query = """SELECT hash,doc,text FROM sentences WHERE source=? AND split='test'
                   AND words BETWEEN 3 AND 128 ORDER BY hash"""
        for h, doc, text in db.execute(query, (source,)):
            if doc in seen: continue
            words = text.split()
            positions = [i for i, w in enumerate(words) if 3 <= len(w) <= 18 and WORD.fullmatch(w)]
            if not positions: continue
            at = positions[int.from_bytes(h[:4], "little") % len(positions)]
            target = words[at]; context = " ".join(words[max(0, at - 8):at])
            seen.add(doc); documents[source] += 1
            mid = len(target) // 2
            forms = [("clean", "ac", target),
                     ("deletion", "ac", target[:mid] + target[mid + 1:]),
                     ("swap", "ac", target[:mid-1] + target[mid:mid+1] + target[mid-1:mid] + target[mid+1:]),
                     ("prefix", "ac", target[:max(2, mid)]), ("next", "nw", "")]
            for condition, kind, typed in forms:
                if condition == "swap" and typed == target: continue
                identifier = source + "-" + h.hex()[:16] + "-" + condition
                rows.append("\t".join([identifier, kind, context, typed, target]))
                meta[identifier] = {"source": source, "document": doc.hex(), "condition": condition,
                                    "typed": typed, "target": target, "kind": kind}
            if documents[source] == 512: break
    db.close()
    (out / "cases.tsv").write_text("\n".join(rows) + "\n")
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    (out / "cases.manifest.json").write_text(json.dumps({
        "cases": len(rows), "documents": dict(documents), "split": "test (not used for unigram selection)",
        "case_sha256": sha(out / "cases.tsv"), "target_injected": False,
        "synthetic_errors": True, "fresh_blind_neural_test": False,
        "limitations": "Existing CIFG training and prior corpus research exposure prevent a blind neural evaluation claim."
    }, indent=2) + "\n")
    print("Prepared", len(rows), "cases", dict(documents), flush=True)

def metrics(rows, meta):
    groups = defaultdict(lambda: Counter())
    for identifier, m in meta.items():
        r = rows[identifier]
        committed = (r.get("c") or m["typed"]).lower()
        suggestions = []
        for w in ([r["c"]] if r.get("c") else []) + r.get("s", []):
            if w.lower() != m["typed"] and w.lower() not in suggestions: suggestions.append(w.lower())
        is_next = m["kind"] == "nw"
        values = {"cases": 1, "top3": int(0 <= r["r0"] < 3) if is_next else int(m["target"] in suggestions[:3]),
                  "commit_correct": int(committed == m["target"]) if not is_next else 0,
                  "false_correction": int(m["condition"] == "clean" and committed != m["typed"])}
        for group in ("all", m["source"], m["condition"], m["source"] + "/" + m["condition"]):
            groups[group].update(values)
    return {g: {**dict(c), "top3_rate": c["top3"] / c["cases"]} for g, c in groups.items()}

def evaluate(packdir, out, binary, corpus=CORPUS):
    manifest = json.loads((packdir / "manifest.json").read_text())
    if not (out / "cases.manifest.json").exists(): prepare(out, corpus)
    case_manifest = json.loads((out / "cases.manifest.json").read_text())
    if sha(out / "cases.tsv") != case_manifest["case_sha256"]: raise ValueError("case hash mismatch")
    with MODEL_VOCAB.open() as f:
        neural = {r["word"] for r in csv.DictReader(f, delimiter="\t") if int(r["id"]) >= 4}
    old = pack_words(packdir / "baseline-unigram.bin")
    new = pack_words(packdir / "english-unigram.bin")
    test = split_counts(corpus, "test")
    common = {w for w in old if EMITTABLE.fullmatch(w) and w not in neural}
    common_test = {s: Counter({w:n for w,n in c.items() if w in common}) for s,c in test.items()}
    result = {"lexical_test": {"baseline": lexical_metrics(test, old, old, neural),
                              "candidate": lexical_metrics(test, new, new, neural),
                              "common_support_baseline": lexical_metrics(common_test, old, old, neural),
                              "common_support_candidate": lexical_metrics(common_test, new, new, neural)},
              "cases": case_manifest, "model_changed": False, "device_performance_verified": False}
    env = {k:v for k,v in os.environ.items() if not k.startswith("KB_")}
    env.update(KB_NSS=str(ROOT / "keyboard/nss-english.nsslm"), KB_NSS_ONLY="1", KB_NSS_FLOOR="1")
    if sha(Path(env["KB_NSS"])) != manifest["model_sha256"]: raise ValueError("CIFG model changed")
    result["options"] = {k:v for k,v in env.items() if k.startswith("KB_")}
    result["binary_sha256"] = sha(binary)
    meta = json.loads((out / "meta.json").read_text())
    result["typing"] = {}
    replays = {}
    for label, filename in [("baseline", "baseline-unigram.bin"), ("candidate", "english-unigram.bin")]:
        destination = out / (label + ".jsonl")
        print("Replaying", label, flush=True)
        subprocess.run([str(binary), str(packdir / filename), str(ROOT / "keyboard/safety.kbguard"),
                        str(out / "cases.tsv"), str(destination)], env=env, check=True)
        data = [json.loads(line) for line in destination.read_text().splitlines()]
        rows = {r["id"]: r for r in data if "id" in r}
        if set(rows) != set(meta) or not all(r["ok"] for r in rows.values()): raise ValueError("incomplete/failed replay")
        if not any(r.get("kind") == "done" and r["events"] == len(meta) for r in data): raise ValueError("missing completion")
        result["typing"][label] = metrics(rows, meta)
        result[label + "_pack_sha256"] = sha(packdir / filename)
        replays[label] = rows
    result["paired_top3"] = {}
    # Report paired differences by document; heldout examples never feed back into weights.
    for condition in ("deletion", "swap", "prefix", "next"):
        clustered = defaultdict(list)
        for identifier, m in meta.items():
            if m["condition"] != condition: continue
            def correct(row):
                if m["kind"] == "nw": return int(0 <= row["r0"] < 3)
                suggestions = []
                for w in ([row["c"]] if row.get("c") else []) + row.get("s", []):
                    if w.lower() != m["typed"] and w.lower() not in suggestions: suggestions.append(w.lower())
                return int(m["target"] in suggestions[:3])
            clustered[m["document"]].append(correct(replays["candidate"][identifier]) - correct(replays["baseline"][identifier]))
        values = np.array([[sum(v),len(v)] for v in clustered.values()], dtype=float)
        rng = np.random.default_rng(731)
        samples = []
        for _ in range(2000):
            sample = values[rng.integers(0, len(values), len(values))].sum(0)
            samples.append(sample[0] / sample[1])
        total = values.sum(0)
        result["paired_top3"][condition] = {"delta": float(total[0]/total[1]),
            "document_bootstrap_95ci": list(np.percentile(samples,[2.5,97.5]))}
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"lexical_test":result["lexical_test"], "paired_top3":result["paired_top3"]}), flush=True)

if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--packdir",type=Path,default=ROOT/"tools/data/nss/unigram-v1")
    p.add_argument("--out",type=Path,default=ROOT/"docs/unigram-v1/evaluation")
    p.add_argument("--binary",type=Path,default=ROOT/"tools/evaluation/autocorrect/bin/unigram-v1")
    p.add_argument("--prepare-only",action="store_true")
    a=p.parse_args()
    if a.prepare_only:prepare(a.out)
    else:evaluate(a.packdir,a.out,a.binary)
