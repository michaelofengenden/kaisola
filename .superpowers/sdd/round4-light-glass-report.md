# Round 4: light glass gets what dark got, and the ceiling that stops it

Worktree: `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a620884f74c982fa9`
Branch: `round4-light-glass`, branched from `e030365` (`backlog-integration` head).

| commit | subject |
| --- | --- |
| `8043409` | feat(glass): let light glass show far more of the wallpaper |

Files touched: `App/NativePreviewSettings.swift` and `KaisolaTests/NativePreviewSettingsTests.swift`
only. Nothing in `Acp/*`, `Features/*` or `Mesh/*`.

---

## The short version

> "light mode should also be translucent to wallpaper much better"

Light transmission **0.40 → 0.55** on the sidebar and **0.45 → 0.60** on the
workspace, bought the same way dark's was: by bounding the still's dynamic range
in the bake so the veil stops being the only thing holding the worst case down.
The desktop's colour arrives **39% stronger**; its light and shade arrive
unchanged. Worst-patch contrast holds at parity on the five aerial extremes and
**improves substantially** on four adversarial fixtures. Dark is bit-identical.

The 4.5:1 secondary floor is **not met in light and cannot be** — that is an
AppKit ceiling, not a veil, and §5 gives the measurement and the fix.

---

## 1. Light was not the safe surface it was assumed to be

Round 3 skipped light with a stated reason: "light has the headroom at 0.72,
light was never the complaint, and every light measurement in the file is
untouched." The first half of that turns out to be wrong, and the only way to
find out was to render it.

Extending round 3's harness to the light half and pointing it at four
**blur-invariant ramp fixtures** — a linear ramp passes a Gaussian untouched, so
unlike a photograph its whole range reaches the veil — the *shipped* light
surface measured:

| fixture (light workspace, worst patch) | primary | secondary |
| --- | --- | --- |
| `ramp-full` (black→white) | 7.91 : 1 | 3.27 : 1 |
| `ramp-aerial` (ramp on Michael's blue) | 9.07 : 1 | 3.43 : 1 |
| `ramp-diagonal` (aligned with the veil's own axis) | 8.40 : 1 | 3.34 : 1 |
| **`bright-with-shadow`** | **7.27 : 1** | **3.17 : 1** |

**7.27:1 against a 7.0 floor.** Light had *less* margin than dark ever had; it
simply had no test looking at it. Thinning the light veil without doing anything
else takes primary straight through the floor — at the base this round actually
ships (0.45/0.40) and no cap, the same four fixtures measure **6.09 / 7.47 /
6.55 / 5.36** primary and 2.95 / 3.20 / 3.04 / **2.79** secondary.

So the answer to "can light just get a thinner veil" is no, measurably, and the
round-3 lever is not an optimisation here but the precondition.

## 2. A second thing was wrong on its own terms

Round 2 found the dark bake was crushing 79.7% of the still to black, and noted
in passing that "light was wrong in the mirror direction and got away with it."
It did not get away with it. `luminanceShift` is additive, so lifting a dim
wallpaper onto light's 0.72 target pushes everything above `1 - shift` past
white:

Share of the baked still pinned at 255, BEFORE → AFTER:

| still | any channel | all three (flat white) |
| --- | --- | --- |
| widest aerial on this Mac (`AB7FC3C3`) | **17.3% → 0.0%** | 0.0% → 0.0% |
| `ramp-full` fixture | 19.1% → **0.0%** | **19.1% → 0.0%** |
| `ramp-diagonal` fixture | 7.5% → **0.0%** | **7.5% → 0.0%** |
| `ramp-aerial` fixture | 28.2% → **4.5%** | 0.0% → 0.0% |
| most saturated aerial (`27A37B0F`) | 32.0% → 32.0% | 0.0% → 0.0% |

A fifth of a still pinned at 255 is range the glass cannot show *however thin the
veil gets*, and every flat-white pixel is chroma destroyed as well as structure.

(One clip survives and the cap cannot reach it: the most saturated aerial
(`27A37B0F`, off-neutral 0.824) pins its **blue channel** over 32% of the frame.
That is chroma clipping, not luminance clipping — its luma spread is small, so a
luminance cap never engages. Listed as follow-up 2.)

## 3. What shipped

| constant | before | after |
| --- | --- | --- |
| `GlassBackdropWash.sidebar(light)` | 0.66 / **0.60** / 0.56 | 0.51 / **0.45** / 0.41 |
| `GlassBackdropWash.workspace(light)` | 0.61 / **0.55** / 0.51 | 0.46 / **0.40** / 0.36 |
| `DesktopBackdropRenderer.lightStillSpreadCeiling` | — | **0.26** |
| `desktopTransmissionBand(light).ceiling` | 0.50 | **0.65** |
| `rangeGain(spread:isDark:)` | dark only | **both**, via `stillSpreadCeiling(isDark:)` |
| sidebar transmission | 0.40 | **0.55** |
| workspace transmission | 0.45 | **0.60** |
| every dark constant, `targetLuminance`, `blurRadius`, `saturationCeiling`, `GlassWarmth`, `liveTint` | — | unchanged |

`increasedContrastOverlay` is derived from the base and re-solved itself:
light's two overlays moved 0.500/0.556 → 0.636/0.667, both still strictly inside
the 0.80 ceiling, so the accessibility floor is still met by arithmetic rather
than by a clamp. No constant had to be touched for that, which is what deriving
it was for.

**Live gains the same factor for free.** The sidebar's live tint multiplies with
the veil, so light live transmission goes `(1-0.26)·(1-0.60) = 0.296` →
`(1-0.26)·(1-0.45) = 0.407`, **+38%** — the same factor the painted source
gained. The light *tint* is deliberately not cut the way dark's was: it exists
because AppKit's light materials are near-white and eat the desktop's hue, so
cutting it would remove the layer carrying the colour.

## 4. Before / after, rendered and measured

Michael's actual desktop (the Lake Tahoe aerial), **light sidebar** at 210×900.
"Worst patch" is the mean of the darkest 2% band — in light the darkest pixel is
where black text is hardest to read, the mirror of dark's brightest. Contrast
uses the label alphas rounds 2 and 3 published with (black @0.85 primary, @0.50
secondary in light) so all three reports are directly comparable; AppKit's exact
values are 0.8471 and 0.4980, which read about 0.02 lower on secondary — §5 uses
the exact ones.

| | BEFORE | AFTER |
| --- | --- | --- |
| veil opacities | 0.66 / 0.60 / 0.56 | **0.51 / 0.45 / 0.41** |
| desktop transmission | 0.40 | **0.55** |
| composite rgb | 0.836 / 0.898 / 0.924 | **0.774 / 0.860 / 0.897** |
| mean luminance | 0.8865 | **0.8447** |
| luminance spread p5..p95 | 0.0805 | **0.0803** |
| gradient top→bottom | 0.0385 | **0.0378** |
| off-neutral | 0.057 | **0.083** |
| absolute chroma | 0.0501 | **0.0696** (+39%) |
| still clipped to white | 0.0% | **0.0%** |
| primary contrast | 12.32:1 | **11.35:1** (worst patch **9.48**) |
| secondary contrast | 3.77:1 | **3.68:1** (worst patch **3.48**) |

Light **workspace**: 0.814/0.884/0.915 → **0.752/0.847/0.888**, spread 0.0909 →
**0.0879**, chroma 0.0571 → **0.0767**, primary **11.01:1** (worst **9.05**),
secondary **3.65:1** (worst **3.43**).

### Across the five extremes round 3 used — the contract set

Light, worst patch, **workspace** (always the deeper surface, so always the
binding one):

| wallpaper (luma, off-neutral) | BEFORE P / S | AFTER P / S | chroma |
| --- | --- | --- | --- |
| Lake Tahoe — Michael's (0.438, 0.399) | 9.80 / 3.52 | **9.05 / 3.43** | 0.057 → **0.077** |
| darkest (0.076, 0.130) | 11.74 / 3.72 | **10.70 / 3.62** | 0.002 → **0.003** |
| brightest (0.792, 0.400) | 11.39 / 3.69 | **10.25 / 3.57** | 0.093 → **0.124** |
| most saturated (0.265, 0.824) | 11.00 / 3.65 | **9.83 / 3.52** | 0.087 → **0.117** |
| most neutral, widest range (0.435, 0.015) | **9.08 / 3.43** | **9.34 / 3.46** | 0.006 → **0.007** |
| **minimum over all five** | **9.08 / 3.43** | **9.05 / 3.43** | |

Primary keeps 2 of margin over the 7.0 floor. Secondary lands **exactly on its
pre-change figure** — that is the constraint that chose 0.45, see §5.

Note the last row: the wallpaper whose *range* was the problem is the one that
**improves**, exactly the asymmetry round 3 described for dark. The cap removes
more of the worst case than the veil it buys out.

### Across the four adversarial fixtures — where it really improves

| fixture (light workspace, worst patch) | BEFORE P / S | AFTER P / S |
| --- | --- | --- |
| `ramp-full` | 7.91 / 3.27 | **9.42 / 3.47** |
| `ramp-aerial` | 9.07 / 3.43 | **9.41 / 3.47** |
| `ramp-diagonal` | 8.40 / 3.34 | **9.22 / 3.45** |
| `bright-with-shadow` | **7.27 / 3.17** | **8.88 / 3.40** |

Worst case anywhere: primary **7.27 → 8.88** (+22%), secondary **3.17 → 3.40**
(+7%). The surface got a third more transparent *and* better on its worst
wallpaper at the same time.

### Dark: bit-identical

Rendered before and after on all nine wallpapers, both surfaces:

| | BEFORE | AFTER |
| --- | --- | --- |
| composite rgb (tahoe sidebar) | 0.103 / 0.129 / 0.139 | 0.103 / 0.129 / 0.139 |
| mean luminance | 0.1240 | 0.1240 |
| spread / gradient / off-neutral | 0.0950 / 0.0278 / 0.165 | 0.0950 / 0.0278 / 0.165 |
| worst patch, five aerials | P 9.17 / S 4.86 | P 9.17 / S 4.86 |
| worst patch, adversarial | P 8.10 / S 4.44 | P 8.10 / S 4.44 |

Every figure is identical to three or four decimals, which is the expected
result: `targetLuminance` did **not** move (see §6), so `GlassWarmth`'s
derivation, the dark saturation ceiling and the dark veil are all untouched.

## 5. The floor **did** limit this, and here are the numbers

### Primary (≥7:1): met everywhere, with margin

9.05:1 worst patch on the five aerials, 8.88:1 on the adversarial set. This was
the binding floor *before* the change (7.27:1) and is no longer close.

### Secondary (≥4.5:1): not met, cannot be, and it is not the veil's fault

This is a hard AppKit ceiling and the test now proves it rather than asserting
it. Read from the platform:

```
aqua     : primary rgb 0/0/0  α=0.8471   secondary rgb 0/0/0  α=0.4980
darkAqua : primary rgb 1/1/1  α=0.8471   secondary rgb 1/1/1  α=0.5490
```

Black at α 0.498 over **pure white** — the brightest background that can exist —
is **3.98:1**. No light surface in any Mac app reaches 4.5 with
`secondaryLabelColor`. Kaisola's light glass was at **3.43:1** worst patch
before this round and is at **3.43:1** after it.

**Where the limit actually bit.** Secondary is what chose 0.45 rather than
something thinner, holding "do not make it worse" as the constraint:

| light base (sidebar/workspace) | still cap | worst-patch S, five aerials |
| --- | --- | --- |
| 0.60 / 0.55 (shipped) | none | 3.43 : 1 ← the figure to hold |
| 0.45 / 0.40 | none | **3.20 : 1** ✗ — the veil alone regresses it |
| **0.45 / 0.40** | **0.26** | **3.43 : 1** ✓ shipped |
| 0.44 / 0.39 | 0.26 | 3.42 : 1 ✗ |
| 0.40 / 0.35 | 0.26 | 3.37 : 1 ✗ |
| 0.40 / 0.35 | 0.20 | 3.43 : 1 ✓ — but spread falls 0.0805 → 0.0694 |

So 0.45 with cap 0.26 is the point where transmission is maximised subject to
*both* "secondary does not regress" and "luminance structure does not regress".
Pushing to 0.40 is available only by tightening the cap until the surface loses
14% of its structure to buy 13% more chroma — a bad trade, and the reason the
number is 0.45.

**What would lift it: a custom secondary ink.** Measured on the shipped new
surface, worst patch, at AppKit's *exact* α rather than the round 0.50 the
comparison tables above use (which is why these read 0.02 lower):

| ink | worst patch, five aerials | worst patch, adversarial |
| --- | --- | --- |
| AppKit `secondaryLabelColor`, black α 0.498 | 3.41 : 1 | 3.38 : 1 |
| black α 0.55 | 3.97 : 1 | 3.94 : 1 |
| black α 0.58 | 4.34 : 1 | 4.30 : 1 |
| **black α 0.60** | **4.60 : 1** ✓ | **4.56 : 1** ✓ |
| black α 0.65 | 5.34 : 1 | 5.28 : 1 |

The shipped test measures the same thing independently, through
`DesktopBackdropRenderer.render` and the real composite on its own ramp fixture:
**3.43:1 at α 0.498, 4.66:1 at α 0.60.**

**Black at α 0.60 clears 4.5:1 on the worst patch of the worst fixture**, and
would do so with the veil thinner still. It is not shipped this round because
the app has **207 `.secondary` call sites** across 30 files, all of them in
`Features/*`, `Acp/*` and `Mesh/*` — out of scope — and there is no in-scope
root view to hang a `.foregroundStyle(primary, secondary, tertiary)` hierarchy
override on. A glass constant that silently restyles every label in the app is a
change to make on purpose, not a side effect of a veil retune. The number is now
pinned by `testACustomSecondaryInkWouldClearTheFloorOnLightGlass` so it cannot
go stale.

The text-run scrim was considered and rejected for the same reason round 3
rejected it, plus one more: a scrim would have to be *lighter* than the surface
in light mode, which is a white patch behind every label — visible, and worse
looking than the thing it fixes.

## 6. Two levers deliberately not pulled

**Raising `targetLuminance(light)` above 0.72.** This looked like the best move
in the sweep — at target 0.80 the surface holds today's brightness at 60%
transmission, contrast *rises*, and spread rises 17%. It was rejected on
measurement: raising the target multiplies the highlight clipping the cap exists
to remove. On the most saturated aerial the still's blue channel goes from 32%
pinned at 255 to **95.1%** — the surface loses the ability to render that
wallpaper's colour at all, which is precisely what the change is supposed to
deliver. Holding 0.72 also keeps `GlassWarmth.opacity(isDark:)` — which is
derived as `0.04 · target(isDark) / target(light)` — from silently moving dark's
warmth by −10%, a latent coupling worth knowing about (follow-up 3).

**Cutting the light live tint.** Dark's was halved in round 3. Light's is the
layer that carries the desktop's hue through AppKit's near-white materials, so
cutting it would take colour away in the appearance being asked to show more of
it. The veil change lifts live light by +38% on its own.

## 7. Verification

- `npm run native:fast:build` — clean, no warnings, no errors (also after
  deleting the object cache, so this is a real recompile of both files).
- `npm run native:test:focus -- NativePreviewSettingsTests` — green.
- `npm run native:test:changed -- --include-working-tree` — green; it selected
  `NativePreviewSettingsTests` for both changed files and passed.
- **The numbers in this report are rendered, not modelled.** Round 3's standalone
  harness was extended with the light-side levers and re-validated against round
  3's published figures at the shipped constants *before* any light sweep was
  trusted — it reproduces dark's `0.103/0.129/0.139`, spread `0.0950`, gradient
  `0.0278`, off-neutral `0.165`, P `12.09` (band `10.85`), S `5.84` (band `5.45`)
  exactly. The shipped tests then render through `DesktopBackdropRenderer.render`
  and the real veil composite themselves.
- New tests, all rendering real pixels:
  * `testLightGlassStaysLegibleOnTheWorstPatchOfEveryWallpaper` — six fixtures ×
    two surfaces; primary ≥7 and secondary ≥3.4, and it *proves* the 3.98
    AppKit ceiling by reading `NSColor.secondaryLabelColor` out of the aqua
    appearance and asserting that the ceiling is below 4.5. If Apple ever raises
    the alpha, the test says so and asks to be tightened.
  * `testTheLightVeilLetsThroughMoreWallpaperThanItUsedTo` — chroma +25% minimum
    and spread not traded away.
  * `testTheLightBakeStopsBlowingTheWallpapersHighlightsToWhite` — the 19.1%
    white-out, held at ≤1%.
  * `testACustomSecondaryInkWouldClearTheFloorOnLightGlass` — keeps the
    follow-up's number live.
  * `testTheRangeCapOnlyEverRemovesRangeAndTheOffsetIsSolvedAfterIt` and
    `testTheDarkBakeBoundsTheWallpapersRangeAndNotOnlyItsMean` now run over both
    appearances instead of dark only.
- One pre-existing test needed its bound moved and the reason is recorded in it:
  `testFrostCompositeLandsOnTheSameGroundForEveryWallpaper` asserted the light
  composite stays above 0.85, and at 0.45 coverage it is 0.846. That bound was an
  undocumented "Safari sidebar reference" round number standing in for
  legibility; legibility is now held directly on rendered pixels by the
  worst-patch test, so the bound moved to 0.83 plus a derived assertion that the
  composite stays brighter than the still it frosts. The **invariance** the test
  exists for — spread < 0.001 across every possible wallpaper mean — is untouched.
- Dev-profile launch only (`KAISOLA_NATIVE_BROKER_PROFILE=development npm run
  native:fast -- --refresh-helper`, pid 54835), stopped with `kill -TERM`. Ran
  50 s at **0.0% CPU**, RSS flat at 206 MiB, **zero** error lines in the app log,
  and AX confirms one real window (`Kaisola @(118, 98) 1518×885`). The production
  app (pid 33218) was running throughout and was never touched; no
  `defaults delete`, no writes to `/Applications/Kaisola.app`.
- The pinned arm64 Node runtime was missing in this worktree and was fetched with
  `node scripts/download-native-node-runtime.cjs arm64`.
- No screenshots: `screencapture` is TCC-blocked here, so every appearance claim
  is arithmetic over rendered pixels.

## Concerns / follow-ups

1. **Light's worst-patch secondary is 3.43:1 and the 4.5 floor is unreachable
   with the system semantic.** This is unchanged by this round *by design* — it
   is what chose the veil — but it is the one place the stated floor is not met,
   and it is now the binding constraint on any further light translucency. The
   fix is a custom ink at α 0.60 (measured 4.66:1); it needs a pass over
   `Features/*`, `Acp/*` and `Mesh/*`, or a single
   `.foregroundStyle(.primary, customSecondary, customTertiary)` at the root
   shell. **With it, light could go to roughly base 0.30 on primary alone.**
2. **A saturated wallpaper still pins one channel.** `27A37B0F` clips its blue
   channel over 32% of the still, before and after. The range cap is on
   *luminance* and never engages, because that wallpaper's luma spread is small.
   The lever would be a per-channel bound in the bake; not attempted, because it
   is a different (and larger) change from the one asked for.
3. **`GlassWarmth.opacity(isDark:)` couples the two appearances.** It is
   `0.04 · target(isDark) / target(light)`, so moving the *light* target silently
   moves *dark's* warmth. Nothing moved it this round, and that is partly why
   §6 declined to. If a later pass wants to move `targetLuminance(light)`, give
   the warmth its own declared reference luminance first.
4. **Light's composite is 0.845 rather than 0.887**, which is the ask arriving
   rather than a defect — but it is a visible change to how bright the light
   chrome reads, and it is the kind of thing worth seeing before it ships. If
   Michael wants today's brightness *and* today's transmission, §6 says how
   (raise the target) and what it costs (chroma clipping).
5. **`node_modules` was symlinked to the main checkout** so the worktree could
   package the broker helper for the dev launch. It has been removed again; the
   tree is clean.
