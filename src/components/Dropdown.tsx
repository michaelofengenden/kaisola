import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from './Icon'

export interface DropOption {
  value: string
  name: string
  description?: string
}

/**
 * A small composer dropdown (the "Auto / Default / Max" controls + the agent
 * picker). The menu renders in a portal with fixed positioning so it is NEVER
 * clipped by an overflow ancestor (that was the bug that made agent-switching
 * impossible inside the scrolling thread-tab bar).
 */
export function Dropdown({
  value,
  options,
  onSelect,
  icon,
  title,
  placeholder,
  align = 'left',
  placement = 'auto',
}: {
  value: string
  options: DropOption[]
  onSelect: (value: string) => void
  icon?: string
  title?: string
  placeholder?: string
  align?: 'left' | 'right'
  placement?: 'auto' | 'bottom' | 'top'
}) {
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState<{ left?: number; right?: number; top?: number; bottom?: number; maxHeight?: number }>({})
  const btnRef = useRef<HTMLButtonElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  const current = options.find((o) => o.value === value)

  const place = () => {
    const b = btnRef.current?.getBoundingClientRect()
    if (!b) return
    const pad = 8
    // measure the rendered menu so we can keep it fully on-screen (it was getting
    // clipped at the right edge when opened from a right-docked rail)
    const menuW = menuRef.current?.offsetWidth ?? 240
    const menuH = menuRef.current?.offsetHeight ?? 0
    const openDown = placement === 'bottom' || (placement === 'auto' && b.top < 360)
    setPos({
      left: align === 'right' ? undefined : Math.max(pad, Math.min(b.left, window.innerWidth - menuW - pad)),
      right: align === 'right' ? Math.max(pad, window.innerWidth - b.right) : undefined,
      ...(openDown
        ? placement === 'bottom'
          // forced-below menus STAY below the trigger (the vertical sidebar's
          // "+" flow depends on it) — a long option list shrinks and scrolls
          // instead of sliding up over the button
          ? { top: b.bottom + 6, maxHeight: Math.max(120, Math.min(340, window.innerHeight - b.bottom - 6 - pad)) }
          : { top: Math.max(pad, Math.min(b.bottom + 6, window.innerHeight - menuH - pad)) }
        : { bottom: window.innerHeight - b.top + 6 }),
    })
  }
  useLayoutEffect(() => {
    if (open) place()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, placement])

  useEffect(() => {
    if (!open) return
    const onDoc = (e: PointerEvent) => {
      const t = e.target as Node
      if (btnRef.current?.contains(t) || menuRef.current?.contains(t)) return
      setOpen(false)
    }
    const onScrollResize = () => setOpen(false)
    // capture phase so this runs BEFORE surface-level Escape handlers (e.g.
    // Settings' close-on-Escape) — dismissing the menu must not close the panel
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.stopPropagation()
      setOpen(false)
    }
    // Capture phase is intentional: modal panels (Settings included) stop
    // bubbling pointer events at their surface. A bubble listener therefore
    // left the dropdown preview open when clicking another setting.
    document.addEventListener('pointerdown', onDoc, true)
    window.addEventListener('resize', onScrollResize)
    window.addEventListener('keydown', onKey, true)
    return () => {
      document.removeEventListener('pointerdown', onDoc, true)
      window.removeEventListener('resize', onScrollResize)
      window.removeEventListener('keydown', onKey, true)
    }
  }, [open])

  return (
    <>
      <button ref={btnRef} className="drop-btn" onClick={() => setOpen((o) => !o)} title={title} data-open={open}>
        {icon && <Icon name={icon} size={12} className="drop-btn-icon" />}
        <span className="drop-btn-label">{current?.name ?? placeholder ?? value}</span>
        <Icon name="ChevronDown" size={12} className="drop-caret" />
      </button>
      {open &&
        createPortal(
          <div ref={menuRef} className="drop-menu" style={{ position: 'fixed', ...pos }} role="menu">
            {options.length === 0 && <div className="drop-empty faint">No options</div>}
            {options.map((o) => (
              <button
                key={o.value}
                className="drop-item"
                data-active={o.value === value}
                onClick={() => {
                  onSelect(o.value)
                  setOpen(false)
                }}
              >
                <Icon name="Check" size={12} className="drop-check" />
                <span className="grow">
                  <span className="drop-item-name">{o.name}</span>
                  {o.description && <span className="drop-item-desc">{o.description}</span>}
                </span>
              </button>
            ))}
          </div>,
          document.body,
        )}
    </>
  )
}
