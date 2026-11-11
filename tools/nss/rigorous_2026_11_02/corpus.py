#!/usr/bin/env python3
"""Full-cache preparation: document splits first, holdout-precedence global exact dedup.
All accepted sentences and source counts are retained; no 40k-sentence reservoir.
"""
import argparse,collections,gzip,hashlib,json,sqlite3,sys,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'tools/nss'))
from nss import sources
from nss.text import sentences
from nss.build_corpus import split_of,bucket
from nss.vocab import sha256

def normalized(text):return [' '.join(s) for s in sentences(text) if s]
def digest(text):return hashlib.sha256(text.encode()).digest()
def documents(source,modern):
    if source=='soda':yield from sources.soda()
    elif source=='tatoeba':yield from sources.tatoeba()
    elif source=='wikitext':yield from sources.wikitext()
    elif source=='fineweb':
        import pyarrow.parquet as pq
        for manifest in modern:
            m=json.loads(manifest.read_text());assert m['status']=='downloaded'
            path=manifest.parent/m['file'];assert sha256(path)==m['sha256']
            for batch in pq.ParquetFile(path).iter_batches(batch_size=2048,columns=['text','url']):
                for row in batch.to_pylist():yield row['url'].split('#')[0].rstrip('/'),row['text']

def prepare(out,modern):
    out.mkdir(parents=True,exist_ok=True);dbpath=out/'corpus.sqlite';done=out/'corpus.json'
    if dbpath.exists() or done.exists():raise SystemExit('Refusing partial/existing corpus; use a fresh output directory.')
    db=sqlite3.connect(dbpath);db.executescript('PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-1048576; PRAGMA temp_store=FILE; CREATE TABLE documents(hash BLOB PRIMARY KEY,source TEXT,key TEXT,split TEXT); CREATE TABLE sentences(hash BLOB PRIMARY KEY,source TEXT,doc BLOB,split TEXT,text TEXT,words INTEGER); CREATE TABLE excluded(hash BLOB PRIMARY KEY);')
    # Existing MASC test text is always excluded from new training. Prior evaluation makes it diagnostic, not a fresh final test.
    for _,ws,_ in sources.masc_heldout():
        if None not in ws:db.execute('INSERT OR IGNORE INTO excluded VALUES(?)',(digest(' '.join(ws)),))
    names=['soda','tatoeba','wikitext']+(['fineweb'] if modern else []);stats=collections.Counter();counts={s:collections.Counter() for s in names};dfs={s:collections.Counter() for s in names};started=time.time()
    # Process all held-out documents before any training document so exact holdout text cannot enter train.
    for phase in ['heldout','train']:
        for source in names:
            for number,(key,text) in enumerate(documents(source,modern),1):
                split=split_of(key)
                if (phase=='train')!=(split=='train'):continue
                strings=normalized(text)
                if source=='tatoeba' and any({'tom','mary'}.intersection(s.split()) for s in strings) and bucket('stock|'+key)%1000>=250:continue
                if not strings:continue
                dh=digest('\n'.join(strings))
                if not db.execute('INSERT OR IGNORE INTO documents VALUES(?,?,?,?)',(dh,source,key,split)).rowcount:
                    stats[f'{source}.{split}.duplicate_documents']+=1;continue
                docwords=set()
                for s in strings:
                    h=digest(s);nw=len(s.split())
                    if split=='train' and db.execute('SELECT 1 FROM excluded WHERE hash=?',(h,)).fetchone():
                        stats[f'{source}.train.masc_overlap_removed']+=1;continue
                    if not db.execute('INSERT OR IGNORE INTO sentences VALUES(?,?,?,?,?,?)',(h,source,dh,split,s,nw)).rowcount:
                        stats[f'{source}.{split}.duplicate_sentences']+=1;continue
                    stats[f'{source}.{split}.sentences']+=1;stats[f'{source}.{split}.words']+=nw
                    if split=='train':counts[source].update(s.split());docwords.update(s.split())
                if split=='train':dfs[source].update(docwords)
                if number%5000==0:db.commit()
                if number%100000==0:print(json.dumps({'phase':phase,'source':source,'documents_read':number,'seconds':round(time.time()-started)}),flush=True)
            db.commit();print(json.dumps({'phase_complete':phase,'source':source,'seconds':round(time.time()-started)}),flush=True)
    db.executescript('CREATE INDEX sample_idx ON sentences(source,split,hash);');db.commit()
    allwords=set().union(*(set(c) for c in counts.values()))
    with gzip.open(out/'counts.tsv.gz','wt') as f:
        f.write('word\tobserved_train_count\t'+'\t'.join(s+'_count\t'+s+'_docs' for s in names)+'\n')
        for w in sorted(allwords):f.write(w+'\t'+str(sum(counts[s][w] for s in names))+'\t'+'\t'.join(str(counts[s][w])+'\t'+str(dfs[s][w]) for s in names)+'\n')
    inputs={'soda':sources.SODA,'tatoeba':[sources.TATOEBA],'wikitext':sources.WIKITEXT}
    provenance={s:[{'path':str(p.relative_to(ROOT)),'sha256':sha256(p)} for p in ps] for s,ps in inputs.items()}
    result={'schema':3,'preparer_sha256':sha256(Path(__file__)),'sources':names,'stats':dict(stats),'input_files':provenance,'modern_manifests':[json.loads(p.read_text()) for p in modern],
        'split':'Original sha256(document key) mod 200: valid=0,test=1,else=train; exact normalized documents grouped; holdout precedence; global exact normalized sentence dedup.',
        'limitations':['No user IDs in cached sources; split unit is dialogue/article/text document.','Exact dedup only; near duplicates not certified absent.','Legacy baseline may have seen cross-document duplicates; new training excludes all retained holdout sentences.','Cached heldouts have prior research exposure; no blind modern final test is available.'],
        'training_tokens':sum(v for k,v in stats.items() if k.endswith('.train.words')),'counts_sha256':sha256(out/'counts.tsv.gz'),'seconds':time.time()-started,
        'test_sealed':True,'test_evaluation_performed':False}
    done.write_text(json.dumps(result,indent=2)+'\n');db.execute('PRAGMA wal_checkpoint(TRUNCATE)');db.close();print('PREPARE COMPLETE',json.dumps(result),flush=True)

def sample(dbpath,out,budget,seed):
    import numpy as np
    db=sqlite3.connect(dbpath);names=json.loads((dbpath.parent/'corpus.json').read_text())['sources'];weights={'soda':.40,'tatoeba':.15,'wikitext':.15,'fineweb':.30} if 'fineweb' in names else {'soda':.50,'tatoeba':.25,'wikitext':.25};rows=[];totals={};limit=budget
    for source,weight in weights.items():
        # Digest order gives a stable global sample of the full source, without replacement.
        count=0;target=round(limit*weight)
        for h,doc,text,nw in db.execute('SELECT hash,doc,text,words FROM sentences WHERE source=? AND split="train" ORDER BY hash',(source,)):
            if nw>128:continue
            rows.append({'source':source,'doc':doc.hex(),'hash':h.hex(),'text':text,'words':nw});count+=nw
            if count>=target:break
        if count<target:raise RuntimeError(f'{source}: insufficient unique training words ({count} < {target})')
        totals[source]=count
    rng=np.random.default_rng(seed);rng.shuffle(rows);out.parent.mkdir(parents=True,exist_ok=True)
    with gzip.open(out,'wt') as f:
        for row in rows:f.write(json.dumps(row,ensure_ascii=False)+'\n')
    manifest={'words':sum(totals.values()),'by_source':totals,'sentences':len(rows),'unique_sentences':len({r['hash'] for r in rows}),'seed':seed,'sha256':sha256(out),'input_corpus':sha256(dbpath.parent/'corpus.json'),'without_replacement':True,'sentence_max_words':128,'test_accessed':False}
    out.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest),flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='command',required=True)
    q=sub.add_parser('prepare');q.add_argument('--out',type=Path,required=True);q.add_argument('--modern',type=Path,nargs='*',default=[])
    q=sub.add_parser('sample');q.add_argument('--db',type=Path,required=True);q.add_argument('--out',type=Path,required=True);q.add_argument('--words',type=int,required=True);q.add_argument('--seed',type=int,default=731)
    a=p.parse_args()
    if a.command=='prepare':prepare(a.out,a.modern)
    else:sample(a.db,a.out,a.words,a.seed)
