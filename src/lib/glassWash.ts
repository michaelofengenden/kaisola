import { bridge, isDesktop } from './bridge'
import { useKaisola } from '../store/store'

/**
 * Wallpaper-sampled glass wash. The rail veil (--wash-rail-color, shell.css)
 * defaults to a per-theme constant — the exact color the old blur(1600px)
 * chrome converged to. Sampling retints it toward the average color of the
 * desktop under the window, which is the one thing the CSS blur could never
 * see. Alphas stay untouched: they ARE the chrome's ink level. Every failure
 * path leaves the defaults — the pre-sampling look — so this can only ever
 * add fidelity. (The tab strip carries no veil anymore — it sits on the bare
 * glass field, so there is nothing to retint up there.)
 *
 * The removed painted-glass mode used to retain a desktop raster here. The
 * current path receives only an average RGB triplet from a tiny disk-cached
 * thumbnail, so changing wallpaper tint no longer pins image memory.
 */

/** How much of the wallpaper's color the veils adopt (0 = today's constants). */
const WALLPAPER_TINT = 0.22

// base veil color per theme — keep in sync with the shell.css defaults
const VEIL_BASE = {
  light: { rail: [255, 254, 254] },
  dark: { rail: [11, 12, 17] },
} as const

let requestGeneration = 0

async function apply() {
  const state = useKaisola.getState()
  const generation = ++requestGeneration
  if (state.perfMode === 'eco') return
  let s: Awaited<ReturnType<typeof bridge.glassWash.sample>>
  try {
    s = await bridge.glassWash.sample()
  } catch {
    return // no handler (probe harness / non-mac) — keep the theme defaults
  }
  if (generation !== requestGeneration) return // a newer move/theme/mode won
  if (!s.ok || !s.avg) return
  const root = document.documentElement
  if (useKaisola.getState().wallpaperTint) {
    const mix = (base: readonly number[]) =>
      base
        .map((c, i) => Math.round(c + ([s.avg!.r, s.avg!.g, s.avg!.b][i] - c) * WALLPAPER_TINT))
        .join(' ')
    const base = VEIL_BASE[useKaisola.getState().theme]
    root.style.setProperty('--wash-rail-color', mix(base.rail))
  } else {
    // Settings → Interface switch OFF: the veil stays the theme constant
    root.style.removeProperty('--wash-rail-color')
  }
}

export function initGlassWash(): () => void {
  if (!isDesktop) return () => {}
  void apply()
  // Consolidate mode → window prefs at every boot. Fresh installs default to
  // Eco, so the very next launch is opaque even before Settings is opened.
  {
    const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg-0').trim()
    void bridge.windowMode({
      solidWindow: useKaisola.getState().perfMode !== 'glass',
      ...(/^#[0-9a-fA-F]{6}$/.test(bg) ? { solidBg: bg } : {}),
    }).catch(() => {})
  }
  const offRefresh = bridge.glassWash.onRefresh(() => void apply())
  const unsub = useKaisola.subscribe((s, prev) => {
    if (s.perfMode !== prev.perfMode || s.theme !== prev.theme || s.wallpaperTint !== prev.wallpaperTint) void apply()
    // a theme flip while a solid mode is persisted must refresh the opaque
    // window's boot color, or the next launch flashes the old theme's bg
    if (s.theme !== prev.theme && s.perfMode !== 'glass') {
      const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg-0').trim()
      if (/^#[0-9a-fA-F]{6}$/.test(bg)) void bridge.windowMode({ solidBg: bg }).catch(() => {})
    }
  })
  return () => {
    offRefresh()
    unsub()
  }
}
