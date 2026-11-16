#!/usr/bin/env python3
"""Measure NSS product rules (native/DecoderCore/include/NssRules.hpp) one at a time, in parallel.

  ablate.py run NAME=ENV[,ENV...] [NAME=...] [--jobs N] [--split held|tune]
      e.g. ablate.py run base=nssRules=0 vowel=nssRules=1,nssRuleVowelSwap=1,nssRuleApostrophe=0,...
      Every configuration decodes the same cases (simulated taps where the set has them; the
      split's half plus the always-scored hard/apos sets; no next-word prediction rows), cut into
      shards that all run at once on N worker processes (default: every core). Writes
      results/NAME.jsonl, scored like any run (evaluate.py score NAME --vs REF).
  ablate.py latency NAME=ENV ... [--cases N] [--rounds R]
      Typing latency without contention: one process at a time, configurations interleaved over
      R rounds on the same N held ECPS cases (with taps); prints p50/p95/p99 per configuration.

Needs the tuning build: evaluate.py build --bin rules --tuning.
"""
import argparse, concurrent.futures as cf, json, os, pathlib, subprocess, sys, time
import evaluate as E

BIN = E.BIN/'rules'
SHARDS = E.HERE/'corpus'/'shards'
SETS = ('cases.taps.tsv', 'ext-cases.taps.tsv', 'keep-cases.taps.tsv', 'contraction-cases.tsv', 'tenglish-cases.tsv')
RULES = ('nssRuleVowelSwap', 'nssRuleApostrophe', 'nssRuleDoubledLetters', 'nssRuleFirstLetter')

def meta():
    m = json.loads((E.CORPUS/'cases-meta.json').read_text())
    for extra in sorted(E.CORPUS.glob('*-cases-meta.json')): m.update(json.loads(extra.read_text()))
    return m

def shards(split, size=600):
    """The split's decode rows, cut into shards of about `size` rows (cached under corpus/shards)."""
    out = SHARDS/split
    if out.exists() and any(out.iterdir()): return sorted(out.glob('*.tsv'))
    out.mkdir(parents=True, exist_ok=True)
    m = meta(); rows = []
    for name in SETS:
        for line in open(E.CORPUS/name):
            i = line.split('\t', 1)[0]
            if i in m and m[i]['set'] != 'nw' and (m[i]['set'] in ('hard', 'apos') or E.half(m[i]) == split): rows.append(line)
    paths = []
    for k in range(0, len(rows), size):
        p = out/f'{k // size:04d}.tsv'; p.write_text(''.join(rows[k:k + size])); paths.append(p)
    return paths

def parse(specs):
    configs = {}
    for spec in specs:
        name, _, env = spec.partition('=')
        configs[name] = dict(kv.split('=') for kv in env.split(',') if kv)
    return configs

def decode(binary, env, cases, out):
    t = time.time()
    subprocess.run([str(binary), str(E.REPO/'keyboard/langdata.bin'), str(E.REPO/'keyboard/safety.kbguard'), str(cases), str(out)],
                   env=E.bench_env(**{f'KB_{k}': v for k, v in env.items()}), check=True, stderr=subprocess.DEVNULL)
    return time.time() - t

def run(configs, jobs, split):
    paths = shards(split)
    work = [(name, env, p) for p in paths for name, env in configs.items()]
    tmp = E.RESULTS/'shards'; tmp.mkdir(parents=True, exist_ok=True)
    start = time.time(); done = 0
    awake = subprocess.Popen(['caffeinate', '-ims', '-w', str(os.getpid())])
    with cf.ThreadPoolExecutor(jobs) as pool:
        futures = [pool.submit(decode, BIN, env, p, tmp/f'{name}.{p.stem}.jsonl') for name, env, p in work]
        for f in cf.as_completed(futures):
            f.result(); done += 1
            if done % max(1, len(work) // 10) == 0: print(f'  {done}/{len(work)} shards, {time.time() - start:.0f} s', flush=True)
    awake.terminate()
    for name in configs:
        with open(E.RESULTS/f'{name}.jsonl', 'w') as out:
            for p in paths:
                part = tmp/f'{name}.{p.stem}.jsonl'
                out.write(part.read_text()); part.unlink()
        print(E.RESULTS/f'{name}.jsonl')
    print(f'{len(configs)} configurations x {len(paths)} shards in {time.time() - start:.0f} s on {jobs} workers')

def latency(configs, cases, rounds):
    m = meta()
    rows = [l for l in open(E.CORPUS/'cases.taps.tsv') if (i := l.split('\t', 1)[0]) in m and m[i]['set'] == 'ecps' and E.half(m[i]) == 'held'][:cases]
    tsv = SHARDS/'latency.tsv'; tsv.parent.mkdir(parents=True, exist_ok=True); tsv.write_text(''.join(rows))
    ms = {name: [] for name in configs}
    for _ in range(rounds):
        for name, env in configs.items():
            out = E.RESULTS/'shards'/f'lat-{name}.jsonl'; out.parent.mkdir(parents=True, exist_ok=True)
            decode(BIN, env, tsv, out)
            ms[name] += [json.loads(l)['ms'] for l in open(out) if '"ms"' in l]
            out.unlink()
    report = {}
    print(f'{"configuration":24}{"p50 ms":>9}{"p95 ms":>9}{"p99 ms":>9}')
    for name, xs in ms.items():
        q = {p: E.quantile(xs, p / 100) for p in (50, 95, 99)}
        report[name] = q
        print(f'{name:24}{q[50]:9.2f}{q[95]:9.2f}{q[99]:9.2f}')
    return report

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run'); r.add_argument('configs', nargs='+'); r.add_argument('--jobs', type=int, default=os.cpu_count())
    r.add_argument('--split', choices=('held', 'tune'), default='held')
    l = sub.add_parser('latency'); l.add_argument('configs', nargs='+'); l.add_argument('--cases', type=int, default=1500)
    l.add_argument('--rounds', type=int, default=3); l.add_argument('--json')
    a = ap.parse_args()
    if a.cmd == 'run': run(parse(a.configs), a.jobs, a.split)
    else:
        rep = latency(parse(a.configs), a.cases, a.rounds)
        if a.json: pathlib.Path(a.json).write_text(json.dumps(rep, indent=1) + '\n')
