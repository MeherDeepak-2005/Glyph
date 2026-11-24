"""Fit contraction embeddings to labeled next-word contexts from the NSS training split.

    cd tools/nss
    python3.11 train_contraction_rows.py ../../keyboard/nss-english.nsslm /tmp/context.nsslm

The response for a contraction in its own observed context is +2 logit units,
partially offsetting an omitted apostrophe. The desired shift is zero in contexts
of its stem and in random contexts. Ridge regression against the shipped model's
hidden features fits a separate direction for each word. Centering features at the
beginning-of-sentence state preserves the no-context logits before requantization.
"""
import argparse
import json
from pathlib import Path

import numpy as np

from nss import DATA
from nss.data import Shard
from nss.lexicon import Lexicon
from nss.vocab import Vocabulary
from wsp import nsslm


def contraction_stems(vocab, lexicon):
    stems = {}
    for idx, word in enumerate(vocab.words):
        stem, mark, suffix = word.partition("'")
        if not mark or word.replace("'", "") in lexicon:
            continue
        if suffix == 't' and stem.endswith('n'):
            stem = {'can': 'can', 'won': 'will', 'shan': 'shall'}.get(stem, stem[:-1])
        elif suffix == 's':
            if stem not in {'he', 'she', 'it', 'what', 'that', 'who', 'where', 'how', 'there', 'here', 'let'}:
                continue
        elif suffix not in {'re', 've', 'll', 'm', 'd'}:
            continue
        if stem in vocab.index and vocab.index[stem] >= 4:
            stems[idx] = vocab.index[stem]
    return stems


def training_contexts(data, words, rng):
    """Sample training token positions. Clip each preceding context to its own sentence."""
    contexts = {w: set() for w in words}
    background = set()
    for source in ('tatoeba', 'wikitext'):
        shard = Shard.load(data, source, 'train')
        positions = rng.integers(0, shard.size, size=1_000_000)
        tokens = shard.tokens[positions]
        def context(pos):
            start = shard.offsets[np.searchsorted(shard.offsets, pos, side='right') - 1]
            return tuple(map(int, shard.tokens[max(start + 1, pos - 8):pos]))
        for word in words:
            selected = positions[tokens == word][:512]
            contexts[word].update(context(p) for p in selected)
        background.update(context(p) for p in positions[tokens >= 4][:1024])
    return contexts, background


def fit(model, vocab, data, strength):
    stems = contraction_stems(vocab, Lexicon.load())
    contexts, background = training_contexts(data, set(stems) | set(stems.values()), np.random.default_rng(1122))
    all_contexts = sorted(set.union(background, *contexts.values()))
    lookup = {ctx: i for i, ctx in enumerate(all_contexts)}
    features = np.concatenate([model.features(all_contexts[i:i+256]) for i in range(0, len(all_contexts), 256)])
    # Compute the original prediction strip's third logit for each training context.
    third = []
    for i in range(0, len(features), 256):
        scores = features[i:i+256] @ model.out_matrix[4:].T + model.output_bias[4:]
        third.extend(np.partition(scores, -3, axis=1)[:, -3])
    third = np.asarray(third)
    root = model.features([()])[0]
    bg = [lookup[c] for c in sorted(background)]
    count = 0
    for word, stem in stems.items():
        pos = [lookup[c] for c in sorted(contexts[word]) if c]
        neg = [lookup[c] for c in sorted(contexts[stem]) if c]
        if len(pos) < 24 or not neg:
            continue
        ids = np.array(pos + neg + bg)
        x = (features[ids] - root).astype(np.float64)
        target = np.zeros(len(ids))
        target[:len(pos)] = 2
        weight = np.repeat([1/len(pos), 1/len(neg), 1/len(bg)], [len(pos), len(neg), len(bg)])
        # Near the top-three boundary, penalize changing the original prediction.
        margin = features[ids] @ model.out_matrix[word] + model.output_bias[word] - third[ids]
        protection = 8 * (abs(margin) < 2)
        gram = x.T @ ((weight * (1 + protection))[:, None] * x)
        gram.flat[::len(gram)+1] += 0.05
        delta = strength * np.linalg.solve(gram, x.T @ (weight * target))
        model.embedding[word] += delta.astype(np.float32)
        model.output_bias[word] -= np.dot(delta, root)
        count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--data', type=Path, default=DATA)
    parser.add_argument('--strength', type=float, default=1)
    args = parser.parse_args()
    if args.destination.resolve() == args.source.resolve():
        parser.error('Choose a separate destination for the trained model.')
    if not np.isfinite(args.strength) or args.strength <= 0:
        parser.error('strength must be finite and positive')
    vocab = Vocabulary.load()
    model = nsslm.load(args.source)
    corpus = json.loads((args.data/'corpus.json').read_text())
    if model.words != vocab.words or corpus['vocabulary_sha256'] != vocab.sha256:
        parser.error('The model, corpus and training vocabulary must match.')
    if model.output is not None:
        parser.error('This recipe requires tied embeddings.')
    count = fit(model, vocab, args.data, args.strength)
    print(f'Trained {count} contraction rows. SHA-256 {nsslm.save(model, args.destination)}')


if __name__ == '__main__':
    main()
