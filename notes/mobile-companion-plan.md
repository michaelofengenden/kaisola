# Kaisola Companion — phone control over LAN / Tailscale (plan)

Kairn's fifth pillar is an iOS app that talks to the Mac. Kaisola can ship the
same capability with **zero App Store friction** by serving a companion PWA
from the Electron main process — the phone opens a URL on your tailnet (or
LAN), not an app store. A native wrapper can come later; nothing below
precludes it.

## What the companion is for (v1 scope)

The phone is an **attention surface, not a second IDE**. Three jobs only:

1. **Glance** — the session list: which agents are running, which finished,
   which failed (the same identity hues and repo/branch metadata as the rail).
2. **Answer** — permission cards. An agent blocked on "may I edit `api.ts`?"
   at dinner is the whole reason this exists. Approve / reject / always-allow,
   with the same diff preview the desktop card shows.
3. **Nudge** — send a follow-up prompt to a session (one text box), and read
   the terminal tail / thread tail to see what happened.

Explicitly **out of scope for v1**: full terminal keyboard interaction, file
editing, browsing the repo, starting new sessions. (All possible later; none
worth the surface area now.)

## Architecture

```
┌─ Mac (Kaisola main process) ──────────────────────┐
│  companionServer.cjs                             │
│  • HTTP: serves the companion PWA (dist-mobile/) │
│  • WS:   /ws — event stream + commands           │
│  • auth: pairing token (QR) → session cookie     │
└──────────────┬───────────────────────────────────┘
               │  Tailscale (preferred) or LAN
┌──────────────▼───────────────┐
│  Phone browser (PWA)         │
│  session cards · perm cards  │
│  prompt box · terminal tail  │
└──────────────────────────────┘
```

- **Server**: a small `http` + `ws` server in main (no Express), started only
  when the user enables *Settings → Companion*. Binds `0.0.0.0` on a random
  high port; the UI shows both the LAN URL and — when a `100.64.0.0/10`
  interface exists — the Tailscale URL. Tailscale is just an interface: no
  SDK, no dependency, it simply works when present (Kairn's trick too).
- **Protocol**: one WebSocket, JSON messages, versioned:
  - `state` (full snapshot on connect: sessions, meta, pending permissions)
  - `event` (delta: session busy/idle, new permission, terminal tail chunk)
  - `answer` (client → server: permission decision)
  - `prompt` (client → server: text for session X)
  The main process already owns every one of these facts (terminalManager,
  acpHandler's pendingPermissions, hooks tap) — the server is a subscriber,
  not new plumbing.
- **Permission answering**: reuses `acp:permission:respond` internals — the
  phone is just another "window" answering. The fail-closed timeout stays;
  a phone answer after timeout is a no-op.
- **Terminal tail**: `mgr.snapshot(id)` already returns the scrollback tail —
  send the last ~2KB, then live `onData` deltas, rendered read-only.

## Security model (the part that must be right)

- **Off by default.** The server never starts unless enabled this session.
- **Pairing**: enabling shows a QR code (URL + one-time token). The phone
  exchanges it for a long-lived device token (stored server-side in
  userData/companion.json, revocable from Settings). No token → 401 for
  everything including the PWA shell.
- **TLS**: on a tailnet, transport is already WireGuard-encrypted; on plain
  LAN we warn and keep the surface read-mostly (glance + answer, no prompt)
  unless the user opts in. No self-signed-cert dance in v1.
- **Sensitive-file guardrails apply**: permission diffs that touch
  `sensitiveGlobs` render path-only on the phone (no contents), same as the
  desktop rule that they never auto-allow.
- **No filesystem or arbitrary-command channel exists in the protocol.** The
  server can only do the four message types above — a compromised phone
  session can approve/reject/prompt, never exfiltrate the tree.

## Build phases

| Phase | Deliverable | Size |
|---|---|---|
| 1 | `companionServer.cjs` (HTTP+WS, pairing, state/event stream) + Settings toggle with QR | M |
| 2 | Companion PWA: session list + permission cards (approve/reject/always) | M |
| 3 | Prompt box + terminal/thread tail view | S |
| 4 | Push-style attention: Web Push when a turn ends / permission appears (works when the PWA is closed, needs TLS → tailnet HTTPS via `tailscale serve` or ntfy-style relay) | M |
| 5 | Optional native iOS wrapper (WKWebView shell around the PWA; App Store only if ever worth it) | L |

Phase 1+2 is the Kairn-parity moment: glance + answer from the couch.

## Open questions (decide at build time)

- QR library or plain short-code entry? (short code is zero-dep: `kaisola.ts.net:PORT` + 6 digits)
- Per-window scoping: v1 serves the FIRST full window's state; multi-window
  selection is a later dropdown.
- Web Push vs. polling: start with WS-only (PWA open), add push in phase 4.
