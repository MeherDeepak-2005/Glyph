#!/usr/bin/env python3
"""Evidence-based readiness ledger. Missing evidence always blocks promotion.
No artifact installation, paid compute, or final-test execution is performed here.
"""
import argparse,csv,gzip,json,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
from train import sha256,Vocabulary

def read(path):
    try:return json.loads(path.read_text())
    except (FileNotFoundError,json.JSONDecodeError):return None

def main():
    p=argparse.ArgumentParser();p.add_argument('--data',type=Path,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--require-ready',action='store_true');a=p.parse_args();data=a.data;protocol=read(HERE/'protocol.json');checks={};details={}
    corpus=read(data/'corpus/corpus.json');checks['document_split_corpus_complete']=corpus is not None
    if corpus:
        totals={s:0 for s in corpus['sources']};observed=0;rows=0
        with gzip.open(data/'corpus/counts.tsv.gz','rt') as f:
            for row in csv.DictReader(f,delimiter='\t'):
                values={s:int(row[s+'_count']) for s in totals};n=int(row['observed_train_count'])
                if n!=sum(values.values()):raise RuntimeError('Observed counts do not sum for '+row['word'])
                observed+=n;rows+=1
                for s,n in values.items():totals[s]+=n
        checks['exact_source_counts']=all(totals[s]==corpus['stats'].get(s+'.train.words',0) for s in totals) and observed==corpus['training_tokens'];details['training_counts']={'words':observed,'word_types':rows,'by_source':totals}
    modern=read(data/'modern/import-manifest.json');checks['modern_download_verified']=bool(modern and modern['status']=='downloaded' and modern['sha256']==read(HERE/'modern-shard.json')['sha256']);checks['modern_data_in_training']=bool(corpus and corpus['modern_manifests'])
    plan=read(data/'screen-10m.jsonl.manifest.json');checks['screen_plan_unique_10m']=bool(plan and plan['words']>=10_000_000 and plan['without_replacement'] and plan['unique_sentences']==plan['sentences'])
    dictionary=read(data/'dictionary/dictionary.json');checks['30k_45k_60k_vocabularies_valid']=bool(dictionary)
    if dictionary:
        for size in [30000,45000,60000]:
            vocab=Vocabulary.load(data/f'dictionary/vocabulary-{size}.tsv');checks['30k_45k_60k_vocabularies_valid']&=len(vocab)==size+4 and vocab.sha256==dictionary['selected'][str(size)]['sha256']
        details['vocabulary_validation']=dictionary['selected']
    checks['name_capitalization_review_available']=(data/'dictionary/capitalization-review.json').exists();models={};missing=[]
    for name in protocol['screen']['models']:
        result=read(data/'screen'/(name+'-s731')/'result.json')
        if result:models[name]={'words':result['raw_words'],'selected_step':result['selected_step'],'preflight_passed':result['preflight']['passed'],'test_accessed':result['test_accessed'],'checkpoint_sha256':result['checkpoint_sha256']}
        else:missing.append(name)
    checks['all_screen_models_trained_10m']=not missing and all(r['words']>=10_000_000 and r['preflight_passed'] and not r['test_accessed'] for r in models.values());details['screen_models']=models;details['screen_models_pending']=missing
    checks['matched_cpu_compute_snapshots_complete']=all((data/'screen'/(n+'-s731')/'equal-compute.pt').exists() for n in protocol['screen']['models'])
    manifest=read(data/'validation-cases/cases.manifest.json');checks['natural_validation_cases']=bool(manifest and manifest['target_injected'] is False and not manifest['fresh_blind_final_test']);checks['shipped_baseline_reproduced']=(data/'native-baseline.manifest.json').exists()
    comparisons={n:read(data/('compare-'+n+'.json')) for n in protocol['screen']['models']};checks['all_architectures_real_decoder_evaluated']=all(comparisons.values())
    # Native subword parity requires an explicit report binding model, tokenizer, case and native binary hashes.
    subword=read(data/'subword-native-parity.json');checks['subword_tokenizer_scoring_search_native_parity']=bool(subword and subword.get('passed') and all(k in subword for k in ['model_sha256','tokenizer_sha256','binary_sha256','case_sha256','word_boundary_cases','search_cases']))
    finalists=read(data/'finalists.json');full=[]
    if finalists:
        for name in finalists['models']:
            for seed in protocol['full']['seeds']:
                r=read(data/'full'/(name+'-s'+str(seed))/'result.json')
                if r:full.append(r)
    checks['two_finalists_three_seeds_baseline_exposure']=bool(finalists and len(finalists['models'])==2 and len(full)==6 and all(r['raw_words']>=130_000_000 and r['selected_step']>0 for r in full))
    novelty=read(data/'final-test-novelty.json');checks['fresh_final_split_certified']=bool(novelty and novelty.get('fresh_public_modern_test') and novelty.get('exact_overlap')==0 and novelty.get('near_duplicate_audit_passed') and novelty.get('previously_evaluated') is False)
    final=read(data/'final-test-result.json');ledger=read(data/'final-test-ledger.json');checks['final_test_once']=bool(final and ledger and ledger.get('attempts')==1 and final.get('case_sha256')==ledger.get('case_sha256'))
    checks['final_quality_passed']=False
    if final:
        q=protocol['promotion'];checks['final_quality_passed']=bool(final.get('clean_cases',0)>=q['minimum_clean_test_cases'] and final.get('commit_accuracy_delta_ci',[0,0])[0]>q['commit_accuracy_delta_ci_lower_gt'] and final.get('false_correction_delta_ci',[1,1])[1]<=q['clean_false_correction_delta_ci_upper_max'] and final.get('top3_delta_ci',[-1,-1])[0]>=q['top3_delta_ci_lower_min'])
    device=read(data/'physical-device-result.json');checks['physical_iphone_budgets_passed']=False
    if device:
        q=protocol['promotion'];checks['physical_iphone_budgets_passed']=bool(device.get('physical') and device.get('platform')=='iOS' and device.get('isolated') and len(device.get('trials',[]))>=q['physical_device_trials_min'] and device.get('p50_ratio',2)<=q['max_device_p50_ratio'] and device.get('p95_ratio',2)<=q['max_device_p95_ratio'] and device.get('peak_memory_ratio',2)<=q['max_device_memory_ratio'] and device.get('total_resource_bytes_ratio',2)<=q['max_resource_size_ratio'])
    result={'promotion_allowed':all(checks.values()),'checks':checks,'pending':[k for k,v in checks.items() if not v],'details':details,'cloud_spend':0,'meaning':'A checkpoint selected after step zero proves validation loss decreased; only the decoder/final-test/device gates support a product-improvement claim.'};a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'promotion_allowed':result['promotion_allowed'],'pending':result['pending'],'completed_models':list(models)}),flush=True)
    if a.require_ready and not result['promotion_allowed']:sys.exit(1)
if __name__=='__main__':main()
