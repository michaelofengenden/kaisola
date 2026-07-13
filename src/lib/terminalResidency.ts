/** Terminal ids that have mounted an xterm in THIS renderer. SessionCards keeps
 * exactly these alive as hidden ghost cards across project switches — a switch
 * back re-shows a live xterm instead of replaying the whole pty snapshot. Never
 * seeds NEW ptys: an id lands here only after its terminal actually mounted. */
export const everMountedTerminals = new Set<string>()

/** Hidden xterms kept warm for instant back-switches. Everything beyond this
 * small LRU is unmounted; its pty keeps running with disk-backed scrollback. */
export const hiddenTerminalResidentCap = (mode: 'glass' | 'eco' = 'eco') => {
  const saved = localStorage.getItem('kaisola:hidden-terminal-residents')
  const fallback = mode === 'eco' ? 0 : 1
  const n = Number(saved ?? fallback)
  return Number.isFinite(n) ? Math.min(8, Math.max(0, Math.round(n))) : fallback
}

export const touchMountedTerminal = (id: string) => {
  everMountedTerminals.delete(id)
  everMountedTerminals.add(id)
}

/** Drop a terminal id from the ever-mounted Set — call ONLY on a real terminal
 * close (store's closeTerminal reap), never on a React unmount: the Set must
 * survive tab-hide remounts, and only a genuine close should shrink it. */
export const forgetMountedTerminal = (id: string) => {
  everMountedTerminals.delete(id)
}
