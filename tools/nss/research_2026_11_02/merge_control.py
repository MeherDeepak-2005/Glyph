#!/usr/bin/env python3
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('base',type=Path);p.add_argument('control',type=Path);a=p.parse_args()
b=json.loads(a.base.read_text());c=json.loads(a.control.read_text())
for key in ('audit_sha256','seed','equal_budget_original_words','train_sequence_sha256'):
    if b[key]!=c[key]:raise ValueError('Control mismatch: '+key)
b['models']['warm-chat-control']=c['models']['warm-chat-control'];a.base.write_text(json.dumps(b,indent=2)+'\n')
