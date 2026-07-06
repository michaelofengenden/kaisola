/**
 * Stable identity hues for sessions. Agents map to fixed tokens (the Claude
 * terminal owns the app accent); plain shells hash their REPO ROOT (fallback
 * cwd), so two terminals in the same tree share a stripe — the color means
 * "same folder", not "different tab". Saturation stays low: a whisper, not a
 * painted header.
 */

const AGENT_HUES: Record<string, string> = {
  'claude-code': 'var(--accent)',
  codex: 'var(--info)',
  opencode: 'var(--agent-planning)',
  mock: 'var(--text-3)',
}

/** djb2 — tiny, stable, good spread for short path strings. */
function hash(s: string): number {
  let h = 5381
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0
  return h
}

export function folderHue(folder: string): string {
  let h = hash(folder) % 360
  // keep clear of the accent's olive band so agent identity stays unmistakable
  if (h >= 55 && h <= 100) h = (h + 55) % 360
  return `hsl(${h} 42% 55%)`
}

/** The one entry point: agent identity wins; folders otherwise; calm gray fallback. */
export function sessionHue(opts: { agentKey?: string | null; folder?: string | null }): string {
  if (opts.agentKey && AGENT_HUES[opts.agentKey]) return AGENT_HUES[opts.agentKey]
  if (opts.agentKey) return folderHue(opts.agentKey) // unknown agents still get a stable hue
  if (opts.folder) return folderHue(opts.folder)
  return 'var(--border-strong)'
}

/** Agent key for a terminal record (singletonKey 'agent:<id>' convention). */
export function terminalAgentKey(singletonKey?: string): string | undefined {
  return singletonKey?.startsWith('agent:') ? singletonKey.slice('agent:'.length) : undefined
}
