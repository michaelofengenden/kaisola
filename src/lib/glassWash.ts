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
 * Also caches the pre-blurred wallpaper copy + screen geometry for the
 * painted-mode background layer (--wallpaper-img/-size, .app-wallpaper).
 */

/** How much of the wallpaper's color the veils adopt (0 = today's constants). */
const WALLPAPER_TINT = 0.22

// base veil color per theme — keep in sync with the shell.css defaults
const VEIL_BASE = {
  light: { rail: [255, 254, 254] },
  dark: { rail: [11, 12, 17] },
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
  // consolidate mode → window prefs at every boot: a fresh install defaults to
  // painted before any Settings visit, and its opaque window should arrive on
  // the very next launch without anyone touching the picker
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
