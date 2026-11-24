"""Build the frequency-tapered spelling candidate from the original NSS checkpoint."""
import argparse
import csv
from pathlib import Path

import numpy as np

import nsslm


LEDGER = Path(__file__).resolve().parents[2] / 'data/nss/unigram-v1/unigrams.tsv'


def bias_shift(word: str, probabilities: dict[str, float]) -> float:
    """Give longer and harder-to-spell words a larger prior below 100 tokens per million."""
    probability = probabilities.get(word, 0.0)
    rarity = max(0.0, 1 - probability / 0.0001)
    bare = word.replace("'", "")
    length = len(bare)
    adjacent = zip(bare, bare[1:])
    clusters = sum(a == b or (a in 'aeiou' and b in 'aeiou') for a, b in adjacent)
    cluster_bonus = 0.8 * min(clusters, 2) * min(max(length - 4, 0) / 3, 1)
    contraction_bonus = 0.0
    if "'" in word.strip("'") and bare not in probabilities:
        contraction_bonus = 3 * max(0.0, 1 - probability / 0.0002)
    length_bonus = 0.4 * max(0, length - 7)
    return (cluster_bonus + contraction_bonus + length_bonus) * rarity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.destination.resolve():
        parser.error('Choose a separate output file for the edited model.')
    with LEDGER.open(newline='') as stream:
        probabilities = {r['word']: float(r['estimated_probability'] or 0)
                         for r in csv.DictReader(stream, delimiter='\t')}
    model = nsslm.load(args.source)
    model.output_bias[4:] += np.array([bias_shift(w, probabilities) for w in model.words[4:]],
                                      dtype=np.float32)
    print(nsslm.save(model, args.destination))


if __name__ == '__main__':
    main()
