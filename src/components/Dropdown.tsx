import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
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
  ariaLabel,
  placeholder,
  align = 'left',
  placement = 'auto',
  disabled = false,
}: {
  value: string
  options: DropOption[]
  onSelect: (value: string) => void
  icon?: string
  title?: string
  ariaLabel?: string
  placeholder?: string
  align?: 'left' | 'right'
  placement?: 'auto' | 'bottom' | 'top'
  disabled?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState<{ left?: number; right?: number; top?: number; bottom?: number; maxHeight?: number }>({})
  const btnRef = useRef<HTMLButtonElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  const menuId = useId()
  const current = options.find((o) => o.value === value)
  const visibleValue = current?.name ?? placeholder ?? value

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
    const frame = window.requestAnimationFrame(() => {
      const items = [...(menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitemradio"]') ?? [])]
      ;(items.find((item) => item.dataset.active === 'true') ?? items[0] ?? menuRef.current)?.focus()
    })
    return () => window.cancelAnimationFrame(frame)
  }, [open])

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
      window.requestAnimationFrame(() => btnRef.current?.focus())
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

  useEffect(() => {
    if (disabled && open) setOpen(false)
  }, [disabled, open])

  const openFromKey = (event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (disabled || !['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return
    event.preventDefault()
    setOpen(true)
  }
  const moveMenuFocus = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const items = [...(menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitemradio"]') ?? [])]
    if (!items.length) return
    const at = Math.max(0, items.indexOf(document.activeElement as HTMLButtonElement))
    let next = at
    if (event.key === 'ArrowDown') next = (at + 1) % items.length
    else if (event.key === 'ArrowUp') next = (at - 1 + items.length) % items.length
    else if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = items.length - 1
    else if (event.key === 'Escape') {
      event.preventDefault(); event.stopPropagation(); setOpen(false); window.requestAnimationFrame(() => btnRef.current?.focus()); return
    } else if (event.key === 'Tab') {
      setOpen(false); return
    } else return
    event.preventDefault()
    items[next].focus()
  }

  return (
    <>
      <button
        ref={btnRef}
        className="drop-btn"
        onClick={() => { if (!disabled) setOpen((o) => !o) }}
        onKeyDown={openFromKey}
        title={title}
        disabled={disabled}
        data-open={open}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        aria-label={ariaLabel ? `${ariaLabel}: ${visibleValue}` : (!current?.name && !placeholder ? title : undefined)}
      >
        {icon && <Icon name={icon} size={12} className="drop-btn-icon" />}
        <span className="drop-btn-label">{visibleValue}</span>
        <Icon name="ChevronDown" size={12} className="drop-caret" />
      </button>
      {open &&
        createPortal(
          <div id={menuId} ref={menuRef} className="drop-menu" style={{ position: 'fixed', ...pos }} role="menu" tabIndex={-1} onKeyDown={moveMenuFocus}>
            {options.length === 0 && <div className="drop-empty faint">No options</div>}
            {options.map((o) => (
              <button
                key={o.value}
                className="drop-item"
                data-active={o.value === value}
                role="menuitemradio"
                aria-checked={o.value === value}
                onClick={() => {
                  onSelect(o.value)
                  setOpen(false)
                  window.requestAnimationFrame(() => btnRef.current?.focus())
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
