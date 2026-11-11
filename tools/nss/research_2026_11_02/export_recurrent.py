#!/usr/bin/env python3
"""Export word-level research checkpoints only; keep subword models offline."""
import argparse,json,math,sys
from pathlib import Path
import torch
from torch.nn import functional as F
sys.path.insert(0,str(Path(__file__).resolve().parent))
from train_challengers import ROOT,build,load_sets,draw_training,Vocabulary,encode,batch_tensors,sha256,UNK,EOS
from nss.lexicon import Lexicon
from nss.export import write,quantized_copy,goldens
@torch.no_grad()
def main():
    p=argparse.ArgumentParser();p.add_argument('--checkpoint',type=Path,required=True);p.add_argument('--pack',type=Path,required=True);p.add_argument('--data',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();torch.set_num_threads(2)
    ck=torch.load(a.checkpoint,map_location='cpu',weights_only=False)
    if ck['tokenization']!='word':raise ValueError('A subword checkpoint needs subword search integration; cannot export pieces as words')
    vocab=Vocabulary.load(Path(ck['vocabulary_path']))
    if vocab.sha256!=ck['vocabulary_sha256']:raise ValueError('Vocabulary/checkpoint hash mismatch')
    model=build(ck['arch'],len(vocab));model.load_state_dict(ck['model']);model.eval();reference=quantized_copy(model);lexicon=Lexicon.load(a.pack)
    sets=load_sets(a.data);training,_=draw_training(sets['train'],ck.get('training_original_words',500000));unk=lex=0
    for text in training:
        for word in text.split():
            if vocab.id(word)==UNK:unk+=1;lex+=word in lexicon
    share=lex/max(1,unk)
    if not 0<share<=1:raise ValueError('Invalid measured unknown lexicon share')
    total=center=0
    for texts in sets['valid'].values():
        for text in texts[:120]:
            seq=encode(text,'word',vocab,None);x=torch.tensor([seq[:-1]]);features,_=reference(x);logits=reference.logits(features[0,:-1]);logits[:,[0,2,3]]=-float('inf')
            lp=F.log_softmax(logits,-1);center+=lp[:,UNK].sum().item();total+=len(lp)
    center/=total;a.out.parent.mkdir(parents=True,exist_ok=True);info=write(model,vocab,share,lexicon.sha256,a.out,center)
    manifest={'schema_version':1,'status':'research only; not installed','architecture':model.config(),'parameters':model.parameter_count(),
              'sha256':sha256(a.out),'bytes':info['bytes'],'source_checkpoint_sha256':sha256(a.checkpoint),'vocabulary_sha256':vocab.sha256,
              'langdata_sha256':lexicon.sha256,'unk_lexicon_share':share,'unknown_log_center':center,'validation_word_positions':total,
              'max_abs_quantization_error':info['max_abs_quantization_error']}
    a.out.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    a.out.with_suffix('.goldens.json').write_text(json.dumps(goldens(reference,vocab,share,lexicon,center),indent=2)+'\n');print(json.dumps(manifest),flush=True)
if __name__=='__main__':main()
