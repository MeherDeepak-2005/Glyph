#!/usr/bin/env python3
import json,os,subprocess,time,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
WORK=Path(json.loads((HERE/'workspace.json').read_text())['work'])
ARMS=json.loads((HERE/'arms.json').read_text())['arms']
ENV={k:v for k,v in os.environ.items() if not k.startswith('KB_')}
ENV['KB_NSS']=str(ROOT/'keyboard/nss-english.nsslm')
def complete(path):
 if not path.exists():return False
 with path.open('rb') as f:
  f.seek(max(0,path.stat().st_size-1024));return b'"kind":"done"' in f.read()
# Sequential timings start only after quality and sanitizer jobs finish.
while not all(complete(HERE/(n+'.jsonl')) for n in ARMS):time.sleep(3)
for k,name in enumerate(list(ARMS)+list(ARMS)[::-1]):
 path=HERE/f'latency-{k}-{name}.jsonl'
 subprocess.run([str(WORK/'experiment-bench'),str(ROOT/'keyboard/langdata.bin'),str(ROOT/'keyboard/safety.kbguard'),str(HERE/'latency.tsv'),str(path)],env={**ENV,**ARMS[name],'KB_FULL_PREFIXES':'1'},check=True)
 print('tap timing',k,name,flush=True)
for k,(name,mode) in enumerate([('current',0),('bikey_paper_g',3),('bikey_paper_g',3),('current',0)]):
 with (HERE/f'gesture-time-{k}-{name}.tsv').open('w') as out:
  subprocess.run([str(WORK/'gesture-bench'),str(ROOT/'keyboard/nss-english.nsslm'),str(ROOT/'keyboard/langdata.bin'),str(HERE/'gesture-stress.json'),str(mode)],stdout=out,env=ENV,check=True)
 print('gesture timing',k,name,flush=True)
(HERE/'timing-done.json').write_text(json.dumps({'complete':True})+'\n')
