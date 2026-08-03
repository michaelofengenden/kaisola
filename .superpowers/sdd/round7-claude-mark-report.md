# Round 7 — Claude identity mark, made geometrically faithful

**Ask** (Michael): "we should fix the claude symbol to be more precise."

**Shipped**: yes. `QuietStarburstMark` is deleted; Claude's rail mark is now
`QuietClaudeBurst`, the official Anthropic asterisk traced from the reference
artwork and filled non-zero.

---

## 1. What was wrong

`QuietStarburstMark(rays: 12, innerRadius: 3.6, outerRadius: 9.6)` drew twelve
**uniform straight round-capped strokes** on an exact 30° pitch. The real mark
is none of those things: it is a filled asterisk of twelve **tapered petals of
unequal length** around a **solid hub**, each petal wide where it leaves the hub
and narrowing to a blunt point, and the petals sit at **irregular angles**. That
irregularity is the logo's character; even spokes read as a generic sparkle.

Numerically, against `assets/backlog/pasted-image-2.png` (the official mark,
1280², fill `#D97757`), both rasterized and cropped to their own ink box:

| | 16pt @8× | 32pt @8× | 1024px |
|---|---|---|---|
| **traced (shipped)** | **0.9380** | **0.9716** | **0.9886** |
| prior round's fitted 12-petal re-trace | — | — | 0.44 (recorded, not re-run) |
| 12 uniform spokes (what shipped v1.1.7–v1.1.9) | 0.3949 | 0.4051 | 0.3986 |
| *measurement floor* (the reference against itself) | 0.9575 | 0.9804 | 0.9917 |

The floor row is the point: at 1024px an exact copy of the artwork scores 0.9917
against the 1280² original, so the trace at 0.9886 is within **three
thousandths of exact**. Ink coverage of its own box is 0.3974 against the
reference's 0.3976.

The prior round was right to keep the spokes rather than ship its 0.44 fit — but
0.44 was a symptom of *fitting a parametric model*, not of the problem being
hard. The silhouette is directly traceable.

## 2. Route

Same route that took the OpenAI knot from 0.33 to 0.983, adapted to a mark that
has no published path data to transcribe:

1. Threshold the reference's own alpha at 50% → a single connected blob, **one
   closed contour, no holes** (`cv2.findContours`, RETR_CCOMP confirms zero
   interior contours — the mark has no counters).
2. Trace the contour (10,398 boundary pixels) and simplify with
   Ramer–Douglas–Peucker. Swept ε and took **ε = 1.5px at 1280²**, where the
   fidelity curve flattens: ε=0.75 gives 656 vertices for IoU 0.9887, ε=1.5
   gives **130 vertices for 0.9886**, ε=8 falls to 0.954.
3. Normalize exactly as the knot is: translate and uniformly scale so the
   **tight** bounding box centres in the shared 24-unit viewbox. That framing is
   also the artwork's own — the reference's ink reaches all four of its edges.
4. Emit as `M`/`L`/`Z` for the existing four-command `QuietVectorOutline`
   reader, at 2 decimals (verified lossless at these sizes: IoU identical to 3
   decimals). One subpath, 129 lines, 0 curves.

**Straight segments, not cubics** — deliberately. The mark's edges genuinely are
straight; fitting curves here would invent smoothness the artwork does not have.
This is the honest difference from the knot, whose source really is arcs.

Filled with the **non-zero winding rule**, so the taper and the solid centre are
real geometry rather than a stroke width imitating them.

Coral unchanged and re-confirmed against the reference: `#D97757` light /
`#E58A6D` dark. The reference's dominant fill is exactly `#D97757`.

## 3. Optical weight

Measured with CoreGraphics by rendering each mark into the 16pt slot at 8× and
summing coverage. This reproduces the prior round's published numbers exactly
(knot 0.308, spokes 0.314, knot-at-full-span 0.376), which is what makes the new
number comparable:

| mark | ink of the 16pt slot |
|---|---|
| `arrow.up.arrow.down` (ssh) | 0.162 |
| `terminal` (shell) | 0.208 |
| knot @ `span` 14.5/16 | **0.3084** |
| **traced burst @ `span` 14.2/16** | **0.3109** |
| old 12 spokes | 0.3137 |
| traced burst at full span | 0.395 |

A filled asterisk is a much heavier object than twelve hairlines, so left at
full span it would have made Claude's row the loudest thing in the rail.
`span = 14.2/16` puts it **between the knot's 0.308 and the 0.314 the old
stroked burst carried** — the rail's weight does not change, only its drawing.
`QuietIdentityMarkView.slot`, `symbolSize` (12.5) and `letterSize` (11.5) are
untouched, as are every other identity case and the `QuietIdentity` mapping. The
mark stays `accessibilityHidden`.

## 4. Tests

`QuietIdentityMarkView.starburstStroke` and the ray/radius constants are gone,
so the two tests that encoded them were rewritten, and four were added:

- **`testTheTwoAgentMarksAreInkedAlikeAndBothAreInsetToGetThere`** now *measures*
  both marks' ink in-process (new `QuietIdentityMarkInk` helper: rasterize the
  mark's own `Path` into the slot at 8× with CoreGraphics, fill non-zero,
  average coverage — deterministic, no display, no SF Symbol) and asserts they
  are level with each other, a step above the generic glyphs, and on their
  pinned values. The rule used to live in a comment quoting offline numbers.
- **`testClaudeBurstOutlineIsTheTracedOfficialSilhouette`** pins the segment
  counts (1 move / 129 lines / 0 curves / 1 close), the viewbox normalization,
  and the polygon's **signed shoelace area, −227.38 viewbox units** — a shape
  invariant no rasterizer can drift, and signed so a reversed winding fails too.
- **`testTheBurstHasTwelveUnequalPetalsAroundASolidHub`** measures the three
  properties the complaint was about, off the shipped geometry: exactly 12 petal
  tips (local maxima of radius), tip radii spanning 11.35–13.19 (unequal
  **length**), tip angles gapped 14.9°–40.4° against a uniform 30° (unequal
  **angle**), and a hub that is solid out to 2 viewbox units in all directions.
- **`testTheBurstIsNotTheEvenTwelveFoldSparkleItReplaced`** is the negative
  control that gives the above teeth: a 30° turn must disagree on >15% of the
  mark's area. Measured on the same sampling grid, the old spoke burst scores
  **0.000** — it is exactly 12-fold symmetric — and this outline scores
  **0.274**. That single pair of numbers is the whole change in one measurement.
- **`testClaudeBurstFitsItsSlotAndStaysCentred`** — the same containment,
  centring, squareness and scaling contract the knot is held to.

### One real trap found

SwiftUI's `Path.contains` answers **`false` for the interior point (12, 10)** of
this outline. It ray-casts horizontally, and the ray exits exactly through the
vertex at `19.66 10` — a textbook vertex degeneracy. It is not a near-boundary
case: the hub is solid to radius 2.47 there, and `contains` says *true* again at
2.4 units. The hub test therefore asks `CGPath.contains(_, using: .winding)`,
which is also the exact rule `QuietIdentityMarkView` fills the burst with, so
the assertion matches how the mark is actually drawn. Worth remembering for any
future geometry test in this file.

## 5. Verification

- `npm run native:test:focus -- QuietIdentityMarkTests` — green.
- `npm run native:test:changed -- --include-working-tree` — green.
- Full `xcodebuild` Debug build — **BUILD SUCCEEDED**, no compiler warnings
  (the only two log lines are the pre-existing AppIntents-metadata note and the
  broker-helper run-script note).
- Rendered offscreen at 16pt @1×/@2×/@3× with antialiasing to confirm it still
  reads at rail size; at @2× (the real Retina rail) the tapered petals and solid
  hub are unambiguous. No app was launched and no screenshot taken — TCC.

## 6. Concerns

- **@1× is soft.** At 16 physical pixels the petals are near the resolution
  limit and the mark reads as a coral blur rather than as an asterisk. It is
  still better than the spokes were at that size, and the app is Retina in
  practice, but a 1× display is the one place this mark is weaker than a
  hand-tuned hint would be.
- **The trace inherits the reference's own imperfections.** Anything that was an
  export artifact in `pasted-image-2.png` is now baked into the path. That is
  the correct trade at IoU 0.989 — but the reference, not a vendor SVG, is the
  source of truth here, so if Anthropic's official path data ever becomes
  available it is worth re-deriving.
- **130 vertices is a large literal.** Same order as the knot's, and the segment
  counts and shoelace area are pinned, so a corrupted paste fails loudly.
