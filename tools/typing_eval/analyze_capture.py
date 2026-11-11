#!/usr/bin/env python3
"""Analyze a local JSONL export. Never uploads data or changes a model."""
import argparse
from collections import Counter, defaultdict
import json
import statistics


def analyze(events):
    counts, keys = Counter(), defaultdict(list)
    last, touches, durations = {}, {}, defaultdict(list)
    examples, word_events = [], defaultdict(list)
    active_seconds = 0.0
    committed_characters = 0
    for e in events:
        if e.get('schema') != 1:
            continue
        kind = e['kind']
        counts[kind] += 1
        session = (e['process'], e['session'])
        word = (*session, e['word'])
        time = e['uptime']
        if kind == 'commit':
            committed_characters += len(e.get('text') or '') + 1
        if kind in ('key', 'backspace'):
            prior = last.get(session)
            gap = time - prior if prior is not None else None
            if gap is not None and 0 < gap <= 5:
                active_seconds += gap
                if kind == 'key' and e.get('text', '').isalpha():
                    keys[e['text']].append(gap * 1000)
            last[session] = time
            word_events[word].append(e)
        elif kind == 'session-end':
            last.pop(session, None)
        elif kind == 'touch-down' and e.get('touchID'):
            touches[(e['process'], e['touchID'])] = e
        elif kind in ('touch-up', 'touch-cancel'):
            start = touches.pop((e['process'], e.get('touchID')), None)
            if start and kind == 'touch-up' and 0 <= time - start['uptime'] <= 10:
                durations[start.get('text') or '<control>'].append((time - start['uptime']) * 1000)
        explicit = kind in ('suggestion-pick', 'prediction-pick', 'glide-selection') or (kind == 'undo' and e.get('evidence') == 'explicit-autocorrect-undo')
        if explicit and e.get('replacement'):
            typed, intended = e.get('text') or '', e['replacement']
            label_word = (*session, e.get('relatedWord') if e.get('relatedWord') is not None else e['word'])
            examples.append(dict(process=e['process'], session=e['session'], word=label_word[-1],
                observed=typed, intended=intended, evidence=e.get('evidence'),
                task='completion' if kind == 'suggestion-pick' and intended.startswith(typed) else kind,
                model=e['model'], events=list(word_events.get(label_word, [])),
                # These are word-level intent labels, not validated per-key alignments.
                per_key_alignment_verified=False))
    def summarize(values):
        return dict(samples=len(values), median_ms=round(statistics.median(values), 2))
    return dict(events=dict(counts), active_seconds=round(active_seconds, 3),
                committed_word_wpm=round(counts['commit'] * 60 / active_seconds, 2) if active_seconds else None,
                committed_five_character_wpm=round(committed_characters * 12 / active_seconds, 2) if active_seconds else None,
                interval_by_key={k: summarize(v) for k, v in sorted(keys.items())},
                dwell_by_key={k: summarize(v) for k, v in sorted(durations.items())},
                explicit_word_labels=len(examples)), examples


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('capture')
    p.add_argument('--training-out', help='Optional local JSONL containing explicit word-intent examples')
    args = p.parse_args()
    with open(args.capture) as f:
        events = [json.loads(line) for line in f if line.strip()]
    summary, examples = analyze(events)
    print(json.dumps(summary, indent=2))
    if args.training_out:
        with open(args.training_out, 'w') as f:
            for example in examples:
                f.write(json.dumps(example) + '\n')


if __name__ == '__main__':
    main()
