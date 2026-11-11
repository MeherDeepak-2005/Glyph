import importlib.util,sys,tempfile,unittest
from pathlib import Path
import numpy as np
import torch
HERE=Path(__file__).resolve().parent;sys.path.insert(0,str(HERE))
import audit_dictionary as audit
import train_challengers as train
import evaluate_candidates as candidates

class ResearchTests(unittest.TestCase):
    def test_bottom_hash_sample_independent_of_input_order(self):
        first=[];second=[];rows=[('key'+str(i),i,['word',str(i)]) for i in range(100)]
        for k,i,w in rows:audit.sample_add(first,8,'source',k,i,w)
        for k,i,w in reversed(rows):audit.sample_add(second,8,'source',k,i,w)
        self.assertEqual(sorted(first),sorted(second))
    def test_coverage_counts_running_tokens_not_types(self):
        from collections import Counter
        r=audit.coverage(Counter({'common':99,'missing':1}),{'common'},{'common','missing'})
        self.assertEqual(r['coverage'],.99);self.assertEqual(r['lexicon_coverage'],1)
    def test_unknown_tail_is_normalized_and_excludes_known_words(self):
        v=train.Vocabulary.from_words(['<pad>','<unk>','<bos>','<eos>','known'])
        tail=train.tails(v,{'known':100,'rare':3,'other':1})
        self.assertNotIn('known',tail);self.assertAlmostEqual(sum(tail.values()),1)
        self.assertAlmostEqual(tail['rare']/tail['other'],2)
    def test_vocabulary_remap_preserves_every_shared_parameter(self):
        torch.manual_seed(7)
        oldv=train.Vocabulary.from_words(['<pad>','<unk>','<bos>','<eos>','keep','remove'])
        newv=train.Vocabulary.from_words(['<pad>','<unk>','<bos>','<eos>','new','keep'])
        m=train.build({'arch':'lstm','embed':4,'hidden':6,'proj':4,'cifg':True},len(oldv))
        remapped,count=train.remap({'arch':m.config(),'model':m.state_dict()},oldv,newv,{'new':5,'remove':3})
        self.assertEqual(count,5)
        for word in set(oldv.words)&set(newv.words):
            self.assertTrue(torch.equal(m.embedding.weight[oldv.index[word]],remapped.embedding.weight[newv.index[word]]))
            self.assertEqual(m.output_bias[oldv.index[word]],remapped.output_bias[newv.index[word]])
        self.assertTrue(torch.equal(m.w_recurrent[0],remapped.w_recurrent[0]))
    def test_subword_scores_include_complete_word_boundary_mass(self):
        class SP:
            def vocab_size(self):return 8
            def encode(self,text):return [4] if text=='context' else [5,6]
            def id_to_piece(self,i):return '▁next' if i==7 else 'x'
        class Model:
            def __call__(self,x):return torch.zeros(*x.shape,8),None
            def logits(self,f):return f
        case={'context':'context','candidates':['target']}
        actual=candidates.score_sp(Model(),SP(),case,torch.device('cpu'))[0]
        import math
        expected=2*math.log(1/8)+math.log(2/8) # EOS or next word boundary
        self.assertAlmostEqual(actual,expected,places=5)
if __name__=='__main__':unittest.main()
