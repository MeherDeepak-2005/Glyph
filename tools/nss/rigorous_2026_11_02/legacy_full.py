#!/usr/bin/env python3
"""Full retained halves of every existing benchmark suite; diagnostic, never a fresh final test."""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2];CORPUS=ROOT/'tools/evaluation/autocorrect/corpus'
from train import sha256

def build(out):
    out.mkdir(parents=True,exist_ok=True);rows=[];meta={};inputs=[]
    for path in sorted(CORPUS.glob('*cases.tsv')):
        mpath=path.with_name(path.stem+'-meta.json')
        if not mpath.exists():continue
        source=path.name;metadata=json.loads(mpath.read_text());taps=path.with_name(path.stem+'.taps.tsv');actual=taps if taps.exists() else path;inputs.append({'file':actual.name,'sha256':sha256(actual),'meta_sha256':sha256(mpath)})
        for line in actual.read_text().splitlines():
            cols=line.split('\t');i,kind,context,typed,target=cols[:5];m=metadata[i];key=m.get('key',m['target'])
            if int(hashlib.sha1(key.encode()).hexdigest(),16)%2!=1:continue
            identifier=source+'::'+i;cols[0]=identifier;rows.append('\t'.join(cols));meta[identifier]={'source':source,'document':'target:'+key,'condition':'clean' if kind=='ac' and typed.lower()==target.lower() else m.get('set',source),'typed':typed.lower(),'target':target.lower(),'kind':kind}
    if len(rows)!=len(meta):raise RuntimeError('Duplicate legacy IDs')
    (out/'cases.tsv').write_text('\n'.join(rows)+'\n');(out/'meta.json').write_text(json.dumps(meta)+'\n');manifest={'cases':len(rows),'source_files':inputs,'case_sha256':sha256(out/'cases.tsv'),'metadata_sha256':sha256(out/'meta.json'),'target_injected':False,'fresh_blind_final_test':False,'cluster_unit':'target word (legacy suites lack document IDs)','split':'All retained target-key SHA1-odd rows, every available suite','quality_only':True};(out/'cases.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest),flush=True)

def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);a=p.parse_args();out=a.data/'legacy-full'
    if not (out/'cases.manifest.json').exists():build(out)
    def call(label,args):
        with (a.data/('legacy-'+label+'.log')).open('a') as log:subprocess.run([sys.executable,'-u',*map(str,args)],stdout=log,stderr=log,check=True)
    old=ROOT/'keyboard/langdata.bin';base=out/'baseline.jsonl'
    for label,pack,model in [('ngram',old,None),('baseline',old,ROOT/'keyboard/nss-english.nsslm'),('chat',old,ROOT/'tools/nss/artifacts/chat-final.nsslm'),('dictionary',a.data/'candidate.bin',None)]:
        if not pack.exists():raise RuntimeError('Paired pack not ready')
        call(label,[HERE/'decoder.py','replay','--cases',out,'--out',out/(label+'.jsonl'),'--pack',pack,*(['--model',model] if model else [])])
    for label,baseline in [('ngram',base),('chat',base),('dictionary',out/'ngram.jsonl')]:call('compare-'+label,[HERE/'decoder.py','compare','--cases',out,'--baseline',baseline,'--candidate',out/(label+'.jsonl'),'--out',out/('compare-'+label+'.json')])
    print('FULL LEGACY VALIDATION COMPLETE; NOT A FRESH FINAL TEST',flush=True)
if __name__=='__main__':main()
