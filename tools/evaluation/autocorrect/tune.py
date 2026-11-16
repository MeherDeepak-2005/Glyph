#!/usr/bin/env python3
"""Coordinate search over the KB_TUNABLE constants, on the tune half only.

  tune.py [--passes 2] [--jobs 4] [--start '{"deletionCost": 1.2}'] [--grid '{"channelWeight": [3.0, 5.0]}']
          [--bin ios-tune] [--base final] [--wiki] [--product]

Needs a --tuning build (evaluate.py build --bin ios-tune --tuning) and results/baseline.jsonl
(--base NAME: another full run, e.g. the previous round's final, as the guardrail reference).
--grid replaces GRID; --start overrides the starting values (default: DEFAULTS). Runs decode
with the word model in KB_NSS (default keyboard/nss-english.nsslm).
--wiki adds the tune half of the Wikipedia misspelling list (corpus/ext-cases.tsv) to the run.
Objective: mean of the ECPS, synthetic (and with --wiki, Wikipedia) "fixed" rates. A setting
is rejected when, against the reference run, false corrections (MacKenzie clean + ECPS
correct words) or real-word fixes get worse with McNemar p < 0.05, or more than 30% of the
hard set is changed.
--product evaluates every combination of GRID instead of the coordinate search. Use it for
constants that only work together, such as channelWeight and nssRawCommitMargin.
Every evaluation is appended to results/tune-log.jsonl; the best setting is printed.
A --tuning build reads constants at run time, which hides latency the production build has
(and vice versa): judge latency with production builds of each setting, alternated.
"""
import argparse, concurrent.futures as cf, hashlib, itertools, json, os, subprocess, sys
import evaluate as ev

GRID = {
    'channelWeight': [2.0, 3.0, 4.0, 5.0],
    'insertionCost': [1.2, 1.6, 2.0],
    'deletionCost': [0.8, 1.1, 1.4],
    'transpositionCost': [0.5, 0.65, 0.9],
    'substitutionBase': [0.4, 0.6, 0.8],
    'nssRawCommitMargin': [0.0, 1.0, 2.0],
}
DEFAULTS = {'deletionCost': 1.1, 'insertionCost': 1.6, 'transpositionCost': 0.65, 'substitutionBase': 0.6,
            'channelWeight': 4.0, 'nssRawCommitMargin': 0.0}
META = json.loads((ev.CORPUS/'cases-meta.json').read_text())
META.update(json.loads((ev.CORPUS/'ext-cases-meta.json').read_text()))
META.update(json.loads((ev.CORPUS/'keep-cases-meta.json').read_text()))
CASES = ev.CORPUS/'quick.tsv'

BINARY = 'ios-tune'

def evaluate(setting):
    env = ev.bench_env(**{f'KB_{k}': str(v) for k, v in setting.items()})
    key = hashlib.sha1((json.dumps(setting, sort_keys=True) + CASES.name + env['KB_NSS']).encode()).hexdigest()[:16]
    out = ev.RESULTS/'tune'/BINARY/f'{key}.jsonl'
    out.parent.mkdir(parents=True, exist_ok=True)
    if not out.exists():
        keyboard = ev.REPO/'keyboard'
        subprocess.run([str(ev.BIN/BINARY), str(keyboard/'langdata.bin'), str(keyboard/'safety.kbguard'), str(CASES), str(out) + '.part'],
                       env=env, check=True, stderr=subprocess.DEVNULL)
        os.replace(str(out) + '.part', out)
    return setting, ev.load(out)[0]

def judge(rows, base):
    def flags(ids, pred, r): return [pred(r[i], META[i]) for i in ids]
    by = {}
    for i in rows: by.setdefault(META[i]['set'], []).append(i)
    fixed = lambda r, m: ev.commit(r, m) == m['target']
    changed = lambda r, m: ev.commit(r, m) != ev.norm(m['typed'])
    rate = lambda ids, pred, r: 100 * sum(flags(ids, pred, r)) / len(ids)
    sets = [s for s in ('ecps', 'syn', 'ext_wikipedia') if s in by]
    objective = sum(rate(by[s], fixed, rows) for s in sets) / len(sets)
    ok_ids = by['clean'] + by['ecps_ok']
    worse = lambda ids, pred, bad: (lambda a, b: (sum(x and not y for x, y in zip(a, b)), sum(y and not x for x, y in zip(a, b))))(
        flags(ids, pred, rows), flags(ids, pred, base))
    fc_new, fc_old = worse(ok_ids, changed, True)
    rw_new, rw_old = worse(by['realword'], fixed, False)
    reasons = []
    if fc_new > fc_old and ev.mcnemar(fc_new, fc_old) < 0.05: reasons.append(f'false corrections +{fc_new}/-{fc_old}')
    if rw_old > rw_new and ev.mcnemar(rw_new, rw_old) < 0.05: reasons.append(f'real-word +{rw_new}/-{rw_old}')
    hard = rate(by['hard'], changed, rows)
    if hard > 30: reasons.append(f'hard {hard:.1f}%')
    names = by.get('keep_name', []) + by.get('keep_name_ctx', [])
    if names and rate(names, changed, rows) > rate(names, changed, base):
        reasons.append(f'names {rate(names, changed, rows):.1f}% > {rate(names, changed, base):.1f}%')
    return objective, reasons, dict(ecps=rate(by['ecps'], fixed, rows), syn=rate(by['syn'], fixed, rows),
                                    ecps_top3=rate(by['ecps'], lambda r, m: fixed(r, m) or m['target'] in ev.slots(r, m), rows),
                                    false_corr=100 * sum(flags(ok_ids, changed, rows)) / len(ok_ids), hard=hard,
                                    realword=rate(by['realword'], fixed, rows),
                                    **({'wiki': rate(by['ext_wikipedia'], fixed, rows)} if 'ext_wikipedia' in by else {}),
                                    **({'names': rate(names, changed, rows)} if names else {}))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--passes', type=int, default=2); ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--start', default='{}'); ap.add_argument('--grid'); ap.add_argument('--bin', default='ios-tune')
    ap.add_argument('--base', default='baseline'); ap.add_argument('--wiki', action='store_true')
    ap.add_argument('--product', action='store_true')
    a = ap.parse_args()
    global GRID, BINARY, CASES
    BINARY = a.bin
    if a.grid: GRID = json.loads(a.grid)
    if not CASES.exists(): sys.exit('run "evaluate.py run NAME --quick" once to write corpus/quick.tsv')
    base = ev.load(ev.RESULTS/f'{a.base}.jsonl')[0]
    keep = [l for l in (ev.CORPUS/'keep-cases.tsv').read_text().splitlines(True) if ev.half(META[l.split('\t', 1)[0]]) == 'tune']
    base.update(ev.load(ev.RESULTS/f'{a.base}.keep.jsonl')[0])
    if a.wiki:
        base.update(ev.load(ev.RESULTS/f'{a.base}.ext.jsonl')[0])
        wiki = [l for l in (ev.CORPUS/'ext-cases.tsv').read_text().splitlines(True)
                if META[l.split('\t', 1)[0]]['set'] == 'ext_wikipedia' and ev.half(META[l.split('\t', 1)[0]]) == 'tune']
        CASES = ev.CORPUS/'quick-wiki.tsv'
        CASES.write_text(CASES.with_name('quick.tsv').read_text() + ''.join(wiki))
    CASES = CASES.with_name(CASES.stem + '-keep.tsv')
    CASES.write_text(CASES.with_name(CASES.name.replace('-keep', '')).read_text() + ''.join(keep))
    log = open(ev.RESULTS/'tune-log.jsonl', 'a')
    best = dict(DEFAULTS, **json.loads(a.start))
    _, rows = evaluate(best)
    best_score, reasons, info = judge(rows, base)
    print('start', json.dumps(best), round(best_score, 3), info, reasons, flush=True)
    if a.product:
        settings = [dict(best, **dict(zip(GRID, values))) for values in itertools.product(*GRID.values())]
        with cf.ThreadPoolExecutor(a.jobs) as pool:
            results = []
            for setting, rows in pool.map(evaluate, settings):
                score, reasons, info = judge(rows, base)
                log.write(json.dumps(dict(setting=setting, objective=score, rejected=reasons, **info)) + '\n'); log.flush()
                print(f'  {round(score, 3)} {json.dumps({k: setting[k] for k in GRID})} {info} {reasons or ""}', flush=True)
                if not reasons: results.append((score, setting))
        if results: print('best', json.dumps(max(results, key=lambda r: r[0])[1]), round(max(results, key=lambda r: r[0])[0], 3), flush=True)
        return
    with cf.ThreadPoolExecutor(a.jobs) as pool:
        for p in range(a.passes):
            improved = False
            for name, values in GRID.items():
                trials = [dict(best, **{name: v}) for v in values if v != best[name]]
                for setting, rows in pool.map(evaluate, trials):
                    score, reasons, info = judge(rows, base)
                    log.write(json.dumps(dict(setting=setting, objective=score, rejected=reasons, **info)) + '\n'); log.flush()
                    print(f'  {name}={setting[name]}: {score:.3f} {info} {reasons or ""}', flush=True)
                    if not reasons and score > best_score + 0.02:
                        best, best_score, improved = setting, score, True
                print(f'pass {p} {name} -> {best[name]} (objective {best_score:.3f})', flush=True)
            if not improved: break
    print('best', json.dumps(best), round(best_score, 3), flush=True)

if __name__ == '__main__':
    main()
