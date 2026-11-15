import unittest

import numpy as np

from nss.data import Shard, truncated, truncated_shard
from nss.vocab import BOS, EOS


def sentences(sequence: np.ndarray) -> list[list[int]]:
    starts = np.flatnonzero(sequence == BOS)
    return [sequence[a:b].tolist() for a, b in zip(starts, np.append(starts[1:], len(sequence)))]


class TruncationTests(unittest.TestCase):
    def setUp(self):
        rng = np.random.default_rng(7)
        parts = []
        for _ in range(500):
            parts.append([BOS, *rng.integers(4, 100, int(rng.integers(1, 12))).tolist(), EOS])
        self.sequence = np.asarray([token for part in parts for token in part], np.uint16)

    def test_probability_zero_returns_the_sequence(self):
        self.assertIs(truncated(self.sequence, 0.0, np.random.default_rng(0)), self.sequence)

    def test_every_sentence_stays_a_suffix_with_at_least_one_word(self):
        before = sentences(self.sequence)
        after = sentences(truncated(self.sequence, 1.0, np.random.default_rng(0)))
        self.assertEqual(len(before), len(after))
        for whole, cut in zip(before, after):
            self.assertEqual((cut[0], cut[-1]), (BOS, EOS))
            self.assertGreaterEqual(len(cut), 3)
            self.assertEqual(whole[len(whole) - len(cut) + 1:], cut[1:])
            # one-word sentences have nothing to drop; longer ones always lose a word
            self.assertEqual(len(cut) < len(whole), len(whole) > 3)

    def test_the_share_of_cut_sentences_follows_the_probability(self):
        before = sentences(self.sequence)
        after = sentences(truncated(self.sequence, 0.3, np.random.default_rng(1)))
        eligible = sum(len(whole) > 3 for whole in before)
        cut = sum(len(a) < len(b) for a, b in zip(after, before))
        self.assertAlmostEqual(cut / eligible, 0.3, delta=0.07)

    def test_truncated_shard_keeps_sentence_offsets(self):
        offsets = np.append(np.flatnonzero(self.sequence == BOS), len(self.sequence))
        shard = truncated_shard(Shard(self.sequence, offsets))
        self.assertEqual(shard.sentences, len(offsets) - 1)
        self.assertTrue((shard.tokens[shard.offsets[:-1]] == BOS).all())
        self.assertTrue((shard.tokens[shard.offsets[1:] - 1] == EOS).all())


if __name__ == "__main__":
    unittest.main()
