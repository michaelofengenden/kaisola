# Kaisola — design blueprint

The full design behind the [scaffold](../README.md). These docs were the spec the
Phase-0 build was made from; iterate on them as the product evolves.

- **[SPEC.md](SPEC.md)** — positioning, the one opinionated rule, the core
  product loop (ask → propose → verify → plan → execute → analyze → critique →
  revise → write), the "research sprint" UX, risks (grounded in PaperBench /
  AI-Scientist failure data) and anti-goals.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — file tree, the Zustand store shape,
  the agent-layer interface + the Claude/IPC seam, the Electron security model,
  build scripts, and the seed-data plan.
- **[DESIGN.md](DESIGN.md)** — the design-token system, the shell layout, and
  ASCII specs for the signature components (research diff, provenance popover,
  trust badges, idea card, lab notebook, approval gate, agent feed).
- **[ROADMAP.md](ROADMAP.md)** — Phases 0–4 with goals, features, and success
  criteria (what's real vs stubbed at each step).
- **[domain-types.reference.ts](domain-types.reference.ts)** — a richer
  reference domain model with the Phase-2 enhancements (verification state,
  structured compute estimates, significance fields). The shipped source of
  truth is [`src/domain/types.ts`](../src/domain/types.ts); this is where it
  grows next.
