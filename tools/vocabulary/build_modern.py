#!/usr/bin/env python3
"""Deterministic modern vocabulary delta and hash-bound KBMODERN v1 sidecar.

Only new, source-corroborated single words are admitted. Existing weights/counts
are untouched. Context priority is editorial display rank, never a corpus count.
"""
from __future__ import annotations
import argparse, hashlib, json, struct, sys, tempfile, os
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from verify_language_data import Pack
CATALOG = Path(__file__).with_name("modern_catalog.json")
CONTEXTS = Path(__file__).with_name("modern_contexts.json")
MAGIC = b"KBMODERN"
EMPTY = 0xffffffff

def catalog(path=CATALOG):
    obj = json.loads(path.read_text())
    if obj["schema_version"] != 1: raise ValueError("catalog version")
    result = {}
    for row in obj["entries"]:
        word = row["word"]
        if word in result or word != word.lower() or not row["evidence"]: raise ValueError("invalid/duplicate catalog entry")
        if not 0 <= row["frequency_prior"] <= 12000: raise ValueError("invalid prior")
        if row["preserve"] and row["autocorrect"]: raise ValueError("protected spelling cannot be an automatic replacement")
        if not all(isinstance(row[k], bool) for k in ("preserve", "suggest", "autocorrect")): raise ValueError("invalid flags")
        result[word] = row
    return result

def atomic(path, data):
    path = Path(path)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        tmp = Path(f.name)
        try:
            f.write(data); f.flush(); os.fsync(f.fileno())
        except BaseException:
            tmp.unlink(missing_ok=True); raise
    try: os.replace(tmp, path)
    finally: tmp.unlink(missing_ok=True)

def export_legacy(check=False):
    rows = catalog()
    for kind, path, header in [
        ("supplemental", ROOT/"tools/data/english_supplemental.tsv", "# Generated from tools/vocabulary/modern_catalog.json; edit the catalog.\n"),
        ("curated", ROOT/"tools/vocabulary/curated_terms.tsv", "# Generated from modern_catalog.json; editorial priors, not observations.\n")]:
        lines = []
        for word, row in sorted(rows.items()):
            if row["legacy"] == kind:
                # Keep historical register for the snapshot's independently pinned recipe.
                register = row.get("legacy_register", row["register"])
                lines.append(f'{word} {row["frequency_prior"]}' if kind == "supplemental" else f'{word}	{register}	{row["frequency_prior"]}')
        text = header + "\n".join(lines) + "\n"
        if check:
            if path.read_text() != text: raise ValueError(f"stale catalog export: {path}")
        else: atomic(path, text.encode())

def build(base, output, sidecar=None):
    import build_language_data as builder
    base, output = Path(base), Path(output)
    p = Pack(base)
    if p.version != 6: raise ValueError("modern delta requires KBLM v6")
    raw, freqs = p.vocabulary()
    old = [w.decode("utf8") for w in raw]
    vocabulary = dict(zip(old, freqs)); rows = catalog()
    added = []
    for word, row in rows.items():
        if word not in vocabulary and row["legacy"] is None and row["frequency_prior"] > 0:
            if not builder.WORD.fullmatch(word) or word in builder.EXCLUDE or len(word) < 2 or len(word) > 32:
                raise ValueError(f"unsupported addition: {word}")
            if not any(e.startswith("https://") for e in row["evidence"]): raise ValueError("new term needs corroboration")
            vocabulary[word] = row["frequency_prior"]; added.append(word)
    vocab = sorted(vocabulary.items(), key=lambda x: (-x[1], x[0]))
    ids = {w:i for i,(w,_) in enumerate(vocab)}
    remap = [ids[w] for w in old]
    bi, tri, bt, tt = {}, {}, {}, {}
    for a,(total,es) in p.bigrams().items():
        bi[remap[a]] = [(remap[b],n) for b,n in es]; bt[remap[a]] = total
    for key,(total,es) in p.trigrams().items():
        a,b = p.context_pair(key); pair = (remap[a],remap[b])
        tri[pair] = [(remap[c],n) for c,n in es]; tt[pair] = total
    starters = [(remap[a],n) for a,n in p.sentence_starters()]
    builder.write_bin(vocab, bi, tri, starters, output=output,
        context_totals={"bigrams":bt,"trigrams":tt}, version=6, max_bytes=32_000_000)
    pack_data = output.read_bytes()
    policies = []
    for word,row in rows.items():
        if word not in ids: continue
        flags = int(row["preserve"]) | (int(not row["autocorrect"]) << 1) | (int(row["suggest"] and row["preserve"]) << 2)
        if flags: policies.append((ids[word],flags))
    contexts = []
    for row in json.loads(CONTEXTS.read_text())["contexts"]:
        ctx = row["context"]
        if len(ctx) not in (1,2) or not 1 <= row["priority"] <= 4: raise ValueError("invalid context")
        if any(w not in ids for w in [*ctx,row["next"]]): raise ValueError(f"context word missing: {row}")
        if len(ctx)==1 and ctx[0] in {"no","brain","rage"}: raise ValueError("ambiguous context needs two words")
        contexts.append((ids[ctx[0]] if len(ctx)==2 else EMPTY,ids[ctx[-1]],ids[row["next"]],row["priority"]))
    if len(set(x[:3] for x in contexts)) != len(contexts): raise ValueError("duplicate continuation")
    digest = hashlib.sha256(pack_data).digest()
    blob = struct.pack("<8s4I32s", MAGIC,1,len(vocab),len(policies),len(contexts),digest)
    blob += b"".join(struct.pack("<2I",*r) for r in sorted(policies))
    blob += b"".join(struct.pack("<4I",*r) for r in sorted(contexts))
    blob += hashlib.sha256(blob).digest()
    if len(pack_data) + len(blob) - len(p.data) > 1_000_000: raise ValueError("growth budget")
    target = Path(sidecar) if sidecar else output.with_suffix(".kbmodern")
    atomic(target,blob)
    return {"schema_version":1,"words":len(vocab),"added":sorted(added),"catalog_entries":len(rows),
        "policy_entries":len(policies),"contexts":len(contexts),"pack_bytes":len(pack_data),
        "sidecar_bytes":len(blob),"pack_sha256":digest.hex(),"sidecar_sha256":hashlib.sha256(blob).hexdigest(),
        "baseline_sha256":hashlib.sha256(p.data).hexdigest(),"growth_bytes":len(pack_data)+len(blob)-len(p.data),
        "catalog_sha256":hashlib.sha256(CATALOG.read_bytes()).hexdigest(),
        "contexts_sha256":hashlib.sha256(CONTEXTS.read_bytes()).hexdigest()}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline",type=Path);ap.add_argument("--output",type=Path)
    ap.add_argument("--sidecar",type=Path);ap.add_argument("--report",type=Path)
    ap.add_argument("--export-legacy",action="store_true");ap.add_argument("--check-exports",action="store_true")
    args=ap.parse_args()
    if args.export_legacy or args.check_exports: export_legacy(args.check_exports)
    if args.baseline:
        if not args.output: ap.error("--output required")
        result=build(args.baseline,args.output,args.sidecar)
        text=json.dumps(result,indent=2)+"\n"
        if args.report: atomic(args.report,text.encode())
        print(text)
if __name__=="__main__": main()
