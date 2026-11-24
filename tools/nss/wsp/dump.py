#!/usr/bin/env python3
"""Decode every benchmark case once with the rules off and save each case's candidates.

    python3 dump.py [--model keyboard/nss-english.nsslm] [--out cache/base.jsonl] [--rules off|on]

Runs the tuning build of IOSBench with KB_DUMP=2 (and KB_nssRules=0 unless --rules on) on every core over the
performance-test sets (tune and held halves, no next-word rows). Each JSONL row holds the
context, the typed text, every complete candidate and the top ranked rows with their channel
cost and the dictionary parts the language score is built from. fasteval.py rescores these rows
with any edited weights in seconds.
"""
import argparse, concurrent.futures as cf, os, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
AUTO = REPO/'tools/evaluation/autocorrect'
sys.path.insert(0, str(AUTO))
import evaluate as E
import performance_tests as P

def shards(size=400):
    out = HERE/'cache'/'shards'
    if not (out.exists() and any(out.iterdir())):
        out.mkdir(parents=True, exist_ok=True)
        m = P.meta()
        rows = [l for name in P.SETS for l in open(E.CORPUS/name) if (i := l.split('\t', 1)[0]) in m and m[i]['set'] != 'nw']
        for k in range(0, len(rows), size): (out/f'{k // size:04d}.tsv').write_text(''.join(rows[k:k + size]))
    return sorted(out.glob('*.tsv'), key=lambda p: -sum(len(l.split('\t')[3]) for l in open(p)))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', default=str(REPO/'keyboard/nss-english.nsslm'))
    ap.add_argument('--out', default=str(HERE/'cache'/'base.jsonl'))
    ap.add_argument('--jobs', type=int, default=os.cpu_count())
    ap.add_argument('--rules', choices=('off', 'on'), default='off', help='on = the product rules as the app ships them')
    a = ap.parse_args()
    binary = E.BIN/'wsp-dump'
    sources = [pathlib.Path(s) for s in E.core_sources()] + [AUTO/'IOSBench.cpp', *(REPO/'native/DecoderCore/include').glob('*.hpp')]
    if not binary.exists() or max(s.stat().st_mtime for s in sources) > binary.stat().st_mtime: E.build('wsp-dump', True)
    parts = shards(); tmp = pathlib.Path(a.out + '.parts'); tmp.mkdir(parents=True, exist_ok=True)
    env = E.bench_env(KB_NSS=a.model, KB_DUMP='2', **({'KB_nssRules': '0'} if a.rules == 'off' else {}))
    env.pop('KB_nssRules', None) if a.rules == 'on' else None
    def run(p):
        subprocess.run([str(binary), str(REPO/'keyboard/langdata.bin'), str(REPO/'keyboard/safety.kbguard'), str(p), str(tmp/f'{p.stem}.jsonl')],
                       env=env, check=True, stderr=subprocess.DEVNULL)
    awake = subprocess.Popen(['caffeinate', '-ims', '-w', str(os.getpid())])
    try:
        with cf.ThreadPoolExecutor(a.jobs) as pool: list(pool.map(run, parts))
    finally: awake.terminate()
    with open(a.out, 'w') as f:
        for p in sorted(tmp.glob('*.jsonl')): f.write(p.read_text()); p.unlink()
    tmp.rmdir(); print(a.out)

if __name__ == '__main__':
    main()
