import unittest

import numpy as np

from fit_prediction_caps import fit_caps


class SmallModel:
    # Columns are contexts. Words 4, 5, 6 rank in the top three in both.
    out_matrix = np.array([[0, 0]] * 4 + [[8, 7], [6, 8], [5, 6], [4.8, 2], [1, 3]], np.float32)
    output_bias = np.zeros(9, np.float32)

    def features(self, contexts):
        return np.eye(2, dtype=np.float32)[contexts]


class PredictionCapTests(unittest.TestCase):
    def test_projects_each_proposal_onto_tightest_observed_limit(self):
        model = SmallModel()
        proposed = np.array([0]*6 + [2, 2, 1], np.float32)
        got = fit_caps(model, proposed, [0, 1], margin=0.5)
        # At the boundary the implementation conservatively freezes increases.
        np.testing.assert_array_equal(got, [0]*8 + [1])
        scores = model.features([0, 1]) @ model.out_matrix.T
        np.testing.assert_array_equal(np.argsort(scores)[:, -3:], np.argsort(scores + got)[:, -3:])

    def test_retains_partial_shift_and_never_increases_unproposed_words(self):
        proposed = np.array([0]*7 + [2, 0], np.float32)
        got = fit_caps(SmallModel(), proposed, [0, 1], margin=0.05)
        np.testing.assert_allclose(got, [0]*7 + [0.15, 0], atol=1e-6)
