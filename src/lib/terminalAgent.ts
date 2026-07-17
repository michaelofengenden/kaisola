/**
 * CLI agents that can be recognized from a terminal's foreground process.
 * Keep this as data, not scattered regular expressions: terminal promotion,
 * draft tracking, labels, and restart behavior all consume the same profile.
 */
export interface TerminalCliProfile {
  id: string
  name: string
  commands: readonly string[]
  /** Compatibility prefix used by durable sessions created before generic CLI
   * identities were introduced. New agents use the scoped `::cli:` form. */
  singletonPrefix?: string
  /** Safe best-effort continuation used only for a CLI started by hand. */
  resume?: string
}

export const TERMINAL_CLI_PROFILES: readonly TerminalCliProfile[] = [
  { id: 'claude-code', name: 'Claude', commands: ['claude'], singletonPrefix: 'claude-cli', resume: 'claude --continue' },
  { id: 'codex', name: 'Codex', commands: ['codex'], singletonPrefix: 'codex-cli', resume: 'codex resume --last' },
  // OpenCode's mini renderer is designed for compact/embedded terminals and
  // avoids replaying an unbounded TUI history whenever a small card reflows.
  { id: 'opencode', name: 'OpenCode', commands: ['opencode'], resume: 'opencode --continue --mini --replay-limit 60' },
  { id: 'kimi', name: 'Kimi', commands: ['kimi'], resume: 'kimi --continue' },
  { id: 'gemini', name: 'Gemini', commands: ['gemini'] },
  { id: 'qwen', name: 'Qwen Code', commands: ['qwen'] },
  { id: 'amp', name: 'Amp', commands: ['amp'] },
  { id: 'aider', name: 'Aider', commands: ['aider'] },
  { id: 'goose', name: 'Goose', commands: ['goose'] },
  { id: 'crush', name: 'Crush', commands: ['crush'] },
] as const

const processCommand = (value?: string | null): string => {
  const leaf = String(value || '').trim().split('/').pop() ?? ''
  return leaf.replace(/^-/, '').split(/\s+/)[0].toLowerCase()
}

export function terminalCliProfileForProcess(value?: string | null): TerminalCliProfile | undefined {
  const command = processCommand(value)
  return command ? TERMINAL_CLI_PROFILES.find((profile) => profile.commands.includes(command)) : undefined
}

export function terminalCliProfileById(id?: string | null): TerminalCliProfile | undefined {
  return id ? TERMINAL_CLI_PROFILES.find((profile) => profile.id === id) : undefined
}

export function terminalCliSingletonKey(profile: TerminalCliProfile, terminalId: string): string {
  return profile.singletonPrefix
    ? `agent:${profile.singletonPrefix}-${terminalId}`
    : `agent:${profile.id}::cli:${terminalId}`
}

export function isTransientTerminalCliKey(value?: string | null): boolean {
  if (!value?.startsWith('agent:')) return false
  if (value.includes('::cli:')) return true
  return TERMINAL_CLI_PROFILES.some((profile) => profile.singletonPrefix && value.startsWith(`agent:${profile.singletonPrefix}-`))
}

/** A deterministic 3–4-word topic from the first submitted prompt. */
export function terminalPromptTitle(text: string, maxWords = 4): string | undefined {
  const cleaned = text
    .replace(/(?:https?:\/\/|file:\/\/)\S+/gi, 'link')
    .replace(/[`*_#>()[\]{}]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  if (!cleaned) return undefined
  const words = cleaned.split(' ').filter(Boolean).slice(0, Math.max(3, maxWords))
  const title = words.join(' ').replace(/[.,;:!?-]+$/, '')
  if (!title) return undefined
  return title.charAt(0).toUpperCase() + title.slice(1)
}
