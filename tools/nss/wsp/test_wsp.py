#!/usr/bin/env python3
"""Fast checks for the weight-programming tools and the edited model (about 30 s, no decoder run).

    cd tools/nss/wsp && python3.11 -m unittest test_wsp -v

Needs cache/base.npz (python3 dump.py, then python3.11 cache_build.py cache/base.jsonl).
"""
import hashlib, json, pathlib, sys, tempfile, unittest

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fasteval as F  # noqa: E402
import nss_weights as W  # noqa: E402
import nsslm  # noqa: E402

FINAL = HERE.parent/'artifacts'/'wsp-length-apostrophe.nsslm'
FINAL_PARAMS = dict(gamma=0.3, center=5, beta=2)


class Format(unittest.TestCase):
    def test_round_trip_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as d:
            sha = nsslm.save(nsslm.load(F.BASE), pathlib.Path(d)/'m.nsslm')
        self.assertEqual(sha, hashlib.sha256(F.BASE.read_bytes()).hexdigest())

    def test_numpy_forward_matches_cpp_goldens(self):
        m = nsslm.load(F.BASE)
        goldens = json.loads(F.BASE.with_suffix('.goldens.json').read_text())
        cases = goldens['cases'][:6]
        feats = m.features([tuple(c['ids']) for c in cases])
        norm, unk = m.log_softmax_parts(feats)
        np.testing.assert_allclose(unk, [c['unk'] for c in cases], atol=2e-3)
        ids = np.array([m.index['the']] * len(cases))
        np.testing.assert_allclose(m.gather_log_probs(feats, norm, np.arange(len(cases)), ids), [c['scores']['the'] for c in cases], atol=2e-3)

    def test_final_model_is_the_program_output(self):
        with tempfile.TemporaryDirectory() as d:
            sha = nsslm.save(W.write_weights(nsslm.load(F.BASE), **FINAL_PARAMS), pathlib.Path(d)/'m.nsslm')
        self.assertEqual(sha, hashlib.sha256(FINAL.read_bytes()).hexdigest())


class Edits(unittest.TestCase):
    def test_temperature_scales_logits_and_keeps_recurrence(self):
        a, b = nsslm.load(F.BASE), nsslm.load(F.BASE)
        W.temperature(b, 0.8)
        ctx = [(a.index['i'], a.index['am'], a.index['going'])]
        fa, fb = a.features(ctx), b.features(ctx)
        np.testing.assert_allclose(fb, 0.8 * fa, rtol=1e-4, atol=1e-5)
        la = fa @ a.embedding.T + a.output_bias; lb = fb @ b.embedding.T + b.output_bias
        np.testing.assert_allclose(lb, 0.8 * la, rtol=1e-3, atol=1e-3)

    def test_length_and_apostrophe_priors_touch_only_the_output_bias(self):
        a, b = nsslm.load(F.BASE), W.write_weights(nsslm.load(F.BASE), **FINAL_PARAMS)
        for name in ('embedding', 'gates', 'gate_bias', 'projection'):
            np.testing.assert_array_equal(getattr(a, name), getattr(b, name))
        d = b.output_bias - a.output_bias
        self.assertAlmostEqual(float(d[b.index['abandoned']]), 0.3 * (9 - 5), places=5)
        self.assertAlmostEqual(float(d[b.index["don't"]]), 0.3 * (4 - 5) + 2, places=5)
        self.assertEqual(float(d[nsslm.UNK]), 0.0)


class Benchmark(unittest.TestCase):
    """Rules off, tune half: the fixed-candidate rescoring against the decoder's own run."""

    @classmethod
    def setUpClass(cls):
        cls.bench = F.Bench('tune')

    def test_rescoring_reproduces_the_cpp_decoder(self):
        self.assertGreater(self.bench.agreement(), 0.999)

    def test_edited_weights_beat_the_shipped_weights(self):
        base = self.bench.score(nsslm.load(F.BASE)); final = self.bench.score(nsslm.load(FINAL))
        self.assertGreater(final['accuracy'], base['accuracy'] + 4)
        self.assertGreater(final['metrics']['ECPS real misspellings fixed'], base['metrics']['ECPS real misspellings fixed'] + 3)
        # its known cost: the prediction strip (docs/nss-weight-programming.md), now a guardrail
        self.assertEqual(final['fails'], ['GUARD next word in top 3'])


class RulesOn(unittest.TestCase):
    """The product rules as the app ships them (cache/rules.npz, dump.py --rules on)."""

    def test_rescoring_reproduces_the_cpp_decoder_with_rules(self):
        cache = HERE/'cache'/'rules.npz'
        if not cache.exists(): self.skipTest('no rules-on cache')
        self.assertGreater(F.Bench('tune', cache).agreement(), 0.999)


if __name__ == '__main__':
    unittest.main()
