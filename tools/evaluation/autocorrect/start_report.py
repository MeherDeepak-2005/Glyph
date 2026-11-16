#!/usr/bin/env python3
"""Sentence-start words: compare runs on the rows whose parsed left context is empty.

  start_report.py BASE RUN [RUN ...] [--split held|tune|all]

The sentence's first word gets its own decoding rule (nssStartUnigramWeight,
nssStartCommitMargin in Engine.hpp). This reports, on rows the decoder sees without context
words (contexts parsed as IOSBench.cpp does), misspellings fixed per set, contractions,
and the words that should stay as typed. The external lists and keep sets have no context
at all, so all their rows are here. Pairs are tested with exact McNemar against BASE.
"""
import argparse, json
import evaluate as ev
from context_report import context_words

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('base'); ap.add_argument('runs', nargs='+'); ap.add_argument('--split', default='held', choices=('held', 'tune', 'all'))
    a = ap.parse_args()
    meta, context = {}, {}
    for name in ('cases', 'ext-cases', 'keep-cases', 'contraction-cases', 'tenglish-cases'):
        if not (ev.CORPUS/f'{name}-meta.json').exists(): continue
        meta.update(json.loads((ev.CORPUS/f'{name}-meta.json').read_text()))
        for line in (ev.CORPUS/f'{name}.tsv').read_text().splitlines():
            p = line.split('\t')
            if len(p) >= 5 and p[1] == 'ac': context[p[0]] = context_words(p[2] + ' ')
    keep = lambda i, m: i in context and not context[i] and (a.split == 'all' or m['set'] in ('hard', 'apos') or ev.half(m) == a.split)
    start = {i: m for i, m in meta.items() if keep(i, m)}
    names = [a.base, *a.runs]
    rows = {n: ev.load(ev.RESULTS/f'{n}.jsonl')[0] for n in names}
    fixed = lambda r, m: ev.commit(r, m) == m['target']
    changed = lambda r, m: ev.commit(r, m) != ev.norm(m['typed'])
    top3 = lambda r, m: fixed(r, m) or m['target'] in ev.slots(r, m)
    metrics = [('ECPS misspellings fixed', ['ecps'], fixed, True), ('Synthetic typos fixed', ['syn'], fixed, True),
               ('Real-word errors fixed', ['realword'], fixed, True), ('Contractions restored', ['contraction', 'apos'], fixed, True),
               ('Contractions in top 3', ['contraction', 'apos'], top3, True),
               ('Birkbeck fixed', ['ext_birkbeck'], fixed, True), ('Holbrook fixed', ['ext_holbrook'], fixed, True),
               ('Aspell fixed', ['ext_aspell'], fixed, True), ('Wikipedia fixed', ['ext_wikipedia'], fixed, True),
               ('GUARD correct words changed', ['ecps_ok', 'clean'], changed, False), ('GUARD hard valid words changed', ['hard'], changed, False),
               ('GUARD unknown names changed', ['keep_name'], changed, False), ('GUARD rare dictionary words changed', ['keep_word'], changed, False),
               ('GUARD unknown slang changed', ['keep_slang'], changed, False), ('GUARD Tenglish words changed', ['keep_tenglish'], changed, False)]
    print(f'sentence-start rows, split={a.split}; reference = {a.base}\n')
    print(f'{"metric":36}{"n":>6}' + ''.join(f'{n[:12]:>13}' for n in names) + ''.join(f'{"vs " + n[:12]:>20}' for n in a.runs))
    for label, sets, pred, up in metrics:
        ids = [i for i, m in start.items() if m['set'] in sets and all(i in rows[n] for n in names)]
        if not ids: continue
        val = {n: [bool(pred(rows[n][i], start[i])) for i in ids] for n in names}
        cells = []
        for n in a.runs:
            g = sum(x and not y for x, y in zip(val[n], val[a.base])); l = sum(y and not x for x, y in zip(val[n], val[a.base]))
            p = ev.mcnemar(g, l); worse = (g < l) if up else (g > l)
            cells.append(f'{g:>6}/{l:<5}{p:7.1e}{"!" if worse and p < .05 else "*" if p < .05 else " "}')
        print(f'{label:36}{len(ids):>6}' + ''.join(f'{100 * sum(val[n]) / len(ids):>12.2f}%' for n in names) + ''.join(cells))
    print('\n* better with p < 0.05; ! worse with p < 0.05')

if __name__ == '__main__':
    main()
