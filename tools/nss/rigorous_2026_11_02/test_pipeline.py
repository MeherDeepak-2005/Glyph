import contextlib,io,json,sqlite3,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import torch
import corpus,train

class ContractTests(unittest.TestCase):
    def test_holdouts_win_cross_source_duplicates(self):
        rows={'soda':[('train-s','shared sentence'),('valid-s','held sentence'),('train-u','unique training sentence')],
              'tatoeba':[('train-t','held sentence'),('test-t','shared sentence')],
              'wikitext':[('train-w','unique training sentence'),('valid-w','validation only')]}
        with tempfile.TemporaryDirectory() as td:
            out=Path(td)/'out';fake=Path(td)/'input';fake.write_text('fixture')
            def docs(source,modern):yield from rows[source]
            def split(key):return 'valid' if key.startswith('valid') else 'test' if key.startswith('test') else 'train'
            with patch.object(corpus,'documents',docs),patch.object(corpus,'split_of',split),patch.object(corpus.sources,'masc_heldout',lambda:iter([])),patch.object(corpus.sources,'SODA',[fake]),patch.object(corpus.sources,'TATOEBA',fake),patch.object(corpus.sources,'WIKITEXT',[fake]),patch.object(corpus,'ROOT',Path(td)),contextlib.redirect_stdout(io.StringIO()):corpus.prepare(out,[])
            db=sqlite3.connect(out/'corpus.sqlite');data=db.execute('SELECT split,text FROM sentences').fetchall()
            self.assertNotIn(('train','held sentence'),data);self.assertNotIn(('train','shared sentence'),data)
            self.assertEqual(sum(t=='unique training sentence' for _,t in data),1)
            self.assertEqual(json.loads((out/'corpus.json').read_text())['training_tokens'],3)
    def test_chunked_loss_gradients_match_dense_softmax(self):
        import copy
        torch.manual_seed(71);m=train.build({'arch':'lstm','embed':8,'hidden':12,'proj':8,'cifg':True},16);other=copy.deepcopy(m);seqs=[[2,8,9,3],[2,6,3]]
        loss,n=train.loss_on(m,seqs);loss.backward();x,y=train.tensors(seqs);h,_=other(x);mask=y!=0;dense=torch.nn.functional.cross_entropy(other.logits(h[mask]),y[mask]);dense.backward()
        self.assertAlmostEqual(float(loss.detach()),float(dense.detach()),places=6)
        for (name,p),(oname,q) in zip(m.named_parameters(),other.named_parameters()):self.assertLess(float((p.grad-q.grad).abs().max()),2e-6,name)
    def test_large_plan_exposure_and_complete_batching(self):
        import large_data
        with tempfile.TemporaryDirectory() as td,contextlib.redirect_stdout(io.StringIO()):
            p=Path(td);v=p/'vocab.tsv';v.write_text('id\tword\n0\t<pad>\n1\t<unk>\n2\t<bos>\n3\t<eos>\n4\tone\n5\ttwo\n6\tthree\n');(p/'corpus.json').write_text(json.dumps({'sources':['soda','tatoeba','wikitext']}))
            db=sqlite3.connect(p/'corpus.sqlite');db.execute('CREATE TABLE sentences(source,split,text,words,hash)')
            for source in ['soda','tatoeba','wikitext']:
                for i in range(12):db.execute('INSERT INTO sentences VALUES(?,?,?,?,?)',(source,'train','one two three',3,bytes([i])))
            db.commit();db.close();large_data.encode(p/'corpus.sqlite',v,p/'shards');large_data.plan(p/'shards',p/'plan.npz',300,731);rows=large_data.Rows(p/'plan.npz',train.Vocabulary.load(v));batches=rows.batches(64)
            indices=[int(i) for bi in range(len(batches)) for i in batches[bi]]
            self.assertEqual(sorted(indices),list(range(len(rows))));self.assertGreaterEqual(rows.total_words,300);self.assertLess(rows.total_words,309)
            self.assertTrue(all(rows.encoded[i].tolist()==[2,4,5,6,3] for i in indices));self.assertFalse(json.loads((p/'plan.manifest.json').read_text())['without_replacement'])
    def test_autoregression_and_padding(self):
        x,y=train.tensors([[2,8,9,3],[2,6,3]])
        self.assertEqual(x.tolist(),[[2,8,9],[2,6,0]]);self.assertEqual(y.tolist(),[[8,9,3],[6,3,0]])
        torch.manual_seed(7);m=train.build({'arch':'gru','embed':8,'hidden':12,'proj':8},16)
        loss,n=train.loss_on(m,[[2,8,9,3],[2,6,3]])
        one,n1=train.loss_on(m,[[2,8,9,3]]);two,n2=train.loss_on(m,[[2,6,3]])
        self.assertAlmostEqual(float(loss.detach()),float((one*n1+two*n2).detach())/n,places=6)
    def test_causality_reset_and_streaming(self):
        configs=[{'arch':'lstm','embed':8,'hidden':12,'proj':8,'cifg':True},{'arch':'lstm','embed':8,'hidden':12,'proj':8,'cifg':False},{'arch':'gru','embed':8,'hidden':12,'proj':8},{'arch':'transformer','embed':8,'dim':16,'layers':2,'heads':2,'ffn':24,'window':4}]
        for cfg in configs:
            torch.manual_seed(3);m=train.build(cfg,16);m.eval();a=torch.tensor([[2,4,5,6,7,8,9]]);b=a.clone();b[0,4:]=10
            ha,_=m(a);hb,_=m(b);self.assertLess(float((ha[:,:4]-hb[:,:4]).detach().abs().max()),1e-6)
            prefix=torch.tensor([[2,10,11,3]]);_,state=m(prefix);reset,_=m(a,state);self.assertLess(float((ha-reset).detach().abs().max()),2e-6)
            state=None;parts=[]
            for token in a.unbind(1):h,state=m.step(token,state);parts.append(h)
            self.assertLess(float((ha-torch.stack(parts,1)).detach().abs().max()),2e-6)
if __name__=='__main__':torch.set_num_threads(2);unittest.main()
