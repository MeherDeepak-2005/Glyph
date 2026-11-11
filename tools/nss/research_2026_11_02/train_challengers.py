#!/usr/bin/env python3
"""CPU/GPU research sweep with equal original-word budgets and train-only SentencePiece.
All files go to an isolated cache. Does not install or promote any artifact.
"""
from __future__ import annotations
import argparse,bz2,hashlib,json,math,random,re,sys,time
from collections import Counter,defaultdict
from pathlib import Path
import numpy as np
import sentencepiece as spm
import torch
from torch.nn import functional as F
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/nss'))
from nss.models import build,detach
from nss.vocab import Vocabulary,sha256,BOS,EOS,PAD,UNK
from nss import sources
from nss.text import sentences
WORD=re.compile(r"[a-z]+(?:'[a-z]+)*")
CONFIGS={
 'word-cifg':{'arch':'lstm','embed':64,'hidden':256,'proj':64,'cifg':True},
 'word-gru':{'arch':'gru','embed':64,'hidden':256,'proj':64},
 'sp-lstm':{'arch':'lstm','embed':96,'hidden':256,'proj':96,'cifg':False},
 'sp-gru':{'arch':'gru','embed':96,'hidden':256,'proj':96},
 'sp-transformer':{'arch':'transformer','embed':96,'dim':128,'layers':2,'heads':4,'ffn':256,'window':96}}

def clean(text):
    ws=text.split()
    return 2<=len(ws)<=24 and all(WORD.fullmatch(w) for w in ws)
def read(path):
    with bz2.open(path,'rt') as f:return [s.strip() for s in f if clean(s.strip())]
def batch_tensors(encoded,device):
    width=max(len(s)-1 for s in encoded);x=torch.zeros(len(encoded),width,dtype=torch.long);y=x.clone()
    for i,s in enumerate(encoded):
        x[i,:len(s)-1]=torch.tensor(s[:-1]);y[i,:len(s)-1]=torch.tensor(s[1:])
    return x.to(device),y.to(device)
def encode(text,kind,vocab,sp):
    ids=sp.encode(text,out_type=int) if kind=='sp' else vocab.encode(text.split())
    return [BOS]+ids+[EOS]
def load_sets(data):
    sets={split:{n:read(data/(n+'.'+split+'.sentences.bz2')) for n in ('soda','tatoeba','wikitext')} for split in ('train','valid','test')}
    # MASC remains external test data; never used for selecting checkpoints/tokenizers.
    seen=set();masc=[]
    for _,ws,_ in sources.masc_heldout():
        text=' '.join(w for w in ws if w is not None)
        if None not in ws and clean(text) and text not in seen: seen.add(text);masc.append(text)
    random.Random(731).shuffle(masc);sets['test']['masc']=masc[:300]
    return sets
def draw_training(sets,budget):
    rng=random.Random(731);names=['soda','tatoeba','wikitext'];desired=[.50,.25,.25]
    mean=[np.mean([len(s.split()) for s in sets[n]]) for n in names]
    choices=[w/m for w,m in zip(desired,mean)];out=[];words=0
    while words<budget:
        n=rng.choices(names,weights=choices)[0];text=rng.choice(sets[n]);out.append(text);words+=len(text.split())
    return out,words
@torch.no_grad()
def eval_nll(model,kind,vs,sp,sets,limit,device,tail):
    model.eval();result={}
    for name,texts in sets.items():
        records=texts[:limit];loss=words=pieces=known=correct=unk=0;start=time.perf_counter()
        for first in range(0,len(records),16):
            strings=records[first:first+16];seqs=[encode(s,kind,vs,sp) for s in strings]
            x,y=batch_tensors(seqs,device);features,_=model(x);mask=y!=PAD
            logits=model.logits(features[mask]);target=y[mask];lp=F.log_softmax(logits,-1)
            loss-=lp.gather(1,target[:,None]).sum().item();pieces+=len(target)
            words+=sum(len(s.split()) for s in strings)
            if kind=='word':
                # Unknowns get normalized lexicon fallback; report spelling-unrepresented targets separately.
                for s,seq in zip(strings,seqs):
                    for w,i in zip(s.split(),seq[1:-1]):
                        if i==UNK:loss-=math.log(tail.get(w,tail['__other__']));unk+=1
                k=(target>=4);known+=int(k.sum());correct+=int(((lp.argmax(-1)==target)&k).sum())
        result[name]={'sentences':len(records),'original_words':words,'tokens_including_eos':pieces,
                      'nll_per_original_word_including_eos':loss/max(1,words),
                      'token_ppl':math.exp(min(50,loss/max(1,pieces))),
                      'token_ppl_comparable_only_with_same_tokenizer':True,
                      'word_known_top1':correct/max(1,known) if kind=='word' else None,
                      'word_oov':unk if kind=='word' else None,'seconds':time.perf_counter()-start}
    return result

def tails(vocab,unigrams):
    outside={w:c+1 for w,c in unigrams.items() if w not in vocab.index};total=sum(outside.values())+1
    return {**{w:c/total for w,c in outside.items()},'__other__':1/total}

def remap(old,oldv,newv,unigrams):
    config=old['arch'];model=build(config,len(newv));state=model.state_dict();source=old['model']
    for key,value in state.items():
        if key not in ('embedding.weight','output_bias','output'):value.copy_(source[key])
    outside=sum(c+1 for w,c in unigrams.items() if w not in oldv.index)+1
    copied=0
    with torch.no_grad():
        for i,w in enumerate(newv.words):
            if w in oldv.index:
                j=oldv.index[w];model.embedding.weight[i].copy_(source['embedding.weight'][j]);model.output_bias[i].copy_(source['output_bias'][j]);copied+=1
                if not model.tied:model.output[i].copy_(source['output'][j])
            else:
                model.embedding.weight[i].copy_(source['embedding.weight'][UNK]+torch.randn_like(model.embedding.weight[i])*.005)
                model.output_bias[i]=source['output_bias'][UNK]+math.log(.4*(unigrams.get(w,0)+1)/outside)
                if not model.tied:model.output[i].copy_(source['output'][UNK])
    return model,copied

def save(path,model,kind,vocab,sp_path,extra):
    payload={'model':{k:v.cpu().clone() for k,v in model.state_dict().items()},'arch':model.config(),'tokenization':kind,
             'vocabulary_path':str(vocab.path),'vocabulary_sha256':vocab.sha256,
             'sentencepiece_sha256':sha256(sp_path) if kind=='sp' else None,**extra}
    torch.save(payload,path)

def fit(name,model,kind,vocab,sp,sp_path,training,sets,out,device,lr,tail,eval_limit):
    torch.manual_seed(731);model=model.to(device);optimizer=torch.optim.AdamW(model.parameters(),lr=lr,weight_decay=.01)
    encoded=[encode(s,kind,vocab,sp) for s in training];counts=np.bincount([i for s in encoded for i in s[1:]],minlength=model.vocab_size)
    if not name.startswith('warm'):
        with torch.no_grad():model.output_bias.copy_(torch.tensor(np.log((counts+.5)/(counts+.5).sum()),dtype=torch.float32,device=device))
    initial=eval_nll(model,kind,vocab,sp,sets['valid'],eval_limit,device,tail)
    def score(r):return float(np.mean([v['nll_per_original_word_including_eos'] for v in r.values()]))
    best=score(initial);beststep=0;history=[];start=time.time();totalwords=sum(len(s.split()) for s in training);steps=math.ceil(len(encoded)/16)
    save(out/(name+'.best.pt'),model,kind,vocab,sp_path,{'step':0,'valid':initial,'source':'initialization'})
    for step,first in enumerate(range(0,len(encoded),16),1):
        model.train();x,y=batch_tensors(encoded[first:first+16],device);features,_=model(x)
        logits=model.logits(features[y!=PAD]);target=y[y!=PAD];loss=F.cross_entropy(logits,target)
        optimizer.zero_grad(set_to_none=True);loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),1);optimizer.step()
        if step%100==0:print(json.dumps({'model':name,'step':step,'of':steps,'loss':loss.item(),'seconds':round(time.time()-start)}),flush=True)
        if step%max(1,steps//3)==0 or step==steps:
            valid=eval_nll(model,kind,vocab,sp,sets['valid'],eval_limit,device,tail);record={'step':step,'score':score(valid),'valid':valid};history.append(record)
            if record['score']<best:
                best=record['score'];beststep=step;save(out/(name+'.best.pt'),model,kind,vocab,sp_path,{'step':step,'valid':valid,'training_original_words':totalwords})
    elapsed=time.time()-start
    save(out/(name+'.last.pt'),model,kind,vocab,sp_path,{'step':steps,'training_original_words':totalwords,'selected_for_quality':False})
    checkpoint=torch.load(out/(name+'.best.pt'),map_location=device,weights_only=False);model.load_state_dict(checkpoint['model'])
    test=eval_nll(model,kind,vocab,sp,sets['test'],eval_limit,device,tail)
    parity=streaming_parity(model,encode('can you send me the link',kind,vocab,sp),device)
    result={'arch':model.config(),'parameters':model.parameter_count(),'tokenization':kind,'training_original_words':totalwords,
            'training_pieces_including_specials':sum(len(s) for s in encoded),'seconds':elapsed,'best_step':beststep,
            'initial_validation':initial,'history':history,'test':test,'streaming_max_abs_drift':parity,
            'checkpoint':str((out/(name+'.best.pt')).relative_to(ROOT)),'checkpoint_sha256':sha256(out/(name+'.best.pt')),
            'production_ready':False}
    del optimizer;return result,model
@torch.no_grad()
def streaming_parity(model,seq,device):
    model.eval();x=torch.tensor([seq],device=device);full,_=model(x);state=None;parts=[]
    for t in x.unbind(1):f,state=model.step(t,state);parts.append(f)
    return float((full-torch.stack(parts,1)).abs().max())

def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--words',type=int,default=250000);p.add_argument('--warm-words',type=int,default=500000);p.add_argument('--eval-sentences',type=int,default=120)
    p.add_argument('--device',default='cpu');p.add_argument('--threads',type=int,default=2);p.add_argument('--arms',nargs='*',default=list(CONFIGS)+['warm-chat'])
    a=p.parse_args();torch.set_num_threads(a.threads);torch.set_num_interop_threads(1);torch.manual_seed(731);random.seed(731);np.random.seed(731)
    a.out.mkdir(parents=True,exist_ok=True);device=torch.device(a.device);sets=load_sets(a.data);vocab=Vocabulary.load(a.data/'vocabulary-30000.tsv')
    unigrams={}
    with (a.data/'unigrams.tsv').open() as f:
        next(f)
        for row in f:
            cols=row.rstrip().split('\t');unigrams[cols[0]]=int(cols[2])
    sp_path=a.out/'sentencepiece-6000.model'
    if not sp_path.exists():
        training_text=[text for source in sets['train'].values() for text in source]
        spm.SentencePieceTrainer.train(sentence_iterator=iter(training_text),model_prefix=str(a.out/'sentencepiece-6000'),
            vocab_size=6000,model_type='unigram',pad_id=0,unk_id=1,bos_id=2,eos_id=3,
            character_coverage=1.0,required_chars="abcdefghijklmnopqrstuvwxyz'",normalization_rule_name='identity',
            num_threads=1,shuffle_input_sentence=False,hard_vocab_limit=False,minloglevel=1)
    sp=spm.SentencePieceProcessor(model_file=str(sp_path));train,nwords=draw_training(sets['train'],a.words)
    # Same raw sentences and words across every from-scratch arm. No truncation.
    summary_path=a.out/'results.json';summary=json.loads(summary_path.read_text()) if summary_path.exists() else {}
    summary.update({'schema_version':1,'device':str(device),'torch':torch.__version__,'seed':731,'threads':a.threads,
        'train_sequence_sha256':hashlib.sha256('\n'.join(train).encode()).hexdigest(),'equal_budget_original_words':nwords,
        'evaluation_warning':'Small CPU screening, not convergence or a blind keyboard benchmark. Token perplexities across tokenizers are not comparable; subword NLL scores the deterministic segmentation path, not a marginal over segmentations. Word OOV scores use normalized empirical lexicon tails; unrepresented strings share a finite unknown bucket.',
        'sentencepiece_sha256':sha256(sp_path),'audit_sha256':sha256(a.data/'audit.json'),'models':summary.get('models',{})})
    oldv=Vocabulary.load()
    for label,path in [('baseline-generic',ROOT/'tools/nss/runs/cifg-lstm-96x670/step8000.pt'),('baseline-chat',ROOT/'tools/nss/runs/cifg-lstm-96x670-chat/best.pt')]:
        if label in summary['models']:continue
        checkpoint=torch.load(path,map_location='cpu',weights_only=False);model=build(checkpoint['arch'],len(oldv));model.load_state_dict(checkpoint['model']);model.to(device)
        summary['models'][label]={'arch':model.config(),'parameters':model.parameter_count(),'tokenization':'word',
                                 'test':eval_nll(model,'word',oldv,sp,sets['test'],a.eval_sentences,device,tails(oldv,unigrams)),
                                 'checkpoint_sha256':sha256(path),'new_training':False}
        summary_path.write_text(json.dumps(summary,indent=2)+'\n');print('EVALUATED',label,flush=True)
    for name in a.arms:
        if name in summary['models']:continue
        torch.manual_seed(731)
        current_vocab=vocab
        if name.startswith('warm-chat'):
            ck=torch.load(ROOT/'tools/nss/runs/cifg-lstm-96x670-chat/best.pt',map_location='cpu',weights_only=False)
            if name=='warm-chat-control':
                current_vocab=oldv;model=build(ck['arch'],len(oldv));model.load_state_dict(ck['model'])
            else:model,copied=remap(ck,oldv,vocab,unigrams)
            kind='word';training,_=draw_training(sets['train'],a.warm_words);lr=5e-5
        else:
            kind='sp' if name.startswith('sp-') else 'word';model=build(CONFIGS[name],sp.vocab_size() if kind=='sp' else len(vocab));training=train;lr=.002
        print('TRAIN',name,model.parameter_count(),flush=True)
        result,model=fit(name,model,kind,current_vocab,sp,sp_path,training,sets,a.out,device,lr,tails(current_vocab,unigrams),a.eval_sentences)
        summary['models'][name]=result;summary_path.write_text(json.dumps(summary,indent=2)+'\n');print('DONE',name,flush=True)
    print('SWEEP COMPLETE',flush=True)
if __name__=='__main__':main()
