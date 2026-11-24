import unittest

import torch

from nss.confusions import spelling_loss, spelling_neighbors
from nss.vocab import SPECIALS, Vocabulary


class SpellingTrainingTests(unittest.TestCase):
    def test_neighbors_are_symmetric_and_exclude_identity_and_specials(self):
        words = ["its", "it's", "hit", "hot", "the", "teh", "planet"]
        vocab = Vocabulary.from_words([*SPECIALS, *words])
        table = spelling_neighbors(vocab)
        for first, second in [("its", "it's"), ("hit", "hot"), ("the", "teh")]:
            a, b = vocab.index[first], vocab.index[second]
            self.assertIn(b, table[a].tolist())
            self.assertIn(a, table[b].tolist())
        self.assertTrue((table[:4] == -1).all())
        self.assertTrue((table[vocab.index["planet"]] == -1).all())
        for idx, row in enumerate(table.tolist()):
            self.assertNotIn(idx, row)

    def test_only_contextual_confusable_rows_contribute(self):
        vocab = Vocabulary.from_words([*SPECIALS, 'its', "it's", 'planet'])
        table = spelling_neighbors(vocab)
        features = torch.ones(3, 1, requires_grad=True)
        weight = torch.arange(len(vocab), dtype=torch.float32)[:, None]
        bias = torch.zeros(len(vocab))
        targets = torch.tensor([4, 5, 6])
        loss = spelling_loss(features, weight, bias, targets, torch.tensor([True, False, True]), table)
        torch.testing.assert_close(loss, torch.nn.functional.softplus(torch.tensor(1.)))
        loss.backward()
        self.assertGreater(features.grad[0].item(), 0)
        torch.testing.assert_close(features.grad[1:], torch.zeros(2, 1))
        zeros = spelling_loss(features, weight, bias, targets, torch.zeros(3, dtype=torch.bool), table)
        self.assertEqual(zeros.item(), 0)
