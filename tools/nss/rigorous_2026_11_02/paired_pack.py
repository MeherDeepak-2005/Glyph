#!/usr/bin/env python3
"""Preserve the full shipped lexicon and add only words required by the paired neural vocabulary.
The complete evidence table remains available for broader lexical admission review.
"""
import argparse,csv,json,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2];sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'tools/nss'),str(ROOT/'tools/nss/research_2026_11_02')]
from verify_language_data import Pack
from nss.vocab import Vocabulary,sha256
from build_candidate_pack import build

def main():
    p=argparse.ArgumentParser();p.add_argument('--counts',type=Path,required=True);p.add_argument('--vocab',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();v=Vocabulary.load(a.vocab);source=ROOT/'keyboard/langdata.bin';existing={w.decode() for w in Pack(source).vocabulary()[0]};allowed=existing|set(v.words[4:]);filtered=a.out.with_suffix('.counts.tsv');excluded=[]
    with a.counts.open() as f,filtered.open('w') as out:
        rows=csv.DictReader(f,delimiter='\t');writer=csv.DictWriter(out,fieldnames=rows.fieldnames,delimiter='\t',lineterminator='\n');writer.writeheader()
        for row in rows:
            if row['word'] in allowed:writer.writerow(row)
            else:excluded.append(row['word'])
    info=build(source,filtered,a.out);info.update({'admission':'All shipped forms preserved; additional forms limited to the paired model vocabulary. Broader additions require separate lexical review.','vocabulary_sha256':v.sha256,'full_evidence_sha256':sha256(a.counts),'excluded_evidence_words':len(excluded),'excluded_examples':excluded[:50]});a.out.with_suffix('.manifest.json').write_text(json.dumps(info,indent=2)+'\n')
    actual={w.decode() for w in Pack(a.out).vocabulary()[0]}
    if not set(v.words[4:]).issubset(actual):raise RuntimeError('Model words absent from paired lexicon')
if __name__=='__main__':main()
