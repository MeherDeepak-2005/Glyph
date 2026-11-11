#!/usr/bin/env python3
"""Fetch one revision-pinned modern FineWeb shard with bounded disk use and provenance.
Example: python fetch_modern.py --out tools/.cache/fineweb-2025 --max-gb 3
No credentials required; API and data requests must have normal network access.
"""
import argparse,hashlib,json,shutil,time,urllib.parse,urllib.request
from pathlib import Path
BASE='https://huggingface.co'
REPO='HuggingFaceFW/fineweb'
def get_json(url):
    with urllib.request.urlopen(url,timeout=60) as r:return json.load(r)
def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--crawl',default='CC-MAIN-2025-26');p.add_argument('--max-gb',type=float,default=3);a=p.parse_args()
    a.out.mkdir(parents=True,exist_ok=True);manifest={'repository':REPO,'crawl':a.crawl,'dataset_card':BASE+'/datasets/'+REPO,
        'license':'ODC-By 1.0 dataset license; underlying web-content rights require separate release review',
        'purpose':'Offline frequency/model research. Not a keyboard runtime download.'}
    try:
        revision=get_json(BASE+'/api/datasets/'+REPO)['sha'];manifest['revision']=revision
        tree=get_json(BASE+'/api/datasets/'+REPO+'/tree/'+revision+'/data/'+a.crawl+'?limit=1000')
        candidates=sorted([r for r in tree if r['path'].endswith('.parquet') and r.get('size',0)<=a.max_gb*1e9],key=lambda r:r['path'])
        if not candidates:raise RuntimeError('No shard fits --max-gb; inspect the upstream listing before increasing it.')
        row=candidates[0];size=row['size']
        if shutil.disk_usage(a.out).free<size*1.2:raise RuntimeError('Insufficient disk space with 20% headroom')
        url=BASE+'/datasets/'+REPO+'/resolve/'+revision+'/'+row['path'];dest=a.out/Path(row['path']).name;temp=dest.with_suffix('.partial')
        manifest.update({'url':url,'expected_bytes':size,'upstream_lfs':row.get('lfs')})
        h=hashlib.sha256();received=0
        with urllib.request.urlopen(url,timeout=120) as src,temp.open('wb') as dst:
            while block:=src.read(4*1024*1024):
                received+=len(block)
                if received>a.max_gb*1e9:raise RuntimeError('Transfer exceeded byte budget')
                dst.write(block);h.update(block)
        if received!=size:raise RuntimeError('Downloaded byte count differs from pinned tree metadata')
        expected=(row.get('lfs') or {}).get('oid','').removeprefix('sha256:')
        if expected and expected!=h.hexdigest():raise RuntimeError('Upstream LFS SHA-256 mismatch')
        temp.replace(dest);manifest.update({'status':'downloaded','file':dest.name,'bytes':received,'sha256':h.hexdigest()})
    except Exception as e:
        manifest.update({'status':'blocked','error':str(e)})
        (a.out/'download-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');raise
    (a.out/'download-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest,indent=2))
if __name__=='__main__':main()
