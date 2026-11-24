import unittest

from nss.vocab import SPECIALS, Vocabulary
from train_contraction_rows import contraction_stems


class ContractionRowsTests(unittest.TestCase):
    def test_irregular_stems_and_competing_dictionary_spellings(self):
        vocab = Vocabulary.from_words([*SPECIALS, 'do', 'will', 'we', 'it', 'cat',
                                       "don't", "won't", "we're", "it's", "cat's"])
        pairs = contraction_stems(vocab, {'were', 'its'})
        self.assertEqual({vocab.words[w]: vocab.words[s] for w, s in pairs.items()},
                         {"don't": "do", "won't": "will"})
