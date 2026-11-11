#!/usr/bin/env python3
"""Build diagnostic-only NSS from committed source, preserving the working tree."""
import pathlib,subprocess,tempfile,os,json,hashlib
ROOT=pathlib.Path(__file__).resolve().parents[2];OUT=pathlib.Path(__file__).resolve().parent
work=pathlib.Path(tempfile.mkdtemp(prefix='corev4-nss-audit-'));(OUT/'diagnostic-workdir.txt').write_text(str(work)+'\n')
archive=subprocess.check_output(['git','-C',str(ROOT),'archive','HEAD','native/DecoderCore'])
subprocess.run(['tar','-xf','-','-C',str(work)],input=archive,check=True)
engine=work/'native/DecoderCore/src/Engine.cpp';text=engine.read_text();text='#include <cstdlib>\n#include <iostream>\n#include <iomanip>\n'+text
needle='out.correction = correction(view.lexicon, correctionRows, costs, typed, length, input.letterFlags, input.context, input.kept || aimedAtBlocked, loose, broad, policy, nssChannelWeight);'
assert text.count(needle)==1
probe=r'''
    if (const char* target = std::getenv("KB_AUDIT_TARGET")) {
        auto targetRanked = std::find_if(ranked.begin(), ranked.end(), [&](const auto& r){return r.key == target;});
        auto targetCorrection = std::find_if(correctionRows.begin(), correctionRows.end(), [&](const auto& r){return r.key == target;});
        const auto* g = out.correction.gate ? &*out.correction.gate : nullptr;
        std::cerr << std::setprecision(15) << "AUDIT\t" << std::getenv("KB_AUDIT_ID") << '\t'
            << (targetRanked != ranked.end()) << '\t' << (targetCorrection != correctionRows.end()) << '\t'
            << (costs.contains(target) ? costs.at(target) : -999) << '\t'
            << (targetCorrection != correctionRows.end() ? targetCorrection->language : -999) << '\t'
            << (targetCorrection != correctionRows.end() ? targetCorrection->score : -999) << '\t'
            << typedScore << '\t' << (g ? g->candidate : "-") << '\t'
            << (g ? g->margin : -999) << '\t' << out.correction.threshold << '\t'
            << (g ? g->cost : -999) << '\t' << (g ? int(g->kind) : -1) << '\t'
            << (out.correction.word ? *out.correction.word : "-") << '\t'
            << close.contains(target) << '\t' << broad.contains(target) << '\t' << injected.contains(target) << '\n';
    }
'''
text=text.replace(needle,needle+probe);engine.write_text(text)
harness=(ROOT/'tools/evaluation/autocorrect/IOSBench.cpp').read_text()
needle2='auto r = session->decode(in, view);';assert harness.count(needle2)==1
harness=harness.replace(needle2,'setenv("KB_AUDIT_TARGET", target.c_str(), 1); setenv("KB_AUDIT_ID", id.c_str(), 1);\n            '+needle2)
source=work/'AuditBench.cpp';source.write_text(harness)
cmake=(ROOT/'native/CMakeLists.txt').read_text();start=cmake.index('add_library(DecoderCore STATIC')
sources=[str(work/'native'/s.strip()) for s in cmake[start:cmake.index(')',start)].splitlines()[1:] if s.strip().endswith('.cpp')]
binary=work/'audit';cmd=['xcrun','clang++','-std=c++20','-Os','-DNDEBUG','-I',str(work/'native/DecoderCore/include'),str(source),*sources,'-o',str(binary)]
(OUT/'diagnostic-build-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (OUT/'diagnostic-build.log').open('w') as log:subprocess.run(cmd,check=True,stdout=log,stderr=log)
print('Diagnostic build complete; replaying 1,766 Core-only severe fixes',flush=True)
env=dict(os.environ,KB_NSS=str(ROOT/'keyboard/nss-english.nsslm'))
with (OUT/'diagnostic.tsv').open('w') as err:
 subprocess.run([str(binary),str(ROOT/'keyboard/langdata.bin'),str(ROOT/'keyboard/safety.kbguard'),str(OUT/'core-only-severe.taps.tsv'),str(OUT/'diagnostic.jsonl')],env=env,check=True,stderr=err)
def load(p):return {r['id']:r for r in map(json.loads,p.read_text().splitlines()) if 'id' in r}
old=load(ROOT/'tools/evaluation/autocorrect/results/taps-final-nss-english.ext.jsonl');new=load(OUT/'diagnostic.jsonl')
assert len(new)==1766 and all(r['ok']==1 for r in new.values())
assert all((r['c'],r['s'])==(old[i]['c'],old[i]['s']) for i,r in new.items()),'diagnostic source does not reproduce saved NSS arm'
proof={'source_commit':subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip(),'cases':len(new),'corrections_and_suggestions_match_saved_NSS':True,'production_sources_modified':False,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
(OUT/'diagnostic-validation.json').write_text(json.dumps(proof,indent=2)+'\n');print(json.dumps(proof),flush=True)
