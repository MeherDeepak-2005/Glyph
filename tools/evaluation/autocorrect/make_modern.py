#!/usr/bin/env python3
"""Original synthetic regression cases; not a human messaging benchmark.
Split by target (or phrase context) before comparing display calibration.
"""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/"docs/modern-vocabulary"
def main():
    rows=json.loads((ROOT/"tools/vocabulary/modern_catalog.json").read_text())["entries"]
    protected=[r["word"] for r in rows if r["preserve"]]
    contexts=json.loads((ROOT/"tools/vocabulary/modern_contexts.json").read_text())["contexts"]
    cases=[];meta={}
    def add(category,kind,ctx,typed,target,group):
        key=f"{category}-{sum(m['category']==category for m in meta.values()):04}"
        split="held" if int(hashlib.sha256(group.encode()).hexdigest()[:8],16)%2 else "development"
        cases.append("	".join((key,kind,ctx,typed,target)))
        meta[key]={"category":category,"kind":kind,"typed":typed,"target":target,"context":ctx,
            "split":split,"group":group,"source":"project-authored synthetic regression"}
    for term in protected:
        for ctx,typed in [("",term),("honestly",term),("you said",term.upper()),("they wrote",term.capitalize())]:
            add("preservation","ac",ctx,typed,term,term)
    # 50 terms * four cases: two prefixes and two small spelling slips.
    terms=[t for t in protected if len(t)>=3]
    for term in terms[:50]:
        for ctx,typed in [("",term[:-1]),("honestly",term[:max(3,len(term)-2)]),("",term[:-1]+term[-1]*2),("they said",term[:-2]+term[-1]+term[-2])]:
            add("completion","ac",ctx,typed,term,term)
    for r in contexts:
        for lead in ["","honestly ","they said ","i think "]:
            add("prediction","nw",lead+" ".join(r["context"]),"",r["next"]," ".join(r["context"]))
    regional="colour colours colourful favourite favourites neighbour neighbours flavour organise organised organising organisation recognise recognised centre centres theatre metre metres litre litres travelling travelled traveller cancelled cancelling programme programmes cheque grey tyre jewellery defence licence analyse aluminium mould mum maths prepone".split()
    for term in regional:
        for ctx in ["","please check","we discussed","i prefer","they mentioned"]:
            add("regional","ac",ctx,term,term,term)
    ordinary="please thanks thank hello tomorrow yesterday meeting appointment school family friend message receive correction because definitely possible important available appreciate sincerely regards welcome sorry help understand work home email happy ate cooked based mid slay aura bet cap grass rot".split()
    for term in ordinary:
        for ctx in ["","please discuss","the report says","we talked about","i remember"]:
            add("ordinary","ac",ctx,term,term,term)
    # Explicit collision/meaning and contraction controls, beyond the five 200-case slices.
    for ctx,typed,target in [("she","ate","ate"),("the food is","cooked","cooked"),("the report is","based","based"),
        ("wear a","cap","cap"),("i","dont","don't"),("i","cant","can't"),("","coeevitjkn","correction")]:
        add("controls","ac",ctx,typed,target,target)
    OUT.mkdir(exist_ok=True)
    (OUT/"cases.tsv").write_text("\n".join(cases)+"\n")
    (OUT/"cases-meta.json").write_text(json.dumps(meta,indent=2)+"\n")
    counts={c:sum(r["category"]==c for r in meta.values()) for c in sorted({r["category"] for r in meta.values()})}
    assert all(counts[c]>=200 for c in ("preservation","completion","prediction","regional","ordinary")),counts
    print(counts)
if __name__=="__main__":main()
