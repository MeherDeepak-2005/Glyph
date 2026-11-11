#!/usr/bin/env python3
import argparse,csv,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'tools/nss'));sys.path.insert(0,str(ROOT/'tools'))
from nss.vocab import Vocabulary,sha256
from verify_language_data import Pack
p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);a=p.parse_args()
pack=Pack(a.data/'langdata-candidate.bin');forms={w.decode() for w in pack.vocabulary()[0]};audit=json.loads((a.data/'audit.json').read_text());checks={}
for size in (30000,60000):
    v=Vocabulary.load(a.data/('vocabulary-'+str(size)+'.tsv'));assert len(v)==size+4;assert set(v.words[4:])<=forms
    assert v.sha256==audit['candidates'][str(size)]['sha256'];checks[str(size)]={'unique_words':size,'all_in_candidate_pack':True,'sha256':v.sha256}
rows=0
with (a.data/'unigrams.tsv').open() as f:
    for r in csv.DictReader(f,delimiter='\t'):
        assert int(r['observed_train_count'])==sum(int(r[n+'_count']) for n in ('soda','tatoeba','wikitext'))
        assert float(r['pooled_ppm'])>=0;rows+=1
checks['unigram_rows']=rows;checks['source_count_column_sums']='PASS'
checks['production_pack_unchanged']=sha256(ROOT/'keyboard/langdata.bin')==audit['production_pack_sha256']
checks['production_vocab_unchanged']=Vocabulary.load().sha256==audit['production_vocabulary_sha256']
assert checks['production_pack_unchanged'] and checks['production_vocab_unchanged']
(a.data/'validation.json').write_text(json.dumps(checks,indent=2)+'\n');print(json.dumps(checks,indent=2))
