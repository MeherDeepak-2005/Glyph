#!/usr/bin/env python3
"""Decode one half with the real C++ decoder (rules off) for given models and score it like fasteval.

    python3.11 verify.py --split tune cache/models/NAME.nsslm [...]

Uses the performance tests' tuning build (KB_nssRules=0, KB_NSS=<model>) on every core, so the
beam search itself runs with the edited weights; prints the real metrics next to fasteval's
prediction for the same model, which shows how far the fixed-candidate rescoring can be trusted.
"""
import argparse, concurrent.futures as cf, json, os, pathlib, subprocess, sys, time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fasteval as F  # noqa: E402
import nsslm  # noqa: E402
P, E = F.P, F.E


def shards(split: str, size: int = 300):
    out = HERE/'cache'/f'shards-{split}'
    if not (out.exists() and any(out.iterdir())):
        out.mkdir(parents=True, exist_ok=True)
        m = P.meta(); held = lambda x: x['set'] in ('hard', 'apos') or E.half(x) == 'held'
        rows = [l for name in P.SETS for l in open(E.CORPUS/name)
                if (i := l.split('\t', 1)[0]) in m and m[i]['set'] != 'nw' and held(m[i]) == (split == 'held')]
        for k in range(0, len(rows), size): (out/f'{k // size:04d}.tsv').write_text(''.join(rows[k:k + size]))
    return sorted(out.glob('*.tsv'), key=lambda p: -sum(len(l.split('\t')[3]) for l in open(p)))


def decode(model: pathlib.Path, split: str, jobs: int = os.cpu_count()) -> dict:
    binary = P.binary(True); parts = shards(split)
    tmp = HERE/'cache'/f'.verify-{model.stem}-{split}'; tmp.mkdir(parents=True, exist_ok=True)
    env = E.bench_env(KB_NSS=str(model), KB_nssRules='0')
    run = lambda p: subprocess.run([str(binary), str(E.REPO/'keyboard/langdata.bin'), str(E.REPO/'keyboard/safety.kbguard'), str(p),
                                    str(tmp/f'{p.stem}.jsonl')], env=env, check=True, stderr=subprocess.DEVNULL)
    with cf.ThreadPoolExecutor(jobs) as pool: list(pool.map(run, parts))
    rows = {}
    for p in tmp.glob('*.jsonl'):
        for line in open(p):
            r = json.loads(line)
            if 'id' in r: rows[r['id']] = r
        p.unlink()
    tmp.rmdir()
    return rows


def table(bench, rows: dict) -> dict:
    metrics = E.metrics(bench.meta); out = {}
    for label in F.REPORT:
        if label not in metrics: continue
        ids = [i for i in metrics[label][0] if i in rows]
        if ids: out[label] = 100 * sum(bool(metrics[label][1](rows[i], bench.meta[i])) for i in ids) / len(ids)
    return out


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('models', nargs='+')
    ap.add_argument('--split', default='tune', choices=('tune', 'held'))
    a = ap.parse_args()
    bench = F.Bench(a.split)
    awake = subprocess.Popen(['caffeinate', '-ims', '-w', str(os.getpid())])
    for path in map(pathlib.Path, a.models):
        t = time.time(); real = table(bench, decode(path, a.split)); took = time.time() - t
        fast = bench.score(nsslm.load(path))['metrics']
        print(f'\n{path.name} ({a.split}, real decode {took:.0f}s)\n| Metric | fasteval | C++ decoder | diff |\n|---|---|---|---|')
        for k in real: print(f'| {k} | {fast[k]:.2f} | {real[k]:.2f} | {real[k] - fast[k]:+.2f} |')
    awake.terminate()
