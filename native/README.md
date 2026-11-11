# DecoderCore

The keyboard's English decoder: portable C++20 under `DecoderCore/`, wrapped for iOS by
`iOS/KBDecoderBridge.h/.mm` (Objective-C++ ownership and transport; Swift owns resource
discovery, queues and the decode contract). There is one language model, the word-level
neural search space (NSS, `keyboard/nss-english.nsslm`, trained by `tools/nss`), and one
dictionary, `keyboard/langdata.bin`.

## Pieces

- `PackedLexicon`: the memory-mapped dictionary, KBLM v7 (`tools/build_language_data.py`):
  word frequencies and the spelling trie, nothing else. Every section, offset and trie link
  is validated at load; the blocked-word bitset is installed once from the safety pack.
- `NeuralLanguageModel`: the NSS word model (int8 recurrent kernels, NEON on arm64), its
  context ring and the unknown-word table.
- `NeuralFst`: the NSS graph (Zhang et al., EMNLP Industry 2024) over the dictionary trie,
  with exact vocabulary scores and the published unigram fallback kept as a floor, and
  `NeuralFstSearch`, the lazy joint search C o L o G of the edit/touch channel, the trie and
  the graph.
- `Engine`: one decode path. A typed word is decoded by the joint search; the best completed
  word is committed when it outscores the typed text, which (outside the dictionary) scores
  its context-free unigram mass (`UnigramModel`). An empty word predicts the graph's best
  next words. Glide ranks trie shape candidates by shape and the graph's score in context.
- `Personalization`: the user's unigram counts, confirmed spellings and session keeps, and
  the adoption rule for unknown spellings. `Vocabulary` holds the mutable tries of adopted
  and supplementary words; `Safety` the KBGUARD1 safety pack; `SpatialModel` the key grid
  and channel costs; `Glide` path preprocessing and shape decoding; `Adaptation` the touch
  profile and key-target priors.

## Tests

```sh
native/tests/run.sh
```

builds every test with AddressSanitizer and UBSan and runs it against the shipped
dictionary and model: the dictionary format (every truncated prefix and corrupt field
rejected), personalization, the safety pack, blocked words, the engine's decode and Glide
goldens (`tools/evaluation/fixtures/shared-engine`, written by
`tools/evaluation/autocorrect/GenGolden.cpp`), the NSS model against reference scores, and
the graph's exact scores, lookahead bounds and decisions. `CMakeLists.txt` builds the same
tests with CTest.
