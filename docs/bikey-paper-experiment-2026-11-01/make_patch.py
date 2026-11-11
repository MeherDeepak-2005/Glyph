import difflib,json
from pathlib import Path
HERE=Path(__file__).resolve().parent
WORK=Path(json.loads((HERE/'workspace.json').read_text())['work'])
changes=json.loads((HERE/'source-hashes.json').read_text())['candidate']
patch=[]
for name in changes:
 old=WORK/'baseline'/name;new=HERE/'implementation'/name
 patch.extend(difflib.unified_diff(old.read_text().splitlines(True) if old.exists() else [],new.read_text().splitlines(True),fromfile='a/'+name if old.exists() else '/dev/null',tofile='b/'+name))
(HERE/'implementation.patch').write_text(''.join(patch))
