# Cheap Glass Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the redundant chrome backdrop-blurs with a wallpaper-sampled painted wash, add an opaque-window "painted glass" mode, and expose a three-way efficiency-ranked perf mode picker in Settings.

**Architecture:** `perfMode: 'glass' | 'painted' | 'eco'` replaces `ecoMode` in the zustand store (persisted, migrated). The main process gains a glass sampler (wallpaper → average color + pre-blurred copy) and creation-time solid-window support via `shell-prefs.json`. The renderer paints chrome wash from `--glass-wash`, and in painted mode mounts a pre-blurred wallpaper layer behind the tint field.

**Tech Stack:** Electron 33 (main: CJS), React + zustand v4 persist, plain CSS. No unit-test framework — verification is `npm run build` (tsc+vite), purpose-built Electron probes (`electron/*probe.cjs`), and `electron/smoke.cjs` (`SMOKE_RESULT=PASS`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-08-cheap-glass-modes-design.md`. Read it first.
- macOS-only behavior gates on `process.platform === 'darwin'` exactly like existing vibrancy code; other platforms keep current behavior.
- NO `Co-Authored-By` / AI attribution in any commit message (user's global rule).
- Every commit must leave `npm run build` green and `node electron/smoke.cjs` passing (run smoke at least at Tasks 2, 7, 8, 9).
- macOS sandbox quirks: no `timeout` command; foreground `sleep` blocked in probes' shell — use `perl -e 'select(undef,undef,undef,N)'`; probes MUST register any IPC handler group they exercise (missed `registerLatexHandlers` cost hours once).
- Probes write scratch output under the session scratchpad, never the repo.
- All new probe harnesses follow the existing pattern in `electron/perfprobe.cjs` / `electron/buildprobe.cjs`: boot `dist/` with handlers registered, drive via `executeJavaScript` against `window.__kaisola`.
- Fallback philosophy (spec): every sampling failure degrades silently to today's look (theme tint / gradient). Never a toast, never a crash.

---

### Task 1: Store — `perfMode` replaces `ecoMode` (with persist migration)

**Files:**
- Modify: `src/store/store.ts:455` (GLOBAL_KEYS), `:604` (type), `:794` (setter type), `:1396` (persistSnapshot), `:1605` (default), `:2423-2426` (setter), `:3877-3905` (persist version+migrate)
- Modify: `src/main.tsx:23`
- Modify: `src/components/Terminal.tsx:140`
- Modify: `src/components/Settings.tsx:58,314,316`
- Create: `electron/migrateprobe.cjs` (temporary verification, deleted in the same task)

**Interfaces:**
- Produces: `type PerfMode = 'glass' | 'painted' | 'eco'` (exported), state `perfMode: PerfMode`, action `setPerfMode(mode: PerfMode)` which also sets `document.documentElement.dataset.perf = mode`. Persist version 7.
- Every later task reads `s.perfMode` / calls `s.setPerfMode`.

- [ ] **Step 1: store type + state + setter**

In `src/store/store.ts`:
- Near the top-level exported types add: `export type PerfMode = 'glass' | 'painted' | 'eco'`
- `:604` `ecoMode: boolean` → `perfMode: PerfMode`
- `:794` `setEcoMode: (on: boolean) => void` → `setPerfMode: (mode: PerfMode) => void`
- `:1605` default `ecoMode: false,` → `perfMode: 'glass' as PerfMode,`
- `:1396` persistSnapshot `ecoMode: s.ecoMode,` → `perfMode: s.perfMode,`
- `:455` GLOBAL_KEYS `'ecoMode'` → `'perfMode'`
- `:2423` setter becomes:

```ts
setPerfMode: (mode) => {
  document.documentElement.dataset.perf = mode
  set({ perfMode: mode })
},
```

- [ ] **Step 2: persist migration v6 → v7**

At `:3877` bump `version: 6` → `version: 7` and extend `migrate`. Exact shape (the existing `<6` body stays, its final `return { ... }` gets wrapped):

```ts
version: 7,
migrate: (persisted, version) => {
  // v7 (2026-07-08): ecoMode boolean → perfMode ('glass' | 'painted' | 'eco')
  const toV7 = (p: unknown) => {
    const rec = p as Record<string, unknown>
    if (rec && typeof rec === 'object' && !('perfMode' in rec)) {
      rec.perfMode = rec.ecoMode ? 'eco' : 'glass'
      delete rec.ecoMode
    }
    return p
  }
  if (version >= 7) return persisted
  if (version === 6) return toV7(persisted)
  // …existing v5→6 body unchanged, EXCEPT its final `return {` becomes `return toV7({`
```

Also append a one-line comment to the version-history comment block above (`// v7 (2026-07-08): ecoMode → perfMode`).

- [ ] **Step 3: call sites**

- `src/main.tsx:23`: `document.documentElement.dataset.perf = useKaisola.getState().perfMode`
- `src/components/Terminal.tsx:140`: `const ecoMode = useKaisola((s) => s.perfMode === 'eco')` (nothing else changes — `ecoRef`, `xtermTheme(theme, ecoMode, …)` keep working)
- `src/components/Settings.tsx`: `:58` → `const perfMode = useKaisola((s) => s.perfMode)`; also grab `const setPerfMode = useKaisola((s) => s.setPerfMode)` next to it; `:314` `value={perfMode === 'eco' ? 'on' : 'off'}`; `:316` `onSelect={(v) => setPerfMode(v === 'on' ? 'eco' : 'glass')}` (interim — Task 8 replaces this row entirely)

- [ ] **Step 4: build**

Run: `npm run build` — expect clean tsc + vite output. Fix any missed `ecoMode` reference (`grep -rn "ecoMode" src/` must return only Terminal.tsx's local const).

- [ ] **Step 5: migration probe**

Create `electron/migrateprobe.cjs` from the perfprobe template (same boilerplate; register NO extra handlers — the store is renderer-side). Flow: launch dist → `executeJavaScript`:

```js
// seed a minimal v6 blob under the store key, then reload
const KEY = Object.keys(localStorage).find((k) => /kaisola|pasola/i.test(k))
const blob = JSON.parse(localStorage.getItem(KEY))
blob.version = 6
blob.state.ecoMode = true
delete blob.state.perfMode
localStorage.setItem(KEY, JSON.stringify(blob))
location.reload()
```

then after reload (poll for `window.__kaisola`): assert `getState().perfMode === 'eco'` and `document.documentElement.dataset.perf === 'eco'` and `'ecoMode' in getState() === false`. Print `MIGRATE=PASS/FAIL`. Run it, expect PASS, then `rm electron/migrateprobe.cjs` (one-shot; not worth maintaining).

- [ ] **Step 6: smoke + commit**

Run: `node electron/smoke.cjs 2>&1 | tail -5` → `SMOKE_RESULT=PASS`.

```bash
git add -A src/ && git commit -m "store: perfMode (glass|painted|eco) replaces ecoMode, persisted v7 migration"
```

---

### Task 2: Tier 1 CSS — painted wash replaces the chrome backdrop-blurs (A/B parity gated)

**Files:**
- Modify: `src/styles/shell.css:16` (token), `:106-114` (.tabstrip::before), `:507-525` (.wsrail/.sidebar::before + dark override)
- Modify: `electron/smoke.cjs:280-281` (appSamplingLayer / chromeGlass assertions)
- Create: `electron/glassprobe.cjs` (kept — reused by Tasks 3, 5, 7)

**Interfaces:**
- Produces: CSS custom properties on `.app`: `--glass-wash` (color, defaults to `var(--app-active-glass-tint)`) and `--glass-wash-alpha` (defaults `0%`). Chrome pseudos paint `color-mix(in srgb, var(--glass-wash) var(--glass-wash-alpha), transparent)`. Task 5 sets `--glass-wash` + a nonzero alpha from sampling; alpha 0% ⇒ pixel-parity with today.

- [ ] **Step 1: BEFORE capture (the "failing test")**

Create `electron/glassprobe.cjs` (perfprobe template, no extra IPC groups). It must:
1. boot dist, wait for `.tabstrip` and `.wsrail` (studio layout, like smoke does)
2. `win.webContents.capturePage()` → PNG to `<scratchpad>/glass-before.png`
3. via `executeJavaScript`, compute and print mean RGBA of two rects (tabstrip: full strip height; rail: left 248px column) by drawing the capture into a canvas — simpler: do the mean in Node with `nativeImage` bitmap (`img.crop(rect).resize({width:1,height:1})`, read `toBitmap()` BGRA bytes). Print `CHROME_MEAN={"tabstrip":[r,g,b,a],"rail":[r,g,b,a]}`.

Run on the CURRENT build (`npm run build` first). Save the numbers.

- [ ] **Step 2: CSS change**

In `shell.css` `.app` block (`:11-29` area): delete `--app-active-glass-blur: 1600px;` (line 16) and add:

```css
--glass-wash: var(--app-active-glass-tint);
--glass-wash-alpha: 0%; /* sampling (glassWash.ts) raises this; 0% = exact legacy look */
```

`.tabstrip::before` (`:106`): replace both `backdrop-filter`/`-webkit-backdrop-filter` lines with:

```css
  /* PAINTED WASH — no backdrop-filter. blur(1600px) of the uniform tint field
     was mathematically a constant (radius > window width; see the deleted
     --app-active-glass-blur comment). The constant is now painted directly,
     and Tier-2 sampling tints it with the real wallpaper average — fidelity
     the blur never had. The OS material still carries the live glow. */
  background: color-mix(in srgb, var(--glass-wash) var(--glass-wash-alpha), transparent);
```

`.wsrail::before, .sidebar::before` (`:507`): same replacement (keep the existing comment, adjust it to say "painted wash (pairs with .tabstrip::before)"). DELETE the dark-theme override block (`:521-525`) entirely — with no filter there is nothing to override (saturate/brightness deltas are baked into the sampled wash by Task 5's formula).

- [ ] **Step 3: AFTER capture + parity assert**

`npm run build`, re-run glassprobe → `glass-after.png` + means. **Gate: each channel's mean delta ≤ 2 (of 255) for both rects.** If larger, the pseudos were contributing real pixels — investigate before proceeding (do NOT tune-to-pass without understanding). Also eyeball before/after PNGs side by side.

- [ ] **Step 4: smoke assertions update (same commit — smoke greps the deleted token)**

`electron/smoke.cjs:280` `appSamplingLayer`: drop the `&& /1[0-9]{3}px/.test(appGlassBlur)` clause and the `appGlassBlur` const (`:219`).
`:281` `chromeGlass` becomes the new architecture assertion:

```js
// PAINTED-WASH CHROME: no backdrop-filter anywhere on the chrome pseudos —
// the wash is painted (constant), the OS material carries the glow
chromeGlass: !/blur/.test(tabstripGlassBd) && !/blur/.test(railGlassBd)
  && getComputedStyle(tabstrip, '::before').backgroundColor !== ''
  && getComputedStyle(rail, '::before').display !== 'none',
```

- [ ] **Step 5: full smoke + commit**

`node electron/smoke.cjs 2>&1 | tail -5` → PASS.

```bash
git add src/styles/shell.css electron/smoke.cjs electron/glassprobe.cjs
git commit -m "glass: chrome blur was computing a constant — paint the wash instead"
```

---

### Task 3: Tier 3 — frost grain on the chrome

**Files:**
- Modify: `src/styles/shell.css` (the two chrome-pseudo rules from Task 2)

**Interfaces:**
- Produces: grain layered via `background-image` list on the same pseudos. Smoke/probes can detect `data:image/svg` in `backgroundImage`.

- [ ] **Step 1: add the grain layer**

feTurbulence SVG as a data URI — no script, no binary asset. In both chrome-pseudo rules, replace the single `background:` line with:

```css
  background-image:
    url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='96' height='96'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix type='matrix' values='0 0 0 0 0.5 0 0 0 0 0.5 0 0 0 0 0.5 0 0 0 0.04 0'/%3E%3C/filter%3E%3Crect width='96' height='96' filter='url(%23n)'/%3E%3C/svg%3E"),
    linear-gradient(color-mix(in srgb, var(--glass-wash) var(--glass-wash-alpha), transparent),
                    color-mix(in srgb, var(--glass-wash) var(--glass-wash-alpha), transparent));
  background-repeat: repeat, no-repeat;
```

(The feColorMatrix rows pin the noise to neutral gray and set its alpha to 0.04 — grain, not static. The wash moves into a same-color two-stop gradient because `background-image` can't take a bare color.)

- [ ] **Step 2: verify + commit**

`npm run build`; glassprobe again — mean deltas vs Task 2's "after" must stay ≤ 2 (4% neutral grain barely moves means) AND `executeJavaScript` assert `getComputedStyle(tabstrip,'::before').backgroundImage.includes('data:image/svg')`. Eyeball the PNG zoomed — grain should be *felt*, not seen. If it reads as dirt, lower the `0.04` to `0.025`. Smoke → PASS.

```bash
git add src/styles/shell.css && git commit -m "glass: frost grain — the texture that sells it, painted once"
```

---

### Task 4: Vibrancy nap (main process)

**Files:**
- Modify: `electron/main.cjs:313-329` (syncMacMaterial area) and the window-event wiring at `:334-350`

**Interfaces:**
- Consumes: existing `syncMacMaterial()`, `glassActive`, `macVibrancyType`.
- Produces: vibrancy detached while hidden/minimized; `syncMacMaterial` restores (already wired to `show`/`focus`; add `restore` + the nap).

- [ ] **Step 1: implement**

After `syncMacMaterial` definition add:

```js
// vibrancy nap: the under-window material keeps sampling the desktop even for
// a hidden window (visualEffectState 'active'). Detach while nothing is
// visible; syncMacMaterial re-attaches on show/restore/focus. Liquid Glass
// (glassActive) has no stable detach API — the nap covers vibrancy only.
const napMacMaterial = () => {
  if (process.platform === 'darwin' && typeof win.setVibrancy === 'function' && !glassActive) {
    win.setVibrancy(null)
  }
}
win.on('hide', napMacMaterial)
win.on('minimize', napMacMaterial)
win.on('restore', syncMacMaterial)
```

(`win.on('show', syncMacMaterial)` already exists at `:338`.)

- [ ] **Step 2: verify + commit**

`npm run build` (main is not tsc'd but keep the habit). Quick probe check inside glassprobe run (add temporarily or one-off script): `win.minimize(); await 300ms; win.restore(); await 300ms; capturePage()` — means unchanged vs pre-minimize, no crash. Smoke → PASS.

```bash
git add electron/main.cjs && git commit -m "shell: vibrancy naps while the window is hidden or minimized"
```

---

### Task 5: Tier 2 — wallpaper sampler (main) + `--glass-wash` sync (renderer)

**Files:**
- Create: `electron/ipc/glassHandler.cjs`
- Modify: `electron/main.cjs` (require + register + per-window `wireGlassEvents(win)` in `createWindow`)
- Modify: `electron/preload.cjs:266` area (two lines)
- Modify: `src/lib/bridge.ts` (types + web fallback near `:484`/`:805`)
- Create: `src/lib/glassWash.ts`
- Modify: `src/App.tsx` (one `useEffect` calling `initGlassWash`)

**Interfaces:**
- Produces (main): `registerGlassHandlers(ipcMain)` + `wireGlassEvents(win)` exported from glassHandler. IPC `glass:sample` → `{ ok: true, avg: {r,g,b}, blurDataUrl: string, screen: {x,y,w,h} } | { ok: false }`. Push event `glass:refresh` (no payload) on: window `moved`/`resize` (debounced 450ms), `screen.display-metrics-changed`, `nativeTheme.updated`, 5-min unref'd interval.
- Produces (renderer): `initGlassWash(): () => void` — applies `--glass-wash: rgb(r g b)` + `--glass-wash-alpha: 14%` on `document.documentElement` when sampling succeeds (leaves defaults when not); exposes `getGlassScreen()` and sets `--wallpaper-img` + `--wallpaper-size` for Task 7. Bridge: `bridge.glassWash.sample()`, `bridge.glassWash.onRefresh(cb): () => void`.

- [ ] **Step 1: glassHandler.cjs**

```js
const { nativeImage, BrowserWindow, screen } = require('electron')
const { execFile } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

/** Wallpaper sampling for the painted glass wash. Every failure returns
 *  { ok:false } — the renderer keeps the theme-tint defaults (today's look). */

const exec = (cmd, args, timeout = 4000) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout }, (err, stdout) => resolve(err ? null : String(stdout).trim()))
  })

// Wallpaper path WITHOUT triggering an Automation permission prompt:
// macOS 14+ keeps wallpaper config in com.apple.wallpaper/Store/Index.plist —
// parse it via plutil and pull the first file URL. Fallback: AppleScript
// (System Events) — one-time OS consent dialog, denial degrades silently.
// KAISOLA_SMOKE never runs osascript (no dialogs in probes/CI).
async function wallpaperPath() {
  const plist = path.join(os.homedir(), 'Library/Application Support/com.apple.wallpaper/Store/Index.plist')
  if (fs.existsSync(plist)) {
    const json = await exec('/usr/bin/plutil', ['-convert', 'json', '-o', '-', plist])
    const m = json && json.match(/file:\/\/[^"\\]+/)
    if (m) {
      const p = decodeURIComponent(m[0].replace('file://', ''))
      if (fs.existsSync(p) && fs.statSync(p).isFile()) return p
    }
  }
  if (process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE) return null
  const out = await exec('/usr/bin/osascript', ['-e', 'tell application "System Events" to get POSIX path of (get picture of desktop 1)'])
  return out && fs.existsSync(out) ? out : null
}

// nativeImage can't decode HEIC (dynamic wallpapers) — sips converts once per
// source into the temp cache.
async function loadWallpaper(p) {
  let img = nativeImage.createFromPath(p)
  if (!img.isEmpty()) return img
  const cached = path.join(os.tmpdir(), `kaisola-wp-${Buffer.from(p).toString('base64url').slice(0, 24)}.png`)
  if (!fs.existsSync(cached)) {
    const ok = await exec('/usr/bin/sips', ['-s', 'format', 'png', '--resampleWidth', '1200', p, '--out', cached], 15000)
    if (ok == null) return null
  }
  img = nativeImage.createFromPath(cached)
  return img.isEmpty() ? null : img
}

function sampleForWindow(win, img) {
  const disp = screen.getDisplayMatching(win.getBounds())
  const { width: iw, height: ih } = img.getSize()
  const db = disp.bounds
  // aspect-fill mapping of the wallpaper onto the display
  const scale = Math.max(db.width / iw, db.height / ih)
  const visW = db.width / scale, visH = db.height / scale
  const offX = (iw - visW) / 2, offY = (ih - visH) / 2
  const wb = win.getBounds()
  const rect = {
    x: Math.round(offX + Math.max(0, wb.x - db.x) / scale),
    y: Math.round(offY + Math.max(0, wb.y - db.y) / scale),
    width: Math.max(1, Math.round(Math.min(wb.width, db.width) / scale)),
    height: Math.max(1, Math.round(Math.min(wb.height, db.height) / scale)),
  }
  rect.x = Math.min(rect.x, iw - rect.width)
  rect.y = Math.min(rect.y, ih - rect.height)
  const px = img.crop(rect).resize({ width: 1, height: 1 }).toBitmap() // BGRA
  const avg = { r: px[2], g: px[1], b: px[0] }
  // pre-blurred copy for the painted layer: heavy downscale IS the blur
  const blurDataUrl = 'data:image/jpeg;base64,' + img.resize({ width: 120 }).toJPEG(70).toString('base64')
  return { ok: true, avg, blurDataUrl, screen: { x: db.x, y: db.y, w: db.width, h: db.height } }
}

function registerGlassHandlers(ipcMain) {
  ipcMain.handle('glass:sample', async (e) => {
    try {
      const win = BrowserWindow.fromWebContents(e.sender)
      if (!win || process.platform !== 'darwin') return { ok: false }
      const p = await wallpaperPath()
      if (!p) return { ok: false }
      const img = await loadWallpaper(p)
      if (!img) return { ok: false }
      return sampleForWindow(win, img)
    } catch { return { ok: false } }
  })
}

// nudge the renderer to re-sample when the answer may have changed
function wireGlassEvents(win) {
  if (process.platform !== 'darwin') return
  let t = null
  const nudge = () => {
    clearTimeout(t)
    t = setTimeout(() => {
      if (!win.isDestroyed() && !win.webContents.isDestroyed()) win.webContents.send('glass:refresh')
    }, 450)
  }
  win.on('moved', nudge)
  win.on('resize', nudge)
  const iv = setInterval(nudge, 5 * 60 * 1000) // dynamic wallpapers drift
  if (iv.unref) iv.unref()
  const { screen: scr } = require('electron')
  const onDisplay = () => nudge()
  scr.on('display-metrics-changed', onDisplay)
  const { nativeTheme } = require('electron')
  nativeTheme.on('updated', nudge)
  win.on('closed', () => {
    clearInterval(iv)
    scr.removeListener('display-metrics-changed', onDisplay)
    nativeTheme.removeListener('updated', nudge)
  })
}

module.exports = { registerGlassHandlers, wireGlassEvents }
```

- [ ] **Step 2: wire main + preload + bridge**

- `main.cjs`: `const { registerGlassHandlers, wireGlassEvents } = require('./ipc/glassHandler.cjs')`; call `registerGlassHandlers(ipcMain)` next to `registerUpdateHandlers` in `whenReady`; call `wireGlassEvents(win)` inside `createWindow` (after the other `win.on` wiring, ~`:350`).
- `preload.cjs` next to `glass:` (`:266`):

```js
glassWash: {
  sample: () => ipcRenderer.invoke('glass:sample'),
  onRefresh: (cb) => { const h = () => cb(); ipcRenderer.on('glass:refresh', h); return () => ipcRenderer.removeListener('glass:refresh', h) },
},
```

- `bridge.ts`: mirror the type next to the `glass()` declaration (`:484`):

```ts
/** Wallpaper-sampled glass wash (macOS; failures degrade to theme tint). */
glassWash: {
  sample(): Promise<{ ok: boolean; avg?: { r: number; g: number; b: number }; blurDataUrl?: string; screen?: { x: number; y: number; w: number; h: number } }>
  onRefresh(cb: () => void): () => void
}
```

and in the web fallback object (near `:805`): `glassWash: { async sample() { return { ok: false } }, onRefresh() { return () => {} } },`

- [ ] **Step 3: renderer — `src/lib/glassWash.ts`**

```ts
import { bridge, isDesktop } from './bridge'
import { useKaisola } from '../store/store'

/** Applies the wallpaper-sampled wash as CSS custom properties. All failure
 *  paths leave the defaults (theme tint, 0% alpha) — exactly the pre-sampling
 *  look. Also caches the pre-blurred wallpaper for the painted layer. */

let screenRect: { x: number; y: number; w: number; h: number } | null = null
export const getGlassScreen = () => screenRect

async function apply() {
  if (useKaisola.getState().perfMode === 'eco') return // eco paints nothing glassy
  const s = await bridge.glassWash.sample()
  const root = document.documentElement
  if (!s.ok || !s.avg) return
  root.style.setProperty('--glass-wash', `rgb(${s.avg.r} ${s.avg.g} ${s.avg.b})`)
  root.style.setProperty('--glass-wash-alpha', '14%')
  if (s.blurDataUrl && s.screen) {
    screenRect = s.screen
    root.style.setProperty('--wallpaper-img', `url("${s.blurDataUrl}")`)
    root.style.setProperty('--wallpaper-size', `${s.screen.w}px ${s.screen.h}px`)
  }
}

export function initGlassWash(): () => void {
  if (!isDesktop) return () => {}
  void apply()
  const offRefresh = bridge.glassWash.onRefresh(() => void apply())
  const unsub = useKaisola.subscribe((s, prev) => {
    if (s.perfMode !== prev.perfMode || s.theme !== prev.theme) void apply()
  })
  return () => { offRefresh(); unsub() }
}
```

(Check the store's actual theme field name — `theme` per `main.tsx:22` — and that `useKaisola.subscribe` two-arg form matches existing usage; adjust to the codebase's subscribe idiom if it uses `subscribeWithSelector`.)

- `src/App.tsx`: alongside the existing `watchUserConfig` bootstrap effect add:

```ts
useEffect(() => initGlassWash(), [])
```

- [ ] **Step 4: verify (probe) + commit**

Extend `electron/glassprobe.cjs` (it stays alive): after boot, poll up to 3s for `getComputedStyle(document.documentElement).getPropertyValue('--glass-wash')` to become an `rgb(…)` (sampling is async). Assert: parses to three 0-255 ints; `--glass-wash-alpha` is `14%`; `--wallpaper-img` starts `url("data:image/jpeg`. Print `WASH=PASS/FAIL + values`. NOTE: probe env sets `KAISOLA_SMOKE`? — NO: run glassprobe WITHOUT the smoke env so the plist path is exercised for real on this machine; if the plist path fails here, debug it (this Mac is the target hardware). `npm run build` first. Then full smoke (which runs with `KAISOLA_SMOKE` and must still PASS with sampling skipped → defaults hold — this proves the fallback).

```bash
git add electron/ipc/glassHandler.cjs electron/main.cjs electron/preload.cjs src/lib/bridge.ts src/lib/glassWash.ts src/App.tsx electron/glassprobe.cjs
git commit -m "glass: the wash now samples the actual wallpaper (plist first, no permission prompt)"
```

---

### Task 6: Solid window plumbing (creation-time opaque, restart chip groundwork)

**Files:**
- Modify: `electron/main.cjs:257-330` (createWindow), `:487-494` (near shell:glass — new handler)
- Modify: `electron/preload.cjs`, `src/lib/bridge.ts` (windowMode + relaunch)
- Modify: `src/main.tsx` (read `?solidwin`), `src/styles/global.css:37-43`
- Modify: `src/store/store.ts` `setPerfMode` (write-through)

**Interfaces:**
- Produces: `shell-prefs.json` keys `solidWindow: boolean`, `solidBg: '#rrggbb'`. IPC `shell:window-mode` — invoke with `{ solidWindow, solidBg }` to set (both optional), always returns `{ wantSolid: boolean, liveSolid: boolean }`. IPC `shell:relaunch` → `app.relaunch(); app.exit(0)`. Query param `solidwin=1` → `:root[data-solidwin='true']`. Bridge: `bridge.windowMode(patch?)`, `bridge.relaunch()`.
- Task 8's restart chip shows when `wantSolid !== liveSolid`.

- [ ] **Step 1: createWindow reads prefs**

In `createWindow` before the `new BrowserWindow`:

```js
// painted/eco want an OPAQUE window (occlusion culling + no vibrancy tax) —
// transparency is a creation-time option, so the renderer's preference is
// persisted in shell-prefs and picked up here on the next launch.
const solidWin = readShellPrefs().solidWindow === true
const solidBg = /^#[0-9a-fA-F]{6}$/.test(readShellPrefs().solidBg || '') ? readShellPrefs().solidBg : '#0b0d11'
```

Then in the options: `transparent: !solidWin`, `backgroundColor: solidWin ? solidBg : '#00000000'`, `...(solidWin ? {} : macVibrancy)`. After creation: gate `tryLiquidGlass` (`:327`) and `syncMacMaterial`'s `setVibrancy` restore with `&& !solidWin` (nap functions too). Add `if (solidWin) query.solidwin = '1'` next to the other query params (`:291-308`). Track for the mode handler: `win.__kaisolaSolid = solidWin`.

- [ ] **Step 2: IPC + preload + bridge**

Next to `shell:glass` (`:487`):

```js
// perf-mode window plumbing: the renderer persists what the NEXT window
// should be; liveSolid is what THIS window is (mismatch → restart chip)
ipcMain.handle('shell:window-mode', (e, patch) => {
  if (patch && typeof patch.solidWindow === 'boolean') writeShellPrefs({ solidWindow: patch.solidWindow })
  if (patch && typeof patch.solidBg === 'string' && /^#[0-9a-fA-F]{6}$/.test(patch.solidBg)) writeShellPrefs({ solidBg: patch.solidBg })
  const win = BrowserWindow.fromWebContents(e.sender)
  return { wantSolid: readShellPrefs().solidWindow === true, liveSolid: !!(win && win.__kaisolaSolid) }
})
ipcMain.handle('shell:relaunch', () => { app.relaunch(); app.exit(0) })
```

preload (next to `glass:`): `windowMode: (patch) => ipcRenderer.invoke('shell:window-mode', patch), relaunch: () => ipcRenderer.invoke('shell:relaunch'),`
bridge.ts types + web fallbacks: `windowMode(patch?: { solidWindow?: boolean; solidBg?: string }): Promise<{ wantSolid: boolean; liveSolid: boolean }>` (fallback `{ wantSolid: false, liveSolid: false }`), `relaunch(): Promise<void>` (fallback no-op).

- [ ] **Step 3: renderer side**

- `src/main.tsx` (next to the `?win=` handling — find `new URLSearchParams` usage): `if (params.get('solidwin') === '1') document.documentElement.dataset.solidwin = 'true'`
- `global.css` after `:43`:

```css
/* solid (painted/eco) windows: macOS clips the frame to its native ~10px
   radius (roundedCorners) — the painted 24px radius would leave square
   backgroundColor corners poking past it */
:root[data-shell='desktop'][data-solidwin='true'] .app {
  border-radius: 10px;
}
```

- `store.ts` `setPerfMode` write-through (fire-and-forget, desktop only):

```ts
setPerfMode: (mode) => {
  document.documentElement.dataset.perf = mode
  set({ perfMode: mode })
  // persist what the NEXT window should be (transparency is creation-time)
  const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg-0').trim()
  void bridge.windowMode?.({ solidWindow: mode !== 'glass', ...(/^#[0-9a-fA-F]{6}$/.test(bg) ? { solidBg: bg } : {}) })
},
```

(store.ts already imports from bridge? If not, import `{ bridge }` — check for import cycles; if store↔bridge cycles, move the write-through into `glassWash.ts`'s subscribe instead and note it in the commit.)

- [ ] **Step 4: probe + commit**

Create `electron/solidprobe.cjs` (perfprobe template) with **isolated userData**: before `app.whenReady`, `app.setPath('userData', '<scratchpad>/solidprobe-data')` and write `shell-prefs.json` there with `{ "solidWindow": true, "solidBg": "#0b0d11" }`. Assert after load: `dataset.solidwin === 'true'`; `capturePage()` corner pixel (2,2) alpha === 255 (opaque); `.app` computed border-radius `10px`; then `executeJavaScript` `__kaisola.getState().setPerfMode('glass')` and assert the probe's prefs file now has `solidWindow: false`. Print `SOLID=PASS/FAIL`. Run: `npm run build && node electron/solidprobe.cjs`. Keep the probe (Task 7 reuses). Smoke → PASS (default prefs unaffected).

```bash
git add electron/main.cjs electron/preload.cjs src/lib/bridge.ts src/main.tsx src/styles/global.css src/store/store.ts electron/solidprobe.cjs
git commit -m "shell: solid-window plumbing — painted/eco windows go opaque on next launch"
```

---

### Task 7: Painted mode — the wallpaper painting layer

**Files:**
- Modify: `src/App.tsx` (mount the layer), `src/styles/shell.css` (layer styles), `src/lib/glassWash.ts` (position updates)
- Modify: `electron/solidprobe.cjs` (extend into the painted probe)

**Interfaces:**
- Consumes: `--wallpaper-img`, `--wallpaper-size`, `getGlassScreen()` from Task 5; `data-solidwin` from Task 6.
- Produces: `<div className="app-wallpaper" />` mounted when `perfMode === 'painted' && isDesktop`; CSS vars `--wallpaper-x/--wallpaper-y` (window offset within the screen).

- [ ] **Step 1: position math in glassWash.ts**

Add to `glassWash.ts`:

```ts
function anchor() {
  const r = screenRect
  if (!r) return
  const root = document.documentElement
  // window.screenX/Y are the window's absolute desktop coords; the painting
  // is screen-sized, so shifting it by the negative window offset pins it to
  // the physical desktop (re-anchored on drag-end via glass:refresh)
  root.style.setProperty('--wallpaper-x', `${-(window.screenX - r.x)}px`)
  root.style.setProperty('--wallpaper-y', `${-(window.screenY - r.y)}px`)
}
```

Call `anchor()` at the end of a successful `apply()` and in the `onRefresh` handler (refresh fires ~450ms after drag-end/resize).

- [ ] **Step 2: mount + CSS**

`App.tsx` — first child inside the `.app` root element (read the JSX; it's the element carrying the app className):

```tsx
{isDesktop && perfMode === 'painted' && <div className="app-wallpaper" aria-hidden />}
```

(`const perfMode = useKaisola((s) => s.perfMode)` — add the selector near the other App-level selectors.)

`shell.css`, right after the `.app::before` rule (`:44-65`):

```css
/* PAINTED GLASS: an opaque window that draws its own see-through — the
   pre-blurred wallpaper (sampled in main) pinned to the desktop position.
   z-index -2 sits UNDER the tint field (-1): everything translucent now
   "sees" the painting exactly where it saw the OS material in live glass. */
.app-wallpaper {
  position: absolute;
  inset: 0;
  z-index: -2;
  pointer-events: none;
  background-image: var(--wallpaper-img, radial-gradient(120% 90% at 30% 0%,
    color-mix(in srgb, var(--accent) 14%, var(--bg-0)), var(--bg-0)));
  background-size: var(--wallpaper-size, cover);
  background-position: var(--wallpaper-x, 0) var(--wallpaper-y, 0);
  filter: blur(24px) saturate(1.25); /* static layer: rasters once, repaints never */
  transform: scale(1.04); /* hide the blur's edge vignette */
}
```

- [ ] **Step 3: probe + smoke + commit**

Extend `solidprobe.cjs`: after the Task 6 assertions, `setPerfMode('painted')`, wait 800ms, assert `document.querySelector('.app-wallpaper')` exists and its computed `backgroundImage` contains `data:image/jpeg` (real sample; the probe runs WITHOUT the smoke env) or the radial-gradient fallback (accept either, print which), and `dataset.perf === 'painted'`. Screenshot to `<scratchpad>/painted.png` — **eyeball it**: it should read as glass. Also assert eco still flattens: `setPerfMode('eco')` → `.app-wallpaper` unmounted. `npm run build && node electron/solidprobe.cjs` → `SOLID=PASS`. Full smoke → PASS.

```bash
git add src/App.tsx src/styles/shell.css src/lib/glassWash.ts electron/solidprobe.cjs
git commit -m "glass: painted mode — an opaque window that draws its own see-through"
```

---

### Task 8: Settings picker + settings.json key + restart chip

**Files:**
- Modify: `src/components/Settings.tsx:310-321` (the Energy saver row)
- Modify: `src/lib/userConfig.ts` (applySettings + SETTINGS_TEMPLATE)

**Interfaces:**
- Consumes: `perfMode`/`setPerfMode`, `bridge.windowMode()`, `bridge.relaunch()`.
- Produces: settings.json key `"perfMode": "glass" | "painted" | "eco"`.

- [ ] **Step 1: replace the row**

```tsx
<div className="settings-row">
  <span className="settings-row-label">Appearance energy <span className="faint" style={{ fontWeight: 400 }}>· ranked by GPU cost</span></span>
  <div className="settings-row-control">
    {windowModeMismatch && (
      <button className="settings-chip" onClick={() => void bridge.relaunch()} title="The window's transparency is set at launch — restart to finish switching">
        Restart to finish applying
      </button>
    )}
    <Dropdown
      value={perfMode}
      options={[
        { value: 'glass', name: 'Glass · live ●●●' },
        { value: 'painted', name: 'Glass · painted ●●' },
        { value: 'eco', name: 'Energy saver ●' },
      ]}
      onSelect={(v) => setPerfMode(v as PerfMode)}
      align="right"
      title="Live: real translucency. Painted: same look drawn as a static painting — far cheaper. Energy saver: solid and still — cheapest."
    />
  </div>
</div>
```

`windowModeMismatch`: local state fed by an effect that runs `bridge.windowMode()` on mount AND after every `perfMode` change (`wantSolid !== liveSolid`). Import `PerfMode` from the store. If `.settings-chip` doesn't exist in CSS, reuse the update-pill quiet style: add a `.settings-chip` rule cloned from `.update-pill[data-busy]`'s look (small, ghost, accent text) in `shell.css` near the settings styles.

- [ ] **Step 2: userConfig.ts**

`applySettings` (after the termCursorColor line, `:98`):

```ts
if (cfg.perfMode === 'glass' || cfg.perfMode === 'painted' || cfg.perfMode === 'eco') s.setPerfMode(cfg.perfMode)
```

SETTINGS_TEMPLATE (after the termCursorColor line): `  // "perfMode": "glass",                    // "glass" (live) | "painted" (cheaper) | "eco" (cheapest)`

- [ ] **Step 3: verify + commit**

`npm run build`. Quick probe via solidprobe run (already asserts setPerfMode paths). Manually-shaped check via glassprobe screenshot of the Settings pane is overkill — rely on smoke (which exercises Settings mount) → PASS.

```bash
git add src/components/Settings.tsx src/lib/userConfig.ts src/styles/shell.css
git commit -m "settings: three-way appearance-energy picker, ranked by GPU cost"
```

---

### Task 9: Full verification + release

- [ ] **Step 1: sweep**

`grep -rn "ecoMode\|app-active-glass-blur" src/ electron/` → only Terminal.tsx's local const. `npm run build` clean. `node electron/glassprobe.cjs` PASS, `node electron/solidprobe.cjs` PASS, full `node electron/smoke.cjs` PASS (tee output to a log file, don't pipe-and-lose it).

- [ ] **Step 2: measure (report to Michael, not a gate)**

perfprobe-style GPU sample: live glass vs painted (solid prefs) with a streaming terminal, 20s each; report % like the 19%→0% numbers.

- [ ] **Step 3: release (release-on-push policy)**

```bash
git push && npm version patch --no-git-tag-version
git add package.json package-lock.json
git commit -m "vX.Y.Z — glass for less: sampled wash, painted mode, energy picker"
git tag vX.Y.Z && git push && git push --tags
gh run watch <id> && gh release view vX.Y.Z --json assets -q '.assets[].name'
```

Verify assets include `latest-mac.yml` + dmg/zip. Then update the stale memory `kaisola-glass-energy.md` (terminal-opacity note is outdated; record the new mode model).
