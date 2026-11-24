"""Speller search time per typed non-word (pure Python; held half, 2,000 words) and the size of its tables.

    python3 latency.py
"""
import pathlib, random, sys, time, tracemalloc
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import step1 as S1, speller as S
meta = S1.meta_all(); typed = S1.typed_non_words()
E = S1.E
pairs = S1.pairs(meta, lambda m: E.half(m) == 'tune')
t=time.time(); model = S.train(pairs); print('train', time.time()-t, 's', sum(map(len, model.values())), 'rules', len(model), 'betas')
words = S1.lexicon_words()
tracemalloc.start(); t=time.time(); sp = S.Speller(model, words); print('trie build', time.time()-t, 's', len(words), 'words', tracemalloc.get_traced_memory()[1]/1e6, 'MB py'); tracemalloc.stop()
held = sorted(i for i in typed if i in meta and E.half(meta[i]) == 'held')
random.seed(1); sample = random.sample(held, 2000)
# instrument pops
orig = S.heapq.heappop; cnt=[0]
def pop(h): cnt[0]+=1; return orig(h)
S.heapq.heappop = pop
times, pops, lens = [], [], []
for i in sample:
    w = typed[i]; cnt[0]=0; t=time.perf_counter(); sp.candidates(w, k=8); times.append((time.perf_counter()-t)*1e3); pops.append(cnt[0]); lens.append(len(w))
q = lambda xs, p: sorted(xs)[int(p*(len(xs)-1))]
print('ms p50 %.1f p90 %.1f p99 %.1f max %.1f' % (q(times,.5), q(times,.9), q(times,.99), max(times)))
print('pops p50 %d p90 %d p99 %d max %d; hit cap %.1f%%' % (q(pops,.5), q(pops,.9), q(pops,.99), max(pops), 100*sum(p>=30000 for p in pops)/len(pops)))
for L in (4,6,8,10,12):
    ts=[t for t,l in zip(times,lens) if L<=l<L+2]
    if ts: print(f'len {L}-{L+1}: n {len(ts)} p50 {q(ts,.5):.1f} ms p90 {q(ts,.9):.1f}')
