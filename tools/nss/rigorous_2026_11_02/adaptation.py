#!/usr/bin/env python3
"""Controlled adaptation diagnosis: fixed raw-text subset, matched original-vocab control,
three learning rates, warmup/cosine, preserved bias/norm parameters and complete curves.
"""
import argparse,gzip,json,subprocess,sys,time
from pathlib import Path
HERE=Path(__file__).resolve().parent
from train import sha256,read_plan

def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);a=p.parse_args();plan=a.data/'screen-10m.jsonl.gz'
    while not plan.with_suffix('.manifest.json').exists():time.sleep(5)
    subset=[];count=0
    for row in read_plan(plan):
        subset.append(row);count+=row['words']
        if count>=1_000_000:break
    small=a.data/'adaptation-1m.jsonl.gz'
    with gzip.open(small,'wt') as f:
        for row in subset:f.write(json.dumps(row)+'\n')
    manifest={'words':count,'unique_sentences':len({r['hash'] for r in subset}),'sentences':len(subset),'without_replacement':True,'source_plan_sha256':sha256(plan),'sha256':sha256(small)}
    small.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    results={}
    for lr in ['0.00001','0.00005','0.0002']:
        out=a.data/('adaptation-lr'+lr)
        with (a.data/('adaptation-lr'+lr+'.log')).open('a') as log:
            subprocess.run([sys.executable,'-u',str(HERE/'train.py'),'--db',str(a.data/'corpus/corpus.sqlite'),'--plan',str(small),'--out',str(out),'--vocab',str(a.data/'dictionary/vocabulary-30000.tsv'),'--arms','warm-control','warm-remap','--lr',lr,'--batch','64','--threads','2','--compute-seconds','60'],stdout=log,stderr=log,check=True)
        results[lr]=json.loads((out/'results.json').read_text())
        (a.data/'adaptation.json').write_text(json.dumps({'matched_plan':manifest,'learning_rate_runs':results,'test_accessed':False,'warning':'Controlled intervention; causal explanations require the measured control results. Step zero is failure to improve.'},indent=2)+'\n')
    print('ADAPTATION DIAGNOSIS COMPLETE',flush=True)
if __name__=='__main__':main()
