\- ~~I would like a main homepage window where the first window offical tab could be something like a board where I can see everything that's working what needs me~~ — **shipped 2026-07-17** as the **Board** (pinned first tab, all-project Running / Needs You / Done, live activity lines; commits `a9751af`, `98bb5b4`). Reference: ![Screenshot 2026-07-17 at 12.43.39 AM](backlog-media/Screenshot%202026-07-17%20at%2012.43.39%E2%80%AFAM.png)

\- Build an iPhone-first Kaisola Companion: securely pair with the desktop, see every project's agents and terminal streams, handle needs-you work, and control existing sessions without exposing local IPC or secrets. [Design](superpowers/specs/2026-07-17-mobile-companion-design.md) · [Plan](superpowers/plans/2026-07-17-mobile-companion.md) · [Native preview](../mobile/KaisolaCompanion/README.md) — **in progress**: Phase 0 (desktop spine) and Phase 1 Tasks 8–9 (encrypted pairing + desktop settings) shipped; first preview build is on TestFlight. Tasks 10–11 (real iOS transport, Google sign-in, ChatGPT-class UX) underway. [Phase 1 design](superpowers/specs/2026-07-18-mobile-phase1-and-account-design.md)

\- ~~sometimes when I copy paste a bunch of text with spaces from some output it copies and pastes it into the Command CLI agent terminal on kaisola as a bunch of messages instead of a single message and then it ends up queing messages~~ — **fixed 2026-07-17** (bracketed-paste mode state was lost on terminal remount; spool now tracks and replays DEC modes — commits `1207c96`, `0ec43a6`, `cc90f09`).

\- ~~when switching between windows or resizing terminal/agent tabs, I would like for the terminal not get scrolled up, the cli agent should stay at the recent outputs~~ — **fixed 2026-07-17** (sticky follow-intent: only deliberate scrolls unpin; resizes/tab-switches/remounts keep the terminal pinned to live output — commit `ea35821`)

  

\- the clicking between windows and
