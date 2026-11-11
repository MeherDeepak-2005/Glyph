import hashlib,json,struct,tempfile,unittest
from pathlib import Path
from tools.vocabulary import build_modern as modern
class ModernTests(unittest.TestCase):
 def test_catalog_and_exports(self):
  rows=modern.catalog();self.assertEqual(len(rows),400);modern.export_legacy(check=True)
  self.assertFalse(rows["pookie"]["autocorrect"])
  for w in ("ate","cooked","based"):self.assertTrue(rows[w]["autocorrect"])
 def test_rebuild_deterministic_and_bound(self):
  source=modern.ROOT/"keyboard/langdata.bin"
  with tempfile.TemporaryDirectory() as d:
   a=Path(d)/"a.bin";b=Path(d)/"b.bin"
   modern.build(source,a);modern.build(source,b)
   self.assertEqual(a.read_bytes(),b.read_bytes());self.assertEqual(a.read_bytes(),source.read_bytes())
   blob=a.with_suffix(".kbmodern").read_bytes()
   magic,version,words,policies,contexts,digest=struct.unpack_from("<8s4I32s",blob)
   self.assertEqual((magic,version),(b"KBMODERN",1));self.assertEqual(digest,hashlib.sha256(a.read_bytes()).digest())
   self.assertEqual(len(blob),88+8*policies+16*contexts)
   self.assertEqual(blob[-32:],hashlib.sha256(blob[:-32]).digest())
if __name__=="__main__":unittest.main()
