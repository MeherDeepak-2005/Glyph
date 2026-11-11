#!/usr/bin/env python3
"""Local screening coordinator. No cloud calls, final-test evaluation or installation."""
import argparse,datetime,json,os,subprocess,sys,time,traceback
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2]
def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);a=p.parse_args();a.data.mkdir(parents=True,exist_ok=True)
    state={'pid':os.getpid(),'status':'running','phase':'waiting-for-corpus','cloud_spend':0,'promotion_allowed':False}
    def update(phase,status='running',**extra):
        state.update({'phase':phase,'status':status,'updated_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),**extra});tmp=a.data/'status.tmp';tmp.write_text(json.dumps(state,indent=2)+'\n');tmp.replace(a.data/'status.json');print(json.dumps(state),flush=True)
    def command(phase,args):
        update(phase)
        with (a.data/(phase+'.log')).open('a') as log:subprocess.run([sys.executable,'-u',*map(str,args)],cwd=ROOT,stdout=log,stderr=log,check=True)
    try:
        update('waiting-for-corpus')
        while not (a.data/'corpus/corpus.json').exists():time.sleep(5)
        command('dictionary',[HERE/'dictionary.py','--corpus',a.data/'corpus','--out',a.data/'dictionary'])
        plan=a.data/'screen-10m.jsonl.gz'
        if not plan.exists():command('sample-10m',[HERE/'corpus.py','sample','--db',a.data/'corpus/corpus.sqlite','--out',plan,'--words','10000000','--seed','731'])
        command('screen-10m',[HERE/'train.py','--db',a.data/'corpus/corpus.sqlite','--plan',plan,'--out',a.data/'screen','--vocab',a.data/'dictionary/vocabulary-30000.tsv','--batch','64','--threads','2','--compute-seconds','60'])
        update('screen-complete','awaiting-next-stage',remaining=['native word-model replay and paired quality intervals','subword word-boundary/search integration and native parity','two eligible finalists at baseline exposure, three seeds','new modern data and blind final test','physical iPhone latency, memory, size and false-correction acceptance'])
    except Exception as exc:update(state['phase'],'failed',error=str(exc));traceback.print_exc();raise
if __name__=='__main__':main()
