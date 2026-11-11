#!/usr/bin/env python3
"""Evaluate frozen shipped/chat baselines and each trained recurrent word challenger.
Validation only. Full original suites remain diagnostic; final test is gated separately.
"""
import argparse,json,subprocess,sys,time
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2]

def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);a=p.parse_args();data=a.data
    def call(name,args):
        with (data/(name+'.log')).open('a') as log:subprocess.run([*map(str,args)],cwd=ROOT,stdout=log,stderr=log,check=True)
    def python(name,args):call(name,[sys.executable,'-u',*args])
    while not (data/'dictionary/dictionary.json').exists():time.sleep(5)
    cases=data/'validation-cases'
    if not (cases/'cases.manifest.json').exists():python('validation-cases',[HERE/'decoder.py','cases','--db',data/'corpus/corpus.sqlite','--out',cases])
    old=ROOT/'keyboard/langdata.bin';baseline=data/'native-baseline.jsonl'
    for label,model in [('ngram',None),('baseline',ROOT/'keyboard/nss-english.nsslm'),('chat',ROOT/'tools/nss/artifacts/chat-final.nsslm')]:
        python('native-'+label,[HERE/'decoder.py','replay','--cases',cases,'--out',data/('native-'+label+'.jsonl'),'--pack',old,*(['--model',model] if model else [])])
    for label in ['ngram','chat']:python('compare-'+label,[HERE/'decoder.py','compare','--cases',cases,'--baseline',baseline,'--candidate',data/('native-'+label+'.jsonl'),'--out',data/('compare-'+label+'.json')])
    pack=data/'candidate.bin'
    if not pack.exists():python('candidate-pack',[HERE/'paired_pack.py','--counts',data/'dictionary/unigrams.tsv','--vocab',data/'dictionary/vocabulary-30000.tsv','--out',pack])
    python('native-dictionary',[HERE/'decoder.py','replay','--cases',cases,'--out',data/'native-dictionary.jsonl','--pack',pack])
    python('compare-dictionary',[HERE/'decoder.py','compare','--cases',cases,'--baseline',data/'native-ngram.jsonl','--candidate',data/'native-dictionary.jsonl','--out',data/'compare-dictionary.json'])
    parity=ROOT/'tools/.cache/dictionary-research-2026-11-02/neural-parity'
    for name in ['word-reference','word-cifg','word-lstm','word-gru']:
        folder=data/'screen'/(name+'-s731')
        while not (folder/'result.json').exists():
            status=json.loads((data/'status.json').read_text())
            if status['status']=='failed':raise RuntimeError('Screening failed: '+status.get('error',''))
            time.sleep(5)
        export=data/'exports'/(name+'.nsslm')
        python('export-'+name,[HERE/'export_word.py','--checkpoint',folder/'best.pt','--pack',pack,'--db',data/'corpus/corpus.sqlite','--plan',data/'screen-10m.jsonl.gz','--out',export])
        call('parity-'+name,[parity,export,export.with_suffix('.goldens.json'),pack])
        replay=data/('native-'+name+'.jsonl');python('native-'+name,[HERE/'decoder.py','replay','--cases',cases,'--out',replay,'--pack',pack,'--model',export])
        python('compare-'+name,[HERE/'decoder.py','compare','--cases',cases,'--baseline',baseline,'--candidate',replay,'--out',data/('compare-'+name+'.json')])
    print('NATIVE WORD VALIDATION COMPLETE',flush=True)
if __name__=='__main__':main()
