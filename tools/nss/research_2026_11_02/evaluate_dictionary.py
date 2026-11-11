#!/usr/bin/env python3
"""Paired production-path n-gram decoder screening for unigram pack changes."""
import argparse,collections,hashlib,json,os,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];EVAL=ROOT/'tools/evaluation/autocorrect'
def half(m):return int(hashlib.sha1(m.get('key',m['target']).encode()).hexdigest(),16)%2==1

def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);p.add_argument('--per-set',type=int,default=200);a=p.parse_args()
    meta=json.loads((EVAL/'corpus/cases-meta.json').read_text());groups=collections.defaultdict(list)
    for line in (EVAL/'corpus/cases.tsv').read_text().splitlines():
        i=line.split('\t',1)[0]
        if half(meta[i]):groups[meta[i]['set']].append((hashlib.sha256(i.encode()).hexdigest(),line))
    chosen=[line for group in sorted(groups) for _,line in sorted(groups[group])[:a.per_set]]
    cases=a.data/'decoder-cases.tsv';cases.write_text('\n'.join(chosen)+'\n')
    binary=EVAL/'bin/dictionary-research-2026-11-02';env={k:v for k,v in os.environ.items() if not k.startswith('KB_')}
    for label,pack in [('baseline',ROOT/'keyboard/langdata.bin'),('candidate',a.data/'langdata-candidate.bin')]:
        with (a.data/('decoder-'+label+'.log')).open('w') as log:
            subprocess.run([str(binary),str(pack),str(ROOT/'keyboard/safety.kbguard'),str(cases),str(a.data/('decoder-'+label+'.jsonl'))],env=env,check=True,stdout=log,stderr=log)
        print('DECODER COMPLETE',label,flush=True)
    info={'cases':len(chosen),'counts_by_set':{k:min(a.per_set,len(v)) for k,v in groups.items()},'split':'held, SHA1 target/key odd; deterministic case hash sample',
          'case_sha256':hashlib.sha256(cases.read_bytes()).hexdigest(),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
          'latency_warning':'Training ran concurrently; these timings are not valid device-latency acceptance measurements.'}
    (a.data/'decoder-manifest.json').write_text(json.dumps(info,indent=2)+'\n')
if __name__=='__main__':main()
