# Glyph engineering handbook

**Repository snapshot:** `22417f4` · **Prepared:** 20 November 2026

Glyph is an iOS system keyboard with a companion app. It handles taps, next-word prediction, autocorrect, and Glide using an on-device English decoder. The app guides setup, provides themes and practice, and exposes keyboard health and privacy controls. The extension runs inside the iOS keyboard lifecycle and edits text in the active app through the system text proxy.

For your first change, locate the owner of the behavior before deciding where to edit. The **keyboard view** owns interaction, the **extension controller** owns edits to the host document, and the **decoder** owns candidate search and correction decisions. A change often touches two layers, especially when it alters what the suggestion strip promises to insert.

- [Project history](#project-history)
- [Architecture and ownership](#architecture-and-ownership)
- [A tap from touch to committed text](#a-tap-from-touch-to-committed-text)
- [How the decoder searches and scores](#how-the-decoder-searches-and-scores)
- [Glide from finger movement to text](#glide-from-finger-movement-to-text)
- [Settings personalization and research](#settings-personalization-and-research)
- [Build and release](#build-and-release)
- [Validation and current evidence](#validation-and-current-evidence)
- [Planning and reviewing changes](#planning-and-reviewing-changes)

## Project history

| Period | What changed | Where that leaves the project |
| --- | --- | --- |
| June–July 2026 | The first keyboard used iOS spell checking. The deck, theme controls, emoji, clipboard and media work followed. N-gram autocorrect and experiments with neural rescoring or search priors accumulated. | The companion app and extension UI grew alongside the decoder. Old scorer and Core ML discussions describe experiments and earlier generations. |
| 20–22 October | English candidate generation and decoder policy moved into portable C++. The project experimented with a GRU and built a 30,000-word neural vocabulary. | Swift still owns UIKit and host text behavior. C++ became the place to change English search behavior and run platform-neutral tests. |
| 31 October–1 November | The team implemented the published Neural Search Space (NSS) graph approach, then added exact neural scores and optimized lookahead. | The neural model participates while the engine searches the lexicon. The published graph is the starting point, with explicit local choices for scoring, touch and commit policy. |
| 6–11 November | NSS became the English decoder from the first word. The team reduced its memory cost, reused graph resources and moved the QWERTY deck and geometry into a layout pack. The branch consolidated on English NSS. | Tap and Glide share a neural model and dictionary. This checkout's product targets are iOS, and the tracked C++ core is portable. The older Android integration is historical context. |
| 16 November | The branch landed the research beta, spelling rules and expanded unigram dictionary. An optimized native kernel reduced inference cost. | The current architecture combines neural context, dictionary probabilities, edit and touch costs, and guarded text commits. Training, product rules and app integration have separate validation paths. |

History anchors in Git are `18ed34c`, `e7c61a9`, `d77aa92`, `428e985`, `7aead50`, `64fcf38`, `af33128`, `dc46ddb`, `aacaa52` and `3ad3443`.

## Architecture and ownership

The host app owns the text and cursor. Glyph receives a view of that state through iOS, offers candidates, then checks the current document again when applying an edit.

```text
Touch or gesture
  → UIKit keyboard view
  → Extension controller → iOS text proxy → Active text field
           ↓                     ↑
       Swift engine              │ verified result or literal input
           ↓                     │
       Objective-C++ bridge      │
           ↓                     │
       C++ decoder session ──────┘ via Swift presentation and commit
           ↑
       Layout geometry + lexicon + neural model + safety data

Companion app ↔ App Group settings and files ↔ Keyboard extension
Offline tools → model, dictionary and layout assets → Xcode bundle
```

| Layer | Responsibility | Start here |
| --- | --- | --- |
| Companion app, `keyboard` target | SwiftUI onboarding, setup status, appearance and Theme Studio, practice, achievements, privacy, Keyboard health and research upload. | [App entry](../keyboard/App/keyboardApp.swift), [settings and health views](../keyboard/App/ContentView.swift), [practice](../keyboard/App/PracticeView.swift) |
| Keyboard view | UIKit key deck, hit testing, tap and swipe events, haptics, long-press alternatives, repeat, cursor hold, suggestion strip and panels. | [Touch handling](../keyboard/Views/Keyboard/KeyboardView+Touch.swift), [layout](../keyboard/Views/Keyboard/KeyboardView+Layout.swift), [suggestion strip](../keyboard/Views/SuggestionBar.swift), [panel routing](../keyboard/Views/Keyboard/KeyboardView+Panels.swift) |
| Extension, `demo_keyboard` target | `UIInputViewController` lifecycle, active field, proxy mutations, suggestion presentation and selection, auto-shift, undo, Glide commits and recording hooks. | [Controller](../demo_keyboard/Controller/KeyboardViewController.swift), [host reconciliation](../demo_keyboard/Controller/KeyboardViewController+HostDocument.swift) |
| Swift engine | Loads resources, coordinates work queues and cancellation, adapts touch and personalization data, translates native output into snapshots and produces key priors. | [Engine setup](../keyboard/Engine/Decoder/KeyboardEngine.swift), [decode adapter](../keyboard/Engine/Decoder/KeyboardEngine+Suggestions.swift), [request and snapshot contract](../keyboard/Engine/DecodeContract.swift) |
| Objective-C++ bridge | Marshals strings, coordinates, revisions and cancellation between Swift and C++. Wraps native engine sessions for tap and Glide. | [KBDecoderBridge.mm](../native/iOS/KBDecoderBridge.mm) |
| Portable C++20 core | Packed lexicon and trie, neural inference and state caching, weighted search, commit policy, Glide shape matching, safety and adaptation primitives. | [Public engine API](../native/DecoderCore/include/Engine.hpp), [engine implementation](../native/DecoderCore/src/Engine.cpp), [neural graph](../native/DecoderCore/src/NeuralFst.cpp) |

The app and the extension have separate lifecycles. They share selected settings and files through the App Group. Treat each text-field session and each Glide gesture as a separate unit of state within the extension.

## A tap from touch to committed text

1. **Capture and route.** `KeyboardView+Touch.swift` hit-tests the key and can attach a `KeyTap` offset measured relative to the key in keyboard pitches. `routeInsert` sends normal text to the controller and routes panel search input to the active panel. The English layout pack defines the keyboard pages and offsets and also installs the decoder's letter grid. Moving a letter changes both the deck and decoding geometry. [Touch handling](../keyboard/Views/Keyboard/KeyboardView+Touch.swift) · [English layout pack](../tools/language_packs/README.md)
2. **Insert the literal immediately.** `handleInsert(_:tap:)` lives in `KeyboardViewController+Clipboard.swift`, even though it handles ordinary typing. For a word character it inserts into the host, records aligned touch evidence, updates the word buffer and schedules suggestions. That immediate insert keeps typing responsive while the engine is busy. [Insert and boundary handling](../demo_keyboard/Controller/KeyboardViewController+Clipboard.swift)
3. **Build a request tied to the document.** `scheduleSuggestions` advances a generation. `refreshSuggestions` reads the proxy, extracts the trailing word and up to eight prior words, and builds a `DecodeRequest` carrying the field revision, document revision, word session, generation and layout revision. Tap evidence travels only when it lines up with the word. The engine lowercases input, adjusts touch evidence and forwards it with native cancellation and the vocabulary and personalization identity. [Suggestion scheduling](../demo_keyboard/Controller/KeyboardViewController+Suggestions.swift) · [Decode adapter](../keyboard/Engine/Decoder/KeyboardEngine+Suggestions.swift)
4. **Publish a valid result.** `EngineSession::decode` returns suggestions, evidence and an optional correction. `KeyboardEngine.decode` cancels superseded work and delivers the snapshot on the main queue. Before rendering it, the controller checks the request generation and live host document. `SuggestionCasePolicy` maps canonical words to the display case used by the strip and the commit path. An empty word requests next words. A partial word requests completions and correction candidates. [Engine implementation](../native/DecoderCore/src/Engine.cpp) · [Case policy](../keyboard/Engine/DecodeContract.swift)
5. **Commit at a boundary or on a pick.** Space and applicable punctuation run `applyAutocorrectIfNeeded` against the currently valid presented snapshot. `replaceHostSuffix` verifies the expected suffix and uses `HostSuffixReplacementPlan` to check progress during deletion before inserting the replacement. Without a valid correction, the typed word stays in place. Return uses its own handler, which also tries correction before inserting a newline. A strip pick can complete the partial word, insert a prediction, revert a correction, or replace a glided word. [Autocorrect](../demo_keyboard/Controller/KeyboardViewController+Autocorrect.swift) · [Suffix replacement](../keyboard/Shared/HostSuffixReplacementPlan.swift) · [Pick and delete](../demo_keyboard/Controller/KeyboardViewController+AutoShift.swift)
6. **Resolve undo and move forward.** A correction retains the original, replacement, trailing separator and word session for undo. Backspace or the revert suggestion can restore a verified suffix. An explicit autocorrect undo can protect the original through the keep list. Host callbacks, cursor or selection moves and field changes can invalidate buffered edits, displayed suggestions and in-flight results. [Undo handling](../demo_keyboard/Controller/KeyboardViewController+AutoShift.swift) · [Host document state](../keyboard/Shared/HostDocumentReconciler.swift)

**Example.** For “I think thats”, the literal `thats` appears as the taps arrive. The decoder can propose `that's` because the apostrophe rule lowers the cost of a missing apostrophe. Space can replace the literal with the correction shown by the strip when host state and field policy permit it. Backspace can restore `thats` while the replacement still matches.

Watch two failure modes when editing this path. A callback that was valid when scheduled can be stale when delivered. Also, iOS exposes limited context and proxy edits are individual operations, so a suffix plan can stop partway if the document changes. Cover rapid typing followed by Space, a caret move before a result arrives, a selection, and a host callback during an edit. Field policies are independent: secure fields suppress suggestions, while host autocorrection settings and several field types also suppress automatic replacement. [Field policy](../demo_keyboard/Controller/KeyboardViewController.swift)

## How the decoder searches and scores

### Model dictionary and graph

**The neural model provides context.** The bundled `nss-english.nsslm` is a 3.92 MB quantized export of a one-layer CIFG-LSTM trained on Tatoeba and WikiText-103. It has 670 recurrent cells projected to 96, tied 96-dimensional embeddings, and about 3.36 million parameters. It predicts over about 30,000 words plus special tokens. `NeuralWordModel` executes it in C++. The ARM64 kernel uses int8 weights, block-quantized int16 activations and NEON operations. [Model manifest](../keyboard/nss-english.manifest.json) · [Kernel and training notes](../tools/nss/README.md)

**The dictionary provides spellings and unigram mass.** `PackedLexicon` opens `langdata.bin`. Its 187,462 forms include 73,174 additions over the reference list. The packed trie gives search a path from letters to word IDs. Unigram weights cover words outside the neural vocabulary and provide a floor where configured. The production pack carries zero bigram and trigram rows. `langdata.kbmodern` adds preservation and automatic-replacement restrictions for protected spellings. `safety.kbguard` supplies candidate safety data. Dictionary edits and neural vocabulary edits have different impact because the model's output rows are tied to its ordered vocabulary. [Dictionary evidence](unigram-v1/README.md) · [Packed lexicon](../native/DecoderCore/src/PackedLexicon.cpp)

**NSS turns probabilities into a searchable graph.** `NeuralFst::update` prepares root scores for committed context. `ContextRing` caches recurrent states across keystrokes and across the short host context window. The engine can reuse work while a user types a word and reset it when relevant field, vocabulary, layout or word identity changes. Shared model and lexicon tables can serve multiple sessions. Each session owns its mutable graph and search state. Exact mode uses each modeled word's probability, with an optional unigram floor. An out-of-vocabulary dictionary word receives a share of the context's `<unk>` probability according to its dictionary mass. Arc thresholds govern state expansion. [Graph implementation](../native/DecoderCore/src/NeuralFst.cpp) · [Runtime interfaces](../native/DecoderCore/include/Engine.hpp) · [Published reproduction context](nss-paper/CONFORMANCE.md)

### Candidate search and commit policy

`NeuralFstSearch` explores the lexicon trie, the edit and touch channel, and the language graph together. A hypothesis combines the completed language score with an optimistic prefix score before pruning. This lets context preserve a promising prefix while the input is still ambiguous. A surviving word-ending path can open a continuation state, enabling missing-space candidates. Tap search can reuse existing prefix work on the next key. The main ranking principle is **language log probability minus weighted edit or touch cost**, with subsequent product adjustments. [Search and graph](../native/DecoderCore/src/NeuralFst.cpp)

`EngineSession::decode` handles two distinct outcomes. It ranks suggestions for display and chooses whether a complete candidate can replace the literal. It gives the typed word its own score, filters blocked candidates, applies first-letter costs and blends in a unigram component for sentence-start single words. The default non-word allowances in `Engine.hpp` are 2.0 in ordinary context, 1.5 at sentence start, and 0.0 in the defined mid-sentence capitalized case. A recognized dictionary word starts with a zero allowance. Split and same-sound rules apply their own conditions. The keep list and protected-spelling policy can veto automatic replacement. Evidence rows include the source, scores, cost and margin against the literal. [Engine options](../native/DecoderCore/include/Engine.hpp) · [Commit implementation](../native/DecoderCore/src/Engine.cpp)

The production spelling rules reduce costs for vowel swaps, missing apostrophes, duplicated or missing doubled letters, and certain sound-alike consonants. First-letter changes are penalized, taps are measured relative to the key touched, and split corrections require stronger evidence. Same-sound commit can grant extra allowance when the candidate is sufficiently ahead of the runner-up. The extra frequency prior was measured and rejected. Read the decision log before retuning, and record new gain and cost measurements there. `KB_nssRules=0` disables the rule group in a tuning build. [Rules and ablations](nss-rules.md) · [NssRules.hpp](../native/DecoderCore/include/NssRules.hpp)

## Glide from finger movement to text

1. **Start and track.** The deck starts with a normal key touch. Once it becomes a Glide, it retracts the provisional letter, tracks the path and supplies the current layout. The controller captures the starting context and manages preview identity and cancellation. [Touch tracking](../keyboard/Views/Keyboard/KeyboardView+Touch.swift) · [Glide controller](../demo_keyboard/Controller/KeyboardViewController+Glide.swift)
2. **Score a gesture in its own session.** Swift's `beginGlideSession`, `updateGlideSession` and `finishGlideSession` wrap a bridge session backed by a separate native `EngineSession`. `updateGlide` maps points to the key grid, uses neural lookahead inside the gesture trie search, and ranks by shape and context. Dynamic learned words can join as shape-matched candidates. In this checkout, packed words use graph probabilities, while dynamic words outside the packed lexicon enter through a unigram prior and personal boosts. Glide ranking also applies personal and safety adjustments. [Swift Glide adapter](../keyboard/Engine/Decoder/KeyboardEngine+Glide.swift) · [Native Glide entry point](../native/DecoderCore/src/Engine.cpp)
3. **Finalize or drop.** At lift, the controller can reuse a displayed prediction if the remaining path and endpoint movement are small. Otherwise it finishes the streaming session or uses the applicable final decode path. `commitGlidedWord` verifies the live host document and context before inserting the winner with a trailing space. If the document moved, the result can be dropped. The strip offers alternatives that can replace the committed word, and undo records the retraction. [Glide commit and preview handling](../demo_keyboard/Controller/KeyboardViewController+Glide.swift)

A Glide change can influence preview stability, lift-to-insert latency and final quality independently. Exercise first swipe in an empty field, cancellation, a changed ending, rotation, switching fields during a gesture, and selection of an alternative.

## Settings personalization and research

| Area | Data and behavior | Pointers |
| --- | --- | --- |
| Settings and presentation | `KBSettings` uses shared defaults and change notifications. The controller can rebuild the deck and reapply presentation. The layout JSON is compiled into a versioned pack used by rendering and geometry. | [Settings](../keyboard/Shared/KBSettings.swift), [layout compiler workflow](../tools/language_packs/README.md) |
| Keyboard panels | Emoji search and recents use bundled/local data. Clipboard history uses shared storage and access checks. Remote GIF and sticker search is gated by Full Access and KLIPY build configuration, including the content filter. Panel search routes keys locally. Offscreen media resources can be dropped under memory pressure. | [Panel lifecycle](../keyboard/Views/Keyboard/KeyboardView+Panels.swift), [clipboard](../keyboard/Shared/KBClipboard.swift), [media configuration](../Config/README.md) |
| Local adaptation | `UserModel` and `Personalization` hold word counts, confirmations and keeps. The engine loads and saves local state, filters learnable words and can use learned words in Glide. Tap correction consults the keep flag. The main tap score stays driven by the graph and channel. Touch-profile learning can adjust tap offsets. Reset advances the personal-data epoch and invalidates cached work. | [UserModel](../keyboard/Engine/UserModel.swift), [correction feedback](../keyboard/Engine/Decoder/KeyboardEngine+Correction.swift), [personal data](../keyboard/Shared/KBPersonalData.swift) |
| Health and research | Keyboard health exposes aggregate metrics. Opt-in research separately records text, touch geometry, suggestion evidence and outcomes in schema 3 JSONL. Capture requires an eligible field with no declared text content type and one of the allowed keyboard types. Practice also produces prompt and outcome events. | [Capture gates](../demo_keyboard/Controller/KeyboardViewController+Recording.swift), [recorder schema](typing-recorder.md), [diagnostics](../keyboard/Shared/KBDiagnostics.swift) |

The extension writes research events into App Group storage. Files seal into an outbox at 1 MiB or at upload time. The companion app's beta uploader compresses and encrypts chunks with HPKE before upload to CloudKit. The team's ingestion tools retrieve and decrypt chunks and join events into evaluation tables. Practice targets and explicit choices or undo events provide stronger supervision than an automatic commit. Treat decrypted text as participant data and follow the handling and deletion workflow in the research runbook. [Research upload and ingestion runbook](../tools/research/README.md)

## Build and release

1. Open `keyboard.xcodeproj` on a Mac and select the shared `keyboard` scheme. The project declares iOS 18.0 as its deployment target. For physical-device testing, use signing that provisions both the app and the extension with the matching App Group. Run the companion app, enable Glyph in iOS keyboard settings, and select it via the globe. Use practice to start and a second app to verify system-host behavior. [Xcode targets](../keyboard.xcodeproj/project.pbxproj) · [Setup screens](../keyboard/App/ContentView.swift)
2. Confirm the build's resources and configuration. The extension's synchronized resource membership includes the checked-in dictionary, sidecar, English layout and safety pack. The NSS build phase takes `NSS_MODEL` from `Config/Extension.xcconfig` and copies it to `nss-english.nsslm` in the extension. The supplied model ships in this checkout. If it fails to load, Swift can preserve typed input without offering neural corrections. Remote media defaults to disabled. [Extension configuration](../Config/Extension.xcconfig) · [NSS installer](../tools/nss/install_nss.sh) · [Engine initialization](../keyboard/Engine/Decoder/KeyboardEngine.swift)
3. For a build intended to ship, inspect the built `demo_keyboard.appex` with `python3 tools/verify_release_artifacts.py /path/to/demo_keyboard.appex --allow-neural`. The checked-in audit records about 14.5 MB against a 25 MB gate and lists hashes for the packaged resources. Confirm the actual archive's signing, capabilities, privacy settings and assets. The current app Debug and Release project configurations define `RESEARCH_BETA`, so review that flag and the CloudKit environment with the intended distribution. [Artifact verifier](../tools/verify_release_artifacts.py) · [Recorded bundle audit](../BuildArtifactManifest.json) · [CloudKit setup](../tools/research/README.md)

**When older instructions differ.** The unigram design note describes a dictionary-install step and `NSS_DICTIONARY_DIR`. In this checkout the dictionary pair already sits in `keyboard/`, and the installer copies only the model. The current dictionary SHA-256 matches the recorded bundle audit. The model manifest's dictionary SHA-256 refers to the earlier training/export reference lexicon. Use the project file, installer and bundle audit to establish what is packaged. Use the model manifest to establish which model, vocabulary and training inputs were exported. `native/README.md`, the NSS paper conformance notes and the dictionary note also describe earlier scorer, Glide or rule behavior. For runtime changes, start with the current entry points in this handbook. [Dictionary design history](unigram-v1/README.md) · [Current project wiring](../keyboard.xcodeproj/project.pbxproj)

### Asset pipelines

| Change | Where it begins | What to verify |
| --- | --- | --- |
| Deck and key geometry | `tools/language_packs/sources/en-US/qwerty.json` → layout compiler → `english_layout.kbpack` | Layout pack tests, native key grid, tap and Glide behavior on device. |
| Word forms and frequencies | `tools/vocabulary/build_unigram.py` and the generated unigram ledger → `langdata.bin` and companion policy sidecar | Pack compatibility, coverage, false corrections, native lookahead/search, and bundle inventory. |
| Model and vocabulary | `tools/nss` builds corpora, trains and evaluates checkpoints, and exports `.nsslm`, a manifest and golden scores | Preserve output-row alignment with the ordered vocabulary. Run Python model tests, C++ score goldens, typing benchmarks and on-device latency/memory. |
| Safety data | `tools/build_safety_lexicon.py` and its inputs → `safety.kbguard` | Automatic corrections, suggestions, next words, Glide, and learning follow their intended restrictions. |

Asset references: [Layout](../tools/language_packs/README.md) · [Vocabulary](../tools/vocabulary/README.md) · [NSS training and export](../tools/nss/README.md) · [Safety pack builder](../tools/build_safety_lexicon.py) · [Third-party notices](../THIRD_PARTY_NOTICES.md)

## Validation and current evidence

| Check | How to run or find it | What it establishes |
| --- | --- | --- |
| Native behavior | From the repo root, `cmake -S native -B /tmp/glyph-native -DCMAKE_BUILD_TYPE=Release`, then `cmake --build /tmp/glyph-native` and `ctest --test-dir /tmp/glyph-native --output-on-failure`. | Engine contract, packed lexicon, graph semantics, model goldens and raw decoder. |
| iOS integration | Run `keyboardTests` and `keyboardUITests` from the `keyboard` scheme on a compatible destination. | Hosted behavior, strip and commit agreement, undo, field changes, bridge and startup, pack geometry, surface and device exercises. |
| Autocorrect performance tests | From `tools/evaluation/autocorrect`, run `python3 performance_tests.py`. The harness uses the production decoder configuration and compares with saved dev n-gram and CoreV4 references. Corpus files and outputs are generated or local. See the harness guide for setup. | Held-out correction and top-three accuracy, checks for preserving valid input, and replay latency. Keep tuning and held splits distinct. |
| Physical-device performance | Use `tools/perf/device_perf.sh` and the device benchmark pathway in the autocorrect guide. Check memory across typing, Glide, emoji, clipboard and media. | Startup cost, latency, footprint and lifecycle on iOS hardware. A desktop replay measures a different workload. |
| Release bundle | Run the verifier on the actual `.appex` and confirm installation and first launch on a signed build. | Resource sizes and contents, configured features and runtime startup. |

Validation references: [Native targets](../native/CMakeLists.txt) · [Autocorrect harness](../tools/evaluation/autocorrect/README.md) · [Performance tests](performance-tests.md) · [Device timing script](../tools/perf/device_perf.sh)

### Recorded results

The 16 November working-copy report compares held cases shared by all listed systems. Prod and dev use simulated taps where available. The CoreV4 reference used `engxx.abn` with no taps. The dev and CoreV4 columns come from stored runs.

| Held measure | Glyph NSS | Dev n-gram | CoreV4 |
| --- | ---: | ---: | ---: |
| ECPS real misspellings fixed (9,622) | 90.63% | 90.69% | 89.77% |
| ECPS target in the top three (9,622) | 95.58% | 95.04% | 95.27% |
| Generated typos fixed (5,606) | 91.92% | 89.32% | 79.36% |
| Contractions restored in sentences (3,493) | 85.23% | 76.24% | 17.58% |
| Birkbeck misspellings fixed (15,136) | 32.56% | 42.63% | 41.20% |
| Unknown names changed (292, lower is better) | 49.32% | 74.32% | 80.82% |
| Clean ECPS words changed (9,522, lower is better) | 0.48% | 0.42% | 0.88% |
| Typing replay p95 per word (1,000 ECPS words) | 13.29 ms | 6.32 ms | 20.27 ms |

The report shows gains on synthetic typos, contractions and rare-word or name preservation against the two references. Glyph still changed nearly half the unknown names in the test and fixed fewer Birkbeck misspellings than either reference. The timing references were captured on different days and builds. The updated p95 above comes from the working copy's `prod-2026-11-16-0415` run. The older iPhone 17 comparison used only 140 centered-tap cases and an earlier Glyph configuration. Use the device comparison as historical evidence and inspect rule-level ablations for each guardrail before changing product policy. [Working-copy performance report](performance-tests.md) · [iPhone comparison](keyboard-comparison-2026-11-02/README.md) · [Rule measurements](nss-rules.md)

## Planning and reviewing changes

| If the issue looks like this | Start with this boundary | Evidence that will help review it |
| --- | --- | --- |
| The strip offers a word, but Space writes another | `DecodeSnapshot` → `SuggestionCasePolicy` → `applyAutocorrectIfNeeded` and host suffix validation | Reproduce with exact text and field type. Compare shown candidate, actual commit and generation. Verify undo and a fast Space press with work pending. |
| Suggestions sound wrong in context | `contextWords` → `ContextRing` → `NeuralFst` and the candidate graph | Compare candidate evidence and the literal's margin with and without context. Check first word, sentence breaks, field transitions and real-word errors. |
| Misspellings, names or Tenglish are overcorrected | `NssRules.hpp`, the literal comparison in `Engine.cpp`, and dictionary preservation | Use held guardrail and correction buckets together. For a rule proposal, include an ablation and record gain, cost and decision in the rule log. |
| Tap and Glide are inaccurate on the same keys | Layout pack → installed grid, tap offsets and Glide layout | Verify keyboard rectangles and pitches before tuning language scores. Compare centered and off-center taps, swipes, rotation and device sizes. |
| A newer model improves offline metrics but feels slow | Model export and `NeuralWordModel` → graph lookahead and search → UI delivery | Compare held typing accuracy, cold start, retained-prefix latency, physical-device p95 and peak extension memory. Check score goldens and package size. |
| Personal data or capture changes | `KBPersonalData`, `UserModel`, field gates, recorder and app uploader | Exercise fresh and existing stores, reset while work is pending, excluded fields, opt-in and offline upload recovery. |

Three questions are worth asking when proposing an architectural change:

- **Who owns the decision and who owns the mutation?** A decoder can decide that a candidate is strong. The controller still needs current host evidence before changing text. Show what happens when the result is cancelled or the cursor moves.
- **Which state may be shared, and what invalidates it?** Draw the change across field, word, gesture, layout, vocabulary and personalization boundaries. Distinguish immutable model tables from mutable session state and persisted user data.
- **Which trade-off are we making visible?** Identify affected behavior, the baseline, expected quality gain and acceptable change in false corrections, latency or memory. For user-visible changes include a real host-field scenario as well as engine coverage.

For an architecture proposal, include one before-and-after flow, the affected files or assets, the state that crosses each interface, failure and reset behavior, and measurements for the cases above that your change touches. This gives reviewers enough context to judge where the change belongs and what it must preserve.
