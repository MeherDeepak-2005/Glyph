# Typing recorder (schema 3)

Opt-in research log written by `keyboard/Shared/KBTypingRecorder.swift`: by the keyboard
extension (`demo_keyboard/Controller/KeyboardViewController+Recording.swift`) and, for practice
prompts, by the app (`keyboard/App/PracticeView.swift`). Off until the tester turns it on in the
app: Privacy › Typing Research. Secure, email, phone, URL, number, one-time-code and username
fields are never recorded (`permitsTypingData`).

One JSON event per line. Beta builds (`RESEARCH_BETA`) upload the files, encrypted, from the app
(`keyboard/App/ResearchUploader.swift`); the extension never transmits. Getting the data back and
building tables from it: [tools/research/README.md](../tools/research/README.md).

## Files

`<App Group>/typing-recordings/current.jsonl` is the file being written. At 1 MiB, or when the
app's uploader asks, it is sealed into `outbox/<ms since 1970>-<id>.jsonl`. Every file starts with
a `header` event. The outbox keeps at most 200 MiB and 30 days (oldest chunks are dropped, counted
as `capture-outbox-drop` in Keyboard health); an event's strings are capped at 64 characters, a
Glide path at 1,500 samples; at most 512 events wait in memory. Files use complete file
protection, so nothing is written while the phone is locked.

## Common fields

| field | meaning |
|---|---|
| `schema` | 3 |
| `id` | unique per event (uploads and exports can overlap: deduplicate on it) |
| `time`, `uptime` | wall clock (ISO 8601) and `systemUptime` seconds. `uptime` is one clock for the whole device, so app and keyboard events order against each other; it restarts at boot |
| `process` | random per process; `word`, `session` and `layout` numbers are only unique within one |
| `session` | text-field session (`fieldRevision`); a new field or document reset starts a new one |
| `word` | word session ID: every event for one word shares it; it advances on each commit |
| `relatedWord` | the word session an `undo`, `correction-accepted`, `manual-replacement` or `glide-selection` refers back to |
| `layout` | layout revision; the `layout` event describes it |
| `model`, `language`, `build` | decoder, language, build number |

## Events

| kind | written when | key fields |
|---|---|---|
| `header` | first line of every file | `header`: `install` (random ID made when research was first enabled), `appVersion`, `build`, `device`, `system`, `locale`, `profile` (what the tester said: name, hand, thumbs) |
| `layout` | before the first touch on a geometry not described yet (appearance, rotation, resize, rebuilt deck, another page) | `geometry`: keyboard `width`/`height`, `xPitch`/`yPitch`, every key's `label` and rectangle (`x`,`y`,`w`,`h`), `page`, `profile`, screen size and scale. All in keyboard-view points |
| `touch-down` | a finger lands on a key | `text` key label, `x`/`y` where it landed (view points), `radius` contact radius, `dx`/`dy` the offset the decoder used (key pitches from the key centre, clamped to ±1; letters only), `touchID` |
| `touch-up` / `touch-cancel` | that finger lifts | same `touchID`; `x`/`y`/`radius` are the lift position, `dx`/`dy` still the touch-down offset |
| `key` | a key's output reached the field | `text`, `dx`/`dy`, `intervalMs` (gap to the previous key or Backspace) |
| `backspace` | a plain Backspace | `text` the character removed; `evidence` `in-word` when it removed a letter of the word being typed |
| `key-fix` | a letter erased inside its word was retyped as a different letter | `text` erased letter, `replacement` retyped letter, `dx`/`dy` of the retyped tap |
| `suggestions` | the strip was shown | `text` typed word, `replacement` autocorrect candidate, `candidates`, `candidateEvidence` (channel cost, LM score, margin to the typed word), `confidence` |
| `autocorrection` | the engine replaced a word | `text` typed, `replacement` committed, `confidence` (score margin over the typed word), `candidateEvidence` |
| `commit` | a word was finalized | `text` committed, `typed` literal, `keystrokes` [{key, dx, dy, intervalMs}], `durationMs` first letter → commit, `backspaces`, `evidence` |
| `correction-accepted` | the user carried on after an autocorrection, by typing a letter, punctuation, a pick, a glide or a paste (once per correction) | `text` typed, `replacement` correction, `relatedWord`, `sinceMs` |
| `undo` | a correction, pick or glided word was undone | `text` what was removed, `replacement` what came back, `relatedWord`, `sinceMs`; `evidence`: `explicit-autocorrect-undo` (Backspace), `strip-autocorrect-undo` (undo chip), `explicit-retraction` (a glided or picked word deleted whole) |
| `manual-replacement` | the user erased a word and typed a different one | `text` erased, `replacement` typed; `evidence`: `manual-autocorrect-undo` (retyped what an autocorrection had replaced), `manual-fix-of-correction`, `inferred-word-swap`; `relatedWord` for the first two |
| `suggestion-pick`, `prediction-pick` | the user chose a strip entry | `text` replaced, `replacement` chosen |
| `glide-began` | a touch became a Glide | the provisional start letter (already logged as a `key`) was retracted |
| `glide` | the gesture ended, however it ended | see below |
| `glide-selection` | the user swapped a glided word for a strip alternative | `text` committed, `replacement` chosen, `relatedWord`, `sinceMs` |
| `glide-continued` | the user entered more text containing a word character after the glide | `relatedWord`, `sinceMs` from lift |
| `glide-backspaced` | ordinary backspace reached a character of the original glided word | `relatedWord`, `sinceMs` from lift |
| `word-continued` | the user entered more text containing a word character after a tapped word | `relatedWord`, `sinceMs` from the commit; `evidence`: `typed` (committed as typed), `autocorrection`, `pick` (strip suggestion or prediction) |
| `word-backspaced` | ordinary backspace reached a character of that word (the user rejected it) | same fields as `word-continued` |
| `prompt-shown`, `prompt-done` | practice (app) | `prompt`: `id`, `target`, `mode` (`glide`, `tap`, `sentences`), `result` (what was in the field); `evidence` `matched`, `skipped` or `left` |
| `session-end` | field closed | — |

### `glide`

| field | meaning |
|---|---|
| `glide.path` | every touch sample UIKit delivered (coalesced, so up to the screen's touch rate), the lift point last: `[x, y, ms since the first sample, contact radius]` in keyboard-view points. The decoder itself saw one sample per callback and no lift point |
| `glide.outcome` | `committed`; `rejected` (nothing matched); `cancelled` (the system took the touch); `dropped` (the host text changed before the word could be inserted) |
| `text` | the committed word (lowercase), with `word` = the same word session as its `commit` |
| `candidateEvidence` | the winner and strip alternatives with their shape cost (`spatialCost`) |
| `confidence` | winner's score margin over the runner-up (absent with a single candidate) |
| `glide.source` | which decode gave the word: `preview` (the word shown under the finger), `cache`, `session`, `final` |
| `glide.previews`, `durationMs`, `glide.liftToInsertMs` | preview decodes during the gesture, gesture length, lift → inserted |
| `glide.startKey`, `glide.truncated` | key the finger started on; true when the path was cut at 1,500 samples |

## Labels for training

Commits are observations, not labels: an autocorrection (`automatic-unverified`), a literal word
(`literal-unverified`) or a glided word (`glide-unverified`) may be wrong. Supervision comes from:

- **Practice prompts**: everything between `prompt-shown` and `prompt-done` (same install, by
  `uptime`) was an attempt at `prompt.target`, including the attempts the decoder got wrong.
- **Glide**: `glide-selection` (the chosen word is the label for that path), `undo` with
  `explicit-retraction` or `glide-backspaced` (the user edited the original word; the intended word is unknown),
  and `glide-continued` (weak evidence for the committed word that a later edit can override).
  Follow-up tracking stays within the current document session and tracks up to four glides
  while their text remains within 96 characters before the cursor. Cursor moves and external
  document changes end tracking. The export preserves both follow-up signals and their timing.
- **Word corrections**: `undo` and `manual-replacement` with a `relatedWord` (the correction was
  wrong and the restored word is the label), `correction-accepted` (weak: it stood), picks.
- **Tapped words**: `word-backspaced` (the word was rejected; the next committed word in the same
  field is the likely replacement) and `word-continued` (weak evidence the word was right). They use
  the same tracking as Glide: the last four words entered (glided, typed, autocorrected or picked),
  while their text stays within 96 characters before the cursor.
- **Per-key error model**: `key-fix` pairs; `touch-down` positions against the `layout`
  rectangles for words that were never edited afterwards.
- **Typing speed**: `intervalMs` on keys (gaps over 5 s are pauses), `durationMs` per word.

`tools/research/build_datasets.py` does these joins: `words.tsv` (one row per tapped word with its
strip candidates, `outcome` and `replaced_by`), `autocorrect.tsv` and `glides.jsonl` (with `replaced_by`).

The aggregate counterparts on the Keyboard health screen (no text) are `keyTaps`, `keyErasures`,
`keyConfusions`, `backspaceTaps` and `interKeyIntervalBins` in `KBDiagnostics.Snapshot`; beta
builds upload that snapshot once a day as a `diagnostics` line.

## Schema 2 → 3

Added: `header`, `layout`, `glide`, `correction-accepted`, `prompt-*`; `x`/`y`/`radius` on
touches; `sinceMs`; `confidence` and `candidateEvidence` on `autocorrection`; `relatedWord` on
`manual-replacement`; chunked files with an outbox instead of two rotating 5 MiB files. A glide
commit no longer inherits the keystrokes of a word that was being typed when the gesture began.
