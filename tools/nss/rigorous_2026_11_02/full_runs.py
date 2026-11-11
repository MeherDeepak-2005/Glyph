#!/usr/bin/env python3
"""Train two decoder-selected finalists for 130M raw words x three seeds.
Refuses to select from language-only proxies or missing native/subword evaluations.
"""
import argparse,json,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
from train import CONFIGS,sha256

def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);a=p.parse_args();data=a.data;protocol=json.loads((HERE/'protocol.json').read_text());corpus=json.loads((data/'corpus/corpus.json').read_text())
    if not corpus.get('modern_manifests'):raise SystemExit('Full stage blocked: no verified modern corpus in these training counts.')
    comparisons={};missing=[]
    for name in protocol['screen']['models']:
        path=data/('compare-'+name+'.json')
        if not path.exists():missing.append(name);continue
        comparisons[name]=json.loads(path.read_text())
    if missing:raise SystemExit('Full selection blocked: real decoder evaluations missing for '+', '.join(missing))
    hashes={c['candidate']['case_sha256'] for c in comparisons.values()}
    if len(hashes)!=1:raise RuntimeError('Finalist comparisons use different validation cases')
    def quality(name):
        c=comparisons[name];clean=c['groups']['clean']['false_correction']['candidate'];accuracy=c['groups']['all']['commit_correct']['candidate'];return (clean,-accuracy,name)
    selected=sorted(comparisons,key=quality)[:2]
    if any(not n.startswith('word-') for n in selected):raise SystemExit('Selected subword finalist requires full subword shards/runtime support before scaling; do not substitute a worse word model silently.')
    selection={'models':selected,'criterion':'Lowest clean false-correction rate, then highest committed-word validation accuracy; same natural decoder cases.','comparisons':{n:sha256(data/('compare-'+n+'.json')) for n in comparisons},'test_accessed':False}
    (data/'finalists.json').write_text(json.dumps(selection,indent=2)+'\n')
    def run(name,args):
        with (data/(name+'.log')).open('a') as log:subprocess.run([sys.executable,'-u',*map(str,args)],stdout=log,stderr=log,check=True)
    shards=data/'full-shards';run('encode-full',[HERE/'large_data.py','encode','--db',data/'corpus/corpus.sqlite','--vocab',data/'dictionary/vocabulary-30000.tsv','--out',shards])
    for seed in protocol['full']['seeds']:
        plan=data/('full-'+str(seed)+'.npz')
        if not plan.exists():run('plan-full-'+str(seed),[HERE/'large_data.py','plan','--shards',shards,'--out',plan,'--words',protocol['full']['original_words_per_seed'],'--seed',seed])
        run('full-'+str(seed),[HERE/'train.py','--db',data/'corpus/corpus.sqlite','--plan',plan,'--large','--out',data/'full','--vocab',data/'dictionary/vocabulary-30000.tsv','--arms',*selected,'--seed',seed,'--batch','32','--warmup','1000','--threads','2'])
    print('FULL SEED TRAINING COMPLETE; DEVICE AND BLIND-TEST ACCEPTANCE STILL REQUIRED',flush=True)
if __name__=='__main__':main()
