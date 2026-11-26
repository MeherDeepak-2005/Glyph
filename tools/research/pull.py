#!/usr/bin/env python3
"""Download the uploaded research chunks from CloudKit (public database, record type TypingChunk).

  pull.py --key-id KEY_ID --key-file eckey.pem --out DIR [--environment production|development]

Uses CloudKit Web Services with a server-to-server key (CloudKit Console > Tokens & Keys >
Server-to-Server Keys; the private half is the eckey.pem you created with
`openssl ecparam -name prime256v1 -genkey -noout -out eckey.pem`). Needs only Python and openssl.

Each record's sealed asset is saved once as DIR/sealed/<record name>.grc. Open them with:

  swift tools/research/chunks.swift open Config/research-private-key.txt DIR/opened DIR/sealed/*.grc
  python3 tools/research/build_datasets.py DIR/opened DIR/tables

NOT YET RUN AGAINST A LIVE CONTAINER: written from the CloudKit Web Services reference. Until it
has been, the CloudKit Console (Records > TypingChunk > download the `data` asset) is the fallback.
"""
from __future__ import annotations
import argparse, base64, datetime, hashlib, json, subprocess, sys, urllib.request
from pathlib import Path

HOST = "https://api.apple-cloudkit.com"

def signed(path: str, body: bytes, key_id: str, key_file: Path) -> dict[str, str]:
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    message = f"{date}:{base64.b64encode(hashlib.sha256(body).digest()).decode()}:{path}".encode()
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_file)], input=message,
                               capture_output=True, check=True).stdout
    return {"Content-Type": "application/json", "X-Apple-CloudKit-Request-KeyID": key_id,
            "X-Apple-CloudKit-Request-ISO8601Date": date,
            "X-Apple-CloudKit-Request-SignatureV1": base64.b64encode(signature).decode()}

def records(container: str, environment: str, key_id: str, key_file: Path):
    path = f"/database/1/{container}/{environment}/public/records/query"
    marker = None
    while True:
        query = {"query": {"recordType": "TypingChunk", "sortBy": [{"fieldName": "___createTime", "ascending": True}]},
                 "resultsLimit": 200}
        if marker:
            query["continuationMarker"] = marker
        body = json.dumps(query).encode()
        request = urllib.request.Request(HOST + path, data=body, headers=signed(path, body, key_id, key_file))
        with urllib.request.urlopen(request, timeout=60) as response:
            page = json.load(response)
        yield from page.get("records", [])
        marker = page.get("continuationMarker")
        if not marker:
            return

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--environment", choices=["production", "development"], default="production")
    parser.add_argument("--container", default="iCloud.com.keypointtech.glyph")
    args = parser.parse_args()
    sealed = args.out / "sealed"
    sealed.mkdir(parents=True, exist_ok=True)
    seen = new = failed = 0
    for record in records(args.container, args.environment, args.key_id, args.key_file):
        seen += 1
        name = record.get("recordName", "")
        asset = (record.get("fields", {}).get("data") or {}).get("value") or {}
        target = sealed / f"{name}.grc"
        if not name or "/" in name or target.exists():
            continue
        url = asset.get("downloadURL")
        if not url:
            failed += 1
            print(f"no asset for {name}", file=sys.stderr)
            continue
        try:
            with urllib.request.urlopen(url.replace("${f}", f"{name}.grc"), timeout=120) as response:
                data = response.read()
            temporary = target.with_suffix(".part")
            temporary.write_bytes(data)
            temporary.replace(target)
            new += 1
        except OSError as error:
            failed += 1
            print(f"download failed for {name}: {error}", file=sys.stderr)
    print(f"{seen} records, {new} new chunks in {sealed}, {failed} failed")
    if failed:
        sys.exit(1)

if __name__ == "__main__":
    main()
