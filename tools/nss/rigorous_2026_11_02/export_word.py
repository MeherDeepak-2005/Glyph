#!/usr/bin/env python3
"""Quantized recurrent export paired with its exact vocabulary and candidate pack."""
import argparse,gzip,json,sys
from pathlib import Path
import torch
from torch.nn import functional as F
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2];sys.path[:0]=[str(HERE),str(ROOT/'tools/nss')]
from train import build,Vocabulary,sha256,validation_rows,encode,UNK
from nss.lexicon import Lexicon
from nss.export import write,quantized_copy,goldens
@torch.no_grad()
def main():
    p=argparse.ArgumentParser();p.add_argument('--checkpoint',type=Path,required=True);p.add_argument('--pack',type=Path,required=True);p.add_argument('--db',type=Path,required=True);p.add_argument('--plan',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();torch.set_num_threads(2)
    ck=torch.load(a.checkpoint,map_location='cpu',weights_only=False)
    if ck['tokenization']!='word':raise RuntimeError('Subword checkpoints require a piece tokenizer and word search, not word-format export')
    vocab=Vocabulary.load(Path(ck['vocabulary_path']))
    if vocab.sha256!=ck['vocabulary_sha256']:raise RuntimeError('Vocabulary mismatch')
    model=build(ck['arch'],len(vocab));model.load_state_dict(ck['model']);model.eval();reference=quantized_copy(model);lexicon=Lexicon.load(a.pack)
    unknown=inside=0
    with gzip.open(a.plan,'rt') as f:
        for line in f:
            for word in json.loads(line)['text'].split():
                if vocab.id(word)==UNK:unknown+=1;inside+=word.strip("'") in lexicon
    share=inside/max(1,unknown)
    if not 0<share<=1:raise RuntimeError('Invalid measured fallback share')
    total=center=0
    for rows in validation_rows(a.db,512).values():
        for row in rows:
            seq=encode(row['text'],vocab,None);x=torch.tensor([seq[:-1]]);h,_=reference(x);logits=reference.logits(h[0,:-1]);logits[:,[0,2,3]]=-float('inf');lp=F.log_softmax(logits,-1);center+=float(lp[:,UNK].sum());total+=len(lp)
    center/=total;a.out.parent.mkdir(parents=True,exist_ok=True);info=write(model,vocab,share,lexicon.sha256,a.out,center)
    manifest={'source_checkpoint_sha256':sha256(a.checkpoint),'selected_step':ck['step'],'sha256':sha256(a.out),'bytes':info['bytes'],'architecture':model.config(),'vocabulary_sha256':vocab.sha256,'pack_sha256':lexicon.sha256,'fallback_measured_unknown_tokens':unknown,'fallback_lexicon_tokens':inside,'unknown_lexicon_share':share,'unknown_log_center':center,'validation_positions':total,'max_abs_quantization_error':info['max_abs_quantization_error'],'test_accessed':False,'production_ready':False}
    a.out.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');a.out.with_suffix('.goldens.json').write_text(json.dumps(goldens(reference,vocab,share,lexicon,center),indent=2)+'\n');print(json.dumps(manifest),flush=True)
if __name__=='__main__':main()
