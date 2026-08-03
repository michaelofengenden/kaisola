# Round 3: the glass follows the wallpaper, and dark gets out of its own way

Worktree: `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a5d0e07a8576da74a`
Branch: `round3-glass`, branched from `c273c3c` (`backlog-integration` head).

| commit | subject |
| --- | --- |
| `803f536` | feat(glass): follow the desktop when the wallpaper itself changes |
| `4f16628` | feat(glass): let dark glass show far more of the wallpaper |

Files touched: `App/NativePreviewSettings.swift` and `KaisolaTests/NativePreviewSettingsTests.swift`
only. Nothing in `Acp/*`, `Features/Sessions/*` or `Features/Workspace/*`.

---

## 1. "The glass should update when/if the wallpaper updates as well"

### What was actually missing

Every hint that made the backdrop re-resolve was about the **window**: a Space
switch, an app activation, a screen reconfiguration, a new key window. None of
them is a wallpaper event. A user who changes their desktop picture while
Kaisola stays frontmost — or a rotating/dynamic desktop that advances while they
work — moves nothing the provider was listening to, so the glass keeps painting
the previous wallpaper until the app happens to lose and regain focus.

The `(path, mtime, isDark)` cache key was already correct; the gap was purely
that nothing re-read the desktop to *notice* the key had moved.

### Three signals, one door

Everything funnels through `noteDesktopSignal() -> invalidate()`, so the
coalescing contract is unchanged: a burst still arms exactly one deferred
resolve, and the generation counter still drops a bake that finishes after a
newer one started. **No per-hint disk work was added** — the hints are now
cheaper than before, because a watch tick that finds nothing does not touch the
provider at all.

**a. `com.apple.desktop`, the distributed notification — a fast path only.**

`WallpaperAgent` links `NSDistributedNotificationCenter` (`nm -u`) and carries
the string `com.apple.desktop` (`strings`), so the long-standing notification is
very probably still posted on macOS 26. That is inference, not measurement:
confirming it needs a real desktop change, and changing Michael's desktop is not
something I am willing to do — his desktop is a rotating aerial category and
there is no scripted way to put it back. So it is observed with `object: nil`
(the agent's object string is undocumented and has moved between releases) and
**nothing depends on it**.

**b. A bounded watch — the guarantee.**

| tier | reads | measured cost | cadence |
| --- | --- | --- | --- |
| shallow | 3 `stat`s: the painted file, `Store/Index.plist`, `aerials/thumbnails/` | **0.045 ms** | every **5 s**, active only |
| deep | the above + `NSWorkspace.desktopImageURL(for:)` | **4.1 ms**, main actor | every **30 s** |

Both numbers were measured on this machine (200 iterations each). The split
exists because `desktopImageURL` is 90× the cost of the three `stat`s **and**
has to run on the main actor (`NSScreen` is not `Sendable`) — 4 ms every five
seconds is a dropped frame every five seconds. The `stat`s run detached.

The timer carries a 2.5 s tolerance so its wakeups coalesce, is armed only once
a glass surface has actually asked for a backdrop, and is **suspended entirely**
when the app is not active — `didBecomeActive` already forces a resolve on the
way back in, so an unattended Kaisola costs literally nothing.

Worst-case latency while the user is looking at the window: **5 s** (0 s if the
notification fires). For a rotating picture folder whose store is not rewritten:
30 s.

**c. `NSWorkspace.didWakeNotification`**, because "change picture: on wake" is a
real macOS option.

### Rotating and dynamic desktops

Michael's own desktop resolves through the aerial ladder
(`desktopImageURL` returns the `DefaultDesktop.heic` sentinel on all three of his
screens; `Store/Index.plist` names category `A33A55D9-…`, whose representative
still is `4C108785-….png` — Lake Tahoe).

I looked for a published pointer at the clip *currently playing* in a rotating
category and there is none: the store records the category, not the member, and
`aerials/videos/` carries no index. So the representative still stays
deterministic (the cache key depends on it — a non-deterministic pick is a
wallpaper that changes when you restart), and what the signature tracks instead
is **the category and the set of stills it picks from**: `Index.plist`'s mtime
moves when the category changes, and the thumbnails directory's mtime moves when
macOS finishes downloading another member — which is the only way the
representative can change.

### Proof that the invalidation path fires — method stated honestly

Three tests, one of them with a negative control:

1. **`testAWallpaperChangedInPlaceMovesTheSignatureThatWatchesForIt`** — a real
   fixture directory on disk, exercising all four change shapes: a picture
   replaced at the same path, a different aerial category, a newly cached aerial
   still, and a rotating picture folder advancing (deep probe only).
2. **`testAWatchTickTurnsAStoreChangeIntoAnInvalidation`** — drives the shipped
   `probeDesktop` end to end against a fixture store: first tick baselines, a
   second unchanged tick is silent, then `Index.plist`'s mtime moves and
   `wallpaperSignals` increments. This is the whole chain — filesystem change →
   fingerprint → decision → coalescing door — and it is the shipped code, not a
   reimplementation of it. `supportDirectory` is a parameter purely so this is
   possible; the real store cannot be used because that would mean changing the
   developer's desktop.
3. **`testTheDesktopChangedNotificationReachesTheBackdropProvider`** — posts
   `com.apple.desktop` and asserts the provider counted it.
   **Negative control run:** with the provider's observer temporarily registered
   under `com.apple.desktop.NEGATIVE-CONTROL`, the test fails
   (`("0") is not greater than ("0")`), so the assertion is real and not
   vacuous. Restored and re-run green.

What is **not** proved: that macOS itself posts `com.apple.desktop` on this
release. That is exactly why the watch exists and why nothing depends on the
notification.

---

## 2. "Dark mode should be very translucent"

### The veil was not the only thing in the way

Thinning the dark veil was blocked, and measurably so. At the shipped 0.52 base,
the **worst patch** of the widest wallpaper in this Mac's aerial library
(`AB7FC3C3`, luma 0.435 — a bright sky over dark ground) measured **4.6:1**
secondary contrast against a 4.5 floor. Rendering the same surface at a 0.34
base and changing nothing else takes it to **3.9:1** — below the floor.

The reason is that the bake normalized the still's *mean* and left its *range*
alone. How bright the brightest patch of the sidebar got was therefore still a
function of the user's desktop — the exact dependency `targetLuminance` exists
to remove, surviving in the second moment. Round 2 flagged this as follow-up #4
and deferred it; it turns out to be the thing that unblocks Michael's request.

### The fix: solve gain and offset together

`CIColorControls`' `contrast` is a gain about 0.5. I measured the filter's actual
operation order rather than assuming it — **saturation, then contrast, then
brightness** — because the offset has to be solved *after* the gain has already
moved the mean, or it misses by `(0.5 − mean)(1 − gain)`. The saturation is
divided by the gain so a range-capped wallpaper is not also a desaturated one.

`DesktopBackdropRenderer.darkStillSpreadCeiling = 0.30` (p5..p95 of the same
16×16 box the mean is read from — no extra decode, no extra draw). Never above
gain 1, so it only ever *removes* an excess. **Dark only**: light has the
headroom at 0.72, light was never the complaint, and every light measurement in
the file is untouched.

### Constants

| constant | before | after | transmission |
| --- | --- | --- | --- |
| `GlassBackdropWash.sidebar(dark)` | 0.45 / **0.52** / 0.61 | 0.27 / **0.34** / 0.43 | 0.48 → **0.66** |
| `GlassBackdropWash.workspace(dark)` | 0.48 / **0.55** / 0.64 | 0.30 / **0.37** / 0.46 | 0.45 → **0.63** |
| `SidebarBackdropView.liveTint.dark` | 0.30 | **0.15** | live material 0.336 → **0.561** |
| `darkStillSpreadCeiling` | — | **0.30** | — |
| `increasedContrastOverlayCeiling` | 0.6 | **0.80** | — |
| every light constant, `targetLuminance`, `blurRadius`, `darkVeil`, `GlassWarmth` | — | unchanged | — |

### Before / after, rendered and measured

Michael's actual desktop (the Lake Tahoe aerial), dark **sidebar** at 210×900.
Contrast uses macOS's dark label alphas (white @0.85 primary, @0.55 secondary).
"worst patch" is the mean of the brightest 2% band — strictly harsher than the
round-2 harness's single p95 sample; both are given.

| | BEFORE (v1.1.10) | AFTER |
| --- | --- | --- |
| veil opacities | 0.45 / 0.52 / 0.61 | **0.27 / 0.34 / 0.43** |
| composite rgb | 0.089 / 0.107 / 0.115 | **0.103 / 0.129 / 0.139** |
| mean luminance | 0.104 | **0.124** |
| luminance spread p5..p95 | 0.086 | **0.095** |
| gradient top→bottom | 0.023 | **0.028** |
| off-neutral | 0.143 | **0.165** |
| % pure black | 0.0% | **0.0%** |
| primary contrast | 12.7:1 | **12.1:1** (p95 10.9, worst patch **10.9**) |
| secondary contrast | 6.0:1 | **5.8:1** (p95 5.5, worst patch **5.5**) |

Dark **workspace**: 0.087/0.105/0.111 → **0.102/0.126/0.135**, spread 0.080 →
**0.094**, primary **12.2:1** (worst 11.0), secondary **5.9:1** (worst 5.5).

Across the five extremes of this Mac's 156-still aerial library, dark sidebar,
worst-patch contrast:

| wallpaper (luma, off-neutral) | BEFORE worst P / S | AFTER worst P / S |
| --- | --- | --- |
| Lake Tahoe — Michael's (0.438, 0.399) | 11.7 / 5.7 | **10.9 / 5.5** |
| darkest (0.076, 0.130) | 12.4 / 5.9 | **11.5 / 5.7** |
| brightest (0.792, 0.400) | 11.2 / 5.6 | **10.1 / 5.2** |
| most saturated (0.265, 0.824) | 11.9 / 5.8 | **11.0 / 5.5** |
| most neutral, widest range (0.435, 0.015) | 8.5 / **4.6** | **9.2 / 4.9** |

The worst case **improves** even though the veil is a third thinner, because the
range cap removes more of it than the veil it buys out. Every surface clears
≥7:1 primary and ≥4.5:1 secondary on every wallpaper measured.

### Did the contrast floor limit how far this went? Yes — and here are the numbers

It did, and the binding case is not a photograph. A wallpaper that *is* a linear
gradient (macOS ships several) passes a Gaussian untouched, so its whole range
reaches the veil where a photograph's range collapses. Held against that fixture,
dark sidebar worst-patch secondary:

| veil base | still cap | worst-patch secondary |
| --- | --- | --- |
| 0.52 (shipped) | none | 4.6 : 1 |
| 0.34 | none | **3.9 : 1** ✗ |
| 0.34 | 0.34 | **4.43 : 1** ✗ — this candidate was turned back by the test |
| **0.34** | **0.30** | **4.63 : 1** ✓ shipped |
| 0.26 | 0.30 | 4.5 : 1 — no margin |
| 0.15 | 0.30 | 4.4 : 1 ✗ |

So the honest limit is a base around 0.30, and I stopped at 0.34. The margin is
deliberate: the wallpapers measured are the extremes of *this* Mac's library, not
of every desktop a user can pick, and the floor has to hold for a desktop nobody
has tested.

There is also a structural reason not to push further: past that point extra
transmission stops buying *structure*, because the cap has to tighten in step and
`(1 − base) × ceiling` is conserved. It keeps buying chroma, which is most of
what reads as translucency at this luminance — but at a rapidly diminishing rate
(off-neutral 0.165 at base 0.34, 0.181 at base 0.15).

### The text-run scrim: considered, not needed, and it would not have helped much

A scrim behind text runs only would buy translucency at equal legibility *if* the
floor were the binding constraint on the surface as a whole. It is not, at these
constants: every measured surface clears the floor with 0.1–1.2 of margin on
secondary and 2–4.5 on primary. Spending complexity — and every label in the app
lives in `Features/*`, which is out of scope this round — to unlock the last
0.04 of veil would be a bad trade. If Michael wants to go past base 0.30, that is
the mechanism to reach for, and it should be a deliberate, separate change.

---

## Verification

- `npm run native:fast:build` — clean, no warnings, no errors.
- `npm run native:test:focus -- NativePreviewSettingsTests` — green.
- `./scripts/native-test-changed.sh --base c273c3c` — green.
  (`npm run native:test:changed -- --include-working-tree` selects nothing once
  the work is committed and the tree is clean, so it was run against the branch
  point.)
- Intermediate commit `803f536` was built and tested on its own before `4f16628`
  was applied, so neither commit is broken in isolation.
- Dev-profile launch only (`KAISOLA_NATIVE_BROKER_PROFILE=development npm run
  native:fast -- --refresh-helper`, pid 72625), stopped with `kill -TERM`. It ran
  **89 s** — ~17 shallow watch ticks and 3 deep ones — at **0.0% average CPU**
  with RSS flat (193.7 → 186.4 MiB) and an empty error log, which is the
  behavioural check that the timer and the distributed observer cost nothing at
  idle. No `defaults delete`, no writes to `/Applications/Kaisola.app`.
- The pinned arm64 Node runtime was missing in this worktree and was fetched with
  `node scripts/download-native-node-runtime.cjs arm64`.
- **All glass numbers are rendered, not modelled.** A standalone harness
  reproduces the shipped pipeline (thumbnail → `CIGaussianBlur` →
  `CIColorControls` → `GlassWarmth` → veil gradient → composite) against the real
  aerial files on this machine; it was validated against `round2-shell-report.md`'s
  published figures at the shipped constants before any sweep was trusted
  (report 0.089/0.105/0.112 spread 0.083 primary 12.8 secondary 6.0; harness
  0.089/0.107/0.115 spread 0.086 primary 12.7 secondary 6.0). The *shipped* test
  renders through `DesktopBackdropRenderer.render` itself.
- `CIColorControls`' operation order was measured on the real filter, not read
  from documentation.
- No screenshots: `screencapture` is TCC-blocked here, so every appearance claim
  is arithmetic over rendered pixels.

## Concerns / follow-ups

1. **The distributed notification is unverified against macOS itself.** The
   evidence is `nm`/`strings` on `WallpaperAgent`, and the only way to close it
   is to change a real desktop and watch. The five-second watch is why this does
   not matter for correctness — but if someone later "simplifies" by deleting the
   watch and keeping the notification, wallpaper tracking may silently stop.
   `desktopChangedNotification`'s doc comment says so.
2. **A rotating aerial category still paints one representative still.** If macOS
   ever publishes which clip is playing, that is the upgrade; today there is no
   such pointer and determinism is required by the cache key.
3. **The range cap is computed from the unblurred 16×16 box**, which over-states
   what survives radius-28 blur, so it is conservative — a photograph is damped
   somewhat more than it needs to be. Measuring the spread *after* the blur would
   need a second raster pass; the conservatism costs a few percent of structure
   on mid-range wallpapers and buys margin on the pathological ones.
4. **Light's worst-patch secondary contrast is 3.5–3.6:1** and always was. This
   is a pre-existing macOS ceiling, not a regression from this pass: AppKit's own
   `secondaryLabelColor` on pure white tops out at 3.95:1, so no light glass
   surface can reach 4.5. Untouched here because light was not the ask, but it is
   the one place the stated floor is not met.
5. **`increasedContrastOverlayCeiling` moved 0.6 → 0.80.** Accessibility is
   unchanged — the *total* coverage floor is still 0.80 and is now met by
   arithmetic on all four surfaces rather than by a clamp — but a reviewer should
   know the number moved and why.
6. **`node_modules` is a symlink to the main checkout**, added so the worktree
   could package the broker helper for the dev launch. Untracked; delete it
   before archiving the worktree.
