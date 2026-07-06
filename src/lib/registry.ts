import { useEffect, useState } from 'react'
import { useKaisola } from '../store/store'
import { bridge, type AcpPreset } from './bridge'

/**
 * The agent registry (Zed's agent_servers pattern): built-in presets from the
 * main process merged with agents the user added in Settings. `menu` is what
 * the + menu shows — enabled built-ins plus every custom agent; `all` is the
 * full catalog for the Settings registry.
 */
export interface RegistryAgent {
  id: string
  name: string
  /** How a session opens: an ACP chat thread or the CLI in a real terminal. */
  kind: 'acp' | 'terminal'
  terminalCommand?: string
  /** ACP customs: the exact command Kaisola spawns to speak ACP over stdio. */
  command?: string
  args?: string[]
  login?: string
  deviceLogin?: { command: string; args: string[] }
  installCmd?: string
  docs?: string
  custom?: boolean
}

// presets are static per app run — fetch once, share across every consumer
let presetCache: AcpPreset[] | null = null

export function useAgentRegistry(): { all: RegistryAgent[]; menu: RegistryAgent[] } {
  const customAgents = useKaisola((s) => s.customAgents)
  const enabledAgents = useKaisola((s) => s.enabledAgents)
  const [presets, setPresets] = useState<AcpPreset[]>(presetCache ?? [])
  useEffect(() => {
    if (presetCache) return
    void bridge.acp.presets().then((p) => {
      presetCache = p
      setPresets(p)
    })
  }, [])
  const builtins: RegistryAgent[] = presets
    .filter((p) => !p.hidden)
    .map((p) => ({
      id: p.id,
      name: p.name,
      kind: p.terminalOnly ? 'terminal' : 'acp',
      terminalCommand: p.terminalCommand,
      login: p.login,
      deviceLogin: p.deviceLogin,
      installCmd: p.installCmd,
      docs: p.docs,
    }))
  const customs: RegistryAgent[] = customAgents.map((a) => ({
    id: a.id,
    name: a.name,
    kind: a.kind,
    custom: true,
    command: a.command,
    args: a.args,
    terminalCommand: a.kind === 'terminal' ? [a.command, ...a.args].join(' ').trim() : undefined,
  }))
  return {
    all: [...builtins, ...customs],
    menu: [...builtins.filter((b) => enabledAgents.includes(b.id)), ...customs],
  }
}

/** Display name for a session's agent key, across built-ins and customs. */
export function agentName(agents: RegistryAgent[], key?: string): string | undefined {
  return key ? agents.find((a) => a.id === key)?.name : undefined
}

/** Open a session for a registry agent (terminal CLI or ACP chat thread). */
export function openAgentSession(agent: RegistryAgent) {
  const s = useKaisola.getState()
  if (agent.kind === 'terminal') {
    if (!agent.terminalCommand) return
    s.requestTerminal(agent.terminalCommand, {
      cwd: s.workspacePath ?? undefined,
      name: agent.name,
      singletonKey: `agent:${agent.id}`,
      restart: true,
    })
  } else {
    s.requestNewThread(agent.id)
  }
}
