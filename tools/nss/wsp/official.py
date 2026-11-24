#!/usr/bin/env python3
"""Before/after table from stored performance-test runs (held half), paired McNemar per row.

    python3.11 official.py prod-<before> prod-<after> [prod-<after2> ...]
"""
import pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]/'evaluation/autocorrect'))
import evaluate as E  # noqa: E402
import performance_tests as P  # noqa: E402

runs = sys.argv[1:]
meta = {i: x for i, x in P.meta().items() if x['set'] in ('hard', 'apos') or E.half(x) == 'held'}
rows = {r: E.load(P.OUT/f'{r}.jsonl')[0] for r in runs}
metrics = E.metrics(meta)
print('| Metric | n | ' + ' | '.join(runs) + ' | ' + ' | '.join(f'Δ {r}' for r in runs[1:]) + ' |')
print('|---|---|' + '---|' * (2 * len(runs) - 1))
for title, labels in P.SECTIONS:
    for label in labels:
        if label not in metrics: continue
        ids, pred, up, _ = metrics[label]
        ids = [i for i in ids if all(i in rows[r] for r in runs)]
        if not ids: continue
        val = {r: [bool(pred(rows[r][i], meta[i])) for i in ids] for r in runs}
        rate = {r: 100 * sum(v) / len(v) for r, v in val.items()}
        deltas = []
        for r in runs[1:]:
            b = sum(x and not y for x, y in zip(val[r], val[runs[0]])); c = sum(y and not x for x, y in zip(val[r], val[runs[0]]))
            d = rate[r] - rate[runs[0]]; worse = (d < 0) if up else (d > 0)
            mark = '*' if E.mcnemar(b, c) < 0.05 else ''
            deltas.append(f'{d:+.2f}{mark}{" FAIL" if mark and worse and label.startswith("GUARD") else ""}')
        print(f'| {label.strip()}{"" if up else " ↓"} | {len(ids)} | ' + ' | '.join(f'{rate[r]:.2f}%' for r in runs) + ' | ' + ' | '.join(deltas) + ' |')
lat = [[rows[r][i]['ms'] for i in rows[r] if meta.get(i, {}).get('set') == 'ecps' and 'ms' in rows[r][i]] for r in runs]
print('| ECPS decode p50 ms (8-core run, indicative) | | ' + ' | '.join(f'{E.quantile(x, .5):.2f}' for x in lat) + ' | |')
