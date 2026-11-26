# Empty strip above the keyboard (iOS bug)

**Status: open. TODO: report to Apple through Feedback Assistant.**

An empty rounded band of the system keyboard panel sometimes appears above Glyph's suggestion
strip. It is drawn by iOS, outside the keyboard extension's view, and Gboard shows it too.

## How it behaves (measured 2026-11-26, iPhone 17)

- It first appears after using the keyboard in the pull-down app search (Spotlight).
- From then on, every app that was **already running** shows it when the keyboard opens, and
  keeps showing it until that app is removed from the app switcher.
- An app launched fresh after that does not show it, even right after Spotlight showed it.
- Removing the Apple keyboard from Settings does not stop it.

## What was ruled out

A debug probe logged every keyboard opening (lifecycle, process ID, view and window heights
with millisecond timestamps) over about 60 openings, with each opening labelled strip / no
strip on the device:

- **Keyboard rebuilds**: iOS already creates a new `KeyboardViewController` for every opening and
  destroys it on close (the extension process stays alive). Strip and no-strip openings are
  built the same way. Restarting the host app is what clears it; the keyboard process did not
  restart.
- **Keyboard height**: our view and window settle at exactly 261pt within about 20ms in every
  opening, strip or not. iOS sometimes starts at 216pt or 226pt first; that did not track the
  strip. Forcing a 216pt → 261pt start on every opening did not clear it.
- **Re-asserting the height** (`f754aea`, reverted in `b9a6007`) did nothing.

Nothing in the extension differs between strip and no-strip openings, and the extension has
no access to the host's keyboard panel, so there is no fix on our side.

## For the Apple report

Repro: use a third-party keyboard in the pull-down app search, then open the keyboard in an app
that was already running → empty band above the keyboard; removing that app from the app
switcher and relaunching it clears it. Attach a screenshot with the band and note that the
extension's view height is identical with and without it.
