#!/usr/bin/env python3
"""Analyze preserved paired runs; no engine, policy or tuning changes."""
import sys,json,pathlib,collections,struct,hashlib
ROOT=pathlib.Path(__file__).resolve().parents[2]; OUT=pathlib.Path(__file__).resolve().parent
HERE=ROOT/'tools/evaluation/autocorrect';sys.path[:0]=[str(HERE),str(ROOT/'tools')]
import evaluate as ev
from verify_language_data import Pack
meta={};cases={};core={};nss={};notaps={}
def rows(p):
 out={}
 for line in p.read_text().splitlines():
  r=json.loads(line)
  if 'id' in r:
   assert r['id'] not in out and r['ok']==1
   out[r['id']]=r
 return out
for stem,suffix in [('cases',''),('ext-cases','.ext'),('keep-cases','.keep')]:
 mp=HERE/'corpus'/(stem+'-meta.json' if stem!='cases' else 'cases-meta.json');meta.update(json.loads(mp.read_text()))
 for line in (HERE/'corpus'/(stem+'.tsv')).read_text().splitlines():
  i,kind,ctx,typed,target=line.split('\t');cases[i]={'kind':kind,'context':ctx,'typed':typed,'target':target}
 core.update(rows(ROOT/'docs/corev4-vs-nss-touch-2026-11-01'/('corev4'+suffix+'.jsonl')))
 nss.update(rows(HERE/'results'/('taps-final-nss-english'+suffix+'.jsonl')))
 notaps.update(rows(HERE/'results'/('rules-nss-english'+suffix+'.jsonl')))
assert set(meta)==set(core)==set(nss)==set(notaps)==set(cases)
held={i:m for i,m in meta.items() if m['set'] in ('hard','apos') or ev.half(m)=='held'}
pack=Pack(ROOT/'keyboard/langdata.bin');pw,pf=pack.vocabulary();freq=dict(zip([w.decode() for w in pw],pf))
# Read vocabulary directly from the exact installed model (section kind 3).
b=(ROOT/'keyboard/nss-english.nsslm').read_bytes();nsections=struct.unpack_from('<I',b,64)[0]
# Section records are identified without relying on a training-time vocabulary export.
vocab=None
for at in range(256,256+32*nsections,32):
 sid,kind,nrow,ncol,off,size=struct.unpack_from('<4I2Q',b,at)
 if sid==100 and kind==3:
  offsets=struct.unpack_from('<'+str(nrow+1)+'I',b,off);base=off+4*(nrow+1)
  vocab={b[base+offsets[i]:base+offsets[i+1]].decode() for i in range(nrow)};break
assert vocab and '<unk>' in vocab

def fixed(r,m):return ev.commit(r,m)==m['target']
def top(r,m):return fixed(r,m) or m['target'] in ev.slots(r,m)
def dist(a,b):
 d=[[0]*(len(b)+1) for _ in range(len(a)+1)]
 for i in range(len(a)+1):d[i][0]=i
 for j in range(len(b)+1):d[0][j]=j
 for i in range(1,len(a)+1):
  for j in range(1,len(b)+1):
   d[i][j]=min(d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+(a[i-1]!=b[j-1]))
   if i>1 and j>1 and a[i-1]==b[j-2] and a[i-2]==b[j-1]:d[i][j]=min(d[i][j],d[i-2][j-2]+1)
 return d[-1][-1]
def summary(ids):
 c=[fixed(core[i],meta[i]) for i in ids];n=[fixed(nss[i],meta[i]) for i in ids]
 wins=[i for i,a,z in zip(ids,c,n) if a and not z]
 return {'n':len(ids),'core_fixed':sum(c),'nss_touch_fixed':sum(n),'nss_no_taps_fixed':sum(fixed(notaps[i],meta[i]) for i in ids),'core_only':len(wins),'nss_only':sum(z and not a for a,z in zip(c,n)),'core_top3':sum(top(core[i],meta[i]) for i in ids),'nss_top3':sum(top(nss[i],meta[i]) for i in ids),'core_only_target_in_nss_top3':sum(top(nss[i],meta[i]) for i in wins),'core_only_nss_no_commit':sum(not nss[i].get('c') for i in wins),'core_only_target_outside_neural_vocab':sum(meta[i]['target'] not in vocab for i in wins)}
report={'total_cases':len(meta),'held_cases':len(held),'neural_vocabulary_size':len(vocab),'sets':{},'severe_subgroups':{},'examples':{}}
for st in ['ecps','syn','realword','ext_birkbeck','ext_wikipedia','ext_aspell','ext_holbrook']:
 ids=[i for i,m in held.items() if m['set']==st];report['sets'][st]=summary(ids)
 if st.startswith('ext_'):
  groups=collections.defaultdict(list)
  for i in ids:
   m=meta[i];ed=dist(m['typed'],m['target'])
   groups['edits_'+('3plus' if ed>=3 else str(ed))].append(i)
   groups['neural_'+('known' if m['target'] in vocab else 'unknown')].append(i)
   groups['first_'+('same' if m['target'][0]==m['typed'][0] else 'different')].append(i)
  report['severe_subgroups'][st]={k:summary(v) for k,v in groups.items()}
 for side in ['core_only','nss_only']:
  chosen=[];seen=set()
  for i in ids:
   m=meta[i];a=fixed(core[i],m);z=fixed(nss[i],m)
   if (a and not z if side=='core_only' else z and not a) and len(m['target'])>=6 and m['target'] not in seen:
    seen.add(m['target']);chosen.append({'id':i,**cases[i],'core_correction':core[i].get('c'),'core_suggestions':core[i].get('s'),'nss_correction':nss[i].get('c'),'nss_suggestions':nss[i].get('s'),'target_in_neural_vocab':m['target'] in vocab,'edit_distance':dist(m['typed'],m['target'])})
   if len(chosen)>=12:break
  report['examples'][st+'_'+side]=chosen

# A specific CoreV4 source rule discounts runs of the same substitution.
# Count the string pattern only; this is not an ablation or an emulation of Core key geometry.
repeat_ids=[]
for i,m in held.items():
 if m['set'] not in ('ecps','syn','realword','ext_birkbeck','ext_wikipedia','ext_aspell','ext_holbrook'):continue
 a,b=m['typed'].lower(),m['target']
 if len(a)==len(b) and any(a[j]==a[j+1] and b[j]==b[j+1] and a[j]!=b[j] for j in range(len(a)-1)):repeat_ids.append(i)
report['repeated_substitution_run_pattern']={**summary(repeat_ids),'examples':[{'id':i,**cases[i],'core_correction':core[i].get('c'),'nss_correction':nss[i].get('c')} for i in repeat_ids[:20]]}

(OUT/'paired-analysis.json').write_text(json.dumps(report,indent=2)+'\n')
# The full population of Core-only severe fixes is used for isolated diagnostics, not tuning.
ids=[i for i,m in held.items() if m['set'] in ('ext_birkbeck','ext_wikipedia') and fixed(core[i],m) and not fixed(nss[i],m)]
all_taps={l.split('\t')[0]:l for p in (HERE/'corpus').glob('*cases.taps.tsv') for l in p.read_text().splitlines()}
(OUT/'core-only-severe.taps.tsv').write_text('\n'.join(all_taps[i] for i in ids)+'\n')
print(json.dumps({'sets':report['sets'],'subgroups':report['severe_subgroups'],'examples':{k:v[:3] for k,v in report['examples'].items() if k.startswith('ext_')},'diagnostic_cases':len(ids)},indent=2))
