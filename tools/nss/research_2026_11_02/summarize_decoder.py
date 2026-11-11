import sys,json,math,pathlib,collections
root=pathlib.Path('.');base=root/'tools/.cache/dictionary-research-2026-11-02';ed=root/'tools/evaluation/autocorrect';sys.path.insert(0,str(ed));import evaluate as ev
meta=json.loads((ed/'corpus/cases-meta.json').read_text())
def load(p):return {r['id']:r for l in p.read_text().splitlines() if (r:=json.loads(l)).get('id')}
a=load(base/'decoder-baseline.jsonl');b=load(base/'decoder-candidate.jsonl');groups=collections.defaultdict(list)
for i in a:groups[meta[i]['set']].append(i)
result={'warning':'Deterministic held-out screening subset; previously inspected repository benchmark, not a new blind user test.','sets':{},'changes':[]}
for group,ids in groups.items():
    if group=='nw':
        result['sets'][group]={'n':len(ids),'metric':'next-word top3',
            'baseline_top3':sum(0<=a[i].get('r0',-1)<3 for i in ids),
            'candidate_top3':sum(0<=b[i].get('r0',-1)<3 for i in ids)}
        continue
    def correct(r,m):return (r.get('c') or m['typed']).lower()==m['target'].lower()
    left=sum(correct(a[i],meta[i]) for i in ids);right=sum(correct(b[i],meta[i]) for i in ids)
    wins=sum(not correct(a[i],meta[i]) and correct(b[i],meta[i]) for i in ids);losses=sum(correct(a[i],meta[i]) and not correct(b[i],meta[i]) for i in ids)
    d=wins+losses;p=min(1.,2*sum(math.comb(d,k) for k in range(min(wins,losses)+1))/2**d) if d else 1.
    result['sets'][group]={'n':len(ids),'baseline_correct':left,'candidate_correct':right,'wins':wins,'losses':losses,'mcnemar_exact_two_sided':p,
        'baseline_top3':sum(meta[i]['target'].lower() in ev.slots(a[i],meta[i]) or correct(a[i],meta[i]) for i in ids),
        'candidate_top3':sum(meta[i]['target'].lower() in ev.slots(b[i],meta[i]) or correct(b[i],meta[i]) for i in ids)}
    for i in ids:
        if (a[i].get('c') or meta[i]['typed'])!=(b[i].get('c') or meta[i]['typed']):
            result['changes'].append({'id':i,'set':group,'typed':meta[i]['typed'],'target':meta[i]['target'],'baseline':a[i].get('c'),'candidate':b[i].get('c')})
(base/'decoder-comparison.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result['sets'],indent=2))
