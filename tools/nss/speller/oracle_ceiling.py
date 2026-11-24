"""Step 0 of the speller plan: the ceiling if a speller proposed the true target.

For every held misspelling case (ECPS, synthetic, external lists) whose typed text is not a dictionary
word, add the target as one more candidate with spelling cost c (plus the engine's first-letter cost),
then replay the shipped commit rule (fasteval.Bench, rules on, taps) and score the performance-test
metrics. c is swept: what the speller would have to charge for the target to be committed.
"""
import json, pathlib, sys
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
CACHE = HERE/'cache'  # oracle.jsonl, oracle.npz, the annotate binary, candidate caches
sys.path[:0] = [str(REPO/'tools/nss/wsp'), str(REPO/'tools/evaluation/autocorrect')]
import fasteval as F
import evaluate as E

SETS = ('ecps', 'syn', 'ext_aspell', 'ext_birkbeck', 'ext_holbrook', 'ext_wikipedia')
COSTS = [float(c) for c in sys.argv[1:]] or [0.0, 0.5, 1.0, 1.5, 2.0, 3.0]

targets = {}
for line in open(CACHE/'oracle.jsonl'):
    if '"tg"' not in line: continue
    r = json.loads(line)
    targets[r['id']] = r['tg']

bench = F.Bench('held', CACHE/'oracle.npz')
print(f'held cases {bench.n}; replay agrees with the C++ decoder on {100 * bench.agreement():.2f}% of commits')
base_rows = {k: v.copy() for k, v in bench.rows.items()}
keys = list(bench.keys); key_index = {k: i for i, k in enumerate(keys)}

# the cases a speller would run on, and the target row it would add
cases, rows = [], []
for n, i in enumerate(bench.ids):
    m = bench.meta[i]
    if m['set'] not in SETS or i not in targets: continue
    word, allow, mid, lex, out, uni, split, ss, first, blocked = targets[i]
    in_dict = mid >= 0 or out > -1e29
    if bench.typed['tw'][n] == 1 or word == bench.words[n].lower() or not in_dict or blocked: continue
    if word not in key_index: key_index[word] = len(keys); keys.append(word)
    cases.append(n); rows.append((key_index[word], allow, mid, lex, out, uni, ss, first))
bench.keys = np.array(keys, dtype=object)
print(f'speller would run on {len(cases)} cases (typed non-word, target in the dictionary, not blocked)')

def inject(cost):
    add = {k: [] for k in base_rows}
    for n, (key, allow, mid, lex, out, uni, ss, first) in zip(cases, rows):
        for kind in (0, 1):
            vals = dict(case=n, kind=kind, key=key, cost=cost + first, lang=0.0, allow=allow, mid=mid, lex=lex, out=out,
                        uni=uni, split=0, ss=ss, rest=0.0)
            for k in add: add[k].append(vals[k])
    bench.rows = {k: np.concatenate([base_rows[k], np.array(add[k], dtype=base_rows[k].dtype)]) for k in base_rows}
    bench.C = bench.rows['kind'] == 0

LABELS = ['ECPS real misspellings fixed', 'ECPS target in top 3', 'Synthetic typos fixed', 'ext_aspell fixed', 'ext_birkbeck fixed',
          'ext_holbrook fixed', 'ext_wikipedia fixed']
base = bench.reference
results = {}
for c in COSTS:
    inject(c)
    results[c] = bench.score(bench.base)
head = '| Metric | now | ' + ' | '.join(f'cost {c:g}' for c in COSTS) + ' |'
print('\n' + head + '\n|' + '---|' * (len(COSTS) + 2))
for label in LABELS:
    print(f'| {label} | {base[label]:.1f} | ' + ' | '.join(f'{results[c]["metrics"][label]:.1f}' for c in COSTS) + ' |')
print('| guardrail fails | | ' + ' | '.join(', '.join(results[c]['fails']) or 'none' for c in COSTS) + ' |')

# where it still fails at a mid cost: is the typed text winning, or another word?
c = 1.0 if 1.0 in results else COSTS[len(COSTS) // 2]
res = results[c]['results']
why = {}
for n in cases:
    i = bench.ids[n]; m = bench.meta[i]
    if res[i]['c'] == m['target']: continue
    s = 'birkbeck' if m['set'] == 'ext_birkbeck' else 'ecps' if m['set'] == 'ecps' else 'other'
    reason = 'left as typed' if res[i]['c'] is None else 'another word committed'
    why.setdefault(s, {}).setdefault(reason, 0); why[s][reason] += 1
print(f'\nstill missed at cost {c:g}, by reason: {json.dumps(why)}')
json.dump({str(c): results[c]['metrics'] for c in COSTS}, open(CACHE/'oracle_ceiling.json', 'w'), indent=1)
