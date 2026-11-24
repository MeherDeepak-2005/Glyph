"""Fit output-bias limits on train-split contexts to preserve the shipped model's top three.

    cd tools/nss
    python3.11 fit_prediction_caps.py ../../keyboard/nss-english.nsslm artifacts/wsp-isolated.nsslm /tmp/capped.nsslm

For a proposed positive bias change, every context where the word is outside
the top three supplies an upper bound on the increase. Project the proposed
bias onto all those bounds and retain a margin for unseen contexts. Sampling
uses only the training shards and includes the empty context.
"""
import argparse
import json
from pathlib import Path

import numpy as np

from nss import DATA
from nss.data import Shard
from nss.vocab import Vocabulary
from wsp import nsslm


def sample_contexts(data, positions, seed):
    rng = np.random.default_rng(seed)
    contexts = {()}
    for source in ('tatoeba', 'wikitext'):
        shard = Shard.load(data, source, 'train')
        drawn = rng.integers(0, shard.size, size=positions)
        lengths = rng.integers(1, 9, size=positions)
        starts = shard.offsets[np.searchsorted(shard.offsets, drawn, side='right') - 1]
        for pos, length, start in zip(drawn, lengths, starts):
            if shard.tokens[pos] >= 4:
                contexts.add(tuple(map(int, shard.tokens[max(start + 1, pos - length):pos])))
    return sorted(contexts)


def fit_caps(model, proposed, contexts, margin):
    candidate_ids = np.flatnonzero(proposed > 0)
    caps = proposed[candidate_ids].copy()
    for start in range(0, len(contexts), 256):
        features = model.features(contexts[start:start + 256])
        scores = features @ model.out_matrix.T + model.output_bias
        scores[:, :4] = -np.inf
        selected = scores[:, candidate_ids].copy()
        scores.partition(-3, axis=1)
        gap = scores[:, -3, None] - selected
        # A word above the boundary already occupies a slot. Its increase cannot evict another word.
        gap[gap < 0] = np.inf
        caps = np.minimum(caps, np.maximum(0, gap.min(axis=0) - margin))
    offsets = np.zeros_like(proposed)
    offsets[candidate_ids] = caps
    return offsets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('proposal', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--data', type=Path, default=DATA)
    parser.add_argument('--positions', type=int, default=65536, help='sampled train positions per source')
    parser.add_argument('--margin', type=float, default=0.75, help='retained gap below third place, in logits')
    parser.add_argument('--seed', type=int, default=1122)
    args = parser.parse_args()
    if args.positions < 1 or not np.isfinite(args.margin) or args.margin < 0:
        parser.error('positions must be positive and margin must be finite and nonnegative')
    if args.destination.resolve() in {args.baseline.resolve(), args.proposal.resolve()}:
        parser.error('Choose an output file separate from both inputs.')
    model, teacher = nsslm.load(args.baseline), nsslm.load(args.proposal)
    vocab = Vocabulary.load()
    manifest = json.loads((args.data/'corpus.json').read_text())
    if model.words != vocab.words or teacher.words != model.words or manifest['vocabulary_sha256'] != vocab.sha256:
        parser.error('Both models and the training shards must use the same vocabulary.')
    if (model.raw_header != teacher.raw_header or
            any(not np.array_equal(getattr(model, attr), getattr(teacher, attr))
                for attr in ('embedding', 'output', 'projection', 'gates', 'gate_bias'))):
        parser.error('Proposal must differ from baseline only in its output biases.')
    proposed = teacher.output_bias - model.output_bias
    if np.any(proposed < 0) or np.any(proposed[:4] != 0) or not np.isfinite(proposed).all():
        parser.error('The proposal may only increase ordinary word biases.')
    contexts = sample_contexts(args.data, args.positions, args.seed)
    offsets = fit_caps(model, proposed, contexts, args.margin)
    model.output_bias += offsets
    digest = nsslm.save(model, args.destination)
    print(f'{len(contexts)} training contexts, {np.count_nonzero(offsets)} of '
          f'{np.count_nonzero(proposed)} proposed increases retained. SHA-256 {digest}')


if __name__ == '__main__':
    main()
