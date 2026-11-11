# Extension Build Configuration

`Extension.xcconfig` is the tracked base configuration for the keyboard extension.
It fails closed: remote media and internal neural artifacts are disabled unless a
developer supplies the corresponding ignored local configuration.

## KLIPY

1. Set `KLIPY_API_KEY` in the shell and run the configurator from the repository root:
   ```sh
   KLIPY_API_KEY='your_partner_key' \
   KLIPY_CONTENT_FILTER_APPROVED=YES \
   ./tools/configure_klipy.sh
   ```
   This writes an ignored, mode-`0600` `Klipy.xcconfig`; it never prints the key.
2. Set `KLIPY_CONTENT_FILTER_APPROVED = YES` only after the Partner Panel content
   filter and production account have been reviewed.
3. The configurator enables remote GIF and Sticker requests. Delete
   `Config/Klipy.xcconfig` to return to the fail-closed defaults.
4. Clean and rebuild the extension, then inspect the built extension's `Info.plist`
   to confirm all three values expanded.

For a one-off command-line build, Xcode build-setting overrides also work:
```sh
KLIPY_API_KEY='your_partner_key'
xcodebuild -scheme keyboard -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  KLIPY_API_KEY="$KLIPY_API_KEY" \
  KLIPY_CONTENT_FILTER_APPROVED=YES KLIPY_MEDIA_ENABLED=YES build
unset KLIPY_API_KEY
```
The first `KLIPY_API_KEY` is a shell variable; the second is an Xcode build setting
expanded into the extension's `Info.plist`. It is not a runtime environment variable.

Do not use Xcode Scheme environment variables. A system-hosted keyboard extension
does not inherit them. `Klipy.xcconfig` and `Secrets.xcconfig` are ignored by Git;
the partner key is a public, rotatable mobile client identifier, but it still must
not be committed.

Release verification fails when media is enabled without both a non-empty key and
the approved filter flag. Emoji remains local, and typing performs no KLIPY network
request; GIF and Sticker traffic starts only after an explicit search.

## Language model

The word-level NSS model (`tools/nss`, an `.nsslm` file run by the shared C++ engine,
not Core ML) is the English decoder and its only language model. `Extension.xcconfig`
sets `NSS_ENABLED = YES` and `NSS_MODEL = keyboard/nss-english.nsslm`; the build phase
(`tools/nss/install_nss.sh`) bundles it and `KeyboardEngine.shared` maps it at launch.
To try another export, override `NSS_MODEL` in `Secrets.xcconfig` or on the command line:

```sh
xcodebuild -scheme keyboard -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' NSS_MODEL=$PWD/tools/nss/artifacts/chat-final.nsslm build
```

Audit a shipping extension with `tools/verify_release_artifacts.py --allow-neural`
(the extension bundles the NSS model).

## Debug builds

Debug compiles C, C++ and Objective-C++ with `-Os` (`GCC_OPTIMIZATION_LEVEL = s`, set
once at project level); Swift stays at `-Onone`. At `-O0` the decoder core made a Debug
keyboard 20-25x slower per keystroke than Release on an iPhone 17 (16-20 ms against
0.8 ms, swipe previews ~100 ms against 8 ms), so a Debug install misrepresented the
keyboard. With the C++ optimised, Debug stays within 2x of Release (1.6 ms per keystroke).
Step through decoder C++ in `native/tests`, which builds with `-g` and sanitizers, or
set the level back to 0 locally. `tools/perf/device_perf.sh` measures either build.
