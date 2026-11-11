#!/usr/bin/env python3
"""Build isolated copies and replay this experiment without changing production files.
Usage: python3 reproduce.py --out /private/tmp/bikey-replay --quality --tests --latency
"""
import argparse, concurrent.futures, hashlib, json, os, shutil, subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
ARMS=json.loads((HERE/'arms.json').read_text())['arms']
ENV={k:v for k,v in os.environ.items() if not k.startswith('KB_')}
ENV['KB_NSS']=str(ROOT/'keyboard/nss-english.nsslm')
def run(cmd,log,extra=None):
 with open(log,'w') as out:subprocess.run(list(map(str,cmd)),env={**ENV,**(extra or {})},stdout=out,stderr=subprocess.STDOUT,check=True)
def build(src,target,file,asan=False):
 flags=['-std=c++20','-O1' if asan else '-Os','-Wall','-Wextra','-Werror','-I',src/'native/DecoderCore/include']
 if asan:flags+=['-g','-fsanitize=address,undefined','-fno-omit-frame-pointer']
 if file.endswith('IOSBench.cpp'):flags+=['-DNDEBUG']
 run(['xcrun','clang++',*flags,src/file,*sorted((src/'native/DecoderCore/src').glob('*.cpp')),'-o',target],str(target)+'.build.log')
def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
 for name in ['quality','tests','latency']:ap.add_argument('--'+name,action='store_true')
 a=ap.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
 # Verify the model and lexicon used for the recorded comparison.
 provenance=json.loads((HERE/'provenance.json').read_text())
 for rel,key in [('keyboard/nss-english.nsslm','model_sha256'),('keyboard/langdata.bin','lexicon_sha256')]:
  if hashlib.sha256((ROOT/rel).read_bytes()).hexdigest()!=provenance[key]:raise SystemExit('Changed input: '+rel)
 # Refuse to silently overlay the implementation onto changed source.
 hashes=json.loads((HERE/'baseline-all-hashes.json').read_text())
 hashes.update(json.loads((HERE/'source-hashes.json').read_text())['baseline'])
 for name,expected in hashes.items():
  p=ROOT/name;actual=hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None
  if actual!=expected:raise SystemExit('Source differs from frozen baseline: '+name)
 src=out/'source';shutil.copytree(ROOT/'native',src/'native',dirs_exist_ok=True)
 (src/'tools/evaluation/autocorrect').mkdir(parents=True,exist_ok=True)
 shutil.copy2(ROOT/'tools/evaluation/autocorrect/IOSBench.cpp',src/'tools/evaluation/autocorrect/IOSBench.cpp')
 for p in (HERE/'implementation').rglob('*'):
  if p.is_file():dest=src/p.relative_to(HERE/'implementation');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
 bench=out/'experiment-bench';build(src,bench,'tools/evaluation/autocorrect/IOSBench.cpp')
 if a.quality:
  def quality(item):
   name,extra=item;run([bench,ROOT/'keyboard/langdata.bin',ROOT/'keyboard/safety.kbguard',HERE/'held.tsv',out/(name+'.jsonl')],out/(name+'.log'),extra)
  with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(quality,ARMS.items()))
 if a.tests:
  for name,file in [('bikey','BiKeyTests.cpp'),('graph','NeuralFstTests.cpp'),('engine','EngineTests.cpp')]:
   target=out/(name+'-tests');build(src,target,'native/tests/'+file,True)
   if name=='bikey':
    for arm,mode in [('current',0),('bikey',1),('paper_g',2),('bikey_paper_g',3)]:
     with (out/('glide-'+arm+'.tsv')).open('w') as stdout, (out/('glide-'+arm+'.log')).open('w') as stderr:
      subprocess.run(list(map(str,[target,ROOT/'keyboard/nss-english.nsslm',ROOT/'keyboard/langdata.bin',ROOT/'tools/evaluation/fixtures/shared-engine/glides.json',mode])),env=ENV,stdout=stdout,stderr=stderr,check=True)
   else:
    args=[ROOT/'keyboard/nss-english.nsslm',ROOT/'keyboard/langdata.bin'] if name=='graph' else [ROOT/'keyboard/langdata.bin',ROOT,ROOT/'tools/evaluation/fixtures/shared-engine']
    run([target,*args],out/(name+'-tests.log'))
 if a.latency:
  for k,name in enumerate(list(ARMS)+list(ARMS)[::-1]):
   run([bench,ROOT/'keyboard/langdata.bin',ROOT/'keyboard/safety.kbguard',HERE/'latency.tsv',out/(f'latency-{k}-{name}.jsonl')],out/(f'latency-{k}-{name}.log'),{**ARMS[name],'KB_FULL_PREFIXES':'1'})
 print(out)
if __name__=='__main__':main()
