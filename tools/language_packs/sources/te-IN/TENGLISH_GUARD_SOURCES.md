# Tenglish guard: dictionary sources

`tenglish-guard-unigrams.tsv` (20,000 Roman Telugu words with per-million frequencies) and
the compiled `keyboard/tenglish_guard.bin` come from the sources below, combined by
`tools/language_packs/build_tenglish_guard.py`. Downloaded 19 Nov 2026. Licences were not
screened for this list (performance testing and beta builds); the licensing team reviews
them before a release.

Glyph had no Roman Telugu frequency counts: the 12,000 keys of `keyboard/tenglish_lexicon.bin`
carry Aksharantar source weights (almost all 5.0), and its unigram table keeps only 12 words.

## Taken from github.com/MeherDeepak-2005/iOSKeyboard

Commit `87cfde7f8160df031946b5acadcabf76d01b526c`, branch `codex/nss-paper-replica` (the
repository's only branch and its default). Its Telugu data is byte-identical to Glyph's,
so the builder reads Glyph's copies:

| File | sha256 | Used for |
|---|---|---|
| `tools/data/indiccorpv2-te-stratified-2026-07-20.txt.bz2` | `744556a1da885bba747c629add17599d926c9bcc924d0dfbb60d750181d62230` | Telugu-script word counts, news (100,000 IndicCorp v2 sentences) |
| `keyboard/tenglish_lexicon.bin` | `e56b0f57500e41a638fa975d674bb9f06dcd36ea71f1dbad0447e1b108bb830d` | Roman/Telugu spelling pairs (Aksharantar subset) |
| `tools/language_packs/sources/te-IN/tenglish-core-reviewed.tsv` | `cdd84b73352510ce307e6024d2cb94ba9751bf9409b1acbdc71eae7a2d60a8be` | Reviewed conversational spellings (triple weight) |

`keyboard/telugu_langdata.bin` and `tools/data/tatoeba-tel-ccby-2026-07-19.tsv.bz2` are
there too and were not needed.

## Downloaded

| Source | What was taken | sha256 |
|---|---|---|
| Google Dakshina v1.0, https://storage.googleapis.com/gresearch/dakshina/dakshina_dataset_v1.0.tar (ETag `a560868b1d6702602c4ea4e83794fa26`) | `te/lexicons/te.translit.sampled.train.tsv`: native-speaker romanizations with attestation counts | `11f02287e0c7969d6f730b1df3d93a8e8fb43d418691622ad2289d2e6b578a9a` |
| same | `te/native_script_wikipedia/te.wiki-filt.train.text.shuf.txt.gz`: Telugu-script word counts, encyclopedic (8.6M words) | `d56411fa5a57696be202f019e9d7e5460b57442ce2c73970cae9c473706b43e8` |
| AI4Bharat Aksharantar, https://huggingface.co/datasets/ai4bharat/Aksharantar/resolve/e418c1fc928d9f5393af33268472cf20c1891be8/tel.zip | `tel_train.json`: 2.4M Roman/Telugu pairs (mined IndicCorp rows at half weight); the same archive `keyboard/tenglish_lexicon.bin` was built from | `08f1c2841f4d02fcc2a56362f7760ec16fc52d8a199029c68d44024ab0d22c1a` |
| Telugu-LLM-Labs, https://huggingface.co/datasets/Telugu-LLM-Labs/uonlp_culturaX_telugu_romanized_100k/resolve/32aeecd53a5518c2d30348d1be59210eb39bf67e/uonlp_culturaX_telugu_romanized_100k.csv | 100,000 CulturaX Telugu documents with an Azure romanization, aligned word by word: chat-style spellings (chala, kuda, ledhu) at half weight | `1123faa608ba131c6ff7461abc835986c962f34445533e78f148042509fdbd07` |
| OPUS OpenSubtitles v2018 Telugu monolingual, https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/te.txt.gz | Telugu-script word counts, conversational (subtitles) | `81c7be3682260a19aea8b80efe5950a6eb6bec0e26cfa7e83be11eaf4ff08d07` |
| https://huggingface.co/datasets/RamyaGS/telugu-whatsapp-chat/resolve/8cdbc428a162cb4662f3caee7a5509ad383cfbc5/telugu_whatsapp_chat.csv | Telugu-script word counts, chat messages | `7c34f23c29549ab8e3852e3fa77f76e5e148e3ff5825712dd4de46dd64d4b53d` |
| Roger Mitton's misspelling corpora, https://www.dcs.bbk.ac.uk/~ROGER/corpora.html: `missp.dat` (Birkbeck), `holbrook-missp.dat`, `aspell.dat`, `wikipedia.dat` | English misspellings, used only to leave words out of the list | missp `ed7d8c91961a1201632351943571e77af2011cdf45d24304c4d7cad6cf77ea15`, holbrook `e2f0f0564954d049a1f663f3c7e72899382570a4fe575015169b1117de85ae3c`, aspell `0198fa5c343f82f0541ae39a0116b534e14bfadc54144377cadee2bd6d288988`, wikipedia `061ec33aa12a4aea718a7bb121360812c8348770833e730124af1eecdc2cd380` |

English word frequencies come from Glyph's own `tools/data/nss/unigram-v1/unigrams.tsv`.

Dakshina's dev and test lexicons and its 10,000 romanized sentences are evaluation data
(as `tools/language_packs/README.md` requires) and are not in the list; the test sentences
measure it below.

Looked at and not used: LightFury9/tenglish_vocab (pickle files), indiehackers/telugu_romanized
(romanized text without its Telugu source), and the LLM-generated colloquial sets
sril32996/tenglish-collo and BLESSENA30/telugu_english_colloquial.

## Rebuild

```sh
python3 tools/language_packs/build_tenglish_guard.py extract \
  --dakshina /path/to/dakshina_dataset_v1.0/te --aksharantar-zip /path/to/tel.zip \
  --machine-romanized /path/to/uonlp_culturaX_telugu_romanized_100k.csv \
  --conversation /path/to/te.txt.gz /path/to/telugu_whatsapp_chat.csv \
  --misspellings /path/to/missp.dat /path/to/holbrook-missp.dat /path/to/aspell.dat /path/to/wikipedia.dat
python3 tools/language_packs/build_tenglish_guard.py compile
```

`extract` printed `{"kept": 20000, "excluded": {"english_reading_likelier": 5697,
"english_loanword": 2899, "english_slip_likelier": 217, "attested_english_misspelling": 156,
"over_size_cap": 45051}}`.

## Measured (production NSS raw decoder, IOSBench, 19 Nov 2026)

- Dakshina test sentences (held out; first 8,000 words, two words of context): 44.1% of
  the words are in the list; the decoder autocorrected 12.9% of the words before, 4.4% with
  the list. The largest remaining changes are ee -> we (ee is in no training source) and
  ane -> and (an attested misspelling of "and").
- English misspelling lists (40,910 rows): 86 rows are list words; the decoder fixes 2 of
  them today (chery -> cherry, hegde -> hedge, both Birkbeck), which the list now keeps.
