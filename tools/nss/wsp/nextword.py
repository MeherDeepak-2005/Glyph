#!/usr/bin/env python3
"""Next-word top-3 (empty typed word) on the benchmark's held 'nw' rows, from the model alone.

    python3.11 nextword.py model.nsslm [...]

Approximates the strip with no letters typed: the three most probable vocabulary words after the
context (specials and <unk> excluded). It shows what an output-bias edit does to prediction,
which performance_tests.py does not decode.
"""
import re, sys, pathlib
import numpy as np
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fasteval as F, nsslm  # noqa: E402

def context(raw: str) -> list[str]:
    raw = re.split(r'[.!?\n]', raw + ' ')[-1]
    return [w.lower() for w in re.findall(r"[A-Za-z'\u0080-￿]+", raw)][-8:]

meta = F.P.meta()
rows = [l.rstrip('\n').split('\t') for l in open(F.E.CORPUS/'cases.tsv')]
rows = [r for r in rows if r[0] in meta and meta[r[0]]['set'] == 'nw' and F.E.half(meta[r[0]]) == 'held']
for path in sys.argv[1:]:
    m = nsslm.load(path)
    feats = m.features([tuple(i for w in context(r[2]) if (i := m.context_id(w)) >= 0) for r in rows])
    z = feats @ m.out_matrix.T + m.output_bias; z[:, :4] = -np.inf
    top = np.argsort(-z, 1)[:, :3]
    hit = np.mean([r[4].lower() in {m.words[k] for k in t} for r, t in zip(rows, top)])
    print(f'{pathlib.Path(path).name}: next word in top 3 {100 * hit:.2f}% (n={len(rows)})')
