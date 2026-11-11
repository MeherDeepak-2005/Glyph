#!/usr/bin/env python3
import json,statistics
from pathlib import Path
HERE=Path(__file__).resolve().parent
arms=json.loads((HERE/'arms.json').read_text())['arms']
def quant(x,q):return sorted(x)[min(len(x)-1,int(len(x)*q))]
def stats(x):return {'n':len(x),'p50':quant(x,.5),'p95':quant(x,.95),'p99':quant(x,.99)}
summary={};allruns={}
for name in arms:
 runs=[];mem=[]
 for p in sorted(HERE.glob('latency-*-'+name+'.jsonl')):
  raw=[json.loads(l) for l in p.read_text().splitlines()];assert raw[-1].get('kind')=='done'
  rows={r['id']:r for r in raw if 'id'in r};assert raw[-1]['events']==len(rows)
  runs.append(rows);mem.extend(r for r in raw if r.get('kind')=='process'and r.get('at')=='end')
 assert len(runs)==2,name
 assert runs[0].keys()==runs[1].keys()
 values={'word':[],'next_word':[],'keystroke':[]}
 for i,a in runs[0].items():
  b=runs[1][i]
  if'ms'in a:
   assert (a.get('c'),a.get('s'))==(b.get('c'),b.get('s')),name+' nondeterministic'
   values['word'].append((a['ms']+b['ms'])/2)
  else:
   assert (a['r0'],a['kf'],a['s0'])==(b['r0'],b['kf'],b['s0'])
   assert len(a['msk'])==len(b['msk'])
   values['next_word'].append((a['ms0']+b['ms0'])/2)
   values['keystroke'].extend((x+y)/2 for x,y in zip(a['msk'],b['msk']))
 summary[name]={k:stats(x)for k,x in values.items()}
 summary[name]['peak_rss_mib']=max(m['peak_rss_bytes']for m in mem)/2**20
 allruns[name]=runs
for name in arms:
 for k in ['word','next_word','keystroke']:
  r=summary['current'][k]['p95'];v=summary[name][k]['p95'];summary[name][k]['p95_ratio']=v/r
  summary[name][k]['latency_failed']=v>1.1*r and v-r>.05
report={'method':'685 fixed requests (586 typed words, 99 next-word cases), every next-word prefix, two sequential forward/reverse runs per arm; per-case means before percentiles; no quality jobs concurrent. Desktop host only.','tap':summary}
# Gesture correctness and timing, separately from tap guardrails.
gesture={}
for prefix in ['glide','stress']:
 for name in arms:
  p=HERE/(prefix+'-'+name+'.tsv')
  if not p.exists():continue
  rr=[l.split('\t') for l in p.read_text().splitlines()]
  gesture[prefix+'-'+name]={'n':len(rr),'top1':sum(int(r[3])==0 for r in rr),'top3':sum(0<=int(r[3])<3 for r in rr)}
  if prefix=='stress':
   gesture[prefix+'-'+name]['by_noise']={noise:{'n':sum(r[2]==noise for r in rr),'top1':sum(r[2]==noise and int(r[3])==0 for r in rr),'top3':sum(r[2]==noise and 0<=int(r[3])<3 for r in rr)}for noise in sorted(set(r[2]for r in rr))}
for name in ['current','bikey_paper_g']:
 runs=[]
 for p in sorted(HERE.glob('gesture-time-*-'+name+'.tsv')):runs.append({r[0]:r for l in p.read_text().splitlines() if(r:=l.split('\t'))})
 assert len(runs)==2 and len(runs[0])==len(runs[1])==600
 for i,a in runs[0].items():assert a[:4]==runs[1][i][:4]and a[5:]==runs[1][i][5:]
 gesture['timing-'+name]=stats([(float(r[4])+float(runs[1][i][4]))/2 for i,r in runs[0].items()])
report['gesture']=gesture
(HERE/'timing.json').write_text(json.dumps(report,indent=2)+'\n')
for name,data in summary.items():print(name,'word',data['word'],'keys',data['keystroke'])
print('gesture',json.dumps(gesture))
