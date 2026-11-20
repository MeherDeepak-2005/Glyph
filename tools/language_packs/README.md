# English layout pack

The English deck is data, not code. `sources/en-US/qwerty.json` holds the key order of
the letters, 123, #+= and number-pad pages, each page's bottom row, long-press
variants, the keys a field adds (email: `@ .`) and the letter grid's row offsets.
Shift, delete, return, space, globe and emoji are named as controls; the keyboard
supplies their behaviour. Compile it after any change:

```sh
python3 tools/language_packs/build_latin_layout.py \
  tools/language_packs/sources/en-US/qwerty.json keyboard/english_layout.kbpack
python3 -m unittest tools/language_packs/test_language_packs.py
```

The compiled pack also carries the letter grid that tap scoring and Glide decoding
use. The extension hands it to the native decoder at startup (`KBKeyGrid`), so the
keys drawn and the keys decoded come from one file. `native/DecoderCore` keeps QWERTY
as its built-in default for native tests and tools only. A layout with the letters
moved, such as AZERTY, is a new decoding geometry: re-run the typing benchmarks
before shipping one.

### Tenglish guard for English typing

Roman Telugu typed on the English keyboard is kept as typed. `build_tenglish_guard.py`
projects Telugu-script word frequencies (news, Wikipedia, subtitles, chat) onto
attested Roman spellings (the Dakshina training lexicon, Aksharantar, machine-romanized
CulturaX) and keeps the 20,000 most frequent,
leaving out words English should own: likelier English readings, English loanwords,
one-key slips of much more frequent English words, one-key slips of common English
words (200 per million or more) unless people typed them often enough (oka) or they are
on the reviewed `sources/te-IN/tenglish-guard-allowlist.tsv` (aa, lo, ki, inti), and
attested English misspellings.
The reviewable list is `sources/te-IN/tenglish-guard-unigrams.tsv`; its sources and
checksums are in `sources/te-IN/TENGLISH_GUARD_SOURCES.md`. `compile` writes
`keyboard/tenglish_guard.bin` in the KBTD format `TeluguLexicon` reads (no n-grams,
1,336,246 bytes, mapped read-only by English sessions). English decoding never
autocorrects a listed word and shows only completions of it beside it; Telugu
completions fill empty strip slots once 4 letters and 60% of the word are typed.

