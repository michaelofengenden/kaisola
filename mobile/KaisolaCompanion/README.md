# Kaisola Companion preview

This is the native, iPhone-first preview shell for Kaisola Companion. It uses
the canonical desktop protocol fixtures and richer local demo data so the
product can be evaluated before pairing or a network transport is enabled.

The preview is deliberately read-only with respect to the Mac. Permission and
composer actions only mutate in-memory demo state and are labeled as preview
actions. There is no socket, Bonjour advertisement, credential, or provider
connection in this target yet.

## Open in Xcode

```sh
cd mobile/KaisolaCompanion
xcodegen generate
open KaisolaCompanion.xcodeproj
```

Choose an iPhone simulator and run the `KaisolaCompanion` scheme.

## Command-line build

```sh
xcodebuild \
  -project mobile/KaisolaCompanion/KaisolaCompanion.xcodeproj \
  -scheme KaisolaCompanion \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/kaisola-companion-derived \
  CODE_SIGNING_ALLOWED=NO build
```
