#!/usr/bin/env python3
"""Turn a dump.py JSONL file into the compact arrays fasteval.py reads (cache/<name>.npz).

    python3.11 cache_build.py cache/base.jsonl
"""
import json, pathlib, sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]/'tools/evaluation/autocorrect'))
import evaluate as E  # noqa: E402
import performance_tests as P  # noqa: E402

ROW = ('key', 'cost', 'lang', 'allow', 'mid', 'lex', 'out', 'uni', 'split', 'ss')


def build(path: pathlib.Path) -> pathlib.Path:
    meta = P.meta()
    cases, info = [], None
    for line in open(path):
        r = json.loads(line)
        if r.get('kind') == 'wsp': info = r
        if 'id' in r and 'C' in r and r['id'] in meta: cases.append(r)
    keys, key_ids = [], {}
    def key_id(k):
        if k not in key_ids: key_ids[k] = len(keys); keys.append(k)
        return key_ids[k]
    contexts, ctx_ids = [], {}
    case_ctx, flat = [], {name: [] for name in ('case', 'kind') + ROW}
    typed = {name: [] for name in ('key', 'word', 'tw', 'lit', 'pres', 'mid', 'lex', 'out', 'uni', 'start', 'cap', 'c', 'c_cpp')}
    for n, r in enumerate(cases):
        ctx = tuple(r['ctx'])
        if ctx not in ctx_ids: ctx_ids[ctx] = len(contexts); contexts.append(ctx)
        case_ctx.append(ctx_ids[ctx])
        word = r['w']
        cap = bool(ctx) and word[:1].isupper() and word[:1].isascii() and not all(ch.isupper() or not ch.isalpha() for ch in word)
        typed['key'].append(key_id(r['t'])); typed['word'].append(word); typed['tw'].append(r['tw']); typed['lit'].append(r['lit'])
        typed['pres'].append(r['pres']); typed['start'].append(not ctx); typed['cap'].append(cap)
        for name, v in zip(('mid', 'lex', 'out', 'uni'), r['tc'][:4]): typed[name].append(v)
        typed['c_cpp'].append(key_id(r['c']) if r.get('c') else -1)
        typed['c'].append(r['s'])
        for kind, rows in ((0, r['C']), (1, r['R'])):
            for row in rows:
                flat['case'].append(n); flat['kind'].append(kind)
                flat['key'].append(key_id(row[0]))
                for name, v in zip(ROW[1:], list(row[1:]) + [0] * (len(ROW) - len(row))): flat[name].append(v)
    out = path.with_suffix('.npz')
    arrays = {f'row_{k}': np.array(v, dtype=np.float32 if k in ('cost', 'lang', 'lex', 'out', 'uni') else np.int32) for k, v in flat.items()}
    for k in ('tw', 'pres', 'mid', 'start', 'cap', 'c_cpp', 'key'): arrays[f'typed_{k}'] = np.array(typed[k], np.int32)
    for k in ('lit', 'lex', 'out', 'uni'): arrays[f'typed_{k}'] = np.array(typed[k], np.float32)
    ctx_flat = [w for c in contexts for w in c]
    np.savez(out, **arrays, case_ctx=np.array(case_ctx, np.int32),
             ctx_len=np.array([len(c) for c in contexts], np.int32), ctx_words=np.array(ctx_flat, dtype=object),
             keys=np.array(keys, dtype=object), ids=np.array([r['id'] for r in cases], dtype=object),
             words=np.array(typed['word'], dtype=object),
             suggestions=np.array([json.dumps(s) for s in typed['c']], dtype=object),
             info=np.array(json.dumps(info), dtype=object))
    print(f'{out}: {len(cases)} cases, {len(contexts)} contexts, {len(flat["case"])} rows')
    return out


if __name__ == '__main__':
    build(pathlib.Path(sys.argv[1]))
