#!/usr/bin/env python3
"""Report paired modern-vocabulary behavioral regressions separately from membership."""
import json
from pathlib import Path
HERE=Path(__file__).resolve().parents[3]/"docs/modern-vocabulary"
def main():
 meta=json.loads((HERE/"cases-meta.json").read_text());result={"limitations":"Project-authored synthetic cases. Phrase contexts overlap the editorial table; results establish regressions, not independent messaging accuracy.","tiers":{}}
 for tier in ("ngram","nss"):
  result["tiers"][tier]={}
  for split in ("development","held"):
   stats={}
   for side in ("baseline","candidate"):
    stats[side]={}
    for line in (HERE/f"{side}-{tier}.jsonl").read_text().splitlines():
     r=json.loads(line)
     if "id" not in r:continue
     m=meta[r["id"]]
     if m["split"]!=split:continue
     c=m["category"];s=stats[side].setdefault(c,{"cases":0,"successes":0})
     good=r["r0"]>=0 if m["kind"]=="nw" else m["target"] in r["s"] if c=="completion" else (r["c"] or m["typed"]).lower()==m["target"]
     s["cases"]+=1;s["successes"]+=good
   result["tiers"][tier][split]=stats
 (HERE/"behavior-results.json").write_text(json.dumps(result,indent=2)+"\n")
 print(json.dumps(result,indent=2))
if __name__=="__main__":main()
