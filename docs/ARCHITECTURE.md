# Native architecture

Kaisola uses a native shell with explicit process and trust boundaries.

## Layers

1. **SwiftUI/AppKit application** — windows, navigation, terminal surfaces,
   editor/workspace UI, settings, updates, and platform lifecycle.
2. **Feature services** — ACP, Git, files, Mesh, usage, accounts, Companion, and
   persistence. UI talks to typed Swift interfaces rather than shelling out.
3. **Shared packages** — `KaisolaCore` and `KaisolaBrokerProtocol` own portable
   wire models, framing, cryptography, and compatibility constants shared with
   the iPhone app.
4. **Runtime boundary** — the detached Node broker owns durable PTYs. It is a
   deliberately small compatibility island, launched and verified by a signed
   Swift bootstrap. Replacing it requires wire compatibility and live session
   drainage; UI work does not expand it.
5. **External adapters** — ACP and MCP processes remain isolated stdio/network
   peers with capability negotiation and bounded inputs.

## UI policy

- Prefer SwiftUI for composition and state-driven UI.
- Use AppKit-backed views for terminal, text-system, window, and menu behavior.
- The rich code editor is a checked-in CodeMirror bundle served through a
  two-resource private `WKURLSchemeHandler` in an ephemeral `WKWebView`. Its
  content-security policy denies network, frames, workers, forms, and arbitrary
  assets; the message bridge carries only an opaque token and validated text,
  scroll, and undo requests. Swift retains file I/O, paths, line endings,
  permissions, dirty state, persistence, undo, and command authority.
- Localhost browser cards use a separate ephemeral, origin-confined web view.
- Do not introduce a general-purpose web application shell.

## State policy

- Long-running or I/O-heavy services are actors or otherwise isolated from the
  main actor.
- Feature models expose narrow observable state; the root application model is
  a coordinator, not a second database.
- Durable writes are atomic, permission-restricted where sensitive, and scoped
  by account, workspace, broker identity, or session as appropriate.
- Terminal and agent processes survive GUI replacement. Updating the app must
  not restart the broker merely to refresh the interface.

## Dependency direction

`Views -> feature models -> services -> protocols/adapters`

Shared packages never import the application target. Runtime JavaScript never
owns UI or product state outside its terminal/usage protocol boundary.
