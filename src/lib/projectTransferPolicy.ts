const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}

const select = (value: unknown, keep: (key: string) => boolean) =>
  Object.fromEntries(Object.entries(record(value)).filter(([key]) => keep(key)))

/** Project moves may carry global preferences, but prompt/file/session maps
 * must be reduced to the project being moved before crossing a window. */
export function scopeProjectTransferGlobals(
  globals: Record<string, unknown>,
  workspacePath: string | null,
  terminalIds: readonly string[],
): Record<string, unknown> {
  const ids = new Set(terminalIds)
  const inWorkspace = (key: string) => !!workspacePath && (key === workspacePath || key.startsWith(`${workspacePath}/`))
  return {
    ...globals,
    termDrafts: select(globals.termDrafts, (key) => ids.has(key)),
    unsavedBuffers: select(globals.unsavedBuffers, inWorkspace),
    claudeSessions: select(globals.claudeSessions, (key) => key === workspacePath),
    latexMain: select(globals.latexMain, (key) => key === workspacePath),
  }
}

/** Never silently overwrite newer unsent content already present in a target
 * window. The renderer rejects the transfer and the source keeps its project. */
export function projectTransferDataConflict(current: Record<string, unknown>, incoming: Record<string, unknown> | undefined): boolean {
  if (!incoming) return false
  for (const key of ['termDrafts', 'unsavedBuffers']) {
    const have = record(current[key])
    const next = record(incoming[key])
    for (const [id, value] of Object.entries(next)) {
      if (Object.prototype.hasOwnProperty.call(have, id) && have[id] !== value) return true
    }
  }
  return false
}
