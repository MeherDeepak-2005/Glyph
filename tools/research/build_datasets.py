#!/usr/bin/env python3
"""Turn typing-recorder files (schema 3, docs/typing-recorder.md) into analysis tables.

  build_datasets.py RECORDINGS_DIR OUT_DIR [--ledger tools/data/nss/unigram-v1/unigrams.tsv]

RECORDINGS_DIR holds .jsonl files, in any folder layout: chunks opened by chunks.swift, or
exports shared from the app. Every chunk starts with a `header` event naming its install.

Writes into OUT_DIR:
  summary.json         installs, events by kind, words, glides by outcome and label source
  word_frequency.tsv   every committed word: count, installs, how it was entered, in the dictionary?
  oov_words.tsv        the committed words the dictionary does not have, most frequent first
  bigrams.tsv          consecutive committed words within one text field
  speed.tsv            per install: words per minute, inter-key interval, glide share
  autocorrect.tsv      every autocorrection with what the user did next (accepted, undone, fixed
                       by hand), how long it stood, the decoder's margin and the typed keystrokes
  key_fixes.tsv        a letter erased and retyped as another: typed, meant, the retyped tap's offset
  layouts.jsonl        keyboard geometry per (install, process, layout revision)
  glides.jsonl         every Glide gesture: path, layout reference, outcome, candidates, margin and
                       a label with its source:
                         prompt      practice target (ground truth, even when the decoder was wrong)
                         selection   the alternative the user picked on the strip
                         retracted   the user deleted the word: the committed word was wrong
                         unverified  nothing contradicted the committed word (an observation, not truth)

Commits are observations. Only prompt, selection, undo and manual-replacement rows are labels.
"""
from __future__ import annotations
import argparse, csv, json, statistics, sys
from collections import Counter, defaultdict
from pathlib import Path

PAUSE_MS = 5_000
PROMPT_SLACK_S = 0.25

def read(root: Path) -> tuple[list[dict], list[dict]]:
    """Events (deduplicated, each tagged with its install) and diagnostics lines."""
    events, diagnostics, seen = [], [], set()
    for path in sorted(root.rglob("*.jsonl")):
        install = None
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("kind") == "diagnostics":
                    diagnostics.append(event)
                    continue
                if event.get("kind") == "header":
                    install = (event.get("header") or {}).get("install")
                if event.get("schema") != 3 or event.get("id") in seen:
                    continue
                seen.add(event["id"])
                event["install"] = install or f"unknown:{path.stem}"
                events.append(event)
    events.sort(key=lambda e: (e["install"], e.get("process", ""), e.get("uptime", 0.0)))
    return events, diagnostics

def dictionary(ledger: Path | None) -> set[str] | None:
    if ledger is None or not ledger.exists():
        return None
    with ledger.open(newline="", encoding="utf-8") as handle:
        return {row["word"] for row in csv.DictReader(handle, delimiter="\t")}

def prompts(events: list[dict]) -> dict[str, list[dict]]:
    """Per install: the practice prompts as [start, end] intervals of device uptime."""
    shown, spans = {}, defaultdict(list)
    for e in events:
        prompt = e.get("prompt")
        if not prompt:
            continue
        key = (e["install"], prompt["id"])
        if e["kind"] == "prompt-shown":
            shown[key] = e
        elif e["kind"] == "prompt-done" and key in shown:
            start = shown.pop(key)
            spans[e["install"]].append({"start": start["uptime"] - PROMPT_SLACK_S, "end": e["uptime"], "time": start.get("time", ""),
                                        "id": prompt["id"], "target": prompt["target"], "mode": prompt["mode"],
                                        "result": prompt.get("result"), "evidence": e.get("evidence")})
    return spans

def prompt_for(spans: dict[str, list[dict]], event: dict) -> dict | None:
    for span in spans.get(event["install"], ()):
        if span["start"] <= event.get("uptime", -1) <= span["end"] and span["time"][:10] == event.get("time", "")[:10]:
            return span
    return None

def write_tsv(path: Path, header: list[str], rows) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)

def build(root: Path, out: Path, ledger: Path | None) -> dict:
    events, diagnostics = read(root)
    out.mkdir(parents=True, exist_ok=True)
    known = dictionary(ledger)
    spans = prompts(events)
    related = defaultdict(list)
    by_word = defaultdict(list)
    for e in events:
        scope = (e["install"], e.get("process"))
        if e.get("relatedWord") is not None:
            related[scope + (e["relatedWord"],)].append(e)
        by_word[scope + (e.get("word"),)].append(e)

    count, installs, glided, tapped = Counter(), defaultdict(set), Counter(), Counter()
    bigrams, previous = Counter(), {}
    speed = defaultdict(lambda: {"chars": 0, "words": 0, "active_ms": 0.0, "intervals": [], "glides": 0})
    for e in events:
        stats = speed[e["install"]]
        if e["kind"] == "key" and e.get("intervalMs") is not None and e["intervalMs"] <= PAUSE_MS:
            stats["active_ms"] += e["intervalMs"]
            stats["intervals"].append(e["intervalMs"])
        if e["kind"] == "glide" and (e.get("glide") or {}).get("outcome") == "committed":
            stats["active_ms"] += e.get("durationMs") or 0
            stats["glides"] += 1
        if e["kind"] != "commit" or not e.get("text"):
            continue
        word = e["text"].lower()
        count[word] += 1
        installs[word].add(e["install"])
        (glided if e.get("evidence") == "glide-unverified" else tapped)[word] += 1
        stats["chars"] += len(word) + 1
        stats["words"] += 1
        field = (e["install"], e.get("process"), e.get("session"))
        if field in previous:
            bigrams[(previous[field], word)] += 1
        previous[field] = word
    rows = [(w, n, len(installs[w]), tapped[w], glided[w], "" if known is None else int(w in known))
            for w, n in sorted(count.items(), key=lambda item: (-item[1], item[0]))]
    write_tsv(out / "word_frequency.tsv", ["word", "count", "installs", "tapped", "glided", "in_dictionary"], rows)
    write_tsv(out / "oov_words.tsv", ["word", "count", "installs"],
              [(w, n, i) for w, n, i, _, _, inside in rows if inside == 0])
    write_tsv(out / "bigrams.tsv", ["previous", "word", "count"],
              [(a, b, n) for (a, b), n in sorted(bigrams.items(), key=lambda item: (-item[1], item[0]))])
    write_tsv(out / "speed.tsv", ["install", "words", "chars", "active_minutes", "wpm", "median_interkey_ms", "glide_share"],
              [(install, s["words"], s["chars"], round(s["active_ms"] / 60_000, 2),
                round((s["chars"] / 5) / (s["active_ms"] / 60_000), 1) if s["active_ms"] > 0 else "",
                round(statistics.median(s["intervals"]), 1) if s["intervals"] else "",
                round(s["glides"] / s["words"], 3) if s["words"] else "")
               for install, s in sorted(speed.items())])

    outcomes = Counter()
    rows = []
    for e in events:
        if e["kind"] != "autocorrection":
            continue
        key = (e["install"], e.get("process"), e.get("word"))
        outcome, since = "unknown", ""
        for later in related.get(key, ()):
            verdict = {"undo": "undone-strip" if later.get("evidence") == "strip-autocorrect-undo" else "undone-backspace",
                       "correction-accepted": "accepted"}.get(later["kind"])
            if later["kind"] == "manual-replacement":
                verdict = "undone-by-hand" if later.get("evidence") == "manual-autocorrect-undo" else "fixed-by-hand"
            if verdict and (outcome in ("unknown", "accepted")):
                outcome, since = verdict, later.get("sinceMs", "")
        commit = next((c for c in by_word.get(key, ()) if c["kind"] == "commit"), {})
        strokes = commit.get("keystrokes") or []
        offsets = [abs(k[a]) for k in strokes for a in ("dx", "dy") if k.get(a) is not None]
        gaps = [k["intervalMs"] for k in strokes if k.get("intervalMs") is not None and k["intervalMs"] <= PAUSE_MS]
        outcomes[outcome] += 1
        rows.append((e["install"], e.get("time", ""), e.get("text", ""), e.get("replacement", ""), outcome, since,
                     e.get("confidence", ""), commit.get("durationMs", ""), commit.get("backspaces", ""),
                     round(statistics.fmean(offsets), 3) if offsets else "", round(statistics.fmean(gaps), 1) if gaps else "",
                     int(prompt_for(spans, e) is not None),
                     json.dumps([[c["word"], c.get("score"), c.get("spatialCost")] for c in (e.get("candidateEvidence") or [])[:5]]),
                     json.dumps(strokes)))
    write_tsv(out / "autocorrect.tsv", ["install", "time", "typed", "corrected", "outcome", "since_ms", "margin", "word_duration_ms",
                                        "backspaces", "mean_abs_offset", "mean_interkey_ms", "in_practice", "candidates", "keystrokes"], rows)
    write_tsv(out / "key_fixes.tsv", ["install", "typed", "meant", "dx", "dy"],
              [(e["install"], e.get("text", ""), e.get("replacement", ""), e.get("dx", ""), e.get("dy", ""))
               for e in events if e["kind"] == "key-fix"])

    labels, glide_outcomes = Counter(), Counter()
    with (out / "layouts.jsonl").open("w", encoding="utf-8") as handle:
        described = set()
        for e in events:
            if e["kind"] != "layout" or not e.get("geometry"):
                continue
            key = (e["install"], e.get("process"), e.get("layout"), json.dumps(e["geometry"], sort_keys=True))
            if key in described:
                continue
            described.add(key)
            handle.write(json.dumps({"install": e["install"], "process": e.get("process"), "layout": e.get("layout"),
                                     "uptime": e.get("uptime"), "geometry": e["geometry"]}) + "\n")
    with (out / "glides.jsonl").open("w", encoding="utf-8") as handle:
        for e in events:
            glide = e.get("glide")
            if e["kind"] != "glide" or not glide:
                continue
            glide_outcomes[glide["outcome"]] += 1
            committed = (e.get("text") or "").lower() or None
            prompt = prompt_for(spans, e)
            later = related.get((e["install"], e.get("process"), e.get("word")), ())
            picked = next((l for l in later if l["kind"] == "glide-selection"), None)
            retracted = any(l["kind"] == "undo" and l.get("evidence") == "explicit-retraction" for l in later)
            label, source = None, None
            if prompt and " " not in prompt["target"]:
                label, source = prompt["target"].lower(), "prompt"
            elif prompt and committed and committed in prompt["target"].lower().split():
                label, source = committed, "prompt"
            elif glide["outcome"] != "committed":
                source = glide["outcome"]
            elif picked:
                label, source = (picked.get("replacement") or "").lower(), "selection"
            elif retracted:
                source = "retracted"
            else:
                label, source = committed, "unverified"
            labels[source] += 1
            handle.write(json.dumps({
                "install": e["install"], "process": e.get("process"), "layout": e.get("layout"), "time": e.get("time"),
                "id": e["id"], "outcome": glide["outcome"], "committed": committed, "label": label, "label_source": source,
                "prompt_target": prompt["target"] if prompt else None, "start_key": glide.get("startKey"),
                "decode_source": glide.get("source"), "previews": glide.get("previews"), "margin": e.get("confidence"),
                "duration_ms": e.get("durationMs"), "lift_to_insert_ms": glide.get("liftToInsertMs"),
                "candidates": [[c["word"], c.get("spatialCost")] for c in e.get("candidateEvidence") or []],
                "path": glide["path"], "truncated": bool(glide.get("truncated"))}) + "\n")

    summary = {"installs": sorted({e["install"] for e in events}), "events": len(events),
               "events_by_kind": dict(sorted(Counter(e["kind"] for e in events).items())),
               "committed_words": sum(count.values()), "distinct_words": len(count),
               "out_of_dictionary_words": None if known is None else sum(1 for w in count if w not in known),
               "autocorrections": dict(sorted(outcomes.items())), "glides": dict(sorted(glide_outcomes.items())),
               "glide_labels": dict(sorted((k or "none", v) for k, v in labels.items())),
               "practice_prompts": sum(len(v) for v in spans.values()), "diagnostics_snapshots": len(diagnostics)}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("recordings", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--ledger", type=Path, default=Path(__file__).resolve().parents[1] / "data/nss/unigram-v1/unigrams.tsv")
    args = parser.parse_args()
    if not args.recordings.is_dir():
        sys.exit(f"not a directory: {args.recordings}")
    print(json.dumps(build(args.recordings, args.out, args.ledger), indent=2))

if __name__ == "__main__":
    main()
