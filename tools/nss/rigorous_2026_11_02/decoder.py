#!/usr/bin/env python3
"""Freeze document-grouped validation cases; replay real C++ search without target injection.
Synthetic errors/taps are diagnostics, not user recordings or a blind modern test.
"""
import argparse,collections,hashlib,json,os,random,sqlite3,subprocess,sys
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'tools/nss'))
from nss.vocab import sha256
BINARY=ROOT/'tools/evaluation/autocorrect/bin/dictionary-research-2026-11-02'

def cases(dbpath,out,per_source):
    out.mkdir(parents=True,exist_ok=True);db=sqlite3.connect(dbpath);rows=[];meta={};sources=json.loads((dbpath.parent/'corpus.json').read_text())['sources'];counts=collections.Counter();seen=set()
    def candidates():
        for source in sources:
            yield from db.execute('SELECT hash,doc,source,text FROM sentences WHERE source=? AND split="valid" AND words BETWEEN 3 AND 128 ORDER BY hash',(source,))
    for h,doc,source,text in candidates():
        if source not in sources or counts[source]>=per_source or doc in seen:continue
        words=text.split();positions=[i for i,w in enumerate(words) if 3<=len(w)<=18 and all('a'<=c<='z' or c=="'" for c in w)]
        if not positions:continue
        position=positions[int.from_bytes(h[:4],'little')%len(positions)];target=words[position];context=' '.join(words[max(0,position-16):position]);seen.add(doc);counts[source]+=1
        mid=len(target)//2;wrong=target[:mid]+target[mid+1:];swapped=target[:mid-1]+target[mid:mid+1]+target[mid-1:mid]+target[mid+1:]
        for condition,kind,typed in [('clean','ac',target),('deletion','ac',wrong),('swap','ac',swapped),('next','nw','')]:
            if condition=='swap' and typed==target:continue
            identifier=source+'-'+h.hex()[:16]+'-'+condition;rng=random.Random(int.from_bytes(hashlib.sha256(identifier.encode()).digest()[:8],'little'))
            taps=';'.join(f'{rng.gauss(0,.16):.5f},{rng.gauss(0,.12):.5f}' for _ in typed)
            rows.append('\t'.join([identifier,kind,context,typed,target,taps]))
            meta[identifier]={'source':source,'document':doc.hex(),'condition':condition,'typed':typed,'target':target,'kind':kind}
        if all(counts[s]>=per_source for s in sources):break
    if not all(counts[s]>0 for s in sources):raise RuntimeError('No eligible validation documents for a source')
    casepath=out/'cases.tsv';casepath.write_text('\n'.join(rows)+'\n');(out/'meta.json').write_text(json.dumps(meta,indent=2)+'\n')
    manifest={'case_sha256':sha256(casepath),'metadata_sha256':sha256(out/'meta.json'),'documents_per_source':dict(counts),'requested_cap_per_source':per_source,'unequal_source_counts_require_macro_domain_reporting':True,'cases':len(rows),'corpus_sha256':sha256(dbpath.parent/'corpus.json'),'split':'validation documents only','synthetic_errors_and_taps':True,'target_injected':False,'fresh_blind_final_test':False}
    (out/'cases.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest),flush=True)

def replay(casesdir,out,pack,model,dump):
    out.parent.mkdir(parents=True,exist_ok=True);env={k:v for k,v in os.environ.items() if not k.startswith('KB_')};env['KB_DIAG']='1'
    if model:env['KB_NSS']=str(model)
    if dump:env['KB_DUMP']='1'
    manifest={'case_sha256':sha256(casesdir/'cases.tsv'),'pack_sha256':sha256(pack),'model_sha256':sha256(model) if model else None,'binary_sha256':sha256(BINARY),'safety_sha256':sha256(ROOT/'keyboard/safety.kbguard'),'options':{k:v for k,v in env.items() if k.startswith('KB_')},'quality_only':True,'device_latency_valid':False}
    if out.exists() and out.with_suffix('.manifest.json').exists():
        if json.loads(out.with_suffix('.manifest.json').read_text())!=manifest:raise RuntimeError('Existing replay identity differs')
        print('SKIP',out);return
    temp=out.with_suffix('.partial');subprocess.run([str(BINARY),str(pack),str(ROOT/'keyboard/safety.kbguard'),str(casesdir/'cases.tsv'),str(temp)],env=env,check=True)
    data=[json.loads(s) for s in temp.read_text().splitlines()];done=next((r for r in data if r.get('kind')=='done'),None)
    expected=len(json.loads((casesdir/'meta.json').read_text()))
    if not done or done['events']!=expected or sum('id' in r for r in data)!=expected:raise RuntimeError('Incomplete decoder replay')
    if any(not r['ok'] for r in data if 'id' in r):raise RuntimeError('Native engine errors')
    temp.replace(out);out.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print('REPLAY COMPLETE',out,flush=True)

def load(path):return {r['id']:r for s in path.read_text().splitlines() if 'id' in (r:=json.loads(s))}
def predictions(row,meta):
    if meta['kind']=='nw':return {'top1':int(row['r0']==0),'top3':int(0<=row['r0']<3)}
    committed=row.get('c') or meta['typed'];target=meta['target'];typed=meta['typed'];suggestions=[]
    for s in ([row['c']] if row.get('c') else [])+row.get('s',[]):
        if s!=typed and s not in suggestions:suggestions.append(s)
    return {'commit_correct':int(committed==target),'top1':int((suggestions[0] if suggestions else typed)==target),'top3':int(target in suggestions[:3] or committed==target),'changed':int(committed!=typed),'correct_change':int(committed==target and committed!=typed),'false_correction':int(target==typed and committed!=target),'candidate_recall':int(row.get('rk',-1)>=0)}

def compare(casesdir,base,candidate,out):
    meta=json.loads((casesdir/'meta.json').read_text());b=load(base);c=load(candidate)
    if set(b)!=set(meta) or set(c)!=set(meta):raise RuntimeError('Unpaired/incomplete decoder outputs')
    bm=json.loads(base.with_suffix('.manifest.json').read_text());cm=json.loads(candidate.with_suffix('.manifest.json').read_text())
    for k in ['case_sha256','binary_sha256','safety_sha256']:
        if bm[k]!=cm[k]:raise RuntimeError('Unmatched '+k)
    groups=collections.defaultdict(list)
    for i,m in meta.items():
        for group in ['all',m['source'],m['condition'],m['source']+'/'+m['condition']]:groups[group].append(i)
    result={'warning':'Paired validation diagnostics; cluster unit is documented in cases.manifest.json. Synthetic errors/taps or existing legacy suites; no blind-test or physical-device latency claim.','cases':len(meta),'baseline':bm,'candidate':cm,'groups':{}}
    for group,ids in groups.items():
        by_metric=collections.defaultdict(lambda:collections.defaultdict(list))
        for i in ids:
            pb=predictions(b[i],meta[i]);pc=predictions(c[i],meta[i])
            for metric in pb:by_metric[metric][meta[i]['document']].append((pb[metric],pc[metric]))
        metrics={}
        for metric,documents in by_metric.items():
            values=np.array([[sum(b for b,c in pairs),sum(c for b,c in pairs),len(pairs)] for pairs in documents.values()],dtype=float);total=values.sum(0);rng=np.random.default_rng(731);delta=[]
            for _ in range(2000):
                sampled=values[rng.integers(0,len(values),len(values))].sum(0);delta.append((sampled[1]-sampled[0])/sampled[2])
            metrics[metric]={'baseline':total[0]/total[2],'candidate':total[1]/total[2],'delta':(total[1]-total[0])/total[2],'paired_document_bootstrap_95ci':list(np.percentile(delta,[2.5,97.5])),'cases':int(total[2]),'documents':len(values)}
        ac=[i for i in ids if meta[i]['kind']=='ac'];before=[predictions(b[i],meta[i]) for i in ac];after=[predictions(c[i],meta[i]) for i in ac]
        for label,ps in [('baseline',before),('candidate',after)]:
            changes=sum(p['changed'] for p in ps);typos=sum(meta[i]['typed']!=meta[i]['target'] for i in ac)
            metrics[label+'_correction']={'precision':sum(p['correct_change'] for p in ps)/changes if changes else None,'recall':sum(p['correct_change'] for p in ps)/typos if typos else None,'changes':changes}
        result['groups'][group]=metrics
    out.write_text(json.dumps(result,indent=2)+'\n');print('COMPARISON COMPLETE',out,flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True)
    q=sub.add_parser('cases');q.add_argument('--db',type=Path,required=True);q.add_argument('--out',type=Path,required=True);q.add_argument('--per-source',type=int,default=512)
    q=sub.add_parser('replay');q.add_argument('--cases',type=Path,required=True);q.add_argument('--out',type=Path,required=True);q.add_argument('--pack',type=Path,required=True);q.add_argument('--model',type=Path);q.add_argument('--dump',action='store_true')
    q=sub.add_parser('compare');q.add_argument('--cases',type=Path,required=True);q.add_argument('--baseline',type=Path,required=True);q.add_argument('--candidate',type=Path,required=True);q.add_argument('--out',type=Path,required=True)
    a=p.parse_args()
    if a.command=='cases':cases(a.db,a.out,a.per_source)
    elif a.command=='replay':replay(a.cases,a.out,a.pack,a.model,a.dump)
    else:compare(a.cases,a.baseline,a.candidate,a.out)
