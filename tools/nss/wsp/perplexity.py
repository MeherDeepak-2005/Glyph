#!/usr/bin/env python3
"""Word perplexity of .nsslm models on the NSS test shards (what an edit costs the model as a language model).

    python3.11 perplexity.py model.nsslm [...] [--sentences 2000]

Sentences are <s> w1 ... wn </s> token ids (tools/nss/data/<source>.test.*.npy). Scored like the
runtime: every word position after <s>, </s> excluded, softmax with pad/<s>/</s> masked.
"""
import argparse, pathlib, sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import nsslm  # noqa: E402

DATA = HERE.parent/'data'


def sentences(source: str, count: int) -> list[np.ndarray]:
    tokens = np.load(DATA/f'{source}.test.tokens.npy', mmap_mode='r'); offsets = np.load(DATA/f'{source}.test.offsets.npy')
    pick = np.random.default_rng(0).choice(len(offsets) - 1, min(count, len(offsets) - 1), replace=False)
    return [np.asarray(tokens[offsets[i]:offsets[i + 1]]) for i in sorted(pick)]


def nll(model: nsslm.Model, sents: list[np.ndarray]) -> float:
    """Mean negative log-likelihood per word, all sentences stepped together."""
    b = len(sents); longest = max(len(s) for s in sents)
    h = np.zeros((b, model.projection.shape[0]), np.float32); c = np.zeros((b, model.hidden), np.float32)
    total, count = 0.0, 0
    for t in range(longest - 2):
        live = np.array([i for i, s in enumerate(sents) if len(s) - 2 > t])
        tokens = np.array([sents[i][t] for i in live])
        h2, c2 = model.step(tokens, h[live], c[live]); h[live], c[live] = h2, c2
        norm, _ = model.log_softmax_parts(h2)
        targets = np.array([sents[i][t + 1] for i in live])
        total -= float(model.gather_log_probs(h2, norm, np.arange(len(live)), targets).sum()); count += len(live)
    return total / count


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('models', nargs='+')
    ap.add_argument('--sentences', type=int, default=2000)
    a = ap.parse_args()
    sets = {s: sentences(s, a.sentences) for s in ('tatoeba', 'wikitext', 'masc')}
    print('| Model | ' + ' | '.join(f'{s} ppl' for s in sets) + ' |\n|---|' + '---|' * len(sets))
    for path in a.models:
        m = nsslm.load(path)
        print(f'| {pathlib.Path(path).name} | ' + ' | '.join(f'{np.exp(nll(m, v)):.1f}' for v in sets.values()) + ' |')
