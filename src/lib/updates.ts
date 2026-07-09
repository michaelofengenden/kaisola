import { useEffect, useState } from 'react'
import { bridge, type UpdateState } from './bridge'

/**
 * Live update status, shared by the tab-strip pill and Settings → General.
 * Pulls the main-process snapshot on mount (events may have fired before we
 * subscribed), then follows the event stream. Web builds stay at 'idle'.
 */
export function useUpdateState(): UpdateState {
  const [state, setState] = useState<UpdateState>({ type: 'idle' })
  useEffect(() => {
    if (!bridge.update) return
    let live = true
    const apply = (next: UpdateState) => {
      if (!live) return
      setState((current) => {
        // Subscribe before pulling the snapshot below. If an event and the
        // snapshot cross in flight, only the newest main-process revision wins.
        if (next.revision != null && current.revision != null && next.revision < current.revision) return current
        return next
      })
    }
    const off = bridge.update.onEvent(apply)
    bridge.update.state().then(apply).catch(() => {})
    return () => { live = false; off() }
  }, [])
  return state
}
