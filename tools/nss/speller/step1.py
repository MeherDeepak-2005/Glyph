"""Step 1: learned rewrite speller, merged into the shipped commit rule (replay), calibrated on tune, reported on held.

    python3 step1.py candidates   # speller candidates for every typed non-word (cached in step1/)
    python3 step1.py calibrate    # grid over cost = a * nll + b (+ first-letter cost), top-k, on tune half B
    python3 step1.py held A B K   # held-half report with those settings (rules from the whole tune half; and without Birkbeck)
"""
import hashlib, json, multiprocessing as mp, pathlib, re, subprocess, sys, time
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
CACHE = HERE/'cache'  # oracle.jsonl, oracle.npz, the annotate binary, candidate caches
OUT = CACHE/'step1'; OUT.mkdir(parents=True, exist_ok=True)
sys.path[:0] = [str(HERE), str(REPO/'tools/nss/wsp'), str(REPO/'tools/evaluation/autocorrect')]
import speller as S
import evaluate as E

TRAIN_SETS = ('ecps', 'ext_aspell', 'ext_birkbeck', 'ext_holbrook', 'ext_wikipedia')
ACC = ['ECPS real misspellings fixed', 'Synthetic typos fixed', 'ext_aspell fixed', 'ext_birkbeck fixed', 'ext_holbrook fixed',
       'ext_wikipedia fixed', 'Contractions restored in sentences']
GUARDS = ['GUARD false corrections, ECPS correct', 'GUARD false corrections, MacKenzie clean', 'GUARD unknown names changed',
          'GUARD unknown slang changed', 'GUARD rare dictionary words changed', 'GUARD Tenglish words changed',
          'GUARD plain word changed in sentences', 'GUARD hard valid words changed', 'GUARD correct plurals stripped']
GUARDS_UP = ['GUARD contractions restored', 'GUARD real-word errors fixed']
EXTRA = ['ECPS target in top 3', 'ext_birkbeck in top 3', 'ECPS left uncorrected']


def meta_all():
    m = {}
    for p in [E.CORPUS/'cases-meta.json', *sorted(E.CORPUS.glob('*-cases-meta.json'))]: m.update(json.loads(p.read_text()))
    return m


def half_b(m):  # second split of the tune half, by target word
    return int(hashlib.sha1((m.get('key', m['target']) + '|cal').encode()).hexdigest(), 16) % 2 == 1


def pairs(meta, pick):
    return [(m['typed'].lower(), m['target'].lower()) for m in meta.values() if m['set'] in TRAIN_SETS and pick(m)]


def lexicon_words():
    words = [l.split('\t', 1)[0] for l in open(REPO/'tools/data/nss/unigram-v1/unigrams.tsv')][1:]
    return [w for w in words if re.fullmatch(r"[a-z']+", w)]


def typed_non_words():
    """{id: typed} for every case the speller runs on: typed text not a dictionary word (from the dump)."""
    z = np.load(CACHE/'oracle.npz', allow_pickle=True)
    return {i: w.lower() for i, w, tw in zip(z['ids'], z['words'], z['typed_tw']) if tw == 0}


_SP = None
def _work(item):
    i, typed = item
    return i, [(w, round(c, 4)) for w, c in _SP.candidates(typed, k=8)]


def run_candidates(name, train_pairs, items):
    global _SP
    path = OUT/f'cand-{name}.json'
    if path.exists(): return json.loads(path.read_text())
    t = time.time(); model = S.train(train_pairs)
    _SP = S.Speller(model, lexicon_words())
    with mp.get_context('fork').Pool(mp.cpu_count()) as pool:
        out = dict(pool.map(_work, items, chunksize=64))
    path.write_text(json.dumps(out)); print(f'{name}: {len(train_pairs)} pairs, {sum(map(len, model.values()))} rules, {len(items)} cases, {time.time() - t:.0f}s')
    return out


def annotate(cands, typed):
    """Engine lookup values for every (typed, candidate) pair, via the annotate tool."""
    keys = sorted({(typed[i], w) for i, cs in cands.items() for w, _ in cs})
    res = subprocess.run([str(CACHE/'annotate'), str(REPO/'keyboard/langdata.bin'), str(REPO/'keyboard/safety.kbguard'),
                          str(REPO/'keyboard/nss-english.nsslm')], input=''.join(f'{t}\t{w}\n' for t, w in keys),
                         capture_output=True, text=True, check=True).stdout.splitlines()
    out = {}
    for (t, w), line in zip(keys, res):
        f = line.split('\t'); assert f[0] == w
        out[t, w] = dict(allow=int(f[1]), mid=int(f[2]), lex=float(f[3]), out=float(f[4]), uni=float(f[5]), ss=int(f[6]),
                         first=float(f[7]), blocked=int(f[8]))
    return out


class Replay:
    def __init__(self, split):
        import fasteval as F
        self.bench = F.Bench(split, CACHE/'oracle.npz')
        b = self.bench
        self.base_rows = {k: v.copy() for k, v in b.rows.items()}
        self.keys = list(b.keys); self.key_index = {k: n for n, k in enumerate(self.keys)}
        self.case_of = {i: n for n, i in enumerate(b.ids)}

    def inject(self, cands, info, typed, a, bias, k, only=None):
        b = self.bench
        add = {key: [] for key in self.base_rows}
        for i, cs in cands.items():
            n = self.case_of.get(i)
            if n is None or (only is not None and i not in only): continue
            t = typed[i]
            for w, nll in cs[:k]:
                if w == t: continue
                x = info[t, w]
                if x['blocked']: continue
                if w not in self.key_index: self.key_index[w] = len(self.keys); self.keys.append(w)
                for kind in (0, 1):
                    row = dict(case=n, kind=kind, key=self.key_index[w], cost=a * nll + bias + x['first'], lang=0.0, allow=x['allow'],
                               mid=x['mid'], lex=x['lex'], out=x['out'], uni=x['uni'], split=0, ss=x['ss'], rest=0.0)
                    for key in add: add[key].append(row[key])
        b.keys = np.array(self.keys, dtype=object)
        b.rows = {key: np.concatenate([self.base_rows[key], np.array(add[key], dtype=self.base_rows[key].dtype)]) for key in self.base_rows}
        b.C = b.rows['kind'] == 0

    def metrics(self, ids_filter=None):
        b = self.bench
        res = b.results(b.base)
        meta = {i: m for i, m in b.meta.items() if ids_filter is None or ids_filter(i, m)}
        table, items = {}, {}
        for label, (ids, pred, up, _) in E.metrics(meta).items():
            if label not in ACC + GUARDS + GUARDS_UP + EXTRA: continue
            ids = [i for i in ids if i in res]
            if ids: items[label] = np.array([bool(pred(res[i], meta[i])) for i in ids]); table[label] = 100 * items[label].mean()
        return table, items


def objective(table, items, ref_items):
    acc = np.mean([table[k] for k in ACC if k in table])
    worse, fails = 0.0, []
    for k, up in [(k, False) for k in GUARDS] + [(k, True) for k in GUARDS_UP]:
        if k not in items: continue
        new, ref = items[k], ref_items[k]
        gained, lost = int((new & ~ref).sum()), int((ref & ~new).sum())
        if not up: gained, lost = lost, gained
        worse += max(0.0, (lost - gained) * 100 / len(new))
        if lost > gained and E.mcnemar(gained, lost) < 0.05: fails.append(k)
    return acc - 0.5 * worse - 10 * len(fails), acc, worse, fails


def main():
    cmd = sys.argv[1]
    meta = meta_all(); typed = typed_non_words()
    tune = lambda m: E.half(m) == 'tune'
    held_ids = {i for i in typed if i in meta and E.half(meta[i]) == 'held'}
    tune_ids = {i for i in typed if i in meta and E.half(meta[i]) == 'tune'}
    if cmd == 'candidates':
        run_candidates('tuneA', pairs(meta, lambda m: tune(m) and not half_b(m)), sorted((i, typed[i]) for i in tune_ids))
        run_candidates('full', pairs(meta, tune), sorted((i, typed[i]) for i in held_ids))
        run_candidates('noBirkbeck', pairs(meta, lambda m: tune(m) and m['set'] != 'ext_birkbeck'),
                       sorted((i, typed[i]) for i in held_ids))
        return
    if cmd == 'calibrate':
        cands = json.loads((OUT/'cand-tuneA.json').read_text())
        info = annotate(cands, typed)
        r = Replay('tune')
        # misspelling sets the rules were learned on (half A) are excluded from scoring; guardrails and other sets count fully
        keep = lambda i, m: m['set'] not in TRAIN_SETS or half_b(m)
        base_t, base_i = r.metrics(keep)
        rows = []
        for k in (3, 8):
            for a in (0.15, 0.2, 0.25, 0.3, 0.4):
                for bias in (0.0, 0.5, 1.0, 1.5):
                    r.inject(cands, info, typed, a, bias, k)
                    t, it = r.metrics(keep)
                    score, acc, worse, fails = objective(t, it, base_i)
                    rows.append((score, k, a, bias, acc, worse, fails, t))
                    print(f'k={k} a={a} b={bias}: score {score:.2f} acc {acc:.2f} guard-worse {worse:.2f} fails {fails}', flush=True)
        base_score = objective(base_t, base_i, base_i)
        print(f'\nbaseline (tune B): acc {base_score[1]:.2f}')
        rows.sort(key=lambda x: -x[0])
        for s in rows[:5]: print(s[:7])
        best = rows[0]
        print('\n| Metric | baseline | best |'); print('|---|---|---|')
        for label in ACC + EXTRA + GUARDS + GUARDS_UP:
            if label in base_t: print(f'| {label} | {base_t[label]:.2f} | {best[7][label]:.2f} |')
        return
    if cmd == 'held':
        a, bias, k = float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
        r = Replay('held')
        base_t, base_i = r.metrics()
        report = {}
        for name in ('full', 'noBirkbeck'):
            cands = json.loads((OUT/f'cand-{name}.json').read_text())
            info = annotate(cands, typed)
            r.inject(cands, info, typed, a, bias, k)
            t, it = r.metrics()
            report[name] = (t, it, objective(t, it, base_i))
        print(f'held half, cost = {a} x nll + {bias} (+ first-letter cost), top {k}\n')
        print('| Metric | now | speller | Δ | speller, rules without Birkbeck | Δ |'); print('|---|---|---|---|---|---|')
        for label in ACC + EXTRA + GUARDS + GUARDS_UP:
            if label not in base_t: continue
            f, nb = report['full'][0][label], report['noBirkbeck'][0][label]
            sig = lambda it: '*' if E.mcnemar(int((it[label] & ~base_i[label]).sum()), int((base_i[label] & ~it[label]).sum())) < 0.05 else ''
            print(f'| {label} | {base_t[label]:.2f} | {f:.2f} | {f - base_t[label]:+.2f}{sig(report["full"][1])} | {nb:.2f} | {nb - base_t[label]:+.2f}{sig(report["noBirkbeck"][1])} |')
        for name in report: print(name, 'score/acc/guard-worse/fails:', report[name][2])


if __name__ == '__main__':
    main()
