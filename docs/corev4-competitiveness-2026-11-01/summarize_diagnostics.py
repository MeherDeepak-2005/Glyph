#!/usr/bin/env python3
"""Summarize gate probes after analyze.py and diagnose.py; no tuning."""
import json,pathlib,collections
OUT=pathlib.Path(__file__).resolve().parent;ROOT=OUT.parents[1]
meta=json.loads((ROOT/'tools/evaluation/autocorrect/corpus/ext-cases-meta.json').read_text())
fields=['id','inRanked','inCorrection','cost','language','score','typedScore','gateCandidate','gateMargin','threshold','gateCost','gateKind','correction','close','broad','injected']
strings={'id','gateCandidate','correction'};ints={'inRanked','inCorrection','gateKind','close','broad','injected'}
rows=[]
for line in (OUT/'diagnostic.tsv').read_text().splitlines():
 if not line.startswith('AUDIT\t'):continue
 vals=line.split('\t')[1:];assert len(vals)==len(fields)
 r={k:v if k in strings else int(v) if k in ints else float(v) for k,v in zip(fields,vals)};rows.append(r)
assert len(rows)==1766 and len({r['id'] for r in rows})==1766
proof=json.loads((OUT/'diagnostic-validation.json').read_text());assert proof['corrections_and_suggestions_match_saved_NSS']
result={}
for st in ['ext_birkbeck','ext_wikipedia']:
 rs=[r for r in rows if meta[r['id']]['set']==st];ct=collections.Counter()
 for r in rs:
  target=meta[r['id']]['target']
  reason='target_not_in_correction_pool' if not r['inCorrection'] else 'target_wins_but_gate_rejects' if r['gateCandidate']==target and r['correction']=='-' else 'no_gate_decision' if r['gateCandidate']=='-' else 'another_candidate_wins'
  ct[reason]+=1
 result[st]={'n':len(rs),'reasons':dict(ct),'examples':[{**meta[r['id']],**r} for r in rs if r['gateCandidate']==meta[r['id']]['target'] and r['correction']=='-'][:8]}
(OUT/'gate-diagnostics.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({s:{'n':r['n'],'reasons':r['reasons']} for s,r in result.items()},indent=2))
