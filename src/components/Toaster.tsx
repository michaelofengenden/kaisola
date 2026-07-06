import { useEffect, useRef } from 'react'
import { useKaisola, type ToastKind } from '../store/store'
import { Icon } from './Icon'

const AUTO_DISMISS_MS = 4500

/**
 * Calm, ephemeral toasts (bottom-right, max 3, auto-dismiss). They echo EVENTS
 * — an agent finished, a best-of-N is ready, a merge failed — never ongoing
 * work (that's the dock/queue state dots). The Activity feed is the persistent
 * record; toasts are the transient nudge.
 */
export function Toaster() {
  const toasts = useKaisola((s) => s.toasts)
  const dismissToast = useKaisola((s) => s.dismissToast)
  return (
    <div className="toaster" aria-live="polite" aria-atomic="false">
      {toasts.map((t) => (
        <ToastItem key={t.id} id={t.id} kind={t.kind} text={t.text} onDismiss={dismissToast} />
      ))}
    </div>
  )
}

function ToastItem({
  id,
  kind,
  text,
  onDismiss,
}: {
  id: string
  kind: ToastKind
  text: string
  onDismiss: (id: string) => void
}) {
  useEffect(() => {
    const timer = setTimeout(() => onDismiss(id), AUTO_DISMISS_MS)
    return () => clearTimeout(timer)
  }, [id, onDismiss])

  return (
    <div className="toast" data-kind={kind} role="status">
      <span className="toast-accent" />
      <span className="toast-text" title={text}>{text}</span>
      <button className="toast-dismiss" onClick={() => onDismiss(id)} aria-label="Dismiss">
        <Icon name="X" size={12} />
      </button>
    </div>
  )
}
