#!/usr/bin/env python3
"""Verify the public, revision-pinned manual download before any data ingestion."""
import argparse,datetime,hashlib,json,time
from pathlib import Path
HERE=Path(__file__).resolve().parent

def verify(path):
    expected=json.loads((HERE/'modern-shard.json').read_text());digest=hashlib.sha256()
    with path.open('rb') as f:
        if f.read(4)!=b'PAR1':raise RuntimeError('Not a Parquet file (possibly an HTML error or pointer)')
        f.seek(-4,2)
        if f.read(4)!=b'PAR1':raise RuntimeError('Incomplete/invalid Parquet footer')
        f.seek(0)
        for block in iter(lambda:f.read(8*1024*1024),b''):digest.update(block)
    if digest.hexdigest()!=expected['sha256']:raise RuntimeError('Published SHA256 differs; refusing ingestion')
    import pyarrow.parquet as pq
    parquet=pq.ParquetFile(path);columns=set(parquet.schema.names)
    if not {'text','url','date','dump'}.issubset(columns):raise RuntimeError('Unexpected FineWeb schema')
    manifest={**expected,'status':'downloaded','manual_download':True,'file':path.name,'bytes':path.stat().st_size,'sha256':digest.hexdigest(),'parquet_rows':parquet.metadata.num_rows,'verified_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'url':expected['download']}
    out=path.parent/'import-manifest.json';out.write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest),flush=True);return manifest
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--file',type=Path,required=True);p.add_argument('--watch',action='store_true');a=p.parse_args()
    if a.watch:
        while not a.file.exists():time.sleep(5)
        # Browser downloads commonly use a temporary suffix, then rename atomically.
        previous=-1
        while a.file.stat().st_size!=previous:previous=a.file.stat().st_size;time.sleep(5)
    verify(a.file)
