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
  autocorrect.tsv      every autocorrection with what the user did next (accepted, backspaced, undone,
                       fixed by hand), how long it stood, the decoder's margin and the typed keystrokes
  words.tsv            every tapped word (typed as is, autocorrected or picked from the strip) with the
                       strip's candidates and what the user did next:
                         undone      an undo or manual replacement restored another word
                         backspaced  a later backspace reached the word (rejected)
                         continued   the user typed on (weak evidence the word was right)
                         unverified  nothing followed in the same field
                       replaced_by is the next word committed after the backspace or undo
  key_fixes.tsv        a letter erased and retyped as another: typed, meant, the retyped tap's offset
  layouts.jsonl        keyboard geometry per (install, process, layout revision)
  glides.jsonl         every Glide gesture: path, layout reference, outcome, candidates, margin and
                       a label with its source:
                         prompt      practice target (ground truth, even when the decoder was wrong)
                         selection   the alternative the user picked on the strip
                         retry       the glide was rejected (backspaced, undone, or nothing matched) and the
                                     label is the word the user finally kept in that field, following
                                     glide-delete-glide-... chains (retries counts the rejected attempts
                                     in between); only when the path could have been that word: it was a
                                     candidate, or the path starts and ends near its first and last letters
                         abandoned   rejected, then a word the path could not have been (a change of mind)
                         retracted   the user explicitly undid the inserted word; nothing kept followed
                         backspaced  a later backspace reached the inserted word; nothing kept followed
                         continued   the user entered more text (strong but not certain: unnoticed
                                     real-word errors stay in; see practice_label_checks)
                         unverified  nothing contradicted the committed word (an observation, not truth)
                       and replaced_by, the word finally kept after a rejection (also in words.tsv)

summary.json practice_label_checks: inside practice prompts, how often each behavioural label (what the
label would be without the prompt) matches the target: glide:continued, glide:retry, tap:continued,
tap:replaced_by. That precision is how much to trust the same label outside practice.

Commits are observations. Keep continuation separate from prompt and selection supervision.
"""
from __future__ import annotations
import argparse, csv, json, statistics, sys
from collections import Counter, defaultdict
from pathlib import Path

PAUSE_MS = 5_000
PROMPT_SLACK_S = 0.25
REJECTIONS = ("glide-backspaced", "word-backspaced", "undo")
RETRY_WINDOW_S = 30.0   # longest gap from a rejection to the next attempt that still counts as a retry
MAX_RETRIES = 4         # rejected attempts followed before giving up on the chain
MAX_END_PITCH = 1.0     # how far (in key pitches) a path's ends may be from a retry word's first/last letter
PUNCTUATION = ".,!?;:\"'()[]{}…“”‘’"

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
    commits_in_field = defaultdict(list)
    for e in events:
        scope = (e["install"], e.get("process"))
        if e.get("relatedWord") is not None:
            related[scope + (e["relatedWord"],)].append(e)
        by_word[scope + (e.get("word"),)].append(e)
        if e["kind"] == "commit" and e.get("text"):
            commits_in_field[scope + (e.get("session"),)].append(e)

    geometry = {}
    for e in events:
        if e["kind"] == "layout" and e.get("geometry"):
            geometry[(e["install"], e.get("process"), e.get("layout"))] = e["geometry"]

    def rejection_of(commit: dict) -> dict | None:
        """The first follow-up that rejected this committed word (backspaced into, or a glided word undone whole)."""
        return next((l for l in related.get((commit["install"], commit.get("process"), commit.get("word")), ())
                     if l["kind"] in REJECTIONS and l.get("session") == commit.get("session")
                     and l.get("uptime", 0) >= commit.get("uptime", 0)
                     and (l["kind"] != "undo" or l.get("evidence") == "explicit-retraction")), None)

    def resolve(rejection: dict | None, word: int | None) -> tuple[dict | None, int]:
        """Follow retries from a rejection to the first word in the same field that was kept.

        Returns that commit and how many further attempts were rejected on the way (glide, delete, glide,
        delete, type: the typed word after 1 retry). Stops when the next word comes more than RETRY_WINDOW_S
        after the previous rejection, or after MAX_RETRIES rejected attempts."""
        if rejection is None:
            return None, 0
        field = (rejection["install"], rejection.get("process"), rejection.get("session"))
        point, skip, retries = rejection, {word}, 0
        while True:
            after = point.get("uptime", 0)
            nxt = next((c for c in commits_in_field.get(field, ())
                        if c.get("uptime", 0) > after and (c.get("word") not in skip or c.get("word") is None)), None)
            if nxt is None or nxt.get("uptime", 0) - after > RETRY_WINDOW_S:
                return None, retries
            again = rejection_of(nxt)
            if again is None:
                return nxt, retries
            retries += 1
            if retries > MAX_RETRIES:
                return None, retries
            skip.add(nxt.get("word"))
            point = again

    def replaced_by(rejection: dict | None, word: int | None) -> str | None:
        """The word the user finally kept in the same field after a rejection (see resolve)."""
        final, _ = resolve(rejection, word)
        return final["text"] if final else None

    def plausible(word: str, glide_event: dict) -> bool:
        """Could this path have been an attempt at `word`? It was among the glide's candidates, or the path
        starts and ends within MAX_END_PITCH key pitches of the word's first and last letters (start key only
        when the layout was not recorded)."""
        word = word.lower()
        if word in {(c.get("word") or "").lower() for c in glide_event.get("candidateEvidence") or ()}:
            return True
        letters = [c for c in word if c.isalpha()]
        path = (glide_event.get("glide") or {}).get("path") or []
        if not letters or not path:
            return False
        layout = geometry.get((glide_event["install"], glide_event.get("process"), glide_event.get("layout")))
        if not layout or not layout.get("xPitch") or not layout.get("yPitch"):
            start = ((glide_event.get("glide") or {}).get("startKey") or "").lower()
            return start == letters[0]
        centres = {}
        for key in layout.get("keys", ()):
            label = (key.get("label") or "").lower()
            if len(label) == 1 and label not in centres:
                centres[label] = (key["x"] + key["w"] / 2, key["y"] + key["h"] / 2)

        def near(point: list, letter: str) -> bool:
            if letter not in centres:
                return False
            cx, cy = centres[letter]
            return ((point[0] - cx) / layout["xPitch"]) ** 2 + ((point[1] - cy) / layout["yPitch"]) ** 2 <= MAX_END_PITCH ** 2
        return near(path[0], letters[0]) and near(path[-1], letters[-1])

    def truth(label: str | None, prompt: dict) -> bool | None:
        """Does a label inferred from behaviour agree with the practice target? Sentence prompts: the label is
        one of the sentence's words (an approximation: it does not check which word was meant)."""
        if label is None:
            return None
        words = {w.strip(PUNCTUATION).lower() for w in prompt["target"].split()}
        return label.lower() in words

    checks = defaultdict(lambda: {"n": 0, "agree": 0})

    def check(name: str, label: str | None, prompt: dict | None) -> bool | None:
        agrees = truth(label, prompt) if prompt else None
        if agrees is not None:
            checks[name]["n"] += 1
            checks[name]["agree"] += int(agrees)
        return agrees

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
                       "correction-accepted": "accepted", "word-continued": "accepted",
                       "word-backspaced": "backspaced"}.get(later["kind"])
            if later["kind"] == "manual-replacement":
                verdict = "undone-by-hand" if later.get("evidence") == "manual-autocorrect-undo" else "fixed-by-hand"
            if verdict == "accepted" and outcome == "backspaced":
                continue
            if verdict and (outcome in ("unknown", "accepted", "backspaced")):
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

    word_outcomes = Counter()
    word_rows = []
    for e in events:
        if e["kind"] != "commit" or not e.get("text") or e.get("evidence") == "glide-unverified":
            continue
        key = (e["install"], e.get("process"), e.get("word"))
        own = by_word.get(key, ())
        later = [l for l in related.get(key, ()) if l.get("uptime", 0) >= e.get("uptime", 0)]
        picked = next((o for o in own if o["kind"] in ("suggestion-pick", "prediction-pick")), None)
        entry = "pick" if picked else "autocorrection" if e.get("evidence") == "automatic-unverified" else "typed"
        undone = next((l for l in later if l["kind"] in ("undo", "manual-replacement")), None)
        backspaced = next((l for l in later if l["kind"] == "word-backspaced"), None)
        continued = next((l for l in later if l["kind"] in ("word-continued", "correction-accepted")), None)
        if undone:
            outcome, decided = "undone", undone
        elif backspaced:
            outcome, decided = "backspaced", backspaced
        elif continued:
            outcome, decided = "continued", continued
        else:
            outcome, decided = "unverified", None
        rejection = decided if outcome in ("undone", "backspaced") else None
        replacement = (undone.get("replacement") or None) if undone else None
        shown = [o for o in own if o["kind"] in ("suggestions", "autocorrection") and o.get("candidateEvidence")]
        candidates = shown[-1]["candidateEvidence"] if shown else []
        word_outcomes[outcome] += 1
        final = replacement or replaced_by(rejection, e.get("word"))
        prompt = prompt_for(spans, e)
        if outcome == "continued":
            check("tap:continued", e["text"], prompt)
        elif final:
            check("tap:replaced_by", final, prompt)
        word_rows.append((e["install"], e.get("time", ""), e["text"], e.get("typed", ""), entry, outcome,
                          decided.get("sinceMs", "") if decided else "", final or "",
                          e.get("backspaces", ""), e.get("durationMs", ""), int(prompt is not None),
                          json.dumps([[c["word"], c.get("score"), c.get("spatialCost")] for c in candidates[:8]]),
                          json.dumps(e.get("keystrokes") or [])))
    write_tsv(out / "words.tsv", ["install", "time", "word", "typed", "entry", "outcome", "since_ms", "replaced_by",
                                  "backspaces", "word_duration_ms", "in_practice", "candidates", "keystrokes"], word_rows)

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
            later = [l for l in related.get((e["install"], e.get("process"), e.get("word")), ())
                     if l.get("session") == e.get("session") and l.get("uptime", 0) >= e.get("uptime", 0)]
            picked = next((l for l in later if l["kind"] == "glide-selection"), None)
            retracted = any(l["kind"] == "undo" and l.get("evidence") == "explicit-retraction" for l in later)
            continued = next((l for l in later if l["kind"] == "glide-continued"), None)
            backspaced = next((l for l in later if l["kind"] == "glide-backspaced"), None)
            retraction = next((l for l in later if l["kind"] == "undo" and l.get("evidence") == "explicit-retraction"), None)
            # What behaviour alone says, before any practice target is applied.
            label, source, final, retries = None, None, None, None
            if glide["outcome"] in ("committed", "rejected") and not picked and (retracted or backspaced or glide["outcome"] == "rejected"):
                # Rejected one way or another: the label is the word the user finally kept (glide, delete,
                # glide again, ..., kept), if this path could have been an attempt at it.
                kept, retries = resolve(backspaced or retraction if glide["outcome"] == "committed" else e,
                                        e.get("word") if glide["outcome"] == "committed" else None)
                final = kept["text"].lower() if kept else None
                if final and plausible(final, e):
                    label, source = final, "retry"
                elif final:
                    source = "abandoned"
                else:
                    source = "rejected" if glide["outcome"] == "rejected" else "retracted" if retracted else "backspaced"
            elif glide["outcome"] != "committed":
                source = glide["outcome"]
            elif picked:
                label, source = (picked.get("replacement") or "").lower(), "selection"
            elif continued:
                label, source = committed, "continued"
            else:
                label, source = committed, "unverified"
            agrees = check(f"glide:{source}", label, prompt) if source in ("continued", "retry", "selection", "unverified") else None
            if prompt and " " not in prompt["target"]:
                label, source = prompt["target"].lower(), "prompt"
            elif prompt and committed and committed in prompt["target"].lower().split():
                label, source = committed, "prompt"
            labels[source] += 1
            handle.write(json.dumps({
                "install": e["install"], "process": e.get("process"), "layout": e.get("layout"), "time": e.get("time"),
                "id": e["id"], "outcome": glide["outcome"], "committed": committed, "label": label, "label_source": source,
                "continued": continued is not None, "backspaced": backspaced is not None,
                "continued_after_ms": continued.get("sinceMs") if continued else None,
                "backspaced_after_ms": backspaced.get("sinceMs") if backspaced else None,
                "replaced_by": final, "retries": retries, "practice_agrees": agrees,
                "prompt_target": prompt["target"] if prompt else None, "start_key": glide.get("startKey"),
                "decode_source": glide.get("source"), "previews": glide.get("previews"), "margin": e.get("confidence"),
                "duration_ms": e.get("durationMs"), "lift_to_insert_ms": glide.get("liftToInsertMs"),
                "candidates": [[c["word"], c.get("spatialCost")] for c in e.get("candidateEvidence") or []],
                "path": glide["path"], "truncated": bool(glide.get("truncated"))}) + "\n")

    summary = {"installs": sorted({e["install"] for e in events}), "events": len(events),
               "events_by_kind": dict(sorted(Counter(e["kind"] for e in events).items())),
               "committed_words": sum(count.values()), "distinct_words": len(count),
               "out_of_dictionary_words": None if known is None else sum(1 for w in count if w not in known),
               "autocorrections": dict(sorted(outcomes.items())), "word_outcomes": dict(sorted(word_outcomes.items())),
               "glides": dict(sorted(glide_outcomes.items())),
               "glide_labels": dict(sorted((k or "none", v) for k, v in labels.items())),
               "practice_prompts": sum(len(v) for v in spans.values()), "diagnostics_snapshots": len(diagnostics),
               "practice_label_checks": {name: {**c, "precision": round(c["agree"] / c["n"], 3)}
                                         for name, c in sorted(checks.items())}}
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
