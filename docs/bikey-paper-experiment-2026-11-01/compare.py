#!/usr/bin/env python3
"""Score complete, paired outputs; never treat missing cases as unchanged."""
import argparse, hashlib, importlib.util, json, math
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('--results',type=Path,default=HERE);OUT=ap.parse_args().results.resolve()
spec=importlib.util.spec_from_file_location('evaluation',ROOT/'tools/evaluation/autocorrect/evaluate.py')
ev=importlib.util.module_from_spec(spec);spec.loader.exec_module(ev)
meta=json.loads((ROOT/'tools/evaluation/autocorrect/corpus/cases-meta.json').read_text())
for p in (ROOT/'tools/evaluation/autocorrect/corpus').glob('*-cases-meta.json'):meta.update(json.loads(p.read_text()))
ids=[l.split('\t')[0] for l in (HERE/'held.tsv').read_text().splitlines()]
assert len(ids)==len(set(ids))
meta={i:meta[i] for i in ids}
arms=json.loads((HERE/'arms.json').read_text())['arms']
def read(name):
 records=[json.loads(l) for l in (OUT/(name+'.jsonl')).read_text().splitlines()]
 assert records[-1].get('kind')=='done',name+' incomplete'
 rows={r['id']:r for r in records if 'id' in r}
 assert len(rows)==len(ids)==records[-1]['events'] and rows.keys()==meta.keys(),name+' missing/duplicate cases'
 assert all(r.get('ok',1)==1 for r in rows.values()),name+' decoder errors'
 return rows
runs={n:read(n) for n in arms}
report={'n':len(ids),'scope':'held targets; all hard/apos guards; paired identical simulated touches; no tuning','arms':{}}
for name,rows in runs.items():
 metrics={}
 for label,(pick,pred,higher,guard) in ev.metrics(meta).items():
  if not pick:continue
  ref=[bool(pred(runs['current'][i],meta[i])) for i in pick];new=[bool(pred(rows[i],meta[i])) for i in pick]
  gained=sum(y and not x for x,y in zip(ref,new));lost=sum(x and not y for x,y in zip(ref,new))
  p=ev.mcnemar(gained,lost)
  metrics[label]=dict(n=len(pick),baseline_count=sum(ref),candidate_count=sum(new),baseline=100*sum(ref)/len(ref),candidate=100*sum(new)/len(new),delta_pp=100*(sum(new)-sum(ref))/len(ref),gained=gained,lost=lost,p=p,higher_is_better=higher,guardrail=guard,regression=p<.05 and (gained<lost if higher else gained>lost))
 nw=[i for i,m in meta.items() if m['set']=='nw']
 savings=lambda rr:100*sum(rr[i]['len']-rr[i]['kf'] for i in nw)/sum(rr[i]['len']+1 for i in nw)
 metrics['keystroke savings']={'baseline':savings(runs['current']),'candidate':savings(rows),'regression':savings(rows)<savings(runs['current'])-.5}
 changed=[]
 for i,m in meta.items():
  if m['set']=='nw':continue
  a=ev.commit(runs['current'][i],m);b=ev.commit(rows[i],m)
  if a!=b:changed.append(dict(id=i,set=m['set'],typed=m['typed'],target=m['target'],baseline=a,candidate=b,baseline_correct=a==m['target'],candidate_correct=b==m['target']))
 (OUT/(name+'-changed.json')).write_text(json.dumps(changed,indent=1)+'\n')
 report['arms'][name]={'env':arms[name],'metrics':metrics,'changed_commits':len(changed),'previously_correct_lost':sum(c['baseline_correct'] and not c['candidate_correct'] for c in changed),'newly_correct':sum(not c['baseline_correct'] and c['candidate_correct'] for c in changed),'sequential_latency_required':True}
primary=json.loads((HERE/'decision-policy.json').read_text())['primary']
for name,arm in report['arms'].items():
 if name=='current':continue
 mm=arm['metrics'];arm['quality_eligible']=any(mm[k]['delta_pp']>=.5 for k in primary) and not any(v['regression'] for k,v in mm.items() if k in primary or v.get('guardrail') or k=='keystroke savings')
 arm['quality_regressions']=[k for k,v in mm.items() if v['regression'] and (k in primary or v.get('guardrail') or k=='keystroke savings')]
(OUT/'quality.json').write_text(json.dumps(report,indent=2)+'\n')
labels=['ECPS real misspellings fixed','Synthetic typos fixed','GUARD real-word errors fixed','ext_birkbeck fixed','ext_wikipedia fixed','GUARD rare dictionary words changed','GUARD unknown names changed','GUARD false corrections, ECPS correct','GUARD next word in top 3']
for label in labels:
 print(label,[(n,round(a['metrics'][label]['candidate'],3)) for n,a in report['arms'].items()])
for n,a in report['arms'].items():print(n,'new fixes',a['newly_correct'],'lost fixes',a['previously_correct_lost'],'eligible',a.get('quality_eligible'))
