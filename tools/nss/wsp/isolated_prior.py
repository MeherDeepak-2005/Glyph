"""Boost long, easily misspelled outputs whose immediate neighbors are absent from the lexicon."""
import argparse
import csv
from pathlib import Path
import string
import numpy as np
import nsslm

LEDGER = Path(__file__).resolve().parents[2] / 'data/nss/unigram-v1/unigrams.tsv'
ALPHABET = string.ascii_lowercase + "'"


def has_neighbor(word, lexicon):
    """Any other lexicon word reachable by one insertion, deletion, substitution or swap."""
    for i in range(len(word) + 1):
        left, right = word[:i], word[i:]
        if any(left + letter + right in lexicon for letter in ALPHABET):
            return True
        if right:
            tail = right[1:]
            if left + tail in lexicon:
                return True
            if any(left + letter + tail in lexicon for letter in ALPHABET if letter != right[0]):
                return True
            if len(right) >= 2 and right[0] != right[1] and left + right[1] + right[0] + right[2:] in lexicon:
                return True
    return False


def write_weights(model):
    with LEDGER.open(newline='') as stream:
        lexicon = {r['word'] for r in csv.DictReader(stream, delimiter='\t') if r['nss_emittable'] == '1'}
    for i, word in enumerate(model.words[4:], 4):
        letters = len(word.replace("'", ""))
        if letters > 7 and not has_neighbor(word, lexicon):
            model.output_bias[i] += np.float32(min(2.0, 0.4 * (letters - 7)))
    return model


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.destination.resolve():
        parser.error('Choose a separate output file for the edited model.')
    print(nsslm.save(write_weights(nsslm.load(args.source)), args.destination))
