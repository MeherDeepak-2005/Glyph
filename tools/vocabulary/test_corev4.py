"""Wide-ID serialization and CoreV4 admission regressions."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_language_data as builder
from verify_language_data import Pack

class CoreV4Tests(unittest.TestCase):
    def test_sorted_union_keeps_existing_frequencies(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            data = b'aaa\ncaf\xc3\xa9\ncant\nz\n'
            (root/'english-all.txt').write_bytes(data)
            manifest = root/'manifest.json'
            manifest.write_text(json.dumps({'exports': [{'path':'english-all.txt','forms':4,
                'sha256':hashlib.sha256(data).hexdigest()}]}))
            with patch.object(builder, 'COREV4_MANIFEST', manifest):
                vocab = builder.merge_corev4([('the',100),('z',1)])
                self.assertEqual(vocab, [('the',100),('aaa',1),('café',1),('z',1)])
                (root/'english-all.txt').write_bytes(data+b'tampered\n')
                with self.assertRaises(SystemExit):
                    builder.merge_corev4([])

    def test_writer_keeps_terminal_ids_above_65535(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)/'wide.bin'
            vocab = [(f'w{i:05}',1) for i in range(65538)]
            builder.write_bin(vocab, output=out)
            pack=Pack(out)
            self.assertEqual(pack.version, 7)
            self.assertEqual(pack.vocabulary()[0][65537], b'w65537')
            self.assertTrue(any(row[3]==65537 for row in pack.trie()))
            previous=out.read_bytes()
            with self.assertRaises(ValueError):
                builder.write_bin(vocab,output=out,max_bytes=1)
            self.assertEqual(out.read_bytes(),previous)
