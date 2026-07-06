# Visual capture — `npm run shoot`

A headless "computer-using" view of the **real desktop renderer**, so any agent
(or you) can actually *see* the UI instead of reasoning about code.

```bash
npm run shoot              # capture the full matrix → ./screenshots/*.png
npm run shoot -- ideas     # only states whose name contains "ideas"
npm run shoot -- settings  # only the Settings tabs
```

## How it works

`electron/shoot.cjs` boots the app exactly like `electron/smoke.cjs` (real
Electron, `isDesktop = true`, all IPC handlers registered, isolated temp
`userData`), loads `dist/index.html` in a hidden window, drives the Zustand store
via `window.__kaisola.getState()` into a matrix of states, and writes a PNG per
state with `webContents.capturePage()`. Output lands in `./screenshots/`
(git-ignored — regenerate, don't commit).

The capture is **retina (≈2880×1744)** and uses the desktop renderer, so Settings
shows the desktop variant (key inputs, workspace folder) — higher fidelity than a
web-build screenshot.

## What it captures

- Every stage view (`corpus`, `claims`, `questions`, `ideas`, `analysis`,
  `manuscript`, `review`, `files`) in **light and dark**.
- A toast in flight (the legibility pass).
- **Settings — every tab** (`general`, `agents`, `models`, `sources`,
  `execution`, `automation`), plus a few in dark.

## For an agent / the ui-screenshot-analyst

1. `npm run shoot` (or a filtered subset).
2. `Read` the PNGs in `./screenshots/` — the Read tool renders images visually,
   so you can critique the actual pixels.

## Known limitation

**React-flow canvases (the Claim Graph) don't render in offscreen capture.** In
a hidden Electron window `getBoundingClientRect()` returns 0×0 during react-flow's
measurement pass, so `fitView` can't position the nodes and the viewport stays
empty (the legend + header still capture, confirming the data is present). This
is a headless artifact — the graph renders normally in the interactive app. To
visually verify the claim graph, run the real app (`npm run electron:dev`) on a
machine with a display. Everything DOM-based (shell, Settings, lists, cards,
manuscript, toasts) captures faithfully.
