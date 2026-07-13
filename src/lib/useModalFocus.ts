import { useEffect, type RefObject } from 'react'

const FOCUSABLE = [
  'button:not([disabled])',
  'a[href]',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

/** Keep keyboard focus inside a modal surface and restore the invoking control
 * when it closes. Portalled popovers may temporarily own focus; Tab returns to
 * the modal's first/last control instead of escaping into the obscured shell. */
export function useModalFocus(active: boolean, surfaceRef: RefObject<HTMLElement>) {
  useEffect(() => {
    if (!active) return
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const surface = surfaceRef.current
    if (!surface) return

    const controls = () => [...surface.querySelectorAll<HTMLElement>(FOCUSABLE)]
      .filter((node) => !node.hidden && node.getAttribute('aria-hidden') !== 'true')
    const frame = window.requestAnimationFrame(() => {
      const preferred = surface.querySelector<HTMLElement>('[data-modal-autofocus]:not([disabled])')
      ;(preferred ?? controls()[0] ?? surface).focus({ preventScroll: true })
    })
    // Async account/config checks can replace the initially focused button
    // after the first frame. If that node disappears, browsers fall back to
    // <body>; recover focus inside the still-open dialog automatically.
    const observer = new MutationObserver(() => {
      window.requestAnimationFrame(() => {
        const activeElement = document.activeElement
        if (!surface.isConnected || surface.contains(activeElement)) return
        // A connected element outside the surface can be an intentional
        // portalled dropdown/menu owned by this modal. Recover only when the
        // focused control actually disappeared and Chromium fell back to body.
        if (activeElement instanceof HTMLElement && activeElement !== document.body && activeElement.isConnected) return
        const preferred = surface.querySelector<HTMLElement>('[data-modal-autofocus]:not([disabled])')
        ;(preferred ?? controls()[0] ?? surface).focus({ preventScroll: true })
      })
    })
    observer.observe(surface, { childList: true, subtree: true })
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Tab') return
      const items = controls()
      if (!items.length) {
        event.preventDefault()
        surface.focus({ preventScroll: true })
        return
      }
      const first = items[0]
      const last = items[items.length - 1]
      const current = document.activeElement
      if (event.shiftKey && (current === first || !surface.contains(current))) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && (current === last || !surface.contains(current))) {
        event.preventDefault()
        first.focus()
      }
    }
    document.addEventListener('keydown', onKey, true)
    return () => {
      window.cancelAnimationFrame(frame)
      observer.disconnect()
      document.removeEventListener('keydown', onKey, true)
      if (previous?.isConnected) previous.focus({ preventScroll: true })
    }
  }, [active, surfaceRef])
}
