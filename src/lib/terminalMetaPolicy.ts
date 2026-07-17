import { isTransientTerminalCliKey, terminalCliProfileForProcess, terminalCliSingletonKey } from './terminalAgent.ts'

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
  const profile = terminalCliProfileForProcess(fg)
  if (terminal && !terminal.singletonKey && !isLogin && profile) {
    return replace({
      singletonKey: terminalCliSingletonKey(profile, id),
      restart: profile.resume ? true : undefined,
      boot: profile.resume,
      name: terminal.name ?? profile.name,
    } as Partial<T>)
  }
  const promotedCodex = terminal?.singletonKey?.startsWith('agent:codex')
  if (terminal && promotedCodex && /^codex\b/.test(fg) && (!terminal.restart || !/^codex resume\b/.test(terminal.boot ?? ''))) {
    return replace({ restart: true, boot: 'codex resume --last' } as Partial<T>)
  }
  if (isTransientTerminalCliKey(terminal?.singletonKey) && /^-?(zsh|bash|fish|sh)$/.test(fg)) {
    return replace({ singletonKey: undefined, restart: undefined, boot: undefined } as Partial<T>)
  }
  return terminals
}
