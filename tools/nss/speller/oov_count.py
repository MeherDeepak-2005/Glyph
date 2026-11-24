"""Out-of-vocabulary count: how many performance-test failures have a target outside the NSS 30k vocabulary."""
import collections, json, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(REPO/'tools/evaluation/autocorrect'), str(REPO/'tools/nss/wsp')]
import evaluate as E
import nsslm

RUN = sys.argv[1] if len(sys.argv) > 1 else 'prod-2026-11-22-0249'

model = nsslm.load(REPO/'keyboard/nss-english.nsslm')
vocab = set(model.words[4:])
vocab_lower = {w.lower() for w in vocab}
lexicon = set()
for line in open(REPO/'tools/data/nss/unigram-v1/unigrams.tsv', encoding='utf-8'):
    w = line.split('\t', 1)[0]
    if w != 'word': lexicon.add(w)
lexicon_lower = {w.lower() for w in lexicon}

def tokens(t): return t.split()

def klass(target):
    """nss: every token in the 30k NSS vocab; lex: some token only in the 187k dictionary; none: some token in neither."""
    worst = 'nss'
    for tok in tokens(target):
        if tok in vocab or tok.lower() in vocab_lower: continue
        if tok in lexicon or tok.lower() in lexicon_lower: worst = 'lex' if worst == 'nss' else worst; continue
        return 'none'
    return worst

meta = {}
for p in [E.CORPUS/'cases-meta.json', *sorted(E.CORPUS.glob('*-cases-meta.json'))]: meta.update(json.loads(p.read_text()))
meta = {i: m for i, m in meta.items() if m['set'] in ('hard', 'apos') or E.half(m) == 'held'}
rows = E.load(E.RESULTS/'performance-tests'/f'{RUN}.jsonl')[0]
metrics = E.metrics(meta)

print(f'run {RUN}; NSS vocab {len(vocab):,} words; dictionary {len(lexicon):,} words\n')
print('Accuracy metrics: failures split by where the TARGET word lives')
print(f'{"metric":40}{"n":>6}{"fail":>6} | {"fail: in NSS":>13}{"dict only":>10}{"neither":>9} | {"fix% NSS":>9}{"dict only":>10}{"neither":>9}')
total = collections.Counter(); total_fail = collections.Counter(); nb = collections.Counter()
for label, (ids, pred, up, guard) in metrics.items():
    if not up or guard and label != 'GUARD contractions restored' or label.startswith('  ') or 'top 3' in label: continue
    ids = [i for i in ids if i in rows]
    if not ids: continue
    n = collections.Counter(); ok = collections.Counter(); fail = collections.Counter()
    for i in ids:
        k = klass(meta[i]['target']); n[k] += 1
        if pred(rows[i], meta[i]): ok[k] += 1
        else: fail[k] += 1
    nf = sum(fail.values())
    rate = lambda k: f'{100*ok[k]/n[k]:.1f}% ({n[k]})' if n[k] else '-'
    print(f'{label.strip():40}{len(ids):>6}{nf:>6} | {fail["nss"]:>13}{fail["lex"]:>10}{fail["none"]:>9} | {rate("nss"):>9} {rate("lex"):>10} {rate("none"):>9}')
    if 'first' in label: continue
    gain = (n['lex'] * ok['nss'] / n['nss'] - ok['lex']) if n['nss'] and n['lex'] else 0
    print(f'{"":40}   ceiling if dict-only targets fixed at the in-vocab rate: +{max(gain,0):.0f} cases = +{100*max(gain,0)/len(ids):.2f} pt')
    total.update(n); total_fail.update(fail)
    if 'birkbeck' not in label: nb.update(fail)
nf = sum(total_fail.values())
print(f'\nall accuracy failures: {nf}; target in NSS vocab {total_fail["nss"]} ({100*total_fail["nss"]/nf:.1f}%), '
      f'dictionary only {total_fail["lex"]} ({100*total_fail["lex"]/nf:.1f}%), in neither {total_fail["none"]} ({100*total_fail["none"]/nf:.1f}%)')
print(f'without Birkbeck: {sum(nb.values())} failures; in NSS vocab {nb["nss"]} ({100*nb["nss"]/sum(nb.values()):.1f}%), dictionary only {nb["lex"]} ({100*nb["lex"]/sum(nb.values()):.1f}%), neither {nb["none"]}')
print(f'all accuracy cases: target in NSS vocab {total["nss"]}, dictionary only {total["lex"]}, neither {total["none"]}')

print('\nGuardrails: typed word should be kept; changed rate by where the TYPED word lives')
for label in ('GUARD unknown names changed', 'GUARD unknown slang changed', 'GUARD rare dictionary words changed',
              'GUARD Tenglish words changed', 'GUARD hard valid words changed', 'GUARD false corrections, ECPS correct'):
    if label not in metrics: continue
    ids, pred, _, _ = metrics[label]; ids = [i for i in ids if i in rows]
    n = collections.Counter(); bad = collections.Counter()
    for i in ids:
        k = klass(meta[i]['typed']); n[k] += 1; bad[k] += bool(pred(rows[i], meta[i]))
    cells = '  '.join(f'{k}: {bad[k]}/{n[k]} ({100*bad[k]/n[k]:.0f}%)' for k in ('nss', 'lex', 'none') if n[k])
    print(f'{label:40}{len(ids):>6}  {cells}')
