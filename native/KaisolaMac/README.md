# Kaisola native macOS preview

This is the reversible Phase 1 native shell. It has its own bundle identifier
(`com.kaisola.mac.preview`) and application-support directory. It reads the
shipping Electron broker's private rendezvous metadata, but never writes
Electron state and never starts, owns, resizes, signals, or kills a terminal.

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

Generate and verify the project with:

```bash
xcodegen generate
xcodebuild -project KaisolaMac.xcodeproj -scheme KaisolaMacPreview \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/kaisola-mac-release CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KaisolaMac.xcodeproj -scheme KaisolaMacPreview \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/kaisola-mac-tests CODE_SIGNING_ALLOWED=NO test
```
