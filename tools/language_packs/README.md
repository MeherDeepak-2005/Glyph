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
