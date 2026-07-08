# Cheap Glass — `perfMode` model & painted glass

**Date:** 2026-07-08 · **Status:** approved by Michael (design), pending spec review

## Goal

Keep Kaisola's glass look while cutting its GPU/energy cost, and give the user an
honest, ranked choice in Settings. Two moves:

1. Make **live glass cheaper for free**: the chrome `blur(1600px)` backdrop-filters
   mathematically collapse to a constant color (radius > window width), so replace
   them with a painted wash — and make that wash *track the actual wallpaper*, which
   is fidelity the CSS blur never had.
2. Add a **painted glass** mode: an *opaque* window that draws a pre-blurred copy of
   the wallpaper as its own background. Looks like glass, costs like a painting —
   occlusion culling returns, the native material cost drops to zero.

## Current facts (measured / verified in code)

- Chrome-only glass shipped in v0.1.12: blur lives ONLY on `.tabstrip::before`,
  `.wsrail::before`, `.sidebar::before` (`shell.css:106,507`). Cards are opaque.
- The terminal backbuffer is already opaque in both modes (`Terminal.tsx:54,251`).
- `--app-active-glass-blur: 1600px` — the file's own comment: "the backdrop averages
  to a near-uniform color wash" (`shell.css:16`). The pseudos' backdrop is only the
  uniform tint field (`.app::before`), so the filter output is a constant per theme.
- The *visible* wallpaper glow comes from the native material (vibrancy, or
  NSGlassEffectView on macOS 26 via `electron-liquid-glass`, `main.cjs:36-71`) —
  not from the CSS blurs.
- `transparent: true` (`main.cjs:270`) disables Chromium occlusion culling and forces
  alpha compositing; **both** glass and eco pay this today.
- `shell-prefs.json` in userData is read synchronously by main at launch
  (`main.cjs:40-52`) — the vehicle for creation-time window options.

## Mode model

`ecoMode: boolean` → `perfMode: 'glass' | 'painted' | 'eco'` (store, persisted;
migrate persisted `ecoMode: true` → `'eco'`). `:root[data-perf]` gains `'painted'`.
`settings.json` gains `"perfMode"` (userConfig.ts). All `ecoMode` call sites move to
`perfMode` (eco checks become `perfMode === 'eco'`).

| Mode | Window | Glow source | Animations | GPU |
|---|---|---|---|---|
| `glass` (live) | transparent + vibrancy/Liquid Glass | real OS material | on | ●●● |
| `painted` | **opaque** | pre-blurred wallpaper painting | on | ●● |
| `eco` | **opaque** | none (flat) | still | ● |

**Window solidity is creation-time.** Renderer writes `solidWindow: true/false`
**and `solidBg` (current theme's bg hex — main can't know the theme before the
renderer exists, and a wrong creation color flashes at boot)** to `shell-prefs.json`
(new IPC) whenever `perfMode` changes across the glass boundary; main reads both in
`createWindow` → `transparent: false`, `backgroundColor: solidBg`, no
vibrancy/Liquid Glass. CSS applies instantly on mode switch; a quiet
**"Restart to finish applying"** chip appears when the live window's solidity differs
from the persisted want. Pop-out windows inherit automatically (same `createWindow`).

**Corners:** solid windows keep `roundedCorners: true` (native macOS rounding +
shadow). Main passes `?solidwin=1` (query, like `?win=`) → `:root[data-solidwin]`
collapses the painted `--r-window` radius (`global.css:37`) so no square painted
corners peek past the native clip. Fullscreen already squares off.

## Tier 1 — wash instead of blur; vibrancy nap

- Delete `backdrop-filter` from the three chrome pseudos. Paint them instead with a
  wash derived from `--glass-wash` (defaults to the theme tint — i.e. exactly
  today's constant), alpha tuned by A/B screenshot against the current build over
  the real wallpaper. Expected delta ≈ 0 (the OS material carries the glow and is
  untouched).
- **Vibrancy nap** (`main.cjs`): on window `hide`/`minimize` → `setVibrancy(null)`;
  on `show`/`restore` → `syncMacMaterial()`. Skip when `glassActive` (Liquid Glass
  has no cheap detach — out of scope).

## Tier 2 — wallpaper-sampled wash (main: `electron/ipc/glassHandler.cjs`)

- **Wallpaper path:** AppleScript via `osascript` (`System Events` → desktop
  picture for the display under the window center). No screen-recording permission.
- **Decode:** `nativeImage.createFromPath`; if empty (HEIC dynamic wallpapers),
  convert once via `/usr/bin/sips -s format png` into a temp cache, then load.
- **Average:** crop the wallpaper region under the window (aspect-fill mapping
  approximation), `resize(1,1)`, read the pixel → `{r,g,b}`.
- **Pre-blur (for painted mode):** downscale to ~120px wide, JPEG data URL
  (~tens of KB). The renderer's layer scales it to screen size with a static CSS
  blur — rasters once, repaints never.
- **IPC:** invoke `glass:sample` → `{ avg, blurDataUrl, screen: {x,y,w,h} }`;
  main pushes `glass:refresh` on window `moved`/`resize` (debounced ~400ms),
  `display-metrics-changed`, theme change, and a 5-minute timer (dynamic
  wallpapers). Renderer sets `--glass-wash` (and the painted layer image/offset).
- **Fallbacks:** any step failing → wash stays at theme tint (today's look);
  painted layer falls back to a static theme-toned gradient. Never broken, never
  loud.

## Tier 3 — frost grain

A tiny (~96px) tiling monochrome noise PNG, generated once by a script, committed
as a data URI in CSS. Layered on the chrome pseudos at ~3% over the wash so the
frost reads frosted up close. Eco already hides those pseudos → no grain in eco.

## Tier 4 — painted mode renderer

A fixed `.app-wallpaper` layer at the bottom of `.app`'s stacking context (below
`.app::before` tint), only mounted when `data-perf='painted'`: `background-image` =
pre-blurred wallpaper, sized to the screen, translated by the window's negative
screen position. Re-anchored on `moved` (drag-end; mid-drag drift is imperceptible
under heavy blur — accepted in design review). Everything translucent (tint field,
chrome wash) now "sees through" to the painting. Eco mounts nothing (all-opaque).

## Settings UI

The Energy-saver toggle row becomes a three-option segmented control, ordered by
efficiency, each with a GPU-dots hint (●●● / ●● / ●) and one-line description.
Restart chip per above. `settings.json`: `"perfMode": "glass" | "painted" | "eco"`.

## Verification

- **Tier 1 parity:** probe screenshots of live glass before/after over the real
  wallpaper; accept only near-pixel-identical chrome.
- **Painted probe:** boot with `solidWindow` prefs; assert opaque window,
  `data-solidwin`, wallpaper layer mounted with a real image, wash var set.
- **Smoke:** rewrite the GLASS check for the new architecture (NO backdrop-filter
  anywhere on the field or chrome; wash + grain present on chrome pseudos); keep
  eco assertions; add perfMode migration check. Full suite PASS before release.
- Smoke/probe envs already skip Liquid Glass (`KAISOLA_SMOKE`, `main.cjs:57`).

## Out of scope

- Live parallax of the painting during drags (drag-end anchoring only).
- Other windows glowing through painted mode (wallpaper only — accepted).
- Detaching Liquid Glass on hide (no stable remove API); nap covers vibrancy only.
- Windows/Linux: all of this is macOS-gated like the existing vibrancy plumbing;
  other platforms keep current behavior.
