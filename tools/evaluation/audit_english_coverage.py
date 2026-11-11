#!/usr/bin/env python3
"""Read-only English pack audit; emits JSON to stdout, never builds/downloads data.

The hand-selected probes diagnose specific gaps, not population coverage or
decoder recall. Importing the builder only reuses its pinned corpus tokenizer.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import build_language_data as builder
from verify_language_data import Pack

PROBES = {
    "common_controls": """the and you please thanks thank hello tomorrow yesterday
        meeting appointment school family friend message receive correction because
        definitely possible important available appreciate sincerely regards welcome
        sorry help understand work home email happy""",
    "regional_spelling": """colour colours coloured colouring colourful favourite
        favourites favour behaviour neighbour neighbours honour humour flavour
        organise organised organising organisation recognise recognised centre
        centres theatre metre metres litre litres travelling travelled traveller
        cancelled cancelling programme programmes cheque cheques grey tyre tyres
        jewellery defence licence licences analyse analysed aluminium mould
        mum maths realise realised prioritise prioritised fulfil fulfilment""",
    "international_english": """lakh lakhs crore crores prepone preponed onam
        diwali pongal holi dosa idli chai masala biryani tiffin autorickshaw
        pincode outstation biodata batchmate batchmates updation revert
        kindly arvo brekkie loadshedding robot queue
        hawker kopi lah canteen varsity matric braai airtime matatu jollof
        barangay jeepney buka kiasu""",
    "formal_academic": """acknowledge acknowledged acknowledgement accommodate
        accommodation correspondence courteous respectfully sincerely gratitude
        obliged consideration clarification inconvenience pursuant notwithstanding
        furthermore moreover nevertheless consequently therefore hence whereas
        albeit ostensibly salient cogent nuanced substantiate corroborate refute
        elucidate delineate juxtapose extrapolate empirical epistemology ontology
        pedagogy heuristic methodology reproducibility reproducible replicability
        preregistration interdisciplinarity operationalisation operationalization
        heterogeneity endogeneity multicollinearity meta-analysis epistemic
        hermeneutics phenomenology liminality intertextuality metacognition""",
    "literary": """eloquence eloquent serendipity melancholy ephemeral luminous
        wistful resplendent ineffable reverie soliloquy allegory alliteration
        foreshadowing denouement dénouement catharsis anachronism verisimilitude
        juxtaposition synecdoche metonymy enjambment bildungsroman palimpsest
        susurration liminal numinous ineffability mellifluous""",
    "everyday_inflections": """reschedule rescheduled rescheduling unsubscribe
        unsubscribed unsubscribing screenshot screenshots screenshotted
        screenshotting livestream livestreams livestreamed livestreaming
        livestreamer livestreamers onboarding onboarded autofill
        autofilled autofilling coworker coworkers coworking upskill upskilled
        upskilling reskill reskilling declutter decluttered decluttering
        multitask multitasked multitasking unfollow unfollowed unfollowing
        unmute unmuted unmuting reboot rebooted rebooting""",
    "texting_and_slang": """lol lmao lmfao rofl brb ttyl bbl bbs btw idk ikr
        tbh ngl lmk hmu smh imo imho rn fr irl fomo iykyk tldr asap fyi
        omw wyd wya wdym nvm nbd atm afaik iirc ofc fwiw tbf ty tysm thx
        pls plz u ur r gr8 b4 2day lowkey highkey vibing sus rizz delulu
        bestie situationship ghosted unhinged doomscrolling prolly gonna wanna
        gotta finna slay yeet frfr rn noob gg glhf fyp ootd pov dm dms""",
    "modern_technical": """covid coronavirus lockdown telehealth telemedicine
        vaccine vaccination chatbot chatbots chatgpt llm llms tokenizer tokenizers
        tokenization embeddings reranker quantization quantized webhook webhooks
        github gitlab kotlin swiftui coreml kubernetes devops cybersecurity
        ransomware passkey passkeys phishing deepfake deepfakes generative
        multimodal finetuning podcast podcasts bluetooth autocorrect fintech
        blockchain cryptocurrency contactless ewallet upi otp qr api apis""",
    "international_names_places": """bengaluru bangalore hyderabad telangana
        visakhapatnam vijayawada tirupati srinivas ananya aditya meher mumbai
        chennai kolkata delhi noida gurugram pune kochi thiruvananthapuram
        dhaka karachi lagos abuja accra nairobi johannesburg durban
        singapore manila quezon auckland wellington melbourne sydney toronto
        vancouver edinburgh cardiff belfast siobhan aoife nguyen aisha kwame""",
    "orthography_and_contractions": """café naïve résumé façade jalapeño fiancée
        cafe naive resume facade jalapeno fiancee co-operate e-mail wi-fi cooperate
        email wifi can't don't won't I'm you're they've could've should've
        would've might've must've shan't needn't y'all ma'am o'clock couldn't've
        shouldn't've wouldn't've mightn't mightn't've dont im youre cant""",
}

PHRASES = ["thank you", "thank you for your consideration", "kind regards",
    "yours sincerely", "please let me know", "could you please clarify",
    "i appreciate your help", "sorry for the inconvenience", "at your convenience",
    "would you mind", "with respect to", "in accordance with", "on the other hand",
    "statistically significant", "peer reviewed", "be right back", "on my way",
    "talk to you later", "no worries", "load shedding", "pin code", "cape town"]


def main():
    pack_path = ROOT / "keyboard/langdata.bin"
    pack = Pack(pack_path)
    raw_words, frequencies = pack.vocabulary()
    words = [word.decode("utf-8") for word in raw_words]
    ids = {word: i for i, word in enumerate(words)}
    assert len(ids) == pack.words
    esdb = builder.load_esdb_tiers()
    counts = Counter()
    sentences = 0
    for sentence in builder.corpus_sentences():
        sentences += 1
        counts.update(sentence)
    oov = Counter({word: count for word, count in counts.items() if word not in ids})
    categories = {}
    for category, text in PROBES.items():
        forms = list(dict.fromkeys(text.split()))
        rows = []
        for form in forms:
            key = form.lower().replace("’", "'")
            wid = ids.get(key)
            rows.append({"form": form, "lookup_key": key, "present": wid is not None,
                "frequency": frequencies[wid] if wid is not None else None,
                "esdb_tier": esdb.get(key),
                "passes_ascii_word_pattern": bool(builder.WORD.fullmatch(key)),
                "intentional_builder_exclusion": key in builder.EXCLUDE or
                    (len(key) == 1 and key not in {"a", "i"})})
        categories[category] = {"count": len(rows),
            "present": sum(row["present"] for row in rows),
            "missing": sum(not row["present"] for row in rows), "probes": rows}
    missing_esdb = set(esdb) - ids.keys()
    phrase_rows = [{"phrase": phrase, "all_words_present": all(word in ids for word in phrase.split())}
                   for phrase in PHRASES]
    result = {
        "schema_version": 1, "audit_date": "2026-10-06",
        "scope": "checked-out bundled artifact; not verified App Store binary",
        "inputs": {"esdb": {"path": str(builder.ESDB.relative_to(ROOT)),
            "sha256": builder.ESDB_SHA256}, "build_corpus": {
            "path": str(builder.CORPUS.relative_to(ROOT)), "sha256": builder.TATOEBA_SHA256}},
        "method": "exact lowercased surface-form membership, not decoder execution",
        "probe_limitations": "Hand-selected diagnostic probes, partly motivated by known gaps; not a representative random sample. Categories may overlap. Phrase component probes do not test phrase prediction.",
        "artifact": {"path": str(pack_path.relative_to(ROOT)),
            "sha256": hashlib.sha256(pack.data).hexdigest(), "bytes": len(pack.data),
            "version": pack.version, "words": pack.words, "trie_nodes": pack.trie_nodes,
            "word_id_capacity": 0x7fffffff},
        "esdb": {"total": len(esdb), "overlap": len(set(esdb) & ids.keys()),
            "missing_total": len(missing_esdb),
            "missing_by_tier": dict(sorted(Counter(esdb[word] for word in missing_esdb).items())),
            "missing_without_apostrophe": sum("'" not in word for word in missing_esdb),
            "missing_with_apostrophe": sum("'" in word for word in missing_esdb),
            "note": "Raw normalized source-minus-pack delta, not approved additions or evidence of usage frequency."},
        "build_corpus": {"sentences": sentences, "tokens": sum(counts.values()),
            "types": len(counts), "oov_tokens": sum(oov.values()), "oov_types": len(oov),
            "token_coverage_pct": 100*(1-sum(oov.values())/sum(counts.values())),
            "type_coverage_pct": 100*(1-len(oov)/len(counts)),
            "top_oov": oov.most_common(40),
            "note": "In-sample coverage on the pack's own Tatoeba training source, using the builder's tokenization and 128-token sentence limit; not held-out recall."},
        "unique_probe_keys": len({r["lookup_key"] for c in categories.values() for r in c["probes"]}),
        "categories": categories,
        "phrase_probes": {"note": "Component-word membership only; it does not test phrase prediction or establish tone awareness.", "rows": phrase_rows},
    }
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
