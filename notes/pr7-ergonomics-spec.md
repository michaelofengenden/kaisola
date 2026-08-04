# PR 7 — Project and session ergonomics: spec (v1, 2026-08-03)

Tracker scope: project detach/adopt, ad-hoc cross-project session groups,
richer task ledger views, workflow automation — "only after the daily editor
and Companion paths are dependable."

## Seam facts that bound the design (survey 2026-08-03)

- `projectID` is a SHA-256 of the project path (`nproj_<hex>`), and for
  terminals it is baked into **broker-side identity**: the `owner` capability
  string and the `terminalID` itself (`term-<projectID>-<uuid>`,
  `NativeSessionStore.terminalID(projectID:)`). A client-side rewrite of a
  terminal's project can never be a true rename.
- Chats and Mesh derive `projectID` from their working directory (computed,
  no stored field); Mesh re-validates path↔id at persistence
  (`normalizedSurface`, NativeSessionStore.swift:1935).
- Workspace persistence enforces `pane.surface.projectID == state.projectID`
  (`normalizedProject`, NativeSessionStore.swift:1782) and silently drops
  mismatches — the number-one way to ship an adoption that evaporates on
  relaunch.
- `AttentionCenter.Entry` is already cross-project (no projectID field) and
  renders as a flat inbox in RootShellView (~4798).
- Exactly one `selectedProjectID` drives one pane canvas; nothing renders two
  projects' sessions together today.

## Design

### D1. Detach/adopt — terminals only, via an adoption overlay

The real `projectID` never changes; the broker keeps enforcing it. A new
`SessionAdoptionStore` (the standard capped/atomic JSON recipe) holds
`[terminalID: adoptedProjectID]`:

- **Presentation reads the overlay**: project filters (`sessions(in:)`,
  sidebar rows, pane snapshot enrolment) resolve a terminal's *display*
  project as `adopted ?? real`.
- **Broker RPCs always use the real projectID** (write/resize/kill/detach
  ownership) — the overlay is invisible to the broker.
- **Persistence**: the adopted pane is written into the adopting project's
  `NativeProjectWorkspaceState` with `surface.projectID` rewritten to the
  adopter so the :1782 guard keeps it; on restore, the overlay entry is the
  source of truth and a missing overlay entry returns the pane to its real
  project (reversibility).
- **Detach** = remove from the current project's layout without ending the
  session (the per-session form of what `closeProject` already does).
- Chats and Mesh are out of scope for adoption in v1: their identity is their
  working directory; "moving" one is a different operation (reopen in the
  other project's directory) that already exists.
- UI: pane header context menu gains "Move to Project ▸" listing open
  projects; the sidebar row shows a small adopted-from hint
  ("via <original project>") so provenance is never silent.

### D2. Task ledger enrichment — render-time, no schema change

`AttentionCenter.Entry` stays as-is. The inbox popover gains:

- Project attribution resolved at render time (`targetID` looked up against
  chats/sessions/meshes; adopted terminals show the adopted project).
- Grouping by project with per-group clear; kind filter chips (permissions /
  completed turns / bells).
- Entries whose target no longer exists render dimmed with a "session gone"
  row action to clear.

### D3. Cross-project session groups — deferred behind a design gate

A group needs an owner for its persisted layout, and no current store can
hold a two-project layout without violating the :1782 invariant. Options
(pick one with Michael before building):

- (a) Groups are ephemeral (never persisted) — cheap, honest, limited.
- (b) A group is a first-class store (`SessionGroupStore`) whose layout
  lives outside any project's workspace state; panes render via the adoption
  overlay mechanism.

v1 ships D1 + D2; D3 waits for the gate. Workflow automation (tracker's
fourth item) is explicitly deferred — it has no seam yet.

## Test plan

- Overlay store: cap/atomic/corrupt→empty; adopted-then-removed returns to
  real project.
- Snapshot/restore round-trip: adopted terminal pane survives relaunch in the
  adopting project; deleting the overlay returns it after relaunch.
- Broker addressing: RPCs for an adopted terminal still carry the real
  projectID (unit-test the request builder with an adopted session).
- Recovery: `recoverOwnedSessions` (strict real-projectID match) still
  re-adopts after the overlay is applied on top.
- Ledger: attribution lookup covers all three surface kinds + adopted case;
  missing target renders the dimmed row.

## Risks (from the survey, unchanged)

1. Broker identity mismatch confusing recovery/diagnostics — mitigated by
   never mutating the real id and labeling provenance in UI.
2. Silent pane loss at the :1782 guard — mitigated by writing the adopter's
   id into the persisted surface and a round-trip test.
3. Cross-project groups are new render surface — deferred to the D3 gate.
