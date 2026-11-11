#!/usr/bin/env python3
"""Train-only capitalization evidence for dictionary review, not automatic deletion.
Counts are sampled raw-source observations and explicitly separate from retained corpus counts.
"""
import argparse,collections,json,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2];sys.path[:0]=[str(HERE),str(ROOT/'tools/nss')]
from corpus import documents
from nss.text import cased_sentences
from nss.build_corpus import split_of,bucket,NOT_NAMES
from nss.vocab import Vocabulary,sha256

def main():
    p=argparse.ArgumentParser();p.add_argument('--corpus',type=Path,required=True);p.add_argument('--dictionary',type=Path,required=True);p.add_argument('--modern',type=Path,nargs='*',default=[]);a=p.parse_args();counts=collections.defaultdict(lambda:[0,0]);vocab=Vocabulary.load(a.dictionary/'vocabulary-60000.tsv');names=json.loads((a.corpus/'corpus.json').read_text())['sources']
    for source in names:
        for key,text in documents(source,a.modern):
            if split_of(key)!='train' or bucket('names|'+key)%20:continue
            for sentence in cased_sentences(text):
                for word,capitalized in sentence[1:]:
                    if word in vocab.index and word not in NOT_NAMES:counts[word][0]+=capitalized;counts[word][1]+=1
    out=a.dictionary/'capitalization-review.tsv'
    with out.open('w') as f:
        f.write('word\tsampled_capitalized_inside_sentence\tsampled_occurrences_inside_sentence\tcapitalized_ratio\tlikely_name_or_brand\n')
        for word,(cap,total) in sorted(counts.items(),key=lambda r:(-r[1][1],r[0])):
            if total>=10:f.write(f'{word}\t{cap}\t{total}\t{cap/total:.6f}\t{int(cap/total>=.9)}\n')
    (a.dictionary/'capitalization-review.json').write_text(json.dumps({'sampling':'One raw training document in 20 by document-key hash; sentence-initial words excluded. Exact dedup is not applied to these review observations.','semantics':'Review evidence only; not counts used by the dictionary. Capitalization marks both names and brands; no automatic removal.','test_accessed':False,'sha256':sha256(out)},indent=2)+'\n');print('NAMES REVIEW COMPLETE',flush=True)
if __name__=='__main__':main()
