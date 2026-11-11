#!/usr/bin/env python3
"""Memory-mapped word training shards and explicit multi-epoch exposure plans.
Full runs sample the entire eligible source, rather than repeating a small reservoir.
"""
import argparse,json,sqlite3,sys
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'tools/nss'))
from nss.vocab import Vocabulary,sha256,BOS,EOS

def encode(dbpath,vocabpath,out):
    out.mkdir(parents=True,exist_ok=True);vocab=Vocabulary.load(vocabpath);db=sqlite3.connect(dbpath);manifest={'vocabulary_sha256':vocab.sha256,'corpus_sha256':sha256(dbpath.parent/'corpus.json'),'sources':{},'split':'train only','no_name_masking':True,'sentence_max_words':128,'initial_bias_counts':'Source-mixture estimates from the full training shards, not observed mixture occurrence counts'}
    if (out/'shards.json').exists():
        old=json.loads((out/'shards.json').read_text())
        if old['vocabulary_sha256']!=vocab.sha256 or old['corpus_sha256']!=manifest['corpus_sha256']:raise RuntimeError('Existing shard identity differs')
        return
    names=json.loads((dbpath.parent/'corpus.json').read_text())['sources']
    for source in names:
        ns,nw=db.execute('SELECT count(*),sum(words) FROM sentences WHERE source=? AND split="train" AND words<=128',(source,)).fetchone()
        tokens=np.lib.format.open_memmap(out/(source+'.tokens.npy'),mode='w+',dtype=np.uint16,shape=(nw+2*ns,));offsets=np.lib.format.open_memmap(out/(source+'.offsets.npy'),mode='w+',dtype=np.int64,shape=(ns+1,));words=np.lib.format.open_memmap(out/(source+'.words.npy'),mode='w+',dtype=np.int32,shape=(ns,));offsets[0]=0;at=0
        for i,(text,count) in enumerate(db.execute('SELECT text,words FROM sentences WHERE source=? AND split="train" AND words<=128 ORDER BY hash',(source,))):
            seq=[BOS]+vocab.encode(text.split())+[EOS];tokens[at:at+len(seq)]=seq;at+=len(seq);offsets[i+1]=at;words[i]=count
        if at!=len(tokens):raise RuntimeError('Word-shard token count mismatch')
        tokens.flush();offsets.flush();words.flush();manifest['sources'][source]={'sentences':ns,'raw_words':nw,'tokens':at,'sha256':{suffix:sha256(out/(source+'.'+suffix+'.npy')) for suffix in ['tokens','offsets','words']}}
        print('ENCODED',source,ns,nw,flush=True)
    (out/'shards.json').write_text(json.dumps(manifest,indent=2)+'\n')

def plan(shards,out,budget,seed):
    manifest=json.loads((shards/'shards.json').read_text());rng=np.random.default_rng(seed);sourceids=[];rowids=[];stats={};names=list(manifest['sources']);weights={'soda':.40,'tatoeba':.15,'wikitext':.15,'fineweb':.30} if 'fineweb' in names else {'soda':.50,'tatoeba':.25,'wikitext':.25}
    for sid,source in enumerate(names):
        weight=weights[source]
        lengths=np.load(shards/(source+'.words.npy'),mmap_mode='r');desired=round(budget*weight);seen=0;parts=[];cycles=0
        while seen<desired:
            permutation=rng.permutation(len(lengths)).astype(np.uint32);cumulative=np.cumsum(lengths[permutation],dtype=np.int64);take=min(len(permutation),int(np.searchsorted(cumulative,desired-seen))+1);parts.append(permutation[:take]);seen+=int(cumulative[take-1]);cycles+=1
        chosen=np.concatenate(parts);rowids.append(chosen);sourceids.append(np.full(len(chosen),sid,dtype=np.uint8));stats[source]={'words':seen,'sentences':len(chosen),'unique_sentences':len(np.unique(chosen)),'source_cycles_started':cycles}
    source=np.concatenate(sourceids);row=np.concatenate(rowids);order=rng.permutation(len(row));out.parent.mkdir(parents=True,exist_ok=True);np.savez(out,source=source[order],row=row[order]);info={'seed':seed,'requested_words':budget,'words':sum(s['words'] for s in stats.values()),'sources':stats,'shards_sha256':sha256(shards/'shards.json'),'sha256':sha256(out),'without_replacement':all(s['sentences']==s['unique_sentences'] for s in stats.values()),'full_source_epoch_sampling':True,'shards_path':str(shards)};out.with_suffix('.manifest.json').write_text(json.dumps(info,indent=2)+'\n');print(json.dumps(info),flush=True)

class Encoded:
    def __init__(self,owner):self.owner=owner
    def __getitem__(self,i):
        owner=self.owner;sid=int(owner.source[i]);row=int(owner.row[i]);tokens,offsets,words=owner.shards[sid];return tokens[offsets[row]:offsets[row+1]].astype(np.int64)
class Batches:
    def __init__(self,owner,batch):
        if 512%batch:raise ValueError('Batch must divide 512')
        self.owner=owner;self.batch=batch;self.cached=-1;self.order=None
    def __len__(self):return (len(self.owner)+self.batch-1)//self.batch
    def __getitem__(self,i):
        start=i*self.batch;block=start//512
        if block!=self.cached:
            indices=np.arange(block*512,min((block+1)*512,len(self.owner)));self.order=indices[np.argsort(self.owner.lengths[indices],kind='stable')];self.cached=block
        offset=start%512;return self.order[offset:offset+self.batch]
class Rows:
    def __init__(self,planpath,vocab):
        m=json.loads(planpath.with_suffix('.manifest.json').read_text());folder=Path(m['shards_path']);sm=json.loads((folder/'shards.json').read_text())
        if sm['vocabulary_sha256']!=vocab.sha256 or m['shards_sha256']!=sha256(folder/'shards.json') or m['sha256']!=sha256(planpath):raise RuntimeError('Large-plan/shard/vocabulary hash mismatch')
        arrays=np.load(planpath);self.source=arrays['source'];self.row=arrays['row'];self.shards=[];self.lengths=np.empty(len(self.row),dtype=np.int32);self.initial_counts=np.zeros(len(vocab))
        for sid,source in enumerate(sm['sources']):
            tokens=np.load(folder/(source+'.tokens.npy'),mmap_mode='r');offsets=np.load(folder/(source+'.offsets.npy'),mmap_mode='r');words=np.load(folder/(source+'.words.npy'),mmap_mode='r');self.shards.append((tokens,offsets,words));mask=self.source==sid;self.lengths[mask]=words[self.row[mask]]
            counts=np.bincount(tokens,minlength=len(vocab)).astype(float);counts[BOS]=0;weights={'soda':.40,'tatoeba':.15,'wikitext':.15,'fineweb':.30} if 'fineweb' in sm['sources'] else {'soda':.50,'tatoeba':.25,'wikitext':.25};self.initial_counts+=counts/max(1,len(tokens))*weights[source]*10_000_000
        self.total_words=int(self.lengths.sum());self.encoded=Encoded(self)
        if self.total_words!=m['words']:raise RuntimeError('Large plan exposure mismatch')
    def __len__(self):return len(self.row)
    def __getitem__(self,i):
        if i>=len(self):raise IndexError(i)
        return {'words':int(self.lengths[i])}
    def batches(self,batch):return Batches(self,batch)
if __name__=='__main__':
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True)
    q=sub.add_parser('encode');q.add_argument('--db',type=Path,required=True);q.add_argument('--vocab',type=Path,required=True);q.add_argument('--out',type=Path,required=True)
    q=sub.add_parser('plan');q.add_argument('--shards',type=Path,required=True);q.add_argument('--out',type=Path,required=True);q.add_argument('--words',type=int,default=130000000);q.add_argument('--seed',type=int,default=731)
    a=p.parse_args()
    if a.command=='encode':encode(a.db,a.vocab,a.out)
    else:plan(a.shards,a.out,a.words,a.seed)
