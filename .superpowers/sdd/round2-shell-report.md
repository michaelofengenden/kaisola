# Round 2: new-session affordance + dark glass depth and reclaim

Worktree: `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a69134e1c285395a0`
Branch: `worktree-agent-a69134e1c285395a0`, branched from `581e400` (`backlog-integration` head).

| commit | subject |
| --- | --- |
| `3d23447` | feat(rail): rest the active project's New Session control on screen |
| `4b39303` | refactor(chrome): run the detail card to the window's top edge |
| `4bc36ad` | fix(glass): bake the wallpaper in the space its normalization is measured in |

---

## 1. "Make it easier to open new sessions"

**Chosen: the active project's `+` is simply drawn at rest. One affordance, nothing
added beside it.**

Exactly one project is active at a time, so this puts exactly one 18pt glyph in the
whole rail — the app's most common action becomes visible without the column
acquiring a control per row. The launch menu's contents are untouched (New Terminal,
the agent terminals, Chat, Mesh).

The two candidates I did **not** take, and why:

* **A "New session" row under the active project's sessions.** This is the ghost row
  v1.1.7 deleted, and its objection still stands: a row that appears under the
  pointer moves every row below it while the pointer is travelling toward one. As a
  *permanent* row it is worse — it is a full 32pt of rail spent restating what the
  header's `+` already offers, on the one surface Michael has repeatedly asked to
  keep quiet.
* **A `+` in the footer control cluster.** The footer is width-bound, not
  space-bound. `FooterAccountBudget.nameWidth` charges the account name for every
  control beside it; one more slot costs 18pt, taking the name from ~109pt toward
  the floor `QuietIdentityMarkTests` holds. It also puts creation at the opposite
  end of the column from the project it would create in.

Inactive projects are unchanged: they draw no `+` at all and reach creation through
their context menu. `QuietProjectHeaderControls.showsLaunchControl(isActive:hovering:)`
states the rule as a pure function, so "one resting control, not one per row" is a
test rather than an `if hovering` a later layout pass can re-add.

Verified live on a dev launch with the pointer nowhere near the rail:
`AXMenuButton id=rail.new-session "New session in TimeAblations" @(321, 222) 20×14`,
on the active project's row and on no other.

**One geometric fix rode along.** `QuietRailMetrics.plusTrailingInset` moves 10 → 12.
The sidebar's resize corridor is an overlay on the trailing edge of the List and
reaches `projectSidebarDividerReach` (10.5pt) inward, so at 10 it covered the last
half-point of the `+` slot. `RootShellView` already documented that overlap and
explicitly left it alone while the control existed only under the pointer; a
permanent control that is now the app's main creation door cannot share its pixels
with a drag handle.

---

## 2a. Dark glass: the flatness was a rendering bug, not a veil

### What was actually wrong

`CIContext` colour-manages by default and its working space is **linear sRGB**, so
every filter in the bake operates on linearized values. `luminanceShift` is measured
in the opposite space — `DesktopTintSampler.meanLuminance` reads a `CGContext` raster
in `DeviceRGB`, i.e. gamma-**encoded** bytes. The bake was subtracting an encoded
quantity from linear values.

For Michael's own desktop the encoded mean is 0.438 and the shift is −0.278, but that
still's *linear* mean is only 0.17. The offset drove the whole image past zero:

```
shipped dark bake, rendered and measured
  mean rgb 0.0000/0.0000/0.0295   mean luma 0.0021 (declares 0.16)
  p5 0.0000  p50 0.0000  p95 0.0142
  pure black: 79.7% of the still
```

The dark surface was a veil over black. That is the flatness, and no veil tuning
could have reached it, because there was nothing under the veil to let through. It
also explains why the previous pass's modelled numbers and the shipped surface
disagreed so completely: that pass modelled the composite arithmetically in sRGB
space — which is what the constants *mean* — and never rasterized the renderer's
actual output.

Light was wrong in the mirror direction and got away with it: adding 0.282 in linear
space then re-encoding happens to land near the 0.72 target, so light only lost
structure (spread 0.039 where the same constants in the measured space give 0.063)
rather than losing the picture.

**Fix:** ask the bake's `CIContext` for an sRGB working space — the space the
measurement is taken in. sRGB rather than disabling colour management, so a Display
P3 or HDR wallpaper is still converted before its bytes are treated as sRGB.

### Before / after, measured by rendering the real pipeline

Michael's actual desktop (the Lake Tahoe aerial the app resolves: avg
0.263/0.476/0.575, luma 0.438, off-neutral 0.399). Sidebar surface at 210×900,
workspace at 900×900. Contrast is computed against the composite with macOS's dark
label alphas (white @0.85 primary, white @0.55 secondary); "worst" is the same
against the surface's p95 (brightest) patch, which is where a label is hardest to
read.

| | dark sidebar BEFORE | dark sidebar AFTER | light sidebar (reference) |
| --- | --- | --- | --- |
| composite rgb | 0.032 / 0.031 / 0.042 | **0.089 / 0.105 / 0.112** | 0.835 / 0.899 / 0.929 |
| luminance spread p5..p95 | 0.0104 | **0.0832** (8.0×) | 0.0625 |
| veil gradient top→bottom | 0.0063 | **0.0372** (5.9×) | 0.0393 |
| off-neutral | 0.200 | **0.129** | 0.059 |
| red ÷ blue | 0.77 | **0.79** | 0.90 |
| still clamped to black | **79.7%** | **2.2%** | 0.0% |
| primary label contrast | 14.3:1 | **12.8:1** (≥7 ✓) | 12.3:1 |
| secondary label contrast | 6.3:1 | **6.0:1** (≥4.5 ✓) | 4.5:1 |
| worst-case primary (p95 patch) | 14.1:1 | **11.9:1** (≥7 ✓) | 11.5:1 |
| worst-case secondary | 6.2:1 | **5.8:1** (≥4.5 ✓) | 4.3:1 |

Dark workspace: 0.033/0.032/0.044 → **0.087/0.103/0.110**, spread 0.0080 → **0.0786**,
off-neutral 0.200 → **0.127**, primary **12.8:1** (worst 12.0:1), secondary **6.0:1**
(worst 5.8:1).

The BEFORE contrast figures are *higher* precisely because the surface was near-black
— contrast against nothing is easy. The AFTER numbers are the cost of the surface
having a wallpaper in it at all, and they clear both floors with margin at every
sampled point.

### The residual cool cast

With the bake rendering correctly, dark measured 0.221 off-neutral against light's
0.059 on the identical wallpaper — same picture, same veil arithmetic, 3.7× the cast.
That is the "still a little blue/purple".

`DesktopBackdropRenderer.darkSaturationCeiling` (0.85 → **0.50**, dark only) takes it
to 0.129. The reason this is the right lever rather than one that greys the wallpaper
out is measurable: across the whole sweep the luminance spread does not move
(0.0785 at every ceiling from 0.85 to 0.35). The wallpaper's light and shade all
survive; only how loudly it is coloured changes.

It also makes the surface far less dependent on the desktop. Across the five most
extreme wallpapers in the aerial library on this machine:

| wallpaper (luma, off-neutral) | dark sidebar BEFORE | dark sidebar AFTER |
| --- | --- | --- |
| Lake Tahoe — Michael's (0.438, 0.399) | offN 0.200, spread 0.010 | offN **0.129**, spread **0.083** |
| darkest (0.076, 0.130) | offN 0.003, spread 0.043 | offN **0.011**, spread **0.046** |
| brightest (0.792, 0.400) | offN 0.484, spread 0.125, 41% black | offN **0.138**, spread **0.051**, 0% black |
| most saturated (0.265, 0.824) | offN **1.181**, spread 0.007 | offN **0.330**, spread **0.040** |
| most neutral (0.435, 0.015) | offN 0.171, spread 0.160, 55% black | offN **0.009**, spread **0.157**, 23% black |

Worst-case dark contrast across all five, after: primary **9.9:1** minimum,
secondary **5.1:1** minimum. Both floors hold on every wallpaper tested.

### Third change: the dark veils thin one more step

Sidebar 0.55 → **0.52**, workspace 0.58 → **0.55**. Deliberately small — the flatness
was not the veil, and with the still actually arriving, 45% transmission already gave
dark more spread than light. The extra three points buy margin (spread 0.078 → 0.083,
gradient 0.035 → 0.037) while staying inside the frost band
`testGlassVeilsFrostTheDesktopWithoutErasingIt` holds: 0.48 transmission is still
glass and not a photograph.

Constants **not** changed, and why: `blurRadius` (28 — the sweep buys only
0.078 → 0.084 of spread at radius 22, and light was never the complaint, so a
shared constant is not worth moving for that), `targetLuminance` (0.16 — raising it
brightens the surface and costs contrast without buying spread: the normalization is
an offset, so it moves the mean and not the range), and every light constant.

### The test that would have caught this

`testTheBakeArrivesAtTheLuminanceItDeclares` writes three synthetic wallpapers,
renders them through `DesktopBackdropRenderer.render` in both appearances, and
measures the result: mean luminance within 0.06 of the declared target, structure
surviving (p5..p95 spread > 0.05), and the share clamped to black bounded. Every
existing glass test checked constants and the arithmetic around them; none rendered
anything, which is exactly why none of them noticed a bake that was 80% black.

One fixture is allowed 0.30 black rather than 0.02, and the comment says why: a
linear ramp is blur-invariant, so unlike a real photograph none of its range is
softened away before the normalization sees it, and a wallpaper whose mean is 0.78
cannot be shifted to 0.16 additively without clipping its shadows. Every real
wallpaper measured 0.0–2.2%.

---

## 2b. Reclaiming the top band

### The collision, and how it was resolved

The previous pass's report (`backlog-sidebar-report.md`, item 4) recorded the limit
honestly: the card could not run to the window's top because the two panel toggles
were anchored to *its* top-right corner, and an open Files rail draws a 30pt header
bar starting 6pt below that corner. A card at the top put the hover-revealed pair
directly over the controls the user was aiming at, so the card stopped 28pt short and
only 12 of the band's 40pt reached the pane.

I could not move the Files rail's header controls — `Features/Workspace/*` belongs to
another agent this round — so the toggles had to move. **Three homes were tried and
measured on a dev launch, and all three were rejected**, which is why the pair is
*removed* from the sidebar layout rather than relocated.

1. **The sidebar's traffic-light band.** This looked like the answer, and I built and
   shipped it before measuring: 46pt the platform reserves for the traffic lights
   whether or not anything is drawn in it, carrying nothing. Two problems, both found
   by AX rather than by reasoning.
   * `NavigationSplitView` already puts its own Hide Sidebar item in the band's
     trailing 47pt — `AXButton "Hide Sidebar" @(305, 95) 47×52` against a sidebar
     column ending at x 352. The first build laid both toggles straight on top of it.
   * Fixing that (inset past the item, 6pt gap; verified at
     `@(245, 114)` and `@(273, 114)`, cleanly between the traffic lights ending at
     x 214 and AppKit's item starting at x 305) exposed the fatal one: **that band
     belongs to the AppKit `AXToolbar`, which swallows mouse events over the sidebar
     column.** The controls rendered, reported correct frames, and `AXPress` flipped
     them ("Hide Files" → "Show Files"), but a real synthesized click at their exact
     centre did nothing, twice. A control only VoiceOver can operate is not a control.
2. **The card's top-leading corner.** 16pt of clearance before the session pane's own
   title button starts (`@(374, 113.5)` against a card edge near x 358).
3. **The card's top-trailing corner with the card at the top.** The original
   collision, unchanged — the Files header's controls sit at x 1366–1521, y 118–134.

**What shipped: the pair is removed in `.leftTree`, and every door it held was
verified working on the same launch.**

* The Files rail's own header carries a permanent Hide Files button. A real
  synthesized click through it at **(1372, 126) — window-top + 31, inside the same
  52pt toolbar band** — closed the rail. That is also the evidence that the *detail*
  column, unlike the sidebar, is perfectly clickable that high, so the card loses
  nothing by moving up.
* The sidebar footer's overflow menu carries permanent `Show or Hide Files` and
  `Show or Hide Document Preview` items; an `AXPress` on the first reopened the rail.
* ⌘B / ⇧⌘B, the View menu and the command palette are untouched, and both commands
  keep a default shortcut (pinned by a test).

So closing a panel stays one click, and opening one by mouse is the footer menu
instead of a hover the user had to already know about. Removing rather than
relocating is also the direction this rail has been moving for three releases.

The top-bar layout has no `NavigationSplitView` and no sidebar footer, so there
`detailArea` keeps the hover-revealed pair and the 28pt strip. There the collision
never existed: that card's top sits under a real top bar rather than under the
window's own edge. `detailPanelTopInset` is a function of the layout now instead of
one number serving two shapes.

### Geometry (AX-measured, dev launch, window `@(134, 95) 1412×886`)

| | BEFORE (v1.1.9) | AFTER |
| --- | --- | --- |
| detail card top edge | y **123.0** | y **101.0** |
| card top inset (from window top y 95) | **28pt** | **6pt** (`chromeInset`) |
| card content height | **852.0** | **874.0** |
| reclaimed this pass | — | **22pt** |
| reclaimed from the original 40pt band | 12pt | **34pt** |

Both measurements are the same element — `AXUnknown "Resize document preview"`, the
full-height divider inside the card — on the same window, taken from a build of
`581e400` with only `RootShellView.swift` reverted.

---

## Verification

- `npm run native:fast:build` — clean, no warnings, no errors.
- `npm run native:test:focus -- NativePreviewSettingsTests QuietIdentityMarkTests SidebarScrollPinTests` — green.
- `npm run native:test:changed -- --include-working-tree` — green (9 suites).
- Dev-profile launches only (`KAISOLA_NATIVE_BROKER_PROFILE=development`), stopped
  with `kill -TERM`. AX read with a purpose-built pid-exact
  `AXUIElementCreateApplication` tool; no System Events whose-clauses, so the
  production app (running throughout at pid 33218) was never touched. No
  `defaults delete`, no writes to `/Applications/Kaisola.app`.
- Glass numbers are not modelled arithmetic: a standalone tool reproduces the shipped
  pipeline (thumbnail → `CIGaussianBlur` → `CIColorControls` → `GlassWarmth` → veil
  gradient) against real wallpaper files and rasterizes the result, which is what
  exposed the working-space bug in the first place.
- Live AX evidence, all on the final build:
  * `AXMenuButton id=rail.new-session "New session in TimeAblations" @(321, 222)
    20×14` — present with the pointer nowhere near the rail, and present on the
    **active** project only (the two inactive project rows carry no `+`).
  * The card's reclaim, before and after, in the table above.
  * A real synthesized click at (1372, 126) closing the Files rail, and an `AXPress`
    on the footer's `Show or Hide Files` reopening it.
  * The rejected band placement, including the click that did nothing at
    (286, 126) while `AXPress` on the same element succeeded — the evidence that
    the AppKit toolbar owns those pixels.

## Concerns / follow-ups

1. **Re-opening a closed panel by mouse is now a two-click menu.** With the pair
   gone from the sidebar layout, the pointer route to *open* Files or the document
   preview is the footer's overflow menu (verified working). Closing is unchanged at
   one click, and ⌘B / ⇧⌘B are unchanged. If Michael wants a one-click re-open back,
   the only place left that is both free and clickable is inside the Files/document
   panel headers themselves — `Features/Workspace/*`, out of scope this round.
2. **A collapsed sidebar leaves only keyboard doors.** `NavigationSplitView` installs
   a Hide Sidebar control (verified at `@(305, 95) 47×52`), and with the sidebar
   hidden the footer's overflow menu goes with it. ⌘B / ⇧⌘B, the View menu and the
   palette remain.
3. **The AppKit toolbar swallows clicks over the sidebar column, and nothing in the
   codebase said so.** This cost a full build-measure-rebuild cycle and is the kind
   of thing worth keeping: any future attempt to put SwiftUI controls in the
   traffic-light band will render, pass an AX check, and silently not work. It is now
   written down in `detailPanelTopInset(layout:)`.
4. **Bright wallpaper + dark mode still clips its shadows.** A wallpaper whose mean
   luminance is far above 0.16 cannot be normalized down additively without pushing
   its dark end past zero. It is bounded and no longer catastrophic (0% on the
   brightest real aerial, 25% on an adversarial synthetic ramp, against 79.7% before),
   but the principled fix is to solve gain and offset together — `CIColorControls`
   `contrast` is exactly a gain about 0.5 — so that the still's own minimum lands on
   zero instead of past it. Left out as a separate, larger change.
3. **No screenshots.** `screencapture` is TCC-blocked in this environment, so every
   appearance claim rests on arithmetic over rendered pixels and every geometry claim
   on AX frames.
4. **`node_modules` is a symlink to the main checkout**, added so the worktree could
   package the broker helper for the dev launch. Untracked; delete it before
   archiving the worktree.
