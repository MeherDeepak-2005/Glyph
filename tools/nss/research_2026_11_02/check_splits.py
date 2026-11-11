import sys,json,pathlib,hashlib
sys.path.insert(0,'tools/nss/research_2026_11_02');from train_challengers import *
p=Path('tools/.cache/dictionary-research-2026-11-02');s=load_sets(p);tr=set(x for rows in s['train'].values() for x in rows)
external=set(' '.join(w for w in ws if w is not None) for _,ws,_ in sources.masc_heldout() if None not in ws)
r={'sample_train_sentences':len(tr),'sample_eval_overlaps':{k:{n:len(tr&set(rows)) for n,rows in v.items()} for k,v in s.items() if k!='train'},'all_masc_overlap':len(tr&external),'overlap_examples':sorted(tr&external)[:20]}
(p/'split-overlap.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))
