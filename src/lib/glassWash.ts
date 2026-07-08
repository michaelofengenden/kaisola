import { bridge, isDesktop } from './bridge'
import { useKaisola } from '../store/store'

/**
 * Wallpaper-sampled glass wash. The chrome veils (--wash-strip-color /
 * --wash-rail-color, shell.css) default to per-theme constants — the exact
 * colors the old blur(1600px) chrome converged to. Sampling retints them
 * toward the average color of the desktop under the window, which is the one
 * thing the CSS blur could never see. Alphas stay untouched: they ARE the
 * chrome's ink level. Every failure path leaves the defaults — the
 * pre-sampling look — so this can only ever add fidelity.
 *
 * Also caches the pre-blurred wallpaper copy + screen geometry for the
 * painted-mode background layer (--wallpaper-img/-size, .app-wallpaper).
 */

/** How much of the wallpaper's color the veils adopt (0 = today's constants). */
const WALLPAPER_TINT = 0.22

// base veil colors per theme — keep in sync with the shell.css defaults
const VEIL_BASE = {
  light: { strip: [255, 255, 254], rail: [255, 254, 254] },
  dark: { strip: [11, 13, 18], rail: [11, 12, 17] },
} as const

let screenRect: { x: number; y: number; w: number; h: number } | null = null
export const getGlassScreen = () => screenRect

function anchor() {
  const r = screenRect
  if (!r) return
  const root = document.documentElement
  // window.screenX/Y are the window's desktop coords; the painting is
  // screen-sized, so shifting it by the negative window offset pins it to
  // the physical desktop (re-anchored via glass:refresh after drag-end)
  root.style.setProperty('--wallpaper-x', `${-(window.screenX - r.x)}px`)
  root.style.setProperty('--wallpaper-y', `${-(window.screenY - r.y)}px`)
}

async function apply() {
  const state = useKaisola.getState()
  if (state.perfMode === 'eco') return // eco paints nothing glassy
  let s: Awaited<ReturnType<typeof bridge.glassWash.sample>>
  try {
    s = await bridge.glassWash.sample()
  } catch {
    return // no handler (probe harness / non-mac) — keep the theme defaults
  }
  if (!s.ok || !s.avg) return
  const root = document.documentElement
  const mix = (base: readonly number[]) =>
    base
      .map((c, i) => Math.round(c + ([s.avg!.r, s.avg!.g, s.avg!.b][i] - c) * WALLPAPER_TINT))
      .join(' ')
  const base = VEIL_BASE[useKaisola.getState().theme]
  root.style.setProperty('--wash-strip-color', mix(base.strip))
  root.style.setProperty('--wash-rail-color', mix(base.rail))
  if (s.blurDataUrl && s.screen) {
    screenRect = s.screen
    root.style.setProperty('--wallpaper-img', `url("${s.blurDataUrl}")`)
    root.style.setProperty('--wallpaper-size', `${s.screen.w}px ${s.screen.h}px`)
    anchor()
  }
}

export function initGlassWash(): () => void {
  if (!isDesktop) return () => {}
  void apply()
  const offRefresh = bridge.glassWash.onRefresh(() => void apply())
  const unsub = useKaisola.subscribe((s, prev) => {
    if (s.perfMode !== prev.perfMode || s.theme !== prev.theme) void apply()
  })
  return () => {
    offRefresh()
    unsub()
  }
}
