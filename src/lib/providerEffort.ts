import type { ClaudeEffort, CodexEffort } from '../store/store'

/** Native wire-value guards shared by the single-session composer and Mesh so
 * both surfaces persist exactly what the provider reported — no translation. */
export const isClaudeEffort = (v: string): v is ClaudeEffort => ['default', 'low', 'medium', 'high', 'xhigh', 'max'].includes(v)
export const isCodexEffort = (v: string): v is CodexEffort => ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'].includes(v)

export type EffortOption<V extends string> = { value: V; name: string; description: string }

// Provider effort vocabularies, labelled the way each provider's own app labels
// them (not Kaisola-invented names). One home for both the single-session
// composer and the Mesh member roster so a label can never diverge between the
// two surfaces. The Swift port mirrors this list once.
export const CLAUDE_EFFORT_OPTIONS: ReadonlyArray<EffortOption<ClaudeEffort>> = [
  { value: 'default', name: 'Default', description: 'Use this Claude model’s default effort' },
  { value: 'low', name: 'Low', description: 'Fastest · minimal thinking' },
  { value: 'medium', name: 'Medium', description: 'Balanced thinking for routine work' },
  { value: 'high', name: 'High', description: 'Deep thinking' },
  { value: 'xhigh', name: 'Extra High', description: 'Best for coding and agentic work' },
  { value: 'max', name: 'Max', description: 'Maximum thinking · highest usage' },
]

export const CODEX_EFFORT_OPTIONS: ReadonlyArray<EffortOption<CodexEffort>> = [
  { value: 'low', name: 'Light', description: 'Fastest · minimal reasoning' },
  { value: 'medium', name: 'Medium', description: 'Balanced reasoning' },
  { value: 'high', name: 'High', description: 'Deep reasoning' },
  { value: 'xhigh', name: 'Extra High', description: 'More time for difficult work' },
  { value: 'ultra', name: 'Ultra', description: 'Maximum Codex reasoning · higher usage' },
]

/** Mesh fallback for a Claude adapter that reports no live effort control:
 * the same labelled options minus the provider-default sentinel. */
export const CLAUDE_MESH_EFFORT_OPTIONS = CLAUDE_EFFORT_OPTIONS.filter((option) => option.value !== 'default')
