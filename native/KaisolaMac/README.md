# Kaisola native macOS preview

This is the reversible Phase 1 native shell. It has its own bundle identifier
(`com.kaisola.mac.preview`), application-support directory, updater channel,
and cursor store. Electron remains the daily driver. The preview never writes
Electron state and never owns, resizes, signals, writes to, or kills a terminal.

The running broker must advertise `terminal-observe-v1`. If an older broker is
still preserving live PTYs without that feature, the preview refuses to replace
it and shows a bounded offline explanation. Electron and the iPhone Companion
remain usable; after those old sessions drain, Electron can safely launch the
current observer-capable broker.

The only broker methods admitted by the local transport policy are:

- `terminal.list`
- `terminal.diagnostics`
- `broker.status`
- `terminal.subscribe`
- `terminal.unsubscribe`

Transient socket loss is recovered with capped exponential backoff and jitter.
The app reconnects after wake and when an offline preview returns to the
foreground, then resumes from the exact in-memory UTF-8 byte cursor. Cursor
checkpoints are stored separately under the native bundle directory with mode
`0600` and are scoped by a hash of the broker identity plus project and terminal
ids. A cold launch still requests the broker's full retained snapshot; the disk
cursor is used only to identify and disclose a real retention gap.

## Standalone broker helper

LocalRelease and Release builds package Node 22.23.1, node-pty 1.1.0, the detached broker, and a
small universal Swift bootstrap under `Contents/Resources/BrokerHelper`. The
manifest records every file's hash/mode and every Mach-O architecture and
designated requirement. The runtime and bootstrap are universal arm64/x86_64;
architecture-specific node-pty prebuilds remain separate.

The app registers the bootstrap as a per-user `SMAppService` LaunchAgent. It
adopts a compatible live broker and starts the packaged broker only when no live
broker exists. An incompatible or ambiguous live broker is left untouched.
Helper upgrades are therefore independent from UI updates and never replace a
process with live PTYs.

Download the checksum-pinned runtimes, generate the project, and build a local
universal ad-hoc LocalRelease app with:

```bash
npm run native:helper:download
cd native/KaisolaMac
xcodegen generate
cd ../..
xcodebuild -project native/KaisolaMac/KaisolaMac.xcodeproj \
  -scheme KaisolaMacPreview -configuration LocalRelease \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/kaisola-mac-release \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

`LocalRelease` keeps the hardened runtime but adds the narrow library-validation
exception required because ad-hoc signatures have no common Team ID. The real
`Release` configuration has no exception and is reserved for Developer ID
distribution. Validate the local app's architecture, launchability, deep
signature, nested helper seal, Sparkle embedding, and LaunchAgent contract:

```bash
npm run native:preflight -- \
  --app /tmp/kaisola-mac-release/Build/Products/LocalRelease/KaisolaMacPreview.app
npm run native:helper:probe -- \
  /tmp/kaisola-mac-release/Build/Products/LocalRelease/KaisolaMacPreview.app/Contents/Resources/BrokerHelper \
  --require-signed-host
```

Distribution validation adds `--require-updates --require-developer-id
--require-notarized`. Those flags intentionally fail a local ad-hoc build.

## Native updates

Sparkle 2.9.2 is pinned for a separate native-preview channel. A build enables
Check for Updates only when both values are present and valid:

- `KAISOLA_SPARKLE_FEED_URL`: an HTTPS appcast URL without credentials or a
  fragment;
- `KAISOLA_SPARKLE_PUBLIC_ED_KEY`: the appcast's 32-byte Ed25519 public key in
  base64.

Pass both as Xcode build settings for a distribution build. Missing, partial,
insecure, or malformed configuration fails closed; local development builds
omit the Info.plist keys and keep the menu item disabled.

## Resource and interaction gates

The exact workloads and counting policy live in `ResourceGates/workloads-v1.json`.
The harness uses one `/usr/bin/footprint -j` invocation over the complete app
tree plus explicitly named detached helpers for both Electron and native.
Reports from different workloads or metric families cannot be compared.

See `ResourceGates/README.md` for capture commands and
`ResourceGates/interaction-matrix-v1.md` for the automated/manual SwiftTerm
matrix. Raw reports belong under ignored `ResourceGates/results/`.

## Development verification

Generate and verify the project with:

```bash
xcodegen generate
xcodebuild -project KaisolaMac.xcodeproj -scheme KaisolaMacPreview \
  -configuration LocalRelease -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/kaisola-mac-release \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
xcodebuild -project KaisolaMac.xcodeproj -scheme KaisolaMacPreview \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kaisola-mac-tests CODE_SIGNING_ALLOWED=NO test
```

Before a preview release, also run the repository-wide Node/Electron floor and
complete the open distribution/manual rows in the interaction matrix. A local
green build is not evidence of Developer ID signing, notarization, app
translocation, a real Sparkle update, or real Claude/Codex continuity.
