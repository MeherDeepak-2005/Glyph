#!/usr/bin/env python3
"""Train-only, source-separated counts and a reproducible NSS vocabulary challenger.
Never overwrites the production vocabulary or pack. Run from any directory.
"""
from __future__ import annotations
import argparse, bz2, hashlib, heapq, json, math, re, sys, time
from collections import Counter, defaultdict
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / 'tools/nss'), str(ROOT / 'tools')]
from nss import sources
from nss.text import sentences
from nss.build_corpus import split_of, bucket
from nss.vocab import Vocabulary, sha256, SPECIALS
from verify_language_data import Pack
from vocabulary.build_nss_vocab import FORCED, map_frequency_words, read_frequency_list
WORD = re.compile(r"[a-z]+(?:'[a-z]+)*")
EXCLUDED = {'cant','dont','im','youre','lets','wont'}
# Diagnostic/editorial list; these are NOT counts and never enter evaluation text.
MODERN = '''covid coronavirus pandemic lockdown quarantine vaccine vaccinated vaccination booster
zoom slack discord whatsapp telegram signal tiktok instagram snapchat reddit youtube spotify netflix
streaming livestream livestreaming podcast podcasts influencer influencers creator creators content
chatbot chatbots chatgpt openai anthropic gemini copilot llm llms generative prompt prompts prompting
ai gpu gpus nvidia blockchain crypto bitcoin ethereum fintech wallet wallets contactless upi venmo
zelle doordash deliveroo uber lyft instacart airbnb staycation workcation remote hybrid async
onboarding offboarding reschedule scheduling calendar invite invites mute unmute screenshare screenshot
screenshots smartwatch earbuds airpods iphone android app apps login logout signup passkey passkeys
password passwords cybersecurity ransomware phishing malware deepfake deepfakes doomscrolling
ghosting gaslighting situationship lowkey highkey sus cringe vibe vibes vibing meme memes emoji emojis
lol lmao rofl idk tbh imo imho rn brb afk fyi asap btw ngl fr pov pls thx dm dms
biryani dosa idli chai paneer roti dal masala samosa chaat dosa sambar rasam dosa
vegan gluten keto oatmilk matcha kombucha sustainability reusable recyclable carbon emissions'''.split()
WEIGHTS = {'frequency-words': .30, 'soda': .40, 'tatoeba': .15, 'wikitext': .15}

def digest_text(text): return hashlib.sha256(text.encode()).hexdigest()
def coverage(counts, vocabulary, lexicon):
    n=sum(counts.values()); known=sum(c for w,c in counts.items() if w in vocabulary)
    return {'tokens':n, 'vocabulary_tokens':known, 'coverage':known/max(1,n),
            'lexicon_coverage':sum(c for w,c in counts.items() if w in lexicon)/max(1,n),
            'top_missing': counts.most_common()[:0] + [[w,c] for w,c in counts.most_common() if w not in vocabulary][:60]}
def sample_add(heap, limit, source, key, i, words):
    if not 2 <= len(words) <= 80: return
    # Stable bottom-hash sample, independent of corpus iteration order.
    score=int.from_bytes(hashlib.sha256((source+'|'+key+'|'+str(i)).encode()).digest()[:8], 'little')
    row=(-score, ' '.join(words))
    if len(heap)<limit: heapq.heappush(heap,row)
    elif row>heap[0]: heapq.heapreplace(heap,row)
def build(out, sample_limit):
    out.mkdir(parents=True,exist_ok=True)
    pack=Pack(ROOT/'keyboard/langdata.bin'); forms,freqs=pack.vocabulary()
    oldfreq={w.decode():f for w,f in zip(forms,freqs)}
    lexicon={w for w in oldfreq if WORD.fullmatch(w)}
    old=Vocabulary.load(); oldset=set(old.words[4:]); modern=set(MODERN)
    counters={}; dfs={}; samples={}; meta={}; started=time.time(); seen=set()
    for name,reader in [('soda',sources.soda),('tatoeba',sources.tatoeba),('wikitext',sources.wikitext)]:
        cache=out/(name+'.counts.json')
        cs={s:Counter() for s in ('train','valid','test')}; df=Counter(); heaps={s:[] for s in cs}; ndocs=Counter(); skipped=0
        for number,(key,text) in enumerate(reader(),1):
            # Follow v2's stock-name sentence subsampling, without inventing counts.
            if name=='tatoeba' and ('tom' in text.lower().split() or 'mary' in text.lower().split()) and bucket('stock|'+key)%1000 >= 250:
                skipped+=1; continue
            split=split_of(key); docwords=[]
            for i,ws in enumerate(sentences(text)):
                ws=[w.strip("'") for w in ws if w.strip("'")]
                normalized=' '.join(ws); d=hashlib.sha256(normalized.encode()).digest()[:16]
                # A global digest set prevents exact sentence overlap across sources/splits.
                # The first document owns a duplicate; later copies are omitted.
                token=d
                if token in seen: continue
                seen.add(token); cs[split].update(ws); docwords.extend(ws)
                sample_add(heaps[split], sample_limit if split=='train' else 1200, name,key,i,ws)
            if docwords:
                ndocs[split]+=1
                if split=='train': df.update(set(docwords))
            if number%50000==0: print(json.dumps({'source':name,'documents':number,'seconds':round(time.time()-started)}),flush=True)
        inputs={'soda':sources.SODA,'tatoeba':[sources.TATOEBA],'wikitext':sources.WIKITEXT}[name]
        info={'documents':dict(ndocs),'unique_sentences_cumulative':len(seen),
              'stock_documents_skipped':skipped,'inputs':[{'path':str(p.relative_to(ROOT)),'sha256':sha256(p)} for p in inputs]}
        # Raw text samples stay in ignored local cache, never bundled with the app.
        for split,heap in heaps.items():
            with bz2.open(out/(name+'.'+split+'.sentences.bz2'),'wt') as f:
                for score,text in sorted(heap,reverse=True): f.write(text+'\n')
        cache.write_text(json.dumps({'counts':cs,'df':df,'meta':info}))
        counters[name]=cs; dfs[name]=df; meta[name]=info
        print(name, {s:sum(c.values()) for s,c in cs.items()},flush=True)
    evidence=Counter()
    for cs in counters.values(): evidence.update(cs['train'])
    fwtotal=sum(c for w,c in read_frequency_list(ROOT/'tools/.cache/en_full.txt') if WORD.fullmatch(w))
    # Keep integer raw subtitle counts separate: apostrophe mapping is a fractional estimate.
    fwraw=Counter(dict(read_frequency_list(ROOT/'tools/.cache/en_full.txt')))
    mapped,_=map_frequency_words(list(fwraw.items()),lexicon|modern,evidence)
    trains={n:cs['train'] for n,cs in counters.items()}; trains['frequency-words']=mapped
    totals={n:(fwtotal if n=='frequency-words' else sum(c.values())) for n,c in trains.items()}
    candidates=set(lexicon)
    admitted=[]
    for w in sorted(modern-lexicon):
        count=sum(c[w] for n,c in trains.items() if n!='frequency-words')
        docs=sum(d[w] for d in dfs.values())
        if WORD.fullmatch(w) and w not in EXCLUDED and count>=5 and docs>=3:
            candidates.add(w); admitted.append(w)
    pooled={w:sum(WEIGHTS[n]*c[w]/max(1,totals[n])*1e6 for n,c in trains.items()) for w in candidates}
    forced=set(FORCED)&candidates
    eligible=[]
    for w in candidates-EXCLUDED:
        supporting=sum(c[w]>=3 for c in trains.values())
        soda_ok=trains['soda'][w]>=25 and dfs['soda'][w]>=10
        if w in forced or supporting>=2 or soda_ok or (w in modern and sum(c[w] for c in trains.values())>=5): eligible.append(w)
    ranked=sorted(eligible,key=lambda w:(-pooled[w],w))
    results={}; chosen={}
    for size in (30000,60000):
        selected=forced|set([w for w in ranked if w not in forced][:size-len(forced)])
        selected=sorted(selected,key=lambda w:(-pooled[w],w)); chosen[size]=set(selected)
        path=out/('vocabulary-'+str(size)+'.tsv')
        with path.open('w') as f:
            f.write('id\tword\tscore_ppm\tsources\n')
            for i,w in enumerate(list(SPECIALS)+selected):
                f.write(str(i)+'\t'+w+'\t'+format(pooled.get(w,0),'.8f')+'\t'+','.join(n for n,c in trains.items() if c[w])+'\n')
        results[str(size)]={'words':len(selected),'sha256':sha256(path),'added':sorted(set(selected)-oldset),'removed':sorted(oldset-set(selected)),
                           'validation':{n:coverage(cs['valid'],set(selected),candidates) for n,cs in counters.items()}}
    fields=['word','pooled_ppm','observed_train_count','soda_count','tatoeba_count','wikitext_count','soda_docs','tatoeba_docs','wikitext_docs','subtitle_raw_exact_count','subtitle_mapped_estimate','old_pack_weight']
    with (out/'unigrams.tsv').open('w') as f:
        f.write('\t'.join(fields)+'\n')
        for w in sorted(candidates,key=lambda w:(-pooled[w],w)):
            counts=[trains[n][w] for n in ('soda','tatoeba','wikitext')]
            row=[w,format(pooled[w],'.8f'),sum(counts),*counts,*[dfs[n][w] for n in ('soda','tatoeba','wikitext')],fwraw[w],format(mapped[w],'.4f'),oldfreq.get(w,0)]
            f.write('\t'.join(map(str,row))+'\n')
    masc=Counter(w for _,ws,_ in sources.masc_heldout() for w in ws if w is not None)
    result={'schema_version':1,'status':'research candidate; not installed','production_vocabulary_sha256':old.sha256,
            'production_pack_sha256':sha256(ROOT/'keyboard/langdata.bin'),'old_manifest':json.loads((ROOT/'tools/data/nss/english-nss-vocab-30k.json').read_text()),
            'weights':WEIGHTS,'counts_are':'Observed train-only tokens per source; pooled_ppm and subtitle_mapped_estimate are estimates, not occurrence counts.',
            'split_policy':'Existing document-key sha256 mod 200: valid=0, test=1; selection uses train only. Exact sentence dedup globally across sources; first document owns duplicates.',
            'source_totals':totals,'sources':meta,'old_validation':{n:coverage(cs['valid'],oldset,lexicon) for n,cs in counters.items()},
            'old_masc':coverage(masc,oldset,lexicon),'candidates':results,'modern_lexicon_additions':admitted,
            'modern_diagnostic':[{'word':w,'old_vocab':w in oldset,'old_lexicon':w in lexicon,'new_vocab':w in chosen[30000],
                                  'observed_train_count':sum(c[w] for n,c in trains.items() if n!='frequency-words'),'pooled_ppm':pooled.get(w,0)} for w in sorted(modern)],
            'modern_diagnostic_warning':'Editorial probes overlap vocabulary admission policy and are not an independent test set.',
            'old_pack_floor_words':sum(v<=1 for v in oldfreq.values()),'seconds':time.time()-started}
    for size,vs in chosen.items(): result['candidates'][str(size)]['masc']=coverage(masc,vs,candidates)
    (out/'audit.json').write_text(json.dumps(result,indent=2)+'\n')
    print('AUDIT COMPLETE',json.dumps({k:{'words':v['words'],'masc_coverage':v['masc']['coverage']} for k,v in results.items()}),flush=True)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=ROOT/'tools/.cache/dictionary-research-2026-11-02');p.add_argument('--sample-limit',type=int,default=40000);a=p.parse_args();build(a.out,a.sample_limit)
