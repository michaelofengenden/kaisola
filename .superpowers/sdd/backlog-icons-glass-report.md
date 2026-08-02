# Backlog: icons, agent detection, tinted canvas, dark glass

Worktree `/Users/michaelofengenden/Developer/Kaisola/.claude/worktrees/agent-a9cdc1cf5cf8c1b40`,
branch `worktree-agent-a9cdc1cf5cf8c1b40`, branched from `216196b` (v1.1.9).

| commit | subject |
| --- | --- |
| `6b54732` | fix(rail): find a running agent anywhere in the terminal chain |
| `8103ab2` | feat(rail): draw the real OpenAI knot instead of six stadiums |
| `42aade7` | fix(glass): stop the dark backdrop reading purple-blue and flat |
| `16af008` | fix(canvas): make Tinted actually tinted and name Solid what it is |

Verification: build warning-clean;
`npm run native:test:focus -- QuietIdentityMarkTests NativePreviewSettingsTests TerminalMetaServiceTests`
green; `./scripts/native-test-changed.sh --base 216196b` green.

---

## 1. Claude/Codex CLI detection

`TerminalMetaService.collect` named a row from `chain.last`. A running agent is
never the leaf — it spawns helpers — so the row fell back to the shell mark and
the coral at `QuietIdentityMark.swift:96` never rendered. Both halves of "it's
not recognizing claude cli from the terminal and nor is it orange" are this.

### Real fixtures (captured 2026-08-01, `ps -axo pid=,ppid=,command=`, verbatim)

Kaisola broker terminal with `claude` in it — leaf is `sleep`:

```
69807 40496 /bin/zsh -i
69863 69807 claude
99646 69863 /bin/zsh -c source /Users/michaelofengenden/.claude/shell-snapshots/snapshot-zsh-1785393435850-x7ft8i.sh 2>/dev/null || true && export CODEX_COMPANION_SESSION_ID='b6f70f4a-…'
74322 99646 sleep 10
```

Terminal.app shell with `codex` in it — leaf is `node`:

```
 2465  2464 -zsh
 2490  2465 node /Users/michaelofengenden/miniforge3/bin/codex
 2491  2490 /Users/michaelofengenden/miniforge3/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex
82486  2491 node ./mcp/server.cjs --stdio
```

Both are in `TerminalMetaServiceTests` as `liveClaudeChain` / `liveCodexChain`.

### Fix

`foregroundName(chain:recordsByPID:)` scans the whole chain and prefers the
**shallowest** agent (an agent is the ancestor of its helpers), falling back to
the deepest link that yields a name when no link is an agent, so
`zsh → npm → node` still reads as the build it is.

Marker matching narrowed at the same time: only the executable — and, behind a
runtime wrapper, the first non-flag argument after it — may name the program,
each reduced to its last two path components. Scanning the whole argv (the old
behaviour) would have matched that `zsh -c source ~/.claude/shell-snapshots/…`
link, and `vim ~/.claude/settings.json`, as Claude.

### Live verification (method stated honestly)

Marks are `accessibilityHidden`, so the observed value is `meta.processName` —
the same value `QuietProjectRail.swift:705` feeds to `QuietIdentity.identity`,
the row tooltip (`:828`) and `SessionTitleTracker.agentDisplayName`.

* Dev-profile app launched clean:
  `KAISOLA_NATIVE_BROKER_PROFILE=development npm run native:fast -- --refresh-helper`
  → pid 7625, no crash; stopped with `kill -TERM`.
* A real `zsh -i → claude` chain was stood up on a pty (`script -q /dev/null
  /bin/zsh -i`, pid 8110) and the **shipped** collector run against it live via
  the opt-in test `testLiveAgentChainResolvesThroughTheShippedCollector`
  (`TEST_RUNNER_KAISOLA_LIVE_AGENT_ROOT_PID=8110`) → `processName == "claude"`,
  identity `.claude`.
* Same test against the deep chain above (root 69807, leaf `ssh` at that
  moment) → `"claude"`. Against the live codex chain (root 2465, leaf `node`)
  with `TEST_RUNNER_KAISOLA_LIVE_AGENT_NAME=codex` → `"codex"`.
* Negative control run first: with the wrong expected name the test **failed**,
  proving the environment reached the test host and the assertion was real.
  (Without the `TEST_RUNNER_` prefix xcodebuild drops the variable and the test
  silently skips — noted in the test's own doc comment.)

I did not type into a dev-app terminal through the GUI; that needs AX
scripting, and the collector run above exercises the identical code path
(`ps` → `processChains` → `foregroundName`) on a live process tree.

---

## 2. The OpenAI/ChatGPT knot

**Reference structure** (`assets/backlog/pasted-image.png`, 1024², black on
white): the official logomark — six interlocking ribbon strands woven into a
rounded hexagonal knot with visible over/under crossings and a hexagonal
counter at the centre. The strands are *solid filled*; the white gaps are
counters in the outline, not a stroke.

**Before**: `QuietOpenAIKnotMark` drew six stroked stadiums on an orbit.
Rasterized at 1024 and cropped to its own ink box against the reference:
**IoU 0.333**, ink coverage 0.569 against the reference's 0.382 — a heavier,
blunter hexagon.

**Route taken**: the official outline, transcribed; its elliptical arcs
converted to cubics offline (endpoint→centre parameterization, ≤90° per
segment); then translated and uniformly scaled so its **tight** bounds
(`boundingBoxOfPath`, which is what SwiftUI's `Path.boundingRect` reports)
centre in the shared 24-unit viewbox. 8 subpaths, 36 cubics, 32 lines.

**After**: **IoU 0.983**, ink 0.381 against 0.382. Rasterized at 16pt with
CoreGraphics and compared against a 16pt downsample of the reference before
settling. Filled non-zero, monochrome (`#202123` / `#F2F2F2`), no tile.

The data ships as an `M`/`L`/`C`/`Z` string read by a four-command reader
(`QuietVectorOutline`) — deliberately not an SVG parser; the arc maths stayed
in the offline step. The parsed `[QuietOutlineSegment]` is `Sendable`, so it
can be a `static let` under Swift 6 strict concurrency (a `Path` cannot).

**Optical weight**, measured by rendering each mark into the 16pt slot at 8×
and summing alpha: `terminal` 0.208, `arrow.up.arrow.down` 0.162, the coral
starburst 0.314, the filled knot 0.376 at full span. The knot is inset to
`span = 14.5/16`, where it inks **0.308** — level with the starburst, and a
deliberate step above the generic `.secondary` glyphs, which is the rail's
existing "first-class agents carry full ink" grammar.

Six-fold symmetry is asserted by sampling rather than by constants (there are
no symmetry constants any more): a 60° turn disagrees on 5.6% of the mark's
area (the official outline is hand-tuned), a 30° turn on 59%.

**Not changed**: the Claude starburst geometry. Michael's complaint was
detection and colour, both item 1. A partial re-trace was attempted and
measured against `pasted-image-2.png`: a 12-petal tapered model fitted from
the reference's radial profile scored only **IoU 0.44**, so shipping it would
have been worse than the current clean 12-ray burst. The coral is confirmed
exact — the reference's fill is `#D97757`, which is already the constant.

---

## 3. Tinted canvas

`WorkspaceBackdropMode` has three options. Composited over the canvas at
0.12/0.055, the sampled tint left the light canvas **0.016 off-neutral** against
Solid's 0.000 — one and a half percent of channel spread, i.e. the two options
were the same surface.

Compositing the raw sample moves brightness and hue together and brightness
wins. `DesktopTintSampler.revalued(_:peak:)` re-values it first: scale the
sampled tint so its brightest channel lands on a chosen peak, hue and channel
ratios untouched. Light takes it at full value (over white that is pure hue and
almost no dimming), dark just above the canvas it sits on.

Composite arithmetic, with Michael's real desktop (sampled tint
0.315/0.465/0.534). "off-neutral" = max per-channel departure from the mean
over the mean — the app's own declared-neutral measure.

| appearance | option | composite rgb | luma | off-neutral | primary | secondary |
| --- | --- | --- | --- | --- | --- | --- |
| light | Solid | 1.000 / 1.000 / 1.000 | 1.000 | 0.000 | 14.9:1 | 3.95:1 |
| light | Tinted (before) | 0.918 / 0.936 / 0.944 | 0.933 | 0.016 | 13.3:1 | 3.83:1 |
| light | **Tinted (after)** | 0.816 / 0.941 / 1.000 | 0.919 | **0.113** | 13.0:1 | 3.81:1 |
| dark | Solid | 0.118 / 0.118 / 0.118 | 0.118 | 0.000 | 12.2:1 | 5.89:1 |
| dark | Tinted (before) | 0.149 / 0.173 / 0.184 | 0.169 | 0.116 | 10.6:1 | 5.37:1 |
| dark | **Tinted (after)** | 0.163 / 0.216 / 0.240 | 0.206 | **0.209** | 9.3:1 | 4.91:1 |

Tinted is now 7× (light) / 1.8× (dark) further from neutral than before, while
light keeps 92% of Solid's luminance — it tints instead of dimming. Solid keeps
`windowBackgroundColor`, which already resolved to `#FFFFFF` light / `#1E1E1E`
dark with exactly zero wallpaper contribution; it is now *called* "Solid"
rather than "System" so the choice next to "Tinted" means something. The stored
raw value stays `system`, so nobody's preference moves.

Light secondary label contrast goes 3.83 → 3.81; the 4.5 bar is already missed
by macOS's own `secondaryLabelColor` on white (3.95), so this is a 0.02
movement inside a pre-existing system ceiling, not a regression introduced here.

---

## 4. Dark glass

Investigated what actually reaches the screen by modelling the full stack
(bake → blur → saturation → luminance shift → `GlassWarmth` → veil → label)
against Michael's **actual** desktop, resolved the way the app resolves it: an
Aerial category whose representative still is
`…/com.apple.wallpaper/aerials/thumbnails/4C108785-….png` — Lake Tahoe,
average rgb 0.263/0.476/0.576, luma 0.438, channel spread 0.313. A genuinely
blue picture.

### What was actually wrong

1. **Chroma was never normalized.** `luminanceShift` uses `CIColorControls`
   brightness, a per-channel *offset* — deliberately, so it moves the mean
   without touching channel differences. Lifted to 0.72 in light, the
   wallpaper's absolute chroma is a rounding error; crushed to 0.16 in dark,
   the identical chroma is most of the surface.
2. **`GlassWarmth` was appearance-blind.** 4% of a 0.738-luminance amber
   perturbs a 0.16 still ~19× as hard as a 0.72 one, in a hue opposite the cool
   cast. Blue plus amber is what read as *purple*.
3. **Dark was the least translucent surface in the app** — 0.35–0.40
   transmission against light's 0.40–0.45 — with half the light direction in
   its gradient. That is the "flat".

### Before / after (measured composites, sidebar unless noted)

| | light (uncomplained) | dark BEFORE | dark AFTER |
| --- | --- | --- | --- |
| composite rgb | 0.834 / 0.898 / 0.927 | 0.055 / 0.114 / 0.143 | 0.078 / 0.106 / 0.119 |
| off-neutral | 0.059 | **0.473** | **0.229** |
| red ÷ blue | 0.90 | 0.38 | 0.65 |
| vs the desktop's own 0.400 | 0.15× | **1.27× (more colourful than the wallpaper)** | 0.57× |
| luminance spread p5..p95 | 0.062 | 0.060 | **0.072** |
| veil gradient top→bottom | 0.028 | 0.014 | **0.017** |
| primary label contrast | 12.3:1 | 12.6:1 | **12.8:1** (≥7 ✓) |
| secondary label contrast | 3.8:1 | 6.0:1 | **6.0:1** (≥4.5 ✓) |

Dark workspace after: 0.076/0.102/0.114, off-neutral 0.221, spread 0.068,
primary 12.9:1, secondary 6.1:1.

### Constants

| constant | before | after |
| --- | --- | --- |
| `DesktopBackdropRenderer.saturation` | `0.85` (flat) | `saturationCeiling 0.85` × `min(1, target/mean)` → **0.311** dark for this desktop, unchanged in light for any wallpaper dimmer than 0.72 |
| `GlassWarmth.opacity` | `0.04` (flat) | `opacity(isDark:)` — 0.04 light, **0.0089** dark (scaled by 0.16/0.72) |
| `GlassBackdropWash.sidebar(dark)` | 0.55 / 0.60 / 0.66 | **0.48 / 0.55 / 0.63** (transmission 0.40 → 0.45) |
| `GlassBackdropWash.workspace(dark)` | 0.60 / 0.65 / 0.71 | **0.51 / 0.58 / 0.66** (transmission 0.35 → 0.42) |
| light veils, `targetLuminance`, `blurRadius`, `darkVeil #0D0D0D` | — | unchanged |

The saturation rule makes the composite's off-neutrality a roughly fixed
multiple of the desktop's own for *any* wallpaper — 1.0–1.3× before, 0.5–0.7×
after — which `testDarkBakeNormalizesChromaTheWayItNormalizesLuminance` pins
across three wallpapers, including the before/after regression witness.
Increased-Contrast overlays re-derive from the new bases and still land exactly
on the 0.80 floor without touching the 0.6 ceiling (0.556 sidebar, 0.524
workspace).

---

## Concerns / follow-ups

* The knot's `outlineData` is a transcription. Its fidelity is pinned by ink
  and symmetry tests, not by a raster comparison in CI — the IoU 0.983 number
  was measured offline against `assets/backlog/pasted-image.png` and is
  recorded in the source comment, not re-checked on every run.
* Dark glass is still 0.229 off-neutral against light's 0.059. Exact parity
  needs saturation ≈ 0.08, which would make the painted wallpaper pointless; a
  dark surface simply shows chroma more readily. If Michael still reads it as
  blue, the next lever is `saturationCeiling` for dark specifically.
* `GlassWarmth` doc used to say "deliberately one number"; that claim is now
  retired with an explicit derivation. `testGlassWarmthIsADeclaredAmber` still
  guards the light value.
* Michael's other backlog items — sidebar highlight/indent, sidebar scroll,
  markdown editing, top-bar buttons — are other agents' files and untouched.
* Building `native:fast` in a worktree needs `node_modules`; I symlinked the
  parent's for the dev launch and removed it afterwards, so the tree is clean.
* A session hook committed everything as one `wip(...)` commit mid-run; it was
  unwound with `git reset --mixed 216196b` and re-committed as the four above.
