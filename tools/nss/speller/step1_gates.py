"""Gating variants for the step 1 speller on tune half B (rules learned on tune half A).

    python3 step1_gates.py            # calibrate every gate on tune B
    python3 step1_gates.py held GATE A B K
"""
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import numpy as np
import step1 as S1
import speller as S
import evaluate as E


def dl(a, b):
    ops = S.align(a, b)
    return sum(1 for x, y in ops if x != y)


def gate_fn(name, cap):
    """f(case n, typed, cands) -> the candidates to inject."""
    def none(n, t, cs): return cs
    def dist2(n, t, cs): return [(w, c) for w, c in cs if dl(w, t) >= 2]
    def nocap(n, t, cs): return [] if cap[n] else cs
    def both(n, t, cs): return [] if cap[n] else dist2(n, t, cs)
    def confident(n, t, cs, g=1.5):
        if not cs: return cs
        gap = (cs[1][1] if len(cs) > 1 else 99) - cs[0][1]
        return cs[:1] if gap >= g else []
    def all3(n, t, cs): return [] if cap[n] else confident(n, t, dist2(n, t, cs))
    return dict(none=none, dist2=dist2, nocap=nocap, both=both, confident=confident, all3=all3)[name]


def filtered(r, cands, typed, gate):
    cap = r.bench.typed['cap']
    out = {}
    for i, cs in cands.items():
        n = r.case_of.get(i)
        if n is None: continue
        out[i] = gate(n, typed[i], [(w, c) for w, c in cs if w != typed[i]])
    return out


def main():
    meta = S1.meta_all(); typed = S1.typed_non_words()
    if len(sys.argv) > 1 and sys.argv[1] == 'held':
        gate, a, bias, k = sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])
        r = S1.Replay('held'); base_t, base_i = r.metrics(); report = {}
        for name in ('full', 'noBirkbeck'):
            cands = json.loads((S1.OUT/f'cand-{name}.json').read_text())
            info = S1.annotate(cands, typed)
            r.inject(filtered(r, cands, typed, gate_fn(gate, r.bench.typed['cap'])), info, typed, a, bias, k)
            t, it = r.metrics(); report[name] = (t, it, S1.objective(t, it, base_i))
        print(f'held half, gate {gate}, cost = {a} x nll + {bias} (+ first-letter cost), top {k}\n')
        print('| Metric | now | speller | Δ | speller, rules without Birkbeck | Δ |'); print('|---|---|---|---|---|---|')
        for label in S1.ACC + S1.EXTRA + S1.GUARDS + S1.GUARDS_UP:
            if label not in base_t: continue
            def cell(name):
                t, it, _ = report[name]; g = int((it[label] & ~base_i[label]).sum()); l = int((base_i[label] & ~it[label]).sum())
                return f'{t[label]:.2f} | {t[label] - base_t[label]:+.2f}{"*" if E.mcnemar(g, l) < 0.05 else ""}'
            print(f'| {label} | {base_t[label]:.2f} | {cell("full")} | {cell("noBirkbeck")} |')
        for name in report: print(name, 'score/acc/guard-worse/fails:', report[name][2])
        return
    cands = json.loads((S1.OUT/'cand-tuneA.json').read_text())
    info = S1.annotate(cands, typed)
    r = S1.Replay('tune')
    keep = lambda i, m: m['set'] not in S1.TRAIN_SETS or S1.half_b(m)
    base_t, base_i = r.metrics(keep)
    print(f'baseline tune B accuracy {S1.objective(base_t, base_i, base_i)[1]:.2f}')
    best = {}
    for gate in ('none', 'dist2', 'nocap', 'both', 'confident', 'all3'):
        f = filtered(r, cands, typed, gate_fn(gate, r.bench.typed['cap']))
        for a in (0.15, 0.2, 0.25, 0.3, 0.4):
            for bias in (0.0, 0.25, 0.5, 0.75, 1.0):
                r.inject(f, info, typed, a, bias, 8)
                t, it = r.metrics(keep)
                score, acc, worse, fails = S1.objective(t, it, base_i)
                if gate not in best or score > best[gate][0]: best[gate] = (score, a, bias, acc, worse, fails, t)
        s = best[gate]; print(f'{gate:10} best a={s[1]} b={s[2]}: score {s[0]:.2f} acc {s[3]:.2f} guard-worse {s[4]:.2f} fails {s[5]}', flush=True)
    labels = S1.ACC + S1.EXTRA + S1.GUARDS
    print('\n| Metric | baseline | ' + ' | '.join(best) + ' |'); print('|---|---|' + '---|' * len(best))
    for label in labels:
        if label in base_t: print(f'| {label} | {base_t[label]:.2f} | ' + ' | '.join(f'{best[g][6][label]:.2f}' for g in best) + ' |')
    json.dump({g: v[:6] for g, v in best.items()}, open(S1.OUT/'gates.json', 'w'))


if __name__ == '__main__':
    main()
