#!/usr/bin/env python3
"""Replay the saved CoreV4 executable and compare with the exact saved NSS touch arm.
Run from any directory. Quality only: timings from different runs are not compared.
"""
import pathlib, sys, json, subprocess, hashlib, shutil, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=pathlib.Path(__file__).resolve().parent
HERE=ROOT/'tools/evaluation/autocorrect'
sys.path.insert(0,str(HERE))
import evaluate as ev
BIN=HERE/'bin/corev4-bench'
REF='taps-final-nss-english'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def strict(p):
    rows={}; info=[]
    for line in p.read_text().splitlines():
        r=json.loads(line)
        if 'id' in r:
            assert r['id'] not in rows, (p,r['id'],'duplicate')
            assert r.get('ok')==1,(p,r)
            rows[r['id']]=r
        else: info.append(r)
    return rows,info
manifest={'core_configuration':'US engus, medium, learning off, characters only; saved executable, not rebuilt',
'nss_configuration':'saved taps-final-nss-english: installed nss-english model, product rules, new touch cost, simulated taps',
'files':{},'commands':[],'validation':{}}
core={}; nss={}; meta={}
with tempfile.TemporaryDirectory(prefix='corev4-nss-touch-') as tmp:
    profile=pathlib.Path(tmp)/'profile'
    shutil.copytree(HERE/'bin/corev4-profile',profile)
    for p in [profile/'Profile.ata',*profile.glob('Dictionaries/*.itn')]: p.unlink(missing_ok=True)
    for p in sorted(profile.rglob('*')):
        if p.is_file(): manifest['files'][str(p.relative_to(profile))]=sha(p)
    for stem,suffix in [('cases',''),('ext-cases','.ext'),('keep-cases','.keep')]:
        corpus=ev.CORPUS/(stem+'.tsv'); taps=ev.CORPUS/(stem+'.taps.tsv')
        lines=corpus.read_text().splitlines(); taplines=taps.read_text().splitlines()
        assert lines==['	'.join(l.split('	')[:5]) for l in taplines],stem
        target=OUT/('corev4'+suffix+'.jsonl')
        cmd=[str(BIN),str(profile),str(corpus),str(target),'engus','medium']
        manifest['commands'].append(cmd)
        print('Replay '+stem,flush=True)
        subprocess.run(cmd,check=True,stdout=subprocess.DEVNULL)
        cr,ci=strict(target)
        nr,ni=strict(ev.RESULTS/(REF+suffix+'.jsonl'))
        ids=[l.split('	')[0] for l in lines]
        assert list(cr)==ids and list(nr)==ids,(stem,'ID/order mismatch')
        assert next(r for r in ci if r['kind']=='done')['events']==len(ids)
        assert next(r for r in ni if r['kind']=='done')['events']==len(ids)
        assert next(r for r in ci if r['kind']=='startup')['english_first']
        assert not (set(core)&set(cr)),stem
        core.update(cr);nss.update(nr)
        mp=ev.CORPUS/(stem+'-meta.json' if stem!='cases' else 'cases-meta.json')
        meta.update(json.loads(mp.read_text()))
        manifest['validation'][stem]={'cases':len(ids),'all_statuses_ok':True,'same_ids_in_order':True,'tap_text_identical':True}
        for p in [corpus,taps,mp,target,ev.RESULTS/(REF+suffix+'.jsonl')]:manifest['files'][str(p)]=sha(p)
assert set(meta)==set(core)==set(nss)
held={i:m for i,m in meta.items() if m['set'] in ('hard','apos') or ev.half(m)=='held'}
report={'split':'existing target-word-disjoint held split; hard/apos fixtures included in full','total_cases':len(meta),'held_cases':len(held),'metrics':{}}
original=json.loads((ROOT/'docs/nss-paper/validation/rules-2026-11-01/score-taps-held.json').read_text())
for label,(ids,pred,up,guard) in ev.metrics(held).items():
    if not ids:continue
    cv=[bool(pred(core[i],held[i])) for i in ids];nv=[bool(pred(nss[i],held[i])) for i in ids]
    c=100*sum(cv)/len(ids);n=100*sum(nv)/len(ids)
    old=original['metrics'][label]
    assert old['n']==len(ids) and abs(old['rates'][REF]-n)<1e-10,label
    gains=sum(b and not a for a,b in zip(cv,nv));loss=sum(a and not b for a,b in zip(cv,nv))
    report['metrics'][label]={'n':len(ids),'corev4_pct':c,'nss_touch_pct':n,'nss_minus_core_pp':n-c,'higher_is_better':up,'core_events':sum(cv),'nss_events':sum(nv),'nss_true_core_false':gains,'core_true_nss_false':loss,'paired_mcnemar_p':ev.mcnemar(gains,loss)}
for p in [BIN,HERE/'CoreBench.cpp',HERE/'evaluate.py',ROOT/'keyboard/nss-english.nsslm',ROOT/'keyboard/langdata.bin',ROOT/'keyboard/safety.kbguard']:
    manifest['files'][str(p)]=sha(p)
report['limitations']=['CoreV4 receives characters only; NSS receives simulated taps. This is not a matched touch-input experiment.','Uses existing CoreV4 executable, not a fresh source build.','NSS saved outputs exactly reproduce the supplied reference table. Current uncommitted spatial-model changes are not evaluated.','Existing held split has already been inspected in development; not a new blind test.','No user-typing, physical-device latency, or memory comparison. McNemar p-values treat repeated rows as independent and are descriptive.','Unknown names and rare words are defined against the iOS vocabulary and may exist in CoreV4 dictionaries.']
(OUT/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(report,indent=2),flush=True)
