interface TerminalRow {
  id?: string
}

interface AgentTerminalRow {
  terminalId?: string
}

interface TerminalProjectSlice {
  terminals?: readonly TerminalRow[]
  agentTerminals?: readonly AgentTerminalRow[]
}

export interface TerminalPopState extends TerminalProjectSlice {
  projectSlices?: Record<string, TerminalProjectSlice | undefined>
}

/**
 * A user-owned terminal can transfer its one broker owner to a pop-out window.
 * ACP-created terminals cannot: the ACP connection must retain exclusive
 * output/wait/kill/release authority for the duration of its tool call.
 * Unknown ids fail closed so a stale menu or extension cannot bypass the UI.
 */
export function canPopOutTerminal(state: TerminalPopState, id: string): boolean {
  const slices: TerminalProjectSlice[] = [state, ...Object.values(state.projectSlices ?? {}).filter((slice): slice is TerminalProjectSlice => !!slice)]
  if (slices.some((slice) => slice.agentTerminals?.some((terminal) => terminal.terminalId === id))) return false
  return slices.some((slice) => slice.terminals?.some((terminal) => terminal.id === id))
}
