#!/usr/bin/env python3
"""Fixed-candidate language-ranking diagnostic shared across word/subword models.
The target is explicitly injected. This is NOT end-to-end decoder/beam recall.
"""
import argparse,hashlib,json,math,random,sys,time
from collections import defaultdict
from pathlib import Path
import numpy as np
import sentencepiece as spm
import torch
from torch.nn import functional as F
sys.path.insert(0,str(Path(__file__).resolve().parent))
from train_challengers import ROOT,load_sets,build,Vocabulary,encode,BOS,EOS,UNK,PAD,tails,sha256

def deletions(w):return {w[:i]+w[i+1:] for i in range(len(w))}
def cases_for(sets,words,per_source):
    index=defaultdict(set)
    for w in words:
        if 2<=len(w)<=20:
            index[w].add(w)
            for d in deletions(w):index[d].add(w)
    cases=[];freq=words[:1000]
    for name,texts in sets.items():
        added=0
        for text in texts:
            ws=text.split();at=min(len(ws)-1,max(1,len(ws)//2));target=ws[at]
            if not 3<=len(target)<=18:continue
            typo=target[:len(target)//2]+target[len(target)//2+1:]
            near=set(index.get(typo,set()))
            for d in deletions(typo):near.update(index.get(d,set()))
            near.discard(target);ordered=sorted(near,key=lambda w:(abs(len(w)-len(target)),w))[:23]
            rng=random.Random(int(hashlib.sha256((name+'|'+text).encode()).hexdigest()[:12],16));rng.shuffle(freq)
            for w in freq:
                if len(ordered)>=31:break
                if w!=target and w not in ordered and abs(len(w)-len(target))<=2:ordered.append(w)
            ordered.append(target);ordered.sort();cases.append({'source':name,'context':' '.join(ws[:at]),'target':target,'typo':typo,'candidates':ordered})
            added+=1
            if added>=per_source:break
    return cases
@torch.no_grad()
def score_word(model,vocab,case,tail,device):
    x=torch.tensor([[BOS]+vocab.encode(case['context'].split())],device=device);f,_=model(x);lp=F.log_softmax(model.logits(f[0,-1]),-1)
    return [float(lp[vocab.exact(w)])+(math.log(tail.get(w,tail['__other__'])) if vocab.exact(w)==UNK else 0) for w in case['candidates']]
@torch.no_grad()
def score_sp(model,sp,case,device):
    prefix=[BOS]+sp.encode(case['context']);pieces=[sp.encode(w) for w in case['candidates']]
    length=max(len(prefix)+len(p) for p in pieces);x=torch.zeros(len(pieces),length,dtype=torch.long,device=device)
    for i,p in enumerate(pieces):x[i,:len(prefix)+len(p)]=torch.tensor(prefix+p,device=device)
    features,_=model(x);scores=[]
    # Complete-word closure: the next token must begin a new word or end sentence.
    boundary=torch.tensor([i for i in range(sp.vocab_size()) if sp.id_to_piece(i).startswith('▁')]+[EOS],device=device)
    for i,p in enumerate(pieces):
        rows=features[i,len(prefix)-1:len(prefix)+len(p)];lp=F.log_softmax(model.logits(rows),-1)
        value=lp[:-1].gather(1,torch.tensor(p,device=device)[:,None]).sum()+torch.logsumexp(lp[-1,boundary],0)
        scores.append(float(value))
    return scores

def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);p.add_argument('--runs',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--per-source',type=int,default=40);p.add_argument('--models',nargs='*');a=p.parse_args()
    torch.set_num_threads(2);torch.set_num_interop_threads(1);device=torch.device('cpu');oldv=Vocabulary.load();newv=Vocabulary.load(a.data/'vocabulary-30000.tsv');sp=spm.SentencePieceProcessor(model_file=str(a.runs/'sentencepiece-6000.model'))
    counts={}
    with (a.data/'unigrams.tsv').open() as f:
        next(f)
        for line in f:c=line.split('\t');counts[c[0]]=int(c[2])
    candidate_words=sorted(set(oldv.words[4:])|set(newv.words[4:]),key=lambda w:(-counts.get(w,0),w))
    cases=cases_for(load_sets(a.data)['test'],candidate_words,a.per_source)
    (a.out.parent/'candidate-cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    manifest=json.loads((a.runs/'results.json').read_text());result={'warning':__doc__,'cases':len(cases),'case_sha256':sha256(a.out.parent/'candidate-cases.json'),'models':{}}
    if a.out.exists():
        existing=json.loads(a.out.read_text())
        if existing.get('case_sha256')!=result['case_sha256']:raise ValueError('Existing results use different candidate cases')
        result['models']=existing.get('models',{})
    for name,info in manifest['models'].items():
        if a.models and name not in a.models:continue
        if name.startswith('baseline'):
            path=ROOT/('tools/nss/runs/cifg-lstm-96x670/step8000.pt' if name.endswith('generic') else 'tools/nss/runs/cifg-lstm-96x670-chat/best.pt');vs=oldv;kind='word'
        else:
            path=ROOT/info['checkpoint'];kind=info['tokenization']
            vs=Vocabulary.load(Path(torch.load(path,map_location='cpu',weights_only=False)['vocabulary_path']))
        ck=torch.load(path,map_location=device,weights_only=False);model=build(ck['arch'],sp.vocab_size() if kind=='sp' else len(vs));model.load_state_dict(ck['model']);model.eval();tail=tails(vs,counts);stats=defaultdict(lambda:{'correct':0,'total':0,'reciprocal_rank':0.0,'oov_targets':0,'oov_correct':0});latency=[]
        for case in cases:
            start=time.perf_counter();scores=score_sp(model,sp,case,device) if kind=='sp' else score_word(model,vs,case,tail,device);latency.append((time.perf_counter()-start)*1000)
            order=sorted(range(len(scores)),key=lambda i:(-scores[i],case['candidates'][i]));rank=order.index(case['candidates'].index(case['target']))+1
            for group in ('all',case['source']):
                row=stats[group];row['total']+=1;row['correct']+=rank==1;row['reciprocal_rank']+=1/rank
                if case['target'] not in vs.index:row['oov_targets']+=1;row['oov_correct']+=rank==1
        entry={'sets':{k:{**r,'accuracy':r['correct']/r['total'],'mrr':r['reciprocal_rank']/r['total']} for k,r in stats.items()},'cpu_candidate_batch_ms':{'p50':float(np.percentile(latency,50)),'p95':float(np.percentile(latency,95))}}
        result['models'][name]=entry;a.out.write_text(json.dumps(result,indent=2)+'\n');print(name,json.dumps(entry),flush=True)
if __name__=='__main__':main()
