#!/usr/bin/env python3
"""Resumable, validation-only, equal-raw-text architecture screening.
Never opens test records. Initial/best/last, optimizer and RNG are retained.
"""
import argparse,copy,gzip,hashlib,json,math,random,sqlite3,sys,time
from pathlib import Path
import numpy as np
import sentencepiece as spm
import torch
from torch.nn import functional as F
ROOT=Path(__file__).resolve().parents[3];sys.path[:0]=[str(ROOT/'tools/nss'),str(ROOT/'tools/nss/research_2026_11_02')]
from nss.models import build
from nss.losses import cross_entropy_sum
from nss.vocab import Vocabulary,sha256,BOS,EOS,PAD,UNK
from train_challengers import remap
CONFIGS={
 'word-reference':{'arch':'lstm','embed':96,'hidden':670,'proj':96,'cifg':True},
 'word-cifg':{'arch':'lstm','embed':64,'hidden':256,'proj':64,'cifg':True},
 'word-lstm':{'arch':'lstm','embed':64,'hidden':256,'proj':64,'cifg':False},
 'word-gru':{'arch':'gru','embed':64,'hidden':256,'proj':64},
 'unigram-lstm':{'arch':'lstm','embed':96,'hidden':256,'proj':96,'cifg':False},
 'unigram-gru':{'arch':'gru','embed':96,'hidden':256,'proj':96},
 'unigram-transformer':{'arch':'transformer','embed':96,'dim':128,'layers':2,'heads':4,'ffn':256,'window':96},
 'bpe-lstm':{'arch':'lstm','embed':96,'hidden':256,'proj':96,'cifg':False},
 'bpe-gru':{'arch':'gru','embed':96,'hidden':256,'proj':96},
 'bpe-transformer':{'arch':'transformer','embed':96,'dim':128,'layers':2,'heads':4,'ffn':256,'window':96}}

def seed_all(seed):random.seed(seed);np.random.seed(seed);torch.manual_seed(seed)
def read_plan(path):
    with gzip.open(path,'rt') as f:return [json.loads(s) for s in f]
def tokenizer(data,rows,kind):
    path=data/(kind+'-6000.model')
    if not path.exists():
        total=0;sample=[]
        for r in rows:
            sample.append(r['text']);total+=r['words']
            if total>=1_000_000:break
        spm.SentencePieceTrainer.train(sentence_iterator=iter(sample),model_prefix=str(path.with_suffix('')),model_type=kind,vocab_size=6000,
            pad_id=PAD,unk_id=UNK,bos_id=BOS,eos_id=EOS,required_chars="abcdefghijklmnopqrstuvwxyz'",normalization_rule_name='identity',
            character_coverage=1.0,num_threads=1,shuffle_input_sentence=False,hard_vocab_limit=False,minloglevel=2)
        path.with_suffix('.manifest.json').write_text(json.dumps({'training_only':True,'training_words':total,'input_sha256':hashlib.sha256('\n'.join(sample).encode()).hexdigest(),'sha256':sha256(path)},indent=2)+'\n')
    return spm.SentencePieceProcessor(model_file=str(path)),path

def encode(s,vocab,sp):return [BOS]+(sp.encode(s) if sp else vocab.encode(s.split()))+[EOS]
def tensors(seqs):
    width=max(len(s)-1 for s in seqs);x=torch.zeros(len(seqs),width,dtype=torch.long);y=x.clone()
    for i,s in enumerate(seqs):x[i,:len(s)-1]=torch.tensor(s[:-1]);y[i,:len(s)-1]=torch.tensor(s[1:])
    return x,y

def loss_on(model,seqs):
    x,y=tensors(seqs);h,_=model(x);mask=y!=PAD
    count=int(mask.sum());loss=cross_entropy_sum(h[mask],model.output_weight,model.output_bias,y[mask],chunk=512)/count
    return loss,count

@torch.no_grad()
def evaluate(model,validation,vocab,sp):
    model.eval();out={}
    for source,rows in validation.items():
        total=n=words=correct=known=unk=0
        encoded=rows.encoded if hasattr(rows,'encoded') else [encode(r['text'],vocab,sp) for r in rows]
        for at in range(0,len(encoded),32):
            x,y=tensors(encoded[at:at+32]);h,_=model(x);mask=y!=PAD;logits=model.logits(h[mask]);target=y[mask]
            total+=float(F.cross_entropy(logits,target,reduction='sum'));n+=len(target)
            k=target>=4;known+=int(k.sum());correct+=int(((logits.argmax(-1)==target)&k).sum());unk+=int((target==UNK).sum())
        words=sum(r['words'] for r in rows)
        out[source]={'nll':total/max(1,n),'tokens':n,'raw_words':words,'ppl_same_tokenizer_only':math.exp(min(50,total/max(1,n))),'known_token_top1':correct/max(1,known),'unk':unk}
    return out

def score(valid):return sum(v['nll'] for v in valid.values())/len(valid)
def validation_rows(dbpath,limit):
    db=sqlite3.connect(dbpath);result={}
    names=json.loads((dbpath.parent/'corpus.json').read_text())['sources']
    for source in names:
        result[source]=[{'text':t,'words':n,'doc':d.hex()} for t,n,d in db.execute('SELECT text,words,doc FROM sentences WHERE source=? AND split="valid" AND words<=128 ORDER BY hash LIMIT ?',(source,limit))]
        if not result[source]:raise RuntimeError('Missing validation source '+source)
    return result

def diagnose(model,seqs):
    probe=copy.deepcopy(model);probe.train();initial=float(loss_on(probe,seqs)[0].detach());opt=torch.optim.AdamW(probe.parameters(),lr=.01,weight_decay=0)
    norms=[]
    for _ in range(80):
        opt.zero_grad(set_to_none=True);loss,n=loss_on(probe,seqs);loss.backward();norm=float(torch.nn.utils.clip_grad_norm_(probe.parameters(),5));norms.append(norm);opt.step()
        if not math.isfinite(float(loss)) or not math.isfinite(norm):raise RuntimeError('Non-finite preflight gradient/loss')
    final=float(loss_on(probe,seqs)[0].detach())
    if final>=initial*.60 or max(norms)<=1e-8:raise RuntimeError(f'Tiny-subset convergence failed: {initial} -> {final}')
    seq=torch.tensor([seqs[0]]);probe.eval();full,_=probe(seq);state=None;part=[]
    for token in seq.unbind(1):h,state=probe.step(token,state);part.append(h)
    drift=float((full-torch.stack(part,1)).abs().max())
    # BOS must erase all prior sentence state, for both recurrent and attention models.
    previous=torch.tensor([[BOS,4,5,EOS]]);_,state=probe(previous);reset,_=probe(seq,state)
    reset_drift=float((full-reset).abs().max())
    if drift>3e-5 or reset_drift>3e-5:raise RuntimeError('Streaming/reset parity failed')
    return {'initial_loss':initial,'final_loss':final,'updates':80,'max_gradient_norm':max(norms),'streaming_max_abs':drift,'bos_reset_max_abs':reset_drift,'passed':True}

def atomic_save(path,payload):
    torch.save(payload,path.with_suffix('.tmp'));path.with_suffix('.tmp').replace(path)

def fit(name,cfg,kind,vocab,sp,sp_path,rows,valid,args,init=None):
    seed_all(args.seed);out=args.out/(name+'-s'+str(args.seed));out.mkdir(parents=True,exist_ok=True)
    identity={'name':name,'seed':args.seed,'trainer_sha256':sha256(Path(__file__)),'architecture':cfg,'plan_sha256':sha256(args.plan),'corpus_sha256':sha256(args.db.parent/'corpus.json'),
              'vocabulary_sha256':vocab.sha256,'sentencepiece_sha256':sha256(sp_path) if sp_path else None,'threads':args.threads,
              'batch':args.batch,'lr':args.lr,'equal_compute_seconds':args.compute_seconds,'compute_unit':'process CPU seconds (all worker threads); validation/checkpoint IO excluded','warmup':args.warmup,'training_words':rows.total_words if hasattr(rows,'total_words') else sum(r['words'] for r in rows),'validation_limit':args.valid_limit}
    identity_path=out/'identity.json'
    if identity_path.exists() and json.loads(identity_path.read_text())!=identity:raise RuntimeError('Run identity changed; use fresh output.')
    identity_path.write_text(json.dumps(identity,indent=2)+'\n')
    if (out/'result.json').exists():return json.loads((out/'result.json').read_text())
    model=init if init is not None else build(cfg,sp.vocab_size() if sp else len(vocab));encoded=[encode(r['text'],vocab,sp) for r in rows]
    # Batch order uses raw-word lengths only: identical sentences/order for every tokenizer/architecture.
    if hasattr(rows,'batches'):batches=rows.batches(args.batch)
    else:
        order=[]
        for at in range(0,len(rows),512):order.extend(sorted(range(at,min(at+512,len(rows))),key=lambda i:rows[i]['words']))
        batches=[order[a:a+args.batch] for a in range(0,len(order),args.batch)]
    if init is None:
        counts=rows.initial_counts if hasattr(rows,'initial_counts') else np.bincount([i for s in encoded for i in s[1:]],minlength=model.vocab_size)
        with torch.no_grad():model.output_bias.copy_(torch.tensor(np.log((counts+.5)/(counts+.5).sum()),dtype=torch.float32))
    diag=diagnose(model,[encoded[i] for i in batches[0][:8]])
    decay=[p for n,p in model.named_parameters() if not model.no_decay(n)];no_decay=[p for n,p in model.named_parameters() if model.no_decay(n)]
    optimizer=torch.optim.AdamW([{'params':decay,'weight_decay':.01},{'params':no_decay,'weight_decay':0}],lr=args.lr,betas=(.9,.98))
    initial=evaluate(model,valid,vocab,sp);best=score(initial);step=0;consumed=0;train_seconds=0;compute_saved=False;history=[]
    def payload(step,extra):
        return {'model':model.state_dict(),'arch':model.config(),'optimizer':optimizer.state_dict(),'step':step,
            'tokenization':'sp' if sp else 'word','sentencepiece_path':str(sp_path) if sp_path else None,
            'vocabulary_path':str(vocab.path),'vocabulary_sha256':vocab.sha256,'identity':identity,'raw_words':consumed,
            'train_seconds':train_seconds,'best':best,'torch_rng':torch.get_rng_state(),'numpy_rng':np.random.get_state(),'python_rng':random.getstate(),**extra}
    last=out/'last.pt'
    if last.exists():
        ck=torch.load(last,map_location='cpu',weights_only=False);model.load_state_dict(ck['model']);optimizer.load_state_dict(ck['optimizer']);step=ck['step'];consumed=ck['raw_words'];train_seconds=ck['train_seconds'];best=ck['best'];history=ck['history'];compute_saved=(out/'equal-compute.pt').exists()
        torch.set_rng_state(ck['torch_rng']);np.random.set_state(ck['numpy_rng']);random.setstate(ck['python_rng'])
    else:
        atomic_save(out/'initial.pt',payload(0,{'valid':initial}));atomic_save(out/'best.pt',payload(0,{'valid':initial}))
    (out/'preflight.json').write_text(json.dumps(diag,indent=2)+'\n')
    log=(out/'curve.jsonl').open('a');interval=max(1,len(batches)//10);window_loss=window_tokens=0
    for bi in range(step,len(batches)):
        indices=batches[bi];model.train();begin=time.process_time();progress=bi/max(1,len(batches)-1)
        lr=args.lr*min(1,(bi+1)/min(args.warmup,max(1,len(batches)//20)))*(.05+.95*.5*(1+math.cos(math.pi*progress)))
        for g in optimizer.param_groups:g['lr']=lr
        optimizer.zero_grad(set_to_none=True);loss,n=loss_on(model,[encoded[i] for i in indices]);loss.backward();norm=float(torch.nn.utils.clip_grad_norm_(model.parameters(),1));optimizer.step()
        train_seconds+=time.process_time()-begin;step=bi+1;consumed+=sum(rows[i]['words'] for i in indices);window_loss+=float(loss.detach())*n;window_tokens+=n
        if not math.isfinite(float(loss.detach())) or not math.isfinite(norm):raise RuntimeError('Nonfinite training loss/gradient')
        if not compute_saved and train_seconds>=args.compute_seconds:
            atomic_save(out/'equal-compute.pt',payload(step,{'comparison':'equal process CPU time; validation/serialization excluded'}));compute_saved=True
        if step%100==0 or step==len(batches):
            record={'step':step,'steps_total':len(batches),'raw_words':consumed,'train_nll':window_loss/max(1,window_tokens),'grad_norm':norm,'lr':lr,'train_seconds':train_seconds,'raw_words_per_s':consumed/max(1,train_seconds)};print(json.dumps({'model':name,**record}),flush=True);log.write(json.dumps(record)+'\n');log.flush();window_loss=window_tokens=0
        if step%interval==0 or step==len(batches):
            metrics=evaluate(model,valid,vocab,sp);value=score(metrics);record={'step':step,'validation':metrics,'score':value,'raw_words':consumed,'train_seconds':train_seconds};history.append(record);print(json.dumps({'model':name,**record}),flush=True);log.write(json.dumps(record)+'\n');log.flush()
            if value<best:best=value;atomic_save(out/'best.pt',payload(step,{'valid':metrics}))
            atomic_save(last,payload(step,{'history':history}))
    if not compute_saved:print(json.dumps({'model':name,'equal_compute_status':'run completed before comparison budget; no matched-compute claim'}),flush=True)
    expected=rows.total_words if hasattr(rows,'total_words') else sum(r['words'] for r in rows)
    if consumed!=expected:raise RuntimeError(f'Unequal raw-word exposure: {consumed} != {expected}')
    selected=torch.load(out/'best.pt',map_location='cpu',weights_only=False)
    result={'identity':identity,'parameters':model.parameter_count(),'preflight':diag,'initial_validation':initial,'history':history,
            'selected_step':selected['step'],'trained_improvement':selected['step']>0,'training_seconds':train_seconds,'raw_words':consumed,
            'checkpoint_sha256':sha256(out/'best.pt'),'equal_compute_checkpoint':str(out/'equal-compute.pt') if compute_saved else None,
            'test_accessed':False,'production_ready':False}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');return result

def main():
    p=argparse.ArgumentParser();p.add_argument('--db',type=Path,required=True);p.add_argument('--plan',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--vocab',type=Path,required=True)
    p.add_argument('--large',action='store_true');p.add_argument('--arms',nargs='+',default=list(CONFIGS));p.add_argument('--seed',type=int,default=731);p.add_argument('--threads',type=int,default=2);p.add_argument('--batch',type=int,default=64);p.add_argument('--valid-limit',type=int,default=512);p.add_argument('--lr',type=float,default=.002);p.add_argument('--warmup',type=int,default=200);p.add_argument('--compute-seconds',type=int,default=60)
    a=p.parse_args();torch.set_num_threads(a.threads);torch.set_num_interop_threads(1);a.out.mkdir(parents=True,exist_ok=True);seed_all(a.seed)
    vocab=Vocabulary.load(a.vocab);manifest=json.loads(a.plan.with_suffix('.manifest.json').read_text())
    if a.large:
        from large_data import Rows
        if not manifest.get('full_source_epoch_sampling'):raise RuntimeError('Large plans must draw explicit full-source epochs')
        if any(not name.startswith('word-') for name in a.arms):raise RuntimeError('Memory-mapped full runs currently support word-tokenized models only')
        rows=Rows(a.plan,vocab)
    else:
        rows=read_plan(a.plan)
        if not manifest['without_replacement'] or manifest['unique_sentences']!=len(rows):raise RuntimeError('Repeated sentence pool forbidden')
    valid=validation_rows(a.db,a.valid_limit);summary={}
    for name in a.arms:
        seed_all(a.seed)
        kind=name.split('-')[0];sp=sp_path=None;current=vocab;init=None
        if kind in ['unigram','bpe']:sp,sp_path=tokenizer(a.out,rows,kind)
        if name.startswith('warm-'):
            ck=torch.load(ROOT/'tools/nss/runs/cifg-lstm-96x670-chat/best.pt',map_location='cpu',weights_only=False);oldv=Vocabulary.load()
            if name=='warm-control':current=oldv;init=build(ck['arch'],len(current));init.load_state_dict(ck['model'])
            else:
                unigrams={}
                with gzip.open(a.db.parent/'counts.tsv.gz','rt') as f:
                    next(f)
                    for s in f:w,n,*_=s.rstrip().split('\t');unigrams[w]=int(n)
                init,_=remap(ck,oldv,vocab,unigrams)
            cfg=ck['arch']
        else:cfg=CONFIGS[name]
        print('BEGIN',name,flush=True);summary[name]=fit(name,cfg,kind,current,sp,sp_path,rows,valid,a,init);(a.out/'results.json').write_text(json.dumps(summary,indent=2)+'\n');print('COMPLETE',name,flush=True)
    print('SCREEN COMPLETE',flush=True)
if __name__=='__main__':main()
