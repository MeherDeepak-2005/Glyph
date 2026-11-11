#!/usr/bin/env python3
"""Create an isolated v6 pack using calibrated unigram estimates and unchanged contexts.
Weights in the binary are scaled estimates, NEVER raw corpus occurrence counts.
"""
import argparse,csv,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'tools'))
import build_language_data as builder
from verify_language_data import Pack

def build(source,counts,output):
    old=Pack(source);oldwords,oldfreq=old.vocabulary();oldwords=[w.decode() for w in oldwords]
    if old.version!=6:raise ValueError('Expected v6 pack')
    with counts.open() as f:observed={r['word']:float(r['pooled_ppm']) for r in csv.DictReader(f,delimiter='\t')}
    scale=sum(oldfreq)/sum(observed.values());weights={w:max(1,round(rate*scale)) for w,rate in observed.items()}
    for w,c in zip(oldwords,oldfreq):weights.setdefault(w,c)
    vocab=sorted(weights.items(),key=lambda x:(-x[1],x[0]));ids={w:i for i,(w,_) in enumerate(vocab)};mapped={i:ids[w] for i,w in enumerate(oldwords)}
    bi={};tri={};totals={'bigrams':{},'trigrams':{}}
    for key,(total,rows) in old.bigrams().items():
        bi[mapped[key]]=[(mapped[w],c) for w,c in rows];totals['bigrams'][mapped[key]]=total
    for key,(total,rows) in old.trigrams().items():
        a,b=old.context_pair(key);pair=(mapped[a],mapped[b]);tri[pair]=[(mapped[w],c) for w,c in rows];totals['trigrams'][pair]=total
    starters=[(mapped[w],c) for w,c in old.sentence_starters()]
    builder.write_bin(vocab,bi,tri,starters,output=output,context_totals=totals,version=6, max_bytes=source.stat().st_size+100000)
    new=Pack(output);actual,frequencies=new.vocabulary();actual=[w.decode() for w in actual]
    assert list(zip(actual,frequencies))==vocab
    def logical(p):
        ws=[w.decode() for w in p.vocabulary()[0]]
        b={ws[k]:(total,tuple((ws[w],c) for w,c in rows)) for k,(total,rows) in p.bigrams().items()}
        t={(ws[p.context_pair(k)[0]],ws[p.context_pair(k)[1]]):(total,tuple((ws[w],c) for w,c in rows)) for k,(total,rows) in p.trigrams().items()}
        s=tuple((ws[w],c) for w,c in p.sentence_starters());return b,t,s
    assert logical(old)==logical(new),'Context or starter evidence changed'
    result={'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),
            'status':'research candidate; not installed','words':len(vocab),'added':sorted(set(actual)-set(oldwords)),
            'bytes':output.stat().st_size,'unigram_mass_before':sum(oldfreq),'unigram_mass_after':sum(frequencies),
            'weight_semantics':'pooled_ppm * scale, rounded, floor 1; estimates, not observed counts','ppm_scale':scale,
            'contexts_and_starters':'all logical counts and denominators preserved exactly; numeric IDs rebuilt',
            'parity':'PASS'}
    output.with_suffix('.manifest.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,default=ROOT/'keyboard/langdata.bin');p.add_argument('--counts',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();build(a.source,a.counts,a.out)
