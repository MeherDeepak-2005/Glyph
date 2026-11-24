#!/usr/bin/env python3
"""One iWSP experiment: apply the weight program, score it on the tune half, log it, snapshot it.

    python3.11 run.py                          # the program's PARAMS
    python3.11 run.py tau=0.8 unk=-0.5         # override PARAMS for this attempt (logged with the name)
    python3.11 run.py --grid tau=0.7,0.8,0.9   # one logged attempt per value

The name logged is model_shorthand_name plus the overrides. The tune half is the only score the
search sees; the held half is the hidden test (final.py), never used to pick an edit.
"""
import argparse, csv, importlib, itertools, json, pathlib, shutil, sys, time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fasteval as F  # noqa: E402
import nsslm  # noqa: E402

RESULTS = HERE/'results'/'overall_results.csv'
LIB = HERE/'lib'
MODELS = HERE/'cache'/'models'
FIELDS = ['name', 'score', 'accuracy', 'guard', 'guard_worse', 'ecps_fixed', 'synthetic_fixed', 'contractions', 'names_changed',
          'tenglish_changed', 'false_corrections', 'fails', 'status', 'params', 'description']


def value(v: str):
    try: return float(v)
    except ValueError: return v


def build(program, params: dict) -> nsslm.Model:
    return program.write_weights(nsslm.load(F.BASE), **params)


def log(row: dict) -> None:
    RESULTS.parent.mkdir(exist_ok=True)
    new = not RESULTS.exists()
    with open(RESULTS, 'a', newline='') as f:
        w = csv.DictWriter(f, FIELDS)
        if new: w.writeheader()
        w.writerow(row)


def attempt(bench, program, params: dict, label: str) -> dict:
    name = program.model_shorthand_name + ''.join(f'_{k}{v:g}' if isinstance(v, float) else f'_{k}{v}' for k, v in params.items())
    try:
        model = build(program, params)
        MODELS.mkdir(parents=True, exist_ok=True)
        path = MODELS/f'{name}.nsslm'; nsslm.save(model, path)
        s = bench.score(nsslm.load(path))
        m = s['metrics']
        row = dict(name=name, score=f'{s["score"]:.3f}', accuracy=f'{s["accuracy"]:.3f}', guard=f'{s["guard"]:.3f}', guard_worse=f'{s["guard_worse"]:.3f}',
                   ecps_fixed=f'{m["ECPS real misspellings fixed"]:.2f}', synthetic_fixed=f'{m["Synthetic typos fixed"]:.2f}',
                   contractions=f'{m["Contractions restored in sentences"]:.2f}', names_changed=f'{m["GUARD unknown names changed"]:.2f}',
                   tenglish_changed=f'{m["GUARD Tenglish words changed"]:.2f}', false_corrections=f'{m["GUARD false corrections, ECPS correct"]:.2f}', fails='; '.join(s['fails']),
                   status='success', params=json.dumps(params), description=program.model_description)
    except Exception as e:  # a crashed attempt is logged, as program.md asks
        row = dict(name=name, status='crash', params=json.dumps(params), description=f'{program.model_description} ({e!r})')
    log(row)
    LIB.mkdir(exist_ok=True)
    snap = LIB/f'{name}.py'
    shutil.copy(HERE/'nss_weights.py', snap)
    with open(snap, 'a') as f: f.write(f'\n# run.py parameters for this attempt\nPARAMS = {params!r}\n')
    print(f'{name:40} score {row.get("score", "-"):>8}  acc {row.get("accuracy", "-"):>7}  gw {row.get("guard_worse", "-"):>6}  ECPS {row.get("ecps_fixed", "-"):>6}  syn {row.get("synthetic_fixed", "-"):>6}  '
          f'names {row.get("names_changed", "-"):>6}  tenglish {row.get("tenglish_changed", "-"):>6}  {row["status"]} {row.get("fails", "")}', flush=True)
    return row


def main():
    global RESULTS
    ap = argparse.ArgumentParser()
    ap.add_argument('overrides', nargs='*')
    ap.add_argument('--grid', nargs='*', default=[])
    ap.add_argument('--cache', default=str(F.CACHE), help='cache/rules.npz to search with the product rules on')
    ap.add_argument('--log', default=None, help='results CSV (default results/overall_results.csv)')
    a = ap.parse_args()
    program = importlib.import_module('nss_weights')
    params = dict(program.PARAMS, **{k: value(v) for k, v in (o.split('=', 1) for o in a.overrides)})
    if a.log: RESULTS = pathlib.Path(a.log)
    t = time.time(); bench = F.Bench('tune', pathlib.Path(a.cache)); print(f'tune half loaded in {time.time() - t:.1f}s')
    grid = [(k, [value(x) for x in v.split(',')]) for k, v in (g.split('=', 1) for g in a.grid)]
    combos = [dict(zip([k for k, _ in grid], vs)) for vs in itertools.product(*[v for _, v in grid])] or [{}]
    for combo in combos:
        attempt(bench, program, dict(params, **combo), ''.join(combo))


if __name__ == '__main__':
    main()
