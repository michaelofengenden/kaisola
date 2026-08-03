# Round 7: glass gets the wallpaper's texture, not only its colour

Worktree: `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a89a5ea2674b773aa`
Branch: `round7-glass-detail`, branched from `448ee0f` (`backlog-integration` head).

Files touched: `App/NativePreviewSettings.swift` and `KaisolaTests/NativePreviewSettingsTests.swift`
only.

---

## The short version

> "it seems glass wallpaper picks up the color of the wallpaper. glass wallpaper
> should pick up the **vibe** of the wallpaper as well like **washed details** or
> whatnot if possible."

Local detail in the surface is **2.0× higher** in both appearances, and the
contrast floors got **better**, not worse: dark worst-patch secondary 4.52 → 4.55
(floor 4.5), light 3.43 → 3.44 (its AppKit-pinned baseline). Zero clipping, both
appearances, every fixture. Both translucency figures are untouched (dark 0.66,
light 0.55) — no veil constant moved this round.

The lever is not the blur. It is that the legibility cap moved from a **proxy**
(p5..p95 of a 16×16 box of the source) to **the quantity the floors are actually
measured on** (the worst patch). Once the cap is exact, the blur can come down
three-fold and the floors *improve* while doing it.

---

## 1. The surface was, measurably, a colour field

Rendering the shipped pipeline over this Mac's real aerial library and the ramp
fixtures, one number says the whole thing:

| fixture (dark sidebar) | luminance spread | vertical gradient |
| --- | --- | --- |
| `ramp:aerial` | 0.1838 | 0.1828 |
| `ramp:bright` | 0.1843 | 0.1855 |
| `ramp:neutral-wide` | 0.1807 | 0.1817 |
| `ramp:adversarial` | 0.1807 | 0.1819 |

`spread` and `gradient` agree to three decimals on every fixture. **All** of the
surface's luminance range was one smooth top-to-bottom ramp and none of it was
the picture. That identity is what "picks up the colour but not the vibe" is, and
no metric in the file could see it — `luminanceSpread`, `chroma`, composite rgb
and transmission are all satisfied by a single gradient.

Two causes, and only one of them is the blur:

1. **Blur.** 28 px on a 176 px still is **15.9% of the frame** — about six
   distinguishable masses across an entire wallpaper.
2. **The cap crushed what was left.** `rangeGain` compressed everything by one
   scalar, so whatever mid-frequency structure survived the blur was compressed
   in step with the global gradient.

## 2. Why lowering the blur alone could not work — and what did

The brief's warning is correct and the sweep confirms it. Under a p5..p95 cap,
dropping the relative blur from 15.9% to 6% takes dark worst-patch secondary to
**4.29** — below the 4.5 floor. Adding an unsharp add-back on top makes it worse
(4.06 at share 0.45). Budgeting the detail band explicitly against the same
p5..p95 ceiling still lands at **4.23**.

All three fail for the same reason: **p5..p95 says nothing about the tail, and
the tail is the entire floor.** The worst patch is the mean of the brightest 2%
of the surface in dark, the darkest 2% in light. A percentile band by
construction excludes it.

Measured on the shipped bake, the still's tail excursion `|tail − mean|` ranged
from **0.027 to 0.151** while every one of those stills sat comfortably inside
the 0.30 p5..p95 ceiling — and the excursion maps onto worst-patch contrast
essentially perfectly:

| still tail excursion | 0.027 | 0.081 | 0.128 | 0.138 | 0.151 |
| --- | --- | --- | --- | --- | --- |
| dark worst-patch secondary | 5.59 | 5.15 | 4.85 | 4.76 | **4.52** |

The worst wallpaper on the machine (`A92E4A3F`, box spread 0.856) sat at
**4.52:1 against a 4.5 floor** — a margin of 0.02 — and nothing in the bake knew,
because the bake was looking at a different statistic.

**So cap the tail.** The tone map is affine, `out = (in − mean)·gain + target`,
so `out(tail) − target = (tail − mean)·gain`, and bounding the left-hand side is
one division:

```swift
gain = min(1, tailHeadroom / |tail − mean|)
```

The headrooms are the shipped pipeline's own worst excursions taken a step under
— **0.145 dark, 0.124 light** — so the worst case cannot be worse than what
already shipped, and every *other* wallpaper is now bounded by the same number
instead of being left wherever the picture happened to put it.

That is the trade in one sentence: **the cap gets tighter and exact, and the
slack it buys is spent on structure.**

## 3. What shipped

| constant | before | after |
| --- | --- | --- |
| `stillWidth` | 176 | **448** |
| blur | `blurRadius = 28` (15.9% of frame) | `blurFraction = 0.05` → radius 22.4 |
| cap | `rangeGain(spread:)`, p5..p95 of a 16×16 box of the **source** | `tailGain(excursion:)`, worst patch of the **baked structure** |
| — | `darkStillSpreadCeiling` 0.30 / `light` 0.26 (drove the gain) | retained as the *declared* bound the veil ceilings are priced against |
| new | — | `darkTailHeadroom` 0.145 / `lightTailHeadroom` 0.124 |
| new | — | `localContrastIntensity` 0.6, `localContrastRadiusFactor` 1.4 |
| new | — | `probeSide` 96 |
| bake order | solve blind from the source, then blur | **blur → local-contrast add-back → render → measure → tone-map** |
| every veil constant, `targetLuminance`, `saturationCeiling`, `GlassWarmth`, `liveTint` | — | unchanged |

Three pieces, and each one only works because of the others:

- **`blurFraction` 0.05.** Roughly twenty masses across the frame instead of six:
  a horizon, a shoreline, a cloud bank as soft washes. The old note's requirement
  — "no locatable shape" — is kept; what the round found is that "no locatable
  shape" and "no shape at all" are two different radii and the bake was on the
  second one.
- **`stillWidth` 448.** Not a detail lever — the metric is *flat* in resolution,
  because what the eye sees is set by the blur as a fraction of the frame. It is
  a **fidelity** lever, and the measurement is unambiguous. Baking each aerial
  extreme at several widths and correlating against a 1024 px reference on a
  common grid: 176 → **0.841**, 256 → 0.861, 384 → 0.910, 448 → **0.932**, 640 →
  0.975. At 176 px **16% of the structure the surface shows is not the
  wallpaper's** — it is decode aliasing, harmless while the blur hid it and
  promoted to visible texture the moment it did not.
- **The local-contrast add-back.** A `CIUnsharpMask` over the blurred still adds
  a **zero-mean** mid-frequency residual, so it changes how the still's range is
  spent without changing the mean — and what it does to the extremes is measured
  on the very next line and paid for by the gain. It cannot smuggle range past
  the cap. 0.6 rather than more: at 1.0 dark's worst patch stops improving, and
  past ~1.8 the upscale to the surface rings and the worst patch falls to 4.32,
  which the still-side cap cannot see because the overshoot is created by the
  interpolation.

**Measure, don't guess.** The bake now renders its own structure once, measures
its mean and worst patch on a 96×96 reduction, and solves the tone map against
those. Previously every constant was stated about a picture the veil never saw.

## 4. The detail metric

**RMS of the high-pass residual of the composited surface's luminance** —
subtract a heavily blurred copy (box-blur radius 32, three passes ≈ Gaussian) and
take the standard deviation of what is left. The veil's full-surface gradient
contributes nothing; the wallpaper's shapes contribute everything. It is the one
number that separates *tint* from *texture*, and it is now `localDetail(_:)` in
the test file.

Read on the **sidebar**: at 210 pt wide the still is *downscaled* into it, so its
mid-frequency band lands inside the high-pass. The workspace upscales the same
still 2×, moving that band below the measurement — the texture is there, roughly
an order of magnitude softer, which is what a wide canvas showing a stretched
still physically is. (See concerns.)

### The five extremes of this Mac's aerial library — real photographs

Dark sidebar, detail before → after:

| wallpaper | detail | | worst P | worst S |
| --- | --- | --- | --- | --- |
| Lake Tahoe (Michael's own) | 0.00488 → **0.00933** | 1.91× | 10.85 → 10.02 | 5.45 → 5.17 |
| darkest (`CF6347E2`) | 0.00232 → **0.00324** | 1.39× | 11.54 → 11.30 | 5.68 → 5.60 |
| brightest (`DD7690D7`) | 0.00438 → **0.01926** | 4.40× | 10.06 → 9.30 | 5.18 → 4.91 |
| most saturated (`27A37B0F`) | 0.00448 → **0.00926** | 2.07× | 10.96 → 9.95 | 5.49 → 5.14 |
| most neutral (`AB7FC3C3`) | 0.00252 → **0.00604** | 2.40× | 9.17 → 8.57 | 4.86 → 4.63 |
| widest range (`A92E4A3F`) | 0.00385 → **0.00462** | 1.20× | 8.29 → **8.47** | **4.52 → 4.59** |
| most detailed (`25A6CFB2`) | 0.00719 → **0.01802** | 2.51× | 9.83 → 8.56 | 5.10 → 4.62 |
| **mean / worst** | **0.00307 → 0.00631** | **2.06×** | **8.29 → 8.47** | **4.52 → 4.59** |

Light sidebar: **0.00211 → 0.00420 (1.99×)**, worst P 9.05 → **9.16**, worst S
3.43 → **3.44**.

Note the row that matters most: the wallpaper whose range was the problem
(`A92E4A3F`) is the one whose contrast **improves** — 4.52 → 4.59 — because the
tail cap removes exactly the excursion the p5..p95 proxy was blind to.

### Structured fixtures, in the test suite

| fixture | dark | light |
| --- | --- | --- |
| aerial | 0.00265 → 0.00525 (1.98×) | 0.00180 → 0.00408 (2.26×) |
| dim | 0.00181 → 0.00228 (1.26×) | 0.00112 → 0.00154 (1.38×) |
| bright | 0.00248 → 0.00607 (2.45×) | 0.00156 → 0.00315 (2.02×) |
| saturated | 0.00229 → 0.00469 (2.04×) | 0.00154 → 0.00333 (2.17×) |
| neutral-wide | 0.00276 → 0.00532 (1.93×) | 0.00182 → 0.00411 (2.25×) |
| **total** | | **0.01983 → 0.03982 (2.01×)** |

## 5. Contrast floors, measured on the worst patch

Over the same six ramp fixtures the prior rounds used, both surfaces, rendered:

| | dark | light |
| --- | --- | --- |
| worst primary (floor 7.0) | 8.29 → **8.38** | 9.05 → **9.16** |
| worst secondary | 4.52 → **4.55** (floor 4.5) | 3.43 → **3.44** (AppKit baseline) |
| %pure black | 0.0 → **0.0** | 0.0 → **0.0** |
| %pure white | 0.0 → **0.0** | 0.0 → **0.0** |

Binding surfaces are unchanged: dark's worst case is the **sidebar** (thinner
veil), light's is the **workspace** (deeper veil). Light's secondary still cannot
reach 4.5 and still is not the veil's fault — `secondaryLabelColor` in Aqua is
black at α 0.498, which is 3.98:1 over *pure white*; the existing test proves
that from AppKit rather than asserting it, and a custom α 0.60 ink still measures
4.64:1 (follow-up, unchanged from round 4).

## 6. Bake cost

Off the main thread (`Task.detached(priority: .utility)`) and cached per
wallpaper — no per-frame work was added, and the render path is untouched.

Measured over the seven real aerials, 30 iterations each: **17–24 ms → 23–25 ms**,
i.e. **+1.5 to +6.5 ms, ≈ +5 ms typical**. Two thirds is the larger thumbnail
decode; the rest is the second `createCGImage` the measurement needs.

## 7. Tests

- `testGlassCarriesTheWallpapersTextureAndNotOnlyItsColour` — **new**, and the
  guard the round exists for. It bakes five structured wallpapers through the
  real `DesktopBackdropRenderer.render(key:)`, renders the shipped glass stack,
  and compares against `bakeAsShippedBeforeRound7` — a frozen reimplementation of
  the pre-round-7 bake, kept the same way the veil tests keep the previous veil's
  opacities. Asserts detail never regresses per wallpaper, the aggregate is
  ≥ 1.5×, the contrast floors hold **on the same renders**, and detail is > 2% of
  the surface's own range (the "it is a colour field again" check).
- `testWallpaperBakeBlursPastAnyRecognisableShapeButNotPastEveryShape` — the old
  version asserted `blurRadius >= 24` and passed for exactly the wrong reason: a
  one-sided floor cannot see a bake tuned until no structure survives. Now
  two-sided, stated as a fraction of the frame, plus a pixels-per-feature floor
  so the texture cannot be decode aliasing.
- `testTheRangeCapOnlyEverRemovesRangeAndTheOffsetIsSolvedAfterIt` — restated on
  `tailGain`, keeping every property the spread cap had to hold (never a boost,
  monotone, no divide-by-zero, offset solved after the gain) and adding the one
  the old cap could not make: the worst patch lands *exactly* on the headroom.

`npm run native:test:focus -- NativePreviewSettingsTests` — **113 tests, 0
failures**. `npm run native:test:changed -- --include-working-tree` — passed.
Build warning-clean.

## 8. Concerns and what was deliberately not done

1. **The workspace gains least.** Every glass surface draws the *same* still
   stretched to its own shape, so the 210 pt sidebar downscales it while the wide
   canvas upscales it 2× — the texture is genuinely softer on the canvas
   (1.0–1.4× rather than 1.2–4.4×). At the shipped blur the two still read as one
   material; at a sharper blur they would start to read as a seam, which is part
   of why 5% and not 2.5%. Fixing it properly means baking per-surface aspect,
   which is a second cached still and a larger change than this round.
2. **`dim` barely moves** (1.26×/1.38×). Correct rather than a shortfall — a
   near-black wallpaper has almost no mid-frequency contrast to carry, and the
   cap never manufactures contrast a desktop does not have.
3. **Veil local variation: rejected.** Considered per the brief. It would be a
   fixed, wallpaper-independent pattern — noise on the glass rather than the
   desktop showing through — and now that real wallpaper texture reaches the
   surface it would only dilute it. Not implemented.
4. **`stillSpreadCeiling` is now vestigial as a gain input.** It is retained and
   still asserted because `desktopTransmissionBand` prices both veil ceilings
   against it, but it no longer drives anything. A future round should either
   re-derive those ceilings against `tailHeadroom` or delete the constants.
5. **Not visually confirmed.** Screenshots are TCC-blocked in this environment,
   so every claim here is a rendered measurement, not an eyeball. The blur
   fraction is the one constant chosen on judgement rather than by measurement —
   the floors hold from 2.5% to 16%, so 5% is a taste call about how much
   wallpaper should be recognisable, and it is a one-line change if Michael wants
   it softer or sharper.
