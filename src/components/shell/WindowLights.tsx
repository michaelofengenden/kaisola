import { bridge, isDesktop } from '../../lib/bridge'

/**
 * Renderer-drawn traffic lights (the native ones are hidden — macOS offers no
 * way to size them). A touch larger, tucked into the card corner; glyphs show
 * on hover like the real thing; gray while the window is blurred.
 */
export function WindowLights() {
  if (!isDesktop) return null
  return (
    <div className="lights">
      <button className="light light-close" onClick={() => bridge.winCtl('close')} title="Close">
        <svg viewBox="0 0 12 12" aria-hidden="true">
          <path d="M3.4 3.4 L8.6 8.6 M8.6 3.4 L3.4 8.6" />
        </svg>
      </button>
      <button className="light light-min" onClick={() => bridge.winCtl('minimize')} title="Minimize">
        <svg viewBox="0 0 12 12" aria-hidden="true">
          <path d="M2.8 6 H9.2" />
        </svg>
      </button>
      <button className="light light-full" onClick={() => bridge.winCtl('fullscreen')} title="Full screen">
        <svg viewBox="0 0 12 12" aria-hidden="true">
          <path d="M3 6.8 V9 H5.2 Z" className="fill" />
          <path d="M9 5.2 V3 H6.8 Z" className="fill" />
        </svg>
      </button>
    </div>
  )
}
