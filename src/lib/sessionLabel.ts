import { agentName, type RegistryAgent } from './registry'
import { terminalAgentKey } from './sessionHue'
import type { AssistantThread, TerminalMeta, TerminalSession } from '../store/store'

/** Host of a URL for a compact browser-card label, or undefined if unparseable. */
export const urlHost = (u?: string) => {
  try {
    return u ? new URL(u).host : undefined
  } catch {
    return undefined
  }
}

/**
 * A terminal's display name — stable identity, never keystrokes: manual name →
 * agent → autoName → repo → folder → `Terminal N`. The agent name wins over
 * autoName because agent terminals are always spawned WITH a boot command (so
 * they always have an autoName); putting agent first keeps a de-named Claude
 * terminal reading "Claude", not its raw "claude --settings…" boot line. Call
 * sites pass whatever context they already have (meta/agents/index/count);
 * missing pieces just drop out of the chain, so every surface names the same
 * terminal the same way.
 */
export function terminalLabel(
  t: TerminalSession,
  opts?: { meta?: TerminalMeta; agents?: RegistryAgent[]; index?: number; count?: number },
): string {
  const agentKey = terminalAgentKey(t.singletonKey)
  const folder = opts?.meta?.repo ?? (opts?.meta?.cwd ?? t.cwd)?.split('/').filter(Boolean).pop()
  return (
    t.name ??
    (agentKey ? agentName(opts?.agents ?? [], agentKey) ?? agentKey : undefined) ??
    t.autoName ??
    folder ??
    ((opts?.count ?? 1) > 1 ? `Terminal ${(opts?.index ?? 0) + 1}` : 'Terminal')
  )
}

/**
 * An assistant thread's display name: manual name → autoName → the agent's
 * name, numbered (`Agent 2`) only when several threads share one agent.
 */
export function threadLabel(
  t: AssistantThread,
  agents: RegistryAgent[],
  threads: AssistantThread[],
  index: number,
): string {
  const nm = agentName(agents, t.agentKey) ?? 'Agent'
  return t.name ?? t.autoName ?? `${nm}${threads.filter((x) => x.agentKey === t.agentKey).length > 1 ? ` ${index + 1}` : ''}`
}
