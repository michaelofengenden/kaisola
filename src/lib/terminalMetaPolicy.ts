interface TerminalMetaPatch {
  fgProcess?: string | null
}

interface TerminalRow {
  id: string
  singletonKey?: string
  restart?: boolean
  boot?: string
  name?: string
}

/** Promote a manually launched CLI into a restartable session row. Kept pure
 * so the same rule works for the active project and parked project slices. */
export function terminalsAfterMeta<T extends TerminalRow>(terminals: T[], id: string, patch: TerminalMetaPatch): T[] {
  if (!Object.prototype.hasOwnProperty.call(patch, 'fgProcess')) return terminals
  const terminal = terminals.find((entry) => entry.id === id)
  const fg = String(patch.fgProcess || '')
  const isLogin = /\/login\b/.test(terminal?.boot ?? '')
  const replace = (next: Partial<T>) => terminals.map((entry) => entry.id === id ? { ...entry, ...next } : entry)
  if (terminal && !terminal.singletonKey && !isLogin && /^claude\b/.test(fg)) {
    return replace({ singletonKey: `agent:claude-cli-${id}`, restart: true, boot: 'claude --continue', name: terminal.name ?? 'Claude' } as Partial<T>)
  }
  if (terminal?.singletonKey?.startsWith('agent:claude-cli-') && /^-?(zsh|bash|fish|sh)$/.test(fg)) {
    return replace({ singletonKey: undefined, restart: undefined, boot: undefined } as Partial<T>)
  }
  if (terminal && !terminal.singletonKey && !isLogin && /^codex\b/.test(fg)) {
    return replace({ singletonKey: `agent:codex-cli-${id}`, restart: true, boot: 'codex resume --last', name: terminal.name ?? 'Codex' } as Partial<T>)
  }
  if (terminal?.singletonKey?.startsWith('agent:codex') && /^codex\b/.test(fg) && (!terminal.restart || !/^codex resume\b/.test(terminal.boot ?? ''))) {
    return replace({ restart: true, boot: 'codex resume --last' } as Partial<T>)
  }
  if (terminal?.singletonKey?.startsWith('agent:codex-cli-') && /^-?(zsh|bash|fish|sh)$/.test(fg)) {
    return replace({ singletonKey: undefined, restart: undefined, boot: undefined } as Partial<T>)
  }
  return terminals
}
