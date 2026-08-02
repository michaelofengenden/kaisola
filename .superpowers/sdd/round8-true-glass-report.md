# Round 8: the glass is where the window is, and it stops caring which hue the wallpaper is

Worktree: `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a36fcd191b79e6fe8`
Branch: `round8-glass-desktop-pinning`, branched from `a3cc3cc` (`backlog-integration` head).

| commit | subject |
| --- | --- |
| `6567721` | test(glass): stop the wallpaper watch test racing the resolve it starts |
| `16ef320` | feat(glass): pin the backdrop to the desktop and make the tone map hue-blind |

Files touched: `App/NativePreviewSettings.swift` and `KaisolaTests/NativePreviewSettingsTests.swift`
only. The window-frame hook lives in the same file — see §1.3.

---

## The short version

> "huh the saturation is bizarre though, on blue wallpaper it becomes white and
> on green wallpaper it's very green. also we don't get the translucence at all.
> I meant the glass wallpaper should be translucent to the wallpaper itself
> (like transparent)."

Both halves were real bugs and both are measured here rather than described.

**Translucence.** Every glass surface drew the *same* baked still stretched to
its own shape, so what the sidebar showed bore no relation to the wallpaper
behind the sidebar and **nothing in it moved when the window moved**. That is a
blurry photograph painted on a panel; no veil opacity can make it read as
transparent, which is why three rounds of veil-thinning did not. The backdrop is
now pinned to desktop coordinates: each surface shows the wallpaper region
actually behind it, at the wallpaper's own scale, on the window's own screen.
Following a drag costs **0.26 µs** of arithmetic and one property assignment.

**Saturation.** The bake measured lightness as Rec. 709 luma, which weights green
9.9× blue, and corrected it with an *additive* per-channel offset. Four
wallpapers identical in HSV value and saturation, differing only in hue, read as
**0.24 / 0.20 / 0.39 / 0.50** bright — a 2.4× spread from nothing — and each was
handed a different flat grey to make up the difference. Adding a large constant
to a blue walks it toward white; adding a small one to a green leaves it green.
Rendered, the light sidebar measured Oklab saturation **0.036 blue against 0.083
green**. Lightness and colourfulness are now measured in **Oklab** and *solved*
against the rendered structure. The hue family now agrees to **four decimals at
the bake** and within **8% at the surface**, where the whole residual is the
declared `GlassWarmth` amber.

---

## 1. The glass is positioned like glass

### 1.1 What was wrong

Round 2 skipped desktop pinning with a stated reason: it would "re-lay out on
every window drag". That reason does not apply to a **baked and cached** still.
The still is already rendered; showing a different part of it is a change of
*sampling rectangle*, not of pixels. The skip is what left the sidebar showing a
squashed miniature of the entire desktop — the same one, at every window
position, on every display.

### 1.2 The arithmetic

`DesktopBackdropGeometry` is pure and fully tested:

```swift
wallpaperFrame(imagePixels:screen:scaling:allowsClipping:backingScale:) -> CGRect
contentsRect(surface:imagePixels:screen:scaling:allowsClipping:backingScale:) -> CGRect
layout(from: NSWorkspace.desktopImageOptions(for:)) -> (NSImageScaling, Bool)
```

`imageScaling` + `allowClipping` together spell out every fill mode macOS offers,
and all five are honoured:

| System Settings | `NSImageScaling` | clipping | layout |
| --- | --- | --- | --- |
| Fill Screen | `.scaleProportionallyUpOrDown` | true | `max` ratio, overhangs |
| Fit to Screen | `.scaleProportionallyUpOrDown` | false | `min` ratio, letterboxed |
| Stretch to Fill | `.scaleAxesIndependently` | — | screen |
| Centre | `.scaleNone` | false | pixels ÷ backing scale, centred |
| Tile | `.scaleNone` | true | as Centre, repeating from the screen origin |

`contentsRect` returns a **top-left-origin** unit rectangle, which is
`CALayer.contentsRect`'s convention and a `CGImage`'s; AppKit's y-up screen
coordinates are flipped once, here, rather than at each call site. A surface that
runs off the wallpaper is **slid back inside at full size** rather than shrunk to
the overlap — shrinking would stretch one strip across the whole surface, which
is the artefact that reads as a bug.

### 1.3 The hook, and the drag cost

`DesktopWallpaperPatch` (an `NSViewRepresentable`) holds one `CALayer` whose
`contents` is the cached still and whose `contentsRect` is this rectangle. It is
the app's only hook into where its windows are, and it observes only *frame*
signals: `NSWindow.didMove` / `didResize` / `didChangeScreen` /
`didChangeBackingProperties`, plus `didChangeScreenParameters` and
`activeSpaceDidChange`. `didMove` fires continuously through a live drag, which
is the cadence the backdrop has to follow.

Per drag frame, measured over 100 000 iterations in the Debug build:

**0.26 µs** of geometry, plus `patch.contentsRect = rect` inside a
`CATransaction` with actions disabled. No decode, no blur, no new texture upload
— the same texture is sampled from a different rectangle. `testFollowingADragCostsArithmeticAndNotABake`
holds this at ≤ 20 µs so nobody can later put a decode behind it.

Implicit animation is disabled deliberately: without it a drag eases the backdrop
toward each new position a beat behind the window, which reads as the glass
sliding rather than the desktop standing still.

### 1.4 Two consequences of pinning, handled here

**The blur can no longer be a fraction of the picture.** A 210 pt sidebar shows
about an eighth of a 1512 pt display, so round 7's 5%-of-the-wallpaper blur is
**36% of the sidebar** — one soft wash end to end. Measured: structured-fixture
surface detail fell from 0.0038–0.0058 stretched to **0.0018–0.0022** pinned,
below even the pre-round-7 figure. A real frosted material has a fixed scattering
length in physical units, so the blur is now stated that way —
`desktopBlurPoints = 28` — and the desktop's width joins `DesktopBackdropKey`
(quantized to 128 pt so two similar displays share one bake). `stillWidth`
448 → **896**, because a pinned sidebar magnifies its crop ~7× at 448 and ~3.4× at
896. The radius is taken from the still's *actual* decoded width, not the
declared maximum — `CGImageSourceCreateThumbnailAtIndex` treats it as a maximum,
so a small wallpaper would otherwise be blurred by the wrong number of points.

**The worst patch the floors are measured on is now a crop.** `tailFraction`
moves from 2% to **0.25%**: the smallest glass surface is about an eighth of the
screen, so its own brightest 2% *is* the wallpaper's brightest 0.25%. The bound
is exact — the mean of any 0.25%-sized subset is at most the mean of the
brightest 0.25% — and it is what keeps every floor in the file stated about a
surface that still exists.

### 1.5 Proof

`testEachGlassSurfaceShowsTheWallpaperRegionBehindIt` — hand-computed, not
re-derived from the code:

| case | assertion |
| --- | --- |
| window at x=100, y=60, 210×900 | sub-rect `(100/1512, 22/982, 210/1512, 900/982)` |
| drag 300 pt right | sub-rect slides exactly `300/1512`, nothing else moves |
| drop 40 pt | sub-rect walks **down** `40/982` (the AppKit y-flip) |
| second screen 2560×1440 at (1512, −230), backing 1 | fill binds on width; 210 pt covers 210 pt of *that* display; different part of the picture |
| off the left / right / top edge | slid inside at full size, never a stretched strip |
| surface larger than the wallpaper | degenerates to the whole image, never outside it |
| fit / fill / stretch / centre / tile | each layout checked; two tiles sample the same offset |
| `desktopImageOptions` dictionary and its absence | parsed; defaults are Fill Screen |

`testMovingTheWindowMovesTheWallpaperUnderTheGlass` is the same claim rendered
end to end: over a black-to-white wallpaper, the sidebar's mean luminance is
strictly increasing left → middle → right, in both appearances. **The stretched
pipeline returns three identical numbers**, which is the bug in one line.

---

## 2. The hue-dependent blowout

### 2.1 The mechanism, confirmed by measurement

Four wallpapers built from one structured value field, **identical in HSV value
and HSV saturation**, differing only in hue. Measured before any change:

| fixture | Rec. 709 luma | Oklab L* | Oklab C/L |
| --- | --- | --- | --- |
| blue (H 220) | **0.2415** | 0.3841 | 0.2978 |
| red (H 0) | **0.2047** | 0.4001 | 0.3263 |
| green (H 120) | **0.3932** | 0.5245 | 0.2997 |
| neutral | **0.5000** | 0.5982 | 0.0000 |

Luma reads four equally-bright pictures over a **2.4× range**. `luminanceShift`
then hands the blue one +0.481 of flat grey and the green one +0.329 — and
`CIColorControls.brightness` is a straight per-channel *offset*, which is exactly
the operation that destroys saturation. `tailGain` diverged with it (blue 1.000,
green 0.619) because the tail was luma-measured too.

Rendered light sidebar, Oklab saturation, **shipped pipeline**:

| blue | green | red | neutral |
| --- | --- | --- | --- |
| **0.0361** | **0.0833** | 0.0465 | 0.0033 |

Green is **2.31× blue** from wallpapers that are equally colourful by
construction. That is "on blue wallpaper it becomes white and on green wallpaper
it's very green", in numbers.

It survived four rounds of careful measurement because every one of them checked
wallpapers **one at a time**. A per-wallpaper spot check cannot see a quantity
that is only wrong *relative to another hue*.

### 2.2 The fix

Lightness and colourfulness move into **Oklab**, and the tone map is *solved*
against the rendered structure instead of computed from a formula.

- `targetLightness(isDark:)` and `tailHeadroomLightness(isDark:)` are **derived
  from** `targetLuminance` and `tailHeadroom`, so a neutral wallpaper lands on
  exactly the grey rounds 2–4 priced their veil arithmetic against (0.16 → L*
  0.2801, 0.72 → L* 0.7813) and every published composite figure still holds.
- `solveToneMap(probe:isDark:)` applies a candidate map to the 96×96 probe in
  software, measures, and corrects — three targets, three knobs: **offset** →
  mean L* on target; **gain** → worst patch inside the headroom; **saturation** →
  mean Oklab C/L onto the wallpaper's own colourfulness × `desktopChromaShare`.
- The source colourfulness is **mean HSV saturation**, which is *exactly*
  invariant under a hue rotation, where even Oklab C/L carries a residual 9% hue
  dependence. A perceptual target driven by a hue-blind source measure is the
  pairing the invariance needs. It also keeps a grey desktop grey: zero source
  colourfulness ⇒ zero target ⇒ no amount of solving can invent a hue.
- The map is one **`CIColorMatrix`** — the same single filter pass
  `CIColorControls` was — declared as `BakeToneMap` so the solve can model it
  exactly rather than inferring the filter's internal luma weights and operation
  order (round 3 had to *measure* that order to get the offset right).

Shares are calibrated so the **average** colourfulness over the hue family is
what already shipped — surface Oklab saturation 0.128 dark, 0.055 light. Nothing
about how colourful the glass is has moved; only how evenly it is reached.

The first solve I wrote oscillated (gain chasing a tail that was small *because*
the gain was small) and left dark 0.31/0.12/0.22/0.18 in L*. The fix is
structural: the offset is re-settled **to convergence** inside every outer pass,
and the gain only ever shrinks.

### 2.3 Hue-invariance numbers

`testGlassIsTheSameMaterialWhateverHueTheWallpaperIs`. Ranges are over
blue/green/red; neutral is reported separately because its colourfulness is zero
by construction.

**Baked still** — exact:

| | L* (target) | Oklab saturation |
| --- | --- | --- |
| dark | 0.2798 – 0.2802 (0.2801) | 0.1717 – 0.1718 |
| light | 0.7811 – 0.7817 (0.7813) | 0.1217 – 0.1220 |

**Finished surface**, 210 pt sidebar pinned over the middle of the desktop:

| | L* | Oklab saturation | spread | amber removed | **before** |
| --- | --- | --- | --- | --- | --- |
| dark | 0.2396 – 0.2404 | 0.1261 – 0.1364 | **1.082** | 0.1361 – 0.1374 (**1.010**) | 0.1092 – 0.1496 (1.370) |
| light | 0.8802 – 0.8824 | 0.0548 – 0.0588 | **1.069** | 0.0589 – 0.0602 (**1.022**) | 0.0361 – 0.0833 (**2.307**) |

Light's blue↔green disagreement goes from **2.31× to 1.07×**. Lightness agrees to
0.3% or better in both appearances.

The whole surface residual is `GlassWarmth`: a fixed amber *vector* in Oklab, so
it adds to a red surface and cancels a blue one. Re-rendering with the amber at
zero takes the disagreement to 1–2%, and the test asserts that too — if the
residual ever stops being the amber, something else has become hue-dependent and
the test says so.

Three further guards, so the tolerances mean something:

1. The contrast floors are asserted **on the same renders**, per hue.
2. The coloured surfaces must stay ≥ 4× the neutral one's saturation — otherwise
   a pipeline that painted grey would pass everything above.
3. `bakeAsShippedBeforeRound8` (the round-7 pipeline, frozen) must **fail** the
   same bound by > 1.2×. If it ever stops failing, the fixture has stopped
   reproducing the bug and the numbers above are no longer evidence.

---

## 3. Contrast floors — held, on the pinned geometry

Worst-patch contrast, rendered, over the six ramp fixtures, the structured
fixtures, and the hue family, sampling **seven window positions across the
display** for each:

| | floor | measured |
| --- | --- | --- |
| dark primary | ≥ 7.0 | **8.72 – 10.21** |
| dark secondary | ≥ 4.5 | **4.69 – 5.20** |
| light primary | ≥ 7.0 | **10.08 – 10.51** |
| light secondary | ≥ 3.43 (AppKit ceiling) | **3.55 – 3.62** |
| % pure black / white | 0.0 | **0.0 / 0.0** |

Light's secondary is *above* its round-7 baseline of 3.43–3.44 at every position.
Pinned surfaces measure **better** than stretched ones on the same wallpapers
(dark ramp: 8.34 stretched → 9.38 pinned), because `tailFraction` 0.0025 bounds a
tighter quantity than 0.02 did.

Untouched: dark transmission 0.66, light 0.55, every `GlassBackdropWash` opacity,
`targetLuminance`, `GlassWarmth`, `liveTint`, the increased-contrast overlays.
Reduce Transparency, Solid and Tinted never reach the painted path and are
unchanged — Solid is still one flat opaque colour with no wallpaper contribution
at all.

---

## 4. Bake cost

Debug build, 20 iterations, structured fixture: **64 ms**, of which the solve is
**42 ms**. Round 7's figure was 23–25 ms. Two thirds of the increase is the
solve; the rest is `stillWidth` 896 (4× the pixels of 448).

The first working solve cost **156 ms**. Three changes took it to 42 with
bit-identical output: a 4096-entry table for sRGB→linear (`pow` was most of the
cost), a bounded top-*k* selection instead of sorting 9216 doubles a dozen times,
and per-pixel luma/delta hoisted out of the iteration. `toneSolveIterations` 6 →
4; a fifth pass moves nothing.

It is off the main thread (`Task.detached(priority: .utility)`), cached per
`(wallpaper, appearance, screen width)`, and runs only when one of those changes.
**No per-frame work was added anywhere** — the render path is a `contentsRect`.

---

## 5. Verification

- `npm run native:fast:build` — clean, no warnings, no errors.
- `npm run native:test:focus -- NativePreviewSettingsTests` — **117 tests, 0
  failures**.
- `npm run native:test:changed -- --include-working-tree` — passed (core package
  25 tests + 10 selected native suites).
- Commit `6567721` was built and tested on its own before `16ef320` was applied,
  so neither commit is broken in isolation.
- Dev-profile launch only (`KAISOLA_NATIVE_BROKER_PROFILE=development npm run
  native:fast -- --refresh-helper`, pid 44356), stopped with `kill -TERM`. It ran
  ~2 minutes at **0.0% CPU**, RSS flat at 149 MiB, no crash report, and the only
  log line is a pre-existing `NSTableView` reentrancy warning unrelated to glass.
  Production `/Applications/Kaisola.app` was left running and untouched; no
  `defaults delete`.
- The pinned arm64 Node runtime was missing in this worktree and was fetched with
  `node scripts/download-native-node-runtime.cjs arm64`.
- Screenshots are TCC-blocked here, so **every appearance claim is arithmetic
  over rendered pixels**. Positioning is verified by computing the expected
  sample rect for a known window frame and asserting the sampler returns it, and
  separately by rendering a gradient wallpaper and reading the surface back.
- The Oklab implementation was validated against published reference values
  (pure blue L 0.452 C 0.313; pure green L 0.866 C 0.295) before any of it was
  trusted.

---

## 6. Concerns and what was deliberately not done

1. **The detail metric no longer compares across geometries.** Round 7's
   `localDetail` — high-pass at radius 32 on a 210×900 surface — measures a
   *fixed band of the surface*, which under pinning is a different band of the
   *wallpaper* than it was under stretching. Its own floor is significant:
   a surface with a flat still already measures 0.0016 dark / 0.0010 light, and
   the pinned sidebar measures 0.0021 / 0.0012 against a raw-wallpaper reference
   of 0.0029. Round 7's test still runs and still passes on the stretched render
   — it is a valid measurement of the *bake* — but it is no longer a measurement
   of what the user sees, and I did not redefine it to make my numbers look
   better. A future round should restate it as a **transfer ratio** (surface
   high-pass ÷ same-crop wallpaper high-pass), which is scale-fair.
2. **`desktopBlurPoints = 28` is the one constant chosen on judgement.** The
   floors hold from 14 pt to 56 pt (swept and measured), so it is a taste call
   about how much wallpaper should be recognisable, and it is a one-line change.
   Note that it deliberately **relaxes** the old "no locatable shape" rule to "no
   *legible* shape" — that rule is what made the surface a picture on a panel,
   and translucency is the ask now. On a wide canvas the wallpaper's large
   shapes are visible, which is what frosted glass does.
3. **One bake serves every display.** `screenPoints` is taken from the screen
   holding the key window and quantized to 128 pt. A window on a second display
   of a *different* width re-resolves (via a precise `didChangeScreen` check that
   compares quantized widths rather than hinting unconditionally), but two
   windows on two different-width displays at once share one bake and one of them
   gets a blur off by the width ratio. Baking per display would need the cache
   limit raised from 4.
4. **`saturation`, `luminanceShift` and `tailGain` are now vestigial.** They no
   longer drive the bake; they are the round-7 pipeline, retained because the
   hue-invariance test freezes and measures against it, and because
   `targetLuminance` / `tailHeadroom` still define the solve's targets. Their
   tests are still true statements about the frozen pipeline and are now
   documented as such. `stillSpreadCeiling` remains doubly vestigial (round 7
   already flagged it). A future round should delete the lot and re-derive
   `desktopTransmissionBand` against `tailHeadroomLightness`.
5. **Tile is approximated.** A surface spanning a tile boundary is mapped into
   whichever copy its centre falls in, so the seam is wrong at that one edge.
   Doing it properly needs a repeating layer rather than a `contentsRect`.
6. **Aspect-fit letterboxing shows wallpaper, not the fill colour.** A window
   over the margin of a "Fit to Screen" desktop gets the clamped edge of the
   picture instead of the desktop's fill colour. `desktopImageOptions` publishes
   `.fillColor`; honouring it is a small follow-up.
7. **Not visually confirmed.** As in every previous round, screenshots are
   TCC-blocked. The dev launch proves the new `NSView` and layer path do not
   crash and cost nothing at idle; it cannot prove the surface *looks* right.
