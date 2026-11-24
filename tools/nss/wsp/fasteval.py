#!/usr/bin/env python3
"""Seconds-fast, vectorized rescoring of the rules-off benchmark with any NSS weights.

    python3.11 fasteval.py [model.nsslm ...] [--split tune|held|all]

dump.py decoded every performance-test case once (rules off, shipped weights) and saved each
case's candidate words with their channel (keyboard) costs. The decoder's score is
    language(word | context) - channelWeight * channel cost,
and Space commits the best complete word when it beats the typed text by the commit margin.
Only `language` depends on the weights, so this script reruns the CIFG-LSTM on the unique
contexts in numpy, rebuilds every candidate's language score exactly as NeuralFst does
(model word: max(P(word), P(<unk>) * unigram floor); dictionary word outside the model:
P(<unk>) * outside share; typed non-word: P(<unk>) * typed share; sentence start mixed with
the unigram at nssStartUnigramWeight), replays the commit rule and scores the same metrics as
performance_tests.py. The candidate lists are fixed, so a large weight change can miss a word
the beam would newly find: confirm a result with the real decoder (performance_tests.py
--env KB_nssRules=0 with KB_NSS=<model>).
"""
from __future__ import annotations

import argparse, json, pathlib, sys, time

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO/'tools/evaluation/autocorrect'))
import evaluate as E  # noqa: E402
import performance_tests as P  # noqa: E402
import nsslm  # noqa: E402

BASE = REPO/'keyboard/nss-english.nsslm'
CACHE = HERE/'cache'/'base.npz'   # rules off; cache/rules.npz = rules on (dump.py --rules on)
KEEP_BELOW, KEEP_C, KEEP_R = 15.0, 24, 8

ACCURACY = ['ECPS real misspellings fixed', 'Synthetic typos fixed', 'ext_aspell fixed', 'ext_birkbeck fixed',
            'ext_holbrook fixed', 'ext_wikipedia fixed', 'Contractions restored in sentences']
GUARDS = ['GUARD false corrections, ECPS correct', 'GUARD false corrections, MacKenzie clean', 'GUARD unknown names changed',
          'GUARD rare dictionary words changed', 'GUARD Tenglish words changed', 'GUARD plain word changed in sentences']
GUARDS_UP = ['GUARD next word in top 3', 'GUARD real-word errors fixed', 'ECPS target in top 3', 'Synthetic target in top 3']  # higher is better
REPORT = ACCURACY + ['GUARD next word in top 3', 'ECPS target in top 3', 'ECPS left uncorrected', 'Synthetic target in top 3', 'GUARD contractions restored',
                     'GUARD real-word errors fixed', 'GUARD hard valid words changed'] + GUARDS


def _context(raw: str) -> list[str]:
    """The harness's context: the words after the last sentence end, lowercased, at most 8."""
    import re
    raw = re.split(r'[.!?\n]', raw + ' ')[-1]
    return [w.lower() for w in re.findall(r"[A-Za-z'\u0080-\uffff]+", raw)][-8:]


def _segment_top(case: np.ndarray, score: np.ndarray, k: int) -> np.ndarray:
    """Indices of the k best rows of every case (rows grouped by case), as a boolean mask."""
    order = np.lexsort((-score, case))
    c = case[order]
    start = np.r_[0, np.nonzero(np.diff(c))[0] + 1]
    rank = np.arange(len(c)) - np.repeat(start, np.diff(np.r_[start, len(c)]))
    keep = np.zeros(len(case), bool); keep[order[rank < k]] = True
    return keep


class Bench:
    """The cached candidates for one split, with the shipped model's language scores as reference."""

    def __init__(self, split: str = 'tune', cache: pathlib.Path = CACHE, base: pathlib.Path = BASE):
        z = np.load(cache, allow_pickle=True)
        self.info = json.loads(str(z['info']))
        meta = P.meta()
        ids = z['ids']
        held = lambda m: m['set'] in ('hard', 'apos') or E.half(m) == 'held'
        pick = np.array([split == 'all' or held(meta[i]) == (split == 'held') for i in ids])
        new_index = np.cumsum(pick) - 1
        self.ids = ids[pick]; self.meta = {i: meta[i] for i in self.ids}
        self.keys = z['keys']
        self.words = z['words'][pick]
        self.cpp_suggestions = z['suggestions'][pick]
        t = {k[6:]: z[k][pick] for k in z.files if k.startswith('typed_')}
        self.typed = t
        ctx_len = z['ctx_len']; ctx_start = np.r_[0, np.cumsum(ctx_len)]; words = z['ctx_words']
        case_ctx = z['case_ctx'][pick]
        used, self.case_ctx = np.unique(case_ctx, return_inverse=True)
        self.contexts_words = [tuple(words[ctx_start[c]:ctx_start[c + 1]]) for c in used]
        rows = {k[4:]: z[k] for k in z.files if k.startswith('row_')}
        keep = pick[rows['case']]
        rows = {k: v[keep] for k, v in rows.items()}
        rows['case'] = new_index[rows['case']].astype(np.int32)
        self.n = int(pick.sum())
        self.base = nsslm.load(base)
        self.margins = self.info['margins']; self.cw = self.info['channel_weight']; self.w = self.info['start_weight']
        self.typed_const = np.log(1 - self.info['unk_share']) + np.log(0.5 / self.info['outside_mass'])
        # reference language with the shipped weights: the split rows keep the dumped rest of the phrase
        ref = self._parts(self.base)
        first = self._first(ref, rows)
        rows['rest'] = np.where(rows['split'] == 1, rows['lang'] - first, 0).astype(np.float32)
        score = self._language(ref, rows, first) - self.cw * rows['cost']
        best_c = np.full(self.n, -np.inf); np.maximum.at(best_c, rows['case'][rows['kind'] == 0], score[rows['kind'] == 0])
        top = np.maximum(best_c, self._typed_score(ref))[rows['case']]
        keep = score >= top - KEEP_BELOW
        keep &= np.where(rows['kind'] == 0, _segment_top(rows['case'], np.where(rows['kind'] == 0, score, -np.inf), KEEP_C),
                         _segment_top(rows['case'], np.where(rows['kind'] == 1, score, -np.inf), KEEP_R))
        self.rows = {k: v[keep] for k, v in rows.items()}
        self.C = self.rows['kind'] == 0
        nw = [l.rstrip('\n').split('\t') for l in open(E.CORPUS/'cases.tsv') if (i := l.split('\t', 1)[0]) in meta and meta[i]['set'] == 'nw']
        nw = [r for r in nw if split == 'all' or held(meta[r[0]]) == (split == 'held')]
        self.nw_context = [_context(r[2]) for r in nw]; self.nw_target = [r[4].lower() for r in nw]
        self.score(self.base)

    # model-dependent pieces --------------------------------------------------------------------
    def _parts(self, model: nsslm.Model):
        ctx_ids = [tuple(i for w in c if (i := model.context_id(w)) >= 0) for c in self.contexts_words]
        feats = model.features(ctx_ids)
        norm, unk = model.log_softmax_parts(feats)
        return feats, norm, unk

    def _logp(self, parts, model, case, mid):
        feats, norm, _ = parts
        ctx = self.case_ctx[case]
        out = np.full(len(case), -np.inf, np.float64)
        ok = mid >= 0
        if not ok.any(): return out
        pair = ctx[ok].astype(np.int64) * 40000 + mid[ok]
        uniq, inv = np.unique(pair, return_inverse=True)
        values = model.gather_log_probs(feats, norm, (uniq // 40000).astype(np.int64), (uniq % 40000).astype(np.int64))
        out[ok] = values[inv]
        return out

    def _first(self, parts, rows, model=None):
        model = model or self.base
        eps = parts[2][self.case_ctx[rows['case']]]
        lp = self._logp(parts, model, rows['case'], rows['mid'])
        model_word = np.maximum(eps + rows['lex'], lp)
        return np.where(rows['mid'] >= 0, model_word, eps + rows['out'])

    def _mix(self, language, uni, start):
        hi, lo = np.maximum(language, uni), np.minimum(language, uni)
        a = np.where(language >= uni, 1 - self.w, self.w)
        with np.errstate(divide='ignore', invalid='ignore', over='ignore'):
            mixed = hi + np.log(a + (1 - a) * np.exp(lo - hi))
        return np.where(start & np.isfinite(mixed), mixed, language)

    def _language(self, parts, rows, first):
        language = first + rows['rest'] if 'rest' in rows else first
        start = self.typed['start'][rows['case']].astype(bool) & (rows['split'] == 0)
        return self._mix(language, rows['uni'], start)

    def _typed_score(self, parts, model=None):
        model = model or self.base
        t = self.typed; eps = parts[2][self.case_ctx]
        lp = self._logp(parts, model, np.arange(self.n), t['mid'])
        word = np.where(t['mid'] >= 0, np.maximum(eps + t['lex'], lp), eps + t['out'])
        literal = np.where(t['tw'] == 1, word, eps + self.typed_const)
        return self._mix(literal, t['uni'], t['start'].astype(bool))

    # decisions -------------------------------------------------------------------------------
    def decide(self, model: nsslm.Model):
        parts = self._parts(model)
        rows = self.rows
        score = self._language(parts, rows, self._first(parts, rows, model)) - self.cw * rows['cost']
        typed = self._typed_score(parts, model)
        case = rows['case']
        info = self.info
        if info.get('frequency_rule'): raise SystemExit('the frequency rule is not replayed')
        n = self.n
        ci = np.nonzero(self.C)[0]
        order = ci[np.lexsort((-score[ci], case[ci]))]
        oc = case[order]
        first = np.r_[True, oc[1:] != oc[:-1]]
        second = np.r_[False, (oc[1:] == oc[:-1]) & first[:-1]]
        s1 = np.full(n, -np.inf); s2 = np.full(n, -np.inf); r1 = np.full(n, -1)
        s1[oc[first]] = score[order[first]]; r1[oc[first]] = order[first]; s2[oc[second]] = score[order[second]]
        single = order[rows['split'][order] == 0]
        sc = case[single]; sfirst = np.r_[True, sc[1:] != sc[:-1]] if len(sc) else np.zeros(0, bool)
        ns1 = np.full(n, -np.inf); nr1 = np.full(n, -1)
        ns1[sc[sfirst]] = score[single[sfirst]]; nr1[sc[sfirst]] = single[sfirst]
        has = r1 >= 0
        split1 = np.zeros(n, bool); split1[has] = rows['split'][r1[has]] == 1
        use_single = bool(info.get('split_rule')) & split1 & (s1 - typed <= info.get('split_margin', 3.0))
        best_row = np.where(use_single, nr1, r1)
        best_score = np.where(use_single, ns1, s1)
        with np.errstate(invalid="ignore"): lead = best_score - np.where(use_single, s1, s2)
        ok = best_row >= 0
        best_key = np.full(n, -1); best_allow = np.zeros(n, bool); best_ss = np.zeros(n, bool)
        best_key[ok] = rows['key'][best_row[ok]]; best_allow[ok] = rows['allow'][best_row[ok]] == 1
        if 'ss' in rows: best_ss[ok] = rows['ss'][best_row[ok]] == 1
        t = self.typed
        margin = np.where(t['tw'] == 1, 0.0, np.where(t['start'] == 1, self.margins[1], np.where(t['cap'] == 1, self.margins[2], self.margins[0])))
        if info.get('same_sound_rule'):
            margin = margin + np.where(ok & (t['tw'] == 0) & best_ss & (lead >= info['same_sound_gap']), info['same_sound_margin'], 0.0)
        commit = (best_key >= 0) & (best_score > typed - margin) & best_allow & (t['pres'] == 0)
        correction = np.where(commit, best_key, -1)
        rs = np.where(self.C, -np.inf, score)
        top = _segment_top(case, rs, 3) & ~self.C
        order = np.lexsort((-score[top], case[top]))
        sug = [[] for _ in range(self.n)]
        for c, k in zip(case[top][order], rows['key'][top][order]): sug[c].append(k)
        return correction, typed, sug

    def next_word(self, model: nsslm.Model) -> np.ndarray:
        """Next word in the top 3 with nothing typed (the prediction strip), per held/tune 'nw' row."""
        feats = model.features([tuple(i for w in c if (i := model.context_id(w)) >= 0) for c in self.nw_context])
        z = feats @ model.out_matrix.T + model.output_bias; z[:, :4] = -np.inf
        top = np.argpartition(-z, 3, 1)[:, :3]
        return np.array([t in {model.words[k] for k in row} for t, row in zip(self.nw_target, top)])

    def results(self, model: nsslm.Model) -> dict[str, dict]:
        correction, typed, sug = self.decide(model)
        out = {}
        for n, i in enumerate(self.ids):
            ranked = [self.keys[k] for k in sug[n]]
            if correction[n] >= 0:
                c = self.keys[correction[n]]
                out[i] = {'c': c, 's': [c] + [w for w in ranked if w != c][:2]}
            else:
                out[i] = {'c': None, 's': [self.words[n]] + ranked[:2]}
        return out

    def score(self, model: nsslm.Model) -> dict:
        """Mean accuracy over ACCURACY, minus 0.5 x the points any guardrail lost, minus 10 for each
        guardrail significantly worse than the shipped weights (paired McNemar p < 0.05, the
        performance tests' fail rule)."""
        res = self.results(model)
        metrics = E.metrics(self.meta)
        table, items = {}, {}
        for label in REPORT:
            if label not in metrics: continue
            ids, pred, up, _ = metrics[label]
            ids = [i for i in ids if i in res]
            if ids:
                items[label] = np.array([bool(pred(res[i], self.meta[i])) for i in ids])
                table[label] = 100 * items[label].mean()
        if self.nw_target:
            items['GUARD next word in top 3'] = self.next_word(model); table['GUARD next word in top 3'] = 100 * items['GUARD next word in top 3'].mean()
        acc = np.mean([table[k] for k in ACCURACY if k in table]); guard = np.mean([table[k] for k in GUARDS if k in table])
        if not hasattr(self, 'reference'): self.reference, self.reference_items = table, items
        worse, fails = 0.0, []
        for k, up in [(k, False) for k in GUARDS] + [(k, True) for k in GUARDS_UP]:
            if k not in table: continue
            new, ref = items[k], self.reference_items[k]
            gained, lost = int((new & ~ref).sum()), int((ref & ~new).sum())
            if not up: gained, lost = lost, gained
            worse += max(0.0, (lost - gained) * 100 / len(new))
            if k.startswith("GUARD") and lost > gained and E.mcnemar(gained, lost) < 0.05: fails.append(k)
        return {'score': acc - 0.5 * worse - 10 * len(fails), 'accuracy': acc, 'guard': guard, 'guard_worse': worse,
                'fails': fails, 'metrics': table, 'items': items, 'results': res}

    def agreement(self) -> float:
        """Share of cases where this rescoring commits what the C++ decoder committed (shipped weights)."""
        correction, _, _ = self.decide(self.base)
        return float(np.mean(correction == self.typed['c_cpp']))


def compare(a: dict, b: dict, names=('before', 'after')) -> str:
    lines = [f'| Metric | {names[0]} | {names[1]} | Δ |', '|---|---|---|---|']
    for k in REPORT:
        if k in a['metrics']:
            lines.append(f'| {k} | {a["metrics"][k]:.2f} | {b["metrics"][k]:.2f} | {b["metrics"][k] - a["metrics"][k]:+.2f} |')
    for k in ('score', 'accuracy', 'guard'):
        lines.append(f'| **{k}** | {a[k]:.3f} | {b[k]:.3f} | {b[k] - a[k]:+.3f} |')
    return '\n'.join(lines)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('models', nargs='*', default=[str(BASE)])
    ap.add_argument('--split', default='tune', choices=('tune', 'held', 'all'))
    ap.add_argument('--cache', default=str(CACHE))
    a = ap.parse_args()
    t = time.time(); bench = Bench(a.split, pathlib.Path(a.cache)); print(f'loaded {bench.n} {a.split} cases, {len(bench.rows["case"])} rows in {time.time() - t:.1f}s')
    t = time.time(); print(f'agreement with the C++ decoder (shipped weights): {100 * bench.agreement():.2f}% ({time.time() - t:.1f}s)')
    scores = []
    for path in a.models:
        t = time.time(); s = bench.score(nsslm.load(path)); scores.append(s)
        print(f'{path}: score {s["score"]:.3f} accuracy {s["accuracy"]:.2f} guard {s["guard"]:.2f} ({time.time() - t:.1f}s)')
    if len(scores) == 2: print(compare(*scores))
