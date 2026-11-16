#!/usr/bin/env python3
"""Performance tests: the keyboard decoder's standing against the dev branch's n-gram setup and CoreV4.

  performance_tests.py                 build prod if its sources changed, decode the held half on every
                                       core, measure typing latency, write the report
  performance_tests.py report RUN      re-score a stored prod run without decoding
  performance_tests.py --env KB_x=y    decode with a tuning build and these overrides (e.g. KB_nssRules=0)

"Performance tests" are the benchmark sets in corpus/: ECPS real misspellings, MacKenzie
synthetic typos, the external misspelling lists (Aspell, Birkbeck, Holbrook, Wikipedia),
contractions in sentences, and the guardrails (correct words, names, rare words, Tenglish, slang).
Every system is scored on the held half (make the decision there, not on tune) and on the
same cases; prod decodes with simulated taps where a set has them.

Results live in results/performance-tests/ (git-ignored):
  prod-<date>-<time>.jsonl             a prod run (this script)
  dev-ngram-2026-11-01.*.jsonl         dev branch, n-gram tier with all its rules (adaf83f, taps)
  corev4-engxx-2026-11-14.*.jsonl      CoreV4 iOS harness with engxx.abn (CoreV4 takes no taps)
  report-<date>-<time>.md              the standing, also printed
The latest standing is copied to docs/performance-tests.md.
"""
import argparse, concurrent.futures as cf, datetime, json, os, pathlib, subprocess, sys, time
import evaluate as E

OUT = E.RESULTS/'performance-tests'
DOC = E.REPO/'docs'/'performance-tests.md'
REFERENCES = {'Dev (n-gram)': 'dev-ngram-2026-11-01', 'CoreV4': 'corev4-engxx-2026-11-14'}
SETS = ('cases.taps.tsv', 'ext-cases.taps.tsv', 'keep-cases.taps.tsv', 'contraction-cases.tsv', 'tenglish-cases.tsv')
SECTIONS = [
    ('Real misspellings', ['ECPS real misspellings fixed', 'ECPS target in top 3', 'ECPS left uncorrected']),
    ('External misspelling lists', ['ext_aspell fixed', 'ext_birkbeck fixed', 'ext_holbrook fixed', 'ext_wikipedia fixed',
                                    'ext_birkbeck in top 3', 'ext_wikipedia in top 3']),
    ('Generated typos', ['Synthetic typos fixed', 'Synthetic target in top 3', 'Synthetic first letter wrong fixed',
                         '  syn omission fixed', '  syn insertion fixed', '  syn sub_adjacent fixed', '  syn double fixed',
                         '  syn transposition fixed', '  syn two_errors fixed']),
    ('Contractions', ['Contractions restored in sentences', 'GUARD contractions restored', 'GUARD plain word changed in sentences']),
    ('Guardrails (lower is better unless marked)', ['GUARD false corrections, ECPS correct', 'GUARD false corrections, MacKenzie clean',
        'GUARD hard valid words changed', 'GUARD unknown names changed', 'GUARD rare dictionary words changed',
        'GUARD Tenglish words changed', 'GUARD correct plurals stripped', 'GUARD real-word errors fixed']),
]

def meta():
    m = json.loads((E.CORPUS/'cases-meta.json').read_text())
    for extra in sorted(E.CORPUS.glob('*-cases-meta.json')): m.update(json.loads(extra.read_text()))
    return m

def binary(tuning):
    """Release (app constants) or tuning build, rebuilt only when DecoderCore or the harness changed."""
    name = 'perf-prod-tuning' if tuning else 'perf-prod'
    path = E.BIN/name
    sources = [pathlib.Path(s) for s in E.core_sources()] + [E.HERE/'IOSBench.cpp', *(E.REPO/'native/DecoderCore/include').glob('*.hpp')]
    if not path.exists() or max(s.stat().st_mtime for s in sources) > path.stat().st_mtime:
        print(f'building {name} ...', flush=True); E.build(name, tuning)
    return path

def shards(m, size=300):
    """Held-half decode rows (no next-word rows), in shards; longest first so the cores finish together."""
    out = E.HERE/'corpus'/'shards'/'perf-held'
    if not (out.exists() and any(out.iterdir())):
        out.mkdir(parents=True, exist_ok=True)
        rows = [l for name in SETS for l in open(E.CORPUS/name)
                if (i := l.split('\t', 1)[0]) in m and m[i]['set'] != 'nw' and (m[i]['set'] in ('hard', 'apos') or E.half(m[i]) == 'held')]
        for k in range(0, len(rows), size): (out/f'{k // size:04d}.tsv').write_text(''.join(rows[k:k + size]))
    return sorted(out.glob('*.tsv'), key=lambda p: -sum(len(l.split('\t')[3]) for l in open(p)))

def decode(path, env, cases, out):
    subprocess.run([str(path), str(E.REPO/'keyboard/langdata.bin'), str(E.REPO/'keyboard/safety.kbguard'), str(cases), str(out)],
                   env=E.bench_env(**env), check=True, stderr=subprocess.DEVNULL)

def run(env, jobs):
    m = meta(); path = binary(bool(env)); parts = shards(m)
    stamp = datetime.datetime.now().strftime('%Y-%m-%d-%H%M'); name = f'prod-{stamp}'
    tmp = OUT/f'.{name}'; tmp.mkdir(parents=True, exist_ok=True)
    start = time.time()
    awake = subprocess.Popen(['caffeinate', '-ims', '-w', str(os.getpid())])
    try:
        with cf.ThreadPoolExecutor(jobs) as pool:
            list(pool.map(lambda p: decode(path, env, p, tmp/f'{p.stem}.jsonl'), parts))
        decoded = time.time() - start
        with open(OUT/f'{name}.jsonl', 'w') as f:
            for p in sorted(tmp.glob('*.jsonl')): f.write(p.read_text()); p.unlink()
        tmp.rmdir()
        lat = latency(path, env, m)
    finally:
        awake.terminate()
    print(f'decoded {len(parts)} shards in {decoded:.0f} s on {jobs} workers; latency sample {lat:.0f} s')
    (OUT/f'{name}.env.json').write_text(json.dumps({'env': env, 'binary': path.name, 'decode_s': decoded}) + '\n')
    return name

def latency(path, env, m, cases=1000):
    """One process alone on the first `cases` held ECPS words with taps: the uncontended per-word latency."""
    rows = [l for l in open(E.CORPUS/'cases.taps.tsv') if (i := l.split('\t', 1)[0]) in m and m[i]['set'] == 'ecps' and E.half(m[i]) == 'held'][:cases]
    tsv = E.HERE/'corpus'/'shards'/'perf-latency.tsv'; tsv.write_text(''.join(rows))
    t = time.time(); out = OUT/'.latency.jsonl'
    decode(path, env, tsv, out)
    (OUT/'latency.ids').write_text('\n'.join(l.split('\t', 1)[0] for l in rows) + '\n')
    lat = {json.loads(l)['id']: json.loads(l)['ms'] for l in open(out) if '"ms"' in l}; out.unlink()
    (OUT/'.latest-latency.json').write_text(json.dumps(lat))
    return time.time() - t

def report(name):
    m = {i: x for i, x in meta().items() if x['set'] in ('hard', 'apos') or E.half(x) == 'held'}
    systems = {'Prod (NSS)': E.load(OUT/f'{name}.jsonl')[0], **{k: E.load(OUT/f'{v}.jsonl')[0] for k, v in REFERENCES.items()}}
    metrics = E.metrics(m)
    names = list(systems)
    lines = [f'# Performance tests: {name}', '',
             f'Held half; prod = `{name}` (taps where a set has them), Dev (n-gram) = dev branch n-gram tier with its rules '
             f'(`{REFERENCES["Dev (n-gram)"]}`, taps), CoreV4 = iOS harness with engxx.abn (`{REFERENCES["CoreV4"]}`, no taps). '
             'Each row is scored on the cases every listed system decoded. Δ = prod minus that system, in points; '
             '* = paired McNemar p < 0.05; ↓ = lower is better.', '']
    head = '| Metric | n | ' + ' | '.join(names) + ' | Δ vs Dev | Δ vs CoreV4 |'
    for title, labels in SECTIONS:
        lines += [f'## {title}', '', head, '|' + '---|' * (len(names) + 4)]
        for label in labels:
            if label not in metrics: continue
            ids, pred, up, _ = metrics[label]
            have = [k for k in names if all(i in systems[k] for i in ids[:50]) and any(i in systems[k] for i in ids)]
            if names[0] not in have: continue
            common = [i for i in ids if all(i in systems[k] for k in have)]
            if not common: continue
            val = {k: [bool(pred(systems[k][i], m[i])) for i in common] for k in have}
            rate = {k: 100 * sum(v) / len(v) for k, v in val.items()}
            cells = [f'{rate[k]:.2f}%' if k in rate else '—' for k in names]
            deltas = []
            for ref in names[1:]:
                if ref not in val: deltas.append('—'); continue
                b = sum(x and not y for x, y in zip(val[names[0]], val[ref])); c = sum(y and not x for x, y in zip(val[names[0]], val[ref]))
                d = rate[names[0]] - rate[ref]
                deltas.append(f'{d:+.2f}{"*" if E.mcnemar(b, c) < 0.05 else ""}')
            lines.append(f'| {label.strip()}{"" if up else " ↓"} | {len(common)} | ' + ' | '.join(cells) + ' | ' + ' | '.join(deltas) + ' |')
        lines.append('')
    lat_path = OUT/'.latest-latency.json'
    if lat_path.exists():
        prod_ms = json.loads(lat_path.read_text()); ids = list(prod_ms)
        lines += ['## Typing latency', '', 'Per word, the same 1,000 held ECPS words. Prod measured alone just now; the references from their stored '
                  'runs (also one process, but different days and builds; CoreV4 without taps).', '',
                  '| System | p50 ms | p95 ms | p99 ms |', '|---|---|---|---|']
        for k in names:
            xs = list(prod_ms.values()) if k == names[0] else [systems[k][i]['ms'] for i in ids if i in systems[k] and 'ms' in systems[k][i]]
            if xs: lines.append(f'| {k} | ' + ' | '.join(f'{E.quantile(xs, q):.2f}' for q in (.5, .95, .99)) + ' |')
        lines.append('')
    text = '\n'.join(lines)
    (OUT/f'report-{name.removeprefix("prod-")}.md').write_text(text)
    body = text.replace('\n## ', '\n### ').replace(f'# Performance tests: {name}', f'## Latest standing ({name})', 1)
    DOC.write_text(DOC_HEAD + body + '\n')
    print(text)

DOC_HEAD = '''# Performance tests

"Performance tests" is the name for the keyboard's accuracy and latency benchmark:
`tools/evaluation/autocorrect/performance_tests.py`. It decodes the benchmark's held half
(ECPS real misspellings, MacKenzie synthetic typos, the Aspell/Birkbeck/Holbrook/Wikipedia
misspelling lists, contractions in sentences, and the guardrail sets) on every core, measures
typing latency, and scores prod against two fixed references: the dev branch's n-gram setup
(1 Nov 2026) and CoreV4 (14 Nov 2026, with engxx.abn). Results and reports are in
`tools/evaluation/autocorrect/results/performance-tests/` (git-ignored).

```
cd tools/evaluation/autocorrect
python3 performance_tests.py                       # prod as the app ships it
python3 performance_tests.py --env KB_nssRules=0   # the neural engine alone (see docs/nss-rules.md)
python3 performance_tests.py report prod-<stamp>   # re-score a stored run
```

'''

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', nargs='?', default='run', choices=('run', 'report'))
    ap.add_argument('name', nargs='?')
    ap.add_argument('--env', nargs='*', default=[], help='KB_name=value overrides (uses the tuning build)')
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    report(a.name if a.cmd == 'report' else run(dict(kv.split('=', 1) for kv in a.env), a.jobs))
