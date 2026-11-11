import unittest
from analyze_capture import analyze


def event(kind, time, **kwargs):
    return dict(schema=1, process='fixture', session=1, word=1, model='ngram', kind=kind, uptime=time, **kwargs)


class CaptureTests(unittest.TestCase):
    def test_automatic_outputs_are_not_training_labels(self):
        summary, labels = analyze([event('autocorrection', 1, text='teh', replacement='the'),
                                   event('commit', 2, text='the', evidence='automatic-unverified')])
        self.assertEqual(labels, [])
        self.assertEqual(summary['events']['autocorrection'], 1)

    def test_key_intervals_exclude_idle_and_other_sessions(self):
        events = [event('key', 1, text='a'), event('key', 1.1, text='b'),
                  event('key', 10, text='c'), event('session-end', 10.1), event('key', 10.2, text='d')]
        summary, _ = analyze(events)
        self.assertEqual(summary['active_seconds'], .1)
        self.assertEqual(summary['interval_by_key']['b']['median_ms'], 100)
        self.assertNotIn('c', summary['interval_by_key'])
        self.assertNotIn('d', summary['interval_by_key'])

    def test_dwell_pairs_by_touch_not_word(self):
        down = event('touch-down', 1, touchID='finger1', text='a')
        up = event('touch-up', 1.2, touchID='finger1'); up['word'] = 2
        summary, _ = analyze([down, up])
        self.assertEqual(summary['dwell_by_key']['a']['median_ms'], 200)

    def test_undo_links_back_to_original_word(self):
        key = event('key', 1, text='x')
        undo = event('undo', 2, text='y', replacement='x', evidence='explicit-autocorrect-undo', relatedWord=1)
        undo['word'] = 2
        _, labels = analyze([key, undo])
        self.assertEqual(labels[0]['word'], 1)
        self.assertEqual(labels[0]['events'], [key])

    def test_retracted_partial_completion_is_not_an_intent_label(self):
        _, labels = analyze([event('undo', 1, text='the', replacement='t', evidence='explicit-retraction')])
        self.assertEqual(labels, [])

    def test_explicit_completion_is_not_mislabeled_typo(self):
        _, labels = analyze([event('key', 1, text='t'),
                             event('suggestion-pick', 2, text='t', replacement='the', evidence='explicit-selection')])
        self.assertEqual(labels[0]['task'], 'completion')
        self.assertFalse(labels[0]['per_key_alignment_verified'])
        self.assertEqual(len(labels[0]['events']), 1)


if __name__ == '__main__':
    unittest.main()
