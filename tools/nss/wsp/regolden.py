#!/usr/bin/env python3
"""Rewrite a model's goldens (MODEL.goldens.json) for edited weights, without torch.

    python3.11 regolden.py OLD.nsslm OLD.goldens.json NEW.nsslm NEW.goldens.json

The goldens hold, per context, the reference scores the C++ parity tests reproduce
(tools/nss/nss/export.py:goldens). For a word outside the model vocabulary the score is
log P(<unk>|ctx) + a dictionary term that does not depend on the weights, so it moves with
<unk>; every other value is recomputed from the numpy model. First the OLD model must
reproduce the OLD goldens within their tolerance, otherwise nothing is written.
"""
import json, sys, pathlib

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import nsslm  # noqa: E402

MASK = [nsslm.PAD, nsslm.UNK, nsslm.BOS, nsslm.EOS]


def distribution(m: nsslm.Model, ids: list[int]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """log P(.|<s> ids) with pad/<s>/</s> masked, plus the LSTM state after the context."""
    b = 1
    h = np.zeros((b, m.projection.shape[0]), np.float32); c = np.zeros((b, m.hidden), np.float32)
    h, c = m.step(np.array([nsslm.BOS]), h, c)
    for i in ids: h, c = m.step(np.array([i]), h, c)
    return logp(m, h), h, c


def logp(m: nsslm.Model, h: np.ndarray) -> np.ndarray:
    z = (h @ m.out_matrix.T + m.output_bias)[0].astype(np.float64)
    z[[nsslm.PAD, nsslm.BOS, nsslm.EOS]] = -np.inf
    top = z.max(); return z - (top + np.log(np.exp(z - top).sum()))


def rebuild(m: nsslm.Model, old: dict) -> dict:
    new = json.loads(json.dumps(old))
    for case, ref in zip(new['cases'], old['cases']):
        lp, h, c = distribution(m, case['ids'])
        unk = float(lp[nsslm.UNK])

        def score(word, lp=lp, unk=unk, ref_unk=ref['unk']):
            i = m.index.get(word, nsslm.UNK)
            if i != nsslm.UNK: return float(lp[i])
            return unk + (ref['scores'][word] - ref_unk) if word in ref['scores'] else None

        case['unk'] = unk
        case['scores'] = {w: score(w) for w in ref['scores']}
        values = lp.copy(); values[MASK] = -np.inf
        keep = np.nonzero(values > -15.0)[0]
        order = keep[np.argsort(-values[keep], kind='stable')]
        case['arc_count'] = int(len(order))
        case['top'] = [[m.words[i], float(values[i])] for i in order[:len(ref['top'])]]
        extend = {}
        for pair in ref['extend']:
            a, b = pair.split(' ')
            first = m.index.get(a, nsslm.UNK)
            h2, _ = m.step(np.array([first]), h, c)
            lp2 = logp(m, h2)
            second = float(lp2[m.index[b]]) if b in m.index else float(lp2[nsslm.UNK]) + (ref['extend'][pair] - 0)
            extend[pair] = score(a) + second
        case['extend'] = extend
    return new


def check(a: dict, b: dict, tol: float) -> float:
    worst = 0.0
    for x, y in zip(a['cases'], b['cases']):
        worst = max(worst, abs(x['unk'] - y['unk']))
        worst = max([worst] + [abs(x['scores'][w] - y['scores'][w]) for w in x['scores']])
        worst = max([worst] + [abs(x['extend'][k] - y['extend'][k]) for k in x['extend']])
        if [w for w, _ in x['top']] != [w for w, _ in y['top']]:
            raise SystemExit(f'top words differ for {x["context"]}')
        worst = max([worst] + [abs(p - q) for (_, p), (_, q) in zip(x['top'], y['top'])])
        if abs(x['arc_count'] - y['arc_count']) > 2:
            raise SystemExit(f'arc count {x["arc_count"]} vs {y["arc_count"]} for {x["context"]}')
    return worst


if __name__ == '__main__':
    old_model, old_goldens, new_model, out = sys.argv[1:5]
    old = json.loads(pathlib.Path(old_goldens).read_text())
    worst = check(rebuild(nsslm.load(old_model), old), old, old['tolerance'])
    print(f'old model reproduces old goldens: worst |diff| {worst:.2e} (tolerance {old["tolerance"]})')
    if worst > old['tolerance']: raise SystemExit('refusing to write: the numpy reference does not match')
    pathlib.Path(out).write_text(json.dumps(rebuild(nsslm.load(new_model), old), indent=1) + '\n')
    print(f'wrote {out}')
