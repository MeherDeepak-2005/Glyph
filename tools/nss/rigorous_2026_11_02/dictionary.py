#!/usr/bin/env python3
"""Tune vocabulary mixtures on validation only; preserve actual counts per source.
Outputs are isolated. Modern probes, test counts and MASC never enter admission/ranking.
"""
import argparse,collections,csv,gzip,itertools,json,math,re,sqlite3,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'tools/nss')]
from nss.vocab import Vocabulary,SPECIALS,sha256
from verify_language_data import Pack
from vocabulary.build_nss_vocab import FORCED,map_frequency_words,read_frequency_list
WORD=re.compile(r"[a-z]+(?:'[a-z]+)*$")
BAD={'cant','dont','im','youre','lets','wont'}

def main():
    p=argparse.ArgumentParser();p.add_argument('--corpus',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    pack=Pack(ROOT/'keyboard/langdata.bin');forms,freqs=pack.vocabulary();old={w.decode():n for w,n in zip(forms,freqs)};oldv=Vocabulary.load()
    counts={};source_names=json.loads((a.corpus/'corpus.json').read_text())['sources']
    with gzip.open(a.corpus/'counts.tsv.gz','rt') as f:
        for row in csv.DictReader(f,delimiter='\t'):counts[row['word']]={k:int(v) for k,v in row.items() if k!='word'}
    raw_rows=read_frequency_list(ROOT/'tools/.cache/en_full.txt');raw=collections.Counter()
    for word,count in raw_rows:raw[word]+=count
    lexicon={w for w in old if WORD.fullmatch(w)}
    additions={w for w,r in counts.items() if w not in lexicon and WORD.fullmatch(w) and len(w)<=24 and w not in BAD and r['observed_train_count']>=50 and sum(r[s+'_docs'] for s in source_names)>=10 and (sum(r[s+'_count']>0 for s in source_names)>=2 or (r.get('fineweb_count',0)>=100 and r.get('fineweb_docs',0)>=25))}
    eligible=lexicon|additions;fw,fwtotal=map_frequency_words(raw_rows,eligible,collections.Counter({w:r['observed_train_count'] for w,r in counts.items()}));sources={s:{w:r[s+'_count'] for w,r in counts.items()} for s in source_names};sources['subtitle']=fw
    totals={s:sum(c.values()) for s,c in sources.items()};totals['subtitle']=fwtotal;rates={s:{w:1e6*c.get(w,0)/max(1,totals[s]) for w in eligible} for s,c in sources.items()}
    db=sqlite3.connect(a.corpus/'corpus.sqlite');valid={s:collections.Counter() for s in source_names}
    # Entire retained validation set, rather than 120 hand-sized samples.
    for s,text in db.execute('SELECT source,text FROM sentences WHERE split="valid"'):valid[s].update(text.split())
    forced=set(FORCED)&eligible
    def coverage(words):return {s:sum(c for w,c in cs.items() if w in words or w.strip("'") in words)/max(1,sum(cs.values())) for s,cs in valid.items()}
    def rank(weights):
        score={w:sum(weights[s]*rates[s][w] for s in weights) for w in eligible}
        return sorted(eligible-forced-BAD,key=lambda w:(-score[w],w)),score
    # Register all grid points, tie-break deterministically. Validation tunes only a vocabulary per size.
    trials=[];best={};grid=list(itertools.product([.25,.50,.75],[.15,.30],[.15,.30],[.10,.25]))
    for values in grid:
        weights=dict(zip(['soda','tatoeba','wikitext','subtitle'],values))
        if 'fineweb' in sources:weights['fineweb']=.35
        total=sum(weights.values());weights={s:w/total for s,w in weights.items()};order,score=rank(weights);trial={'weights':weights,'sizes':{}}
        for size in [30000,45000,60000]:
            words=forced|set(order[:size-len(forced)]);cv=coverage(words);macro=sum(cv.values())/len(cv);trial['sizes'][str(size)]={'validation_coverage':cv,'macro':macro}
            if size not in best or macro>best[size]['macro']+1e-12:best[size]={'weights':weights,'words':words,'order':order,'score':score,'coverage':cv,'macro':macro}
        trials.append(trial)
    with (a.out/'unigrams.tsv').open('w') as f:
        columns=['word','pooled_ppm','observed_train_count',*[s+'_count' for s in source_names],*[s+'_docs' for s in source_names],'subtitle_raw_exact_count','subtitle_mapped_estimate','old_pack_weight']
        f.write('\t'.join(columns)+'\n')
        for w in sorted(eligible,key=lambda w:(-best[30000]['score'][w],w)):
            r=counts.get(w,{})
            f.write('\t'.join(map(str,[w,format(best[30000]['score'][w],'.8f'),r.get('observed_train_count',0),*[r.get(s+'_count',0) for s in source_names],*[r.get(s+'_docs',0) for s in source_names],raw.get(w,0),format(fw.get(w,0),'.4f'),old.get(w,0)]))+'\n')
    report={'counts':'Observed counts are exact retained training occurrences. pooled_ppm is a tuned source-mixture estimate, not a raw count. Subtitle mapping is an estimate; raw exact subtitle counts are separate.',
        'input_corpus_sha256':sha256(a.corpus/'corpus.json'),'count_table_sha256':sha256(a.corpus/'counts.tsv.gz'),'subtitle_file_sha256':sha256(ROOT/'tools/.cache/en_full.txt'),
        'admission':'Existing ASCII lexicon plus words with >=50 train occurrences, >=10 document occurrences summed by source, >=2 sources or FineWeb >=100 occurrences across >=25 documents; no editorial modern probes.',
        'lexicon_additions':sorted(additions),'source_token_totals':totals,'old_validation_coverage':coverage(set(oldv.words[4:])),'grid':trials,'selected':{},'test_accessed':False,'production_ready':False}
    for size,v in best.items():
        ordered=sorted(forced,key=lambda w:(-v['score'][w],w))+[w for w in v['order'] if w in v['words']]
        path=a.out/f'vocabulary-{size}.tsv'
        with path.open('w') as f:
            f.write('id\tword\tpooled_ppm\n')
            for i,w in enumerate(list(SPECIALS)+ordered):f.write(f'{i}\t{w}\t{v["score"].get(w,0):.8f}\n')
        if len(set(ordered))!=size:raise RuntimeError('Vocabulary size/uniqueness failed')
        report['selected'][str(size)]={'words':size,'weights':v['weights'],'validation_coverage':v['coverage'],'sha256':sha256(path),'added':len(v['words']-set(oldv.words[4:])),'removed':len(set(oldv.words[4:])-v['words'])}
        # Explicit review surface: rare evidence, forms, likely names supplied separately by names audit.
        with (a.out/f'review-{size}.tsv').open('w') as f:
            f.write('word\taction\tobserved_train_count\tdocument_occurrences_sum\tflags\n')
            for w in ordered:
                r=counts.get(w,{});n=r.get('observed_train_count',0);nd=sum(r.get(s+'_docs',0) for s in source_names);flags=[]
                if n<20:flags.append('rare')
                if len(w)>20:flags.append('long')
                if "'" in w:flags.append('apostrophe')
                if w.endswith(('s','ed','ing')):flags.append('morphology')
                if w not in oldv.index or flags:f.write(f'{w}\t'+('added' if w not in oldv.index else 'retained')+f'\t{n}\t{nd}\t'+','.join(flags)+'\n')
    (a.out/'dictionary.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k in ['selected','old_validation_coverage','lexicon_additions']}),flush=True)
if __name__=='__main__':main()
