/**
 * Agent-turn blame: attribute each line of a file to the CHECKPOINT TURN that
 * introduced it — "Claude: fix the parser · 12m ago" on the current line.
 * Works by walking the file's versions at each checkpoint (shadow git) from
 * newest to oldest with line-survival maps; no git history chain needed
 * (checkpoint commits are parentless snapshots).
 */
import { bridge } from './bridge'
import { mapNewToOld } from './lineDiff'
import type { RepoCheckpoint } from '../store/store'

const MAX_TURNS = 10
const MAX_LINES = 3000

/** sha:path → file content at that snapshot (immutable, cache forever). */
const versionCache = new Map<string, Promise<string>>()

function versionAt(workspace: string, sha: string, path: string): Promise<string> {
  const key = `${sha}:${path}`
  let hit = versionCache.get(key)
  if (!hit) {
    hit = bridge.git.show(workspace, sha, path).then((r) => (r.ok ? r.content ?? '' : ''))
    versionCache.set(key, hit)
    if (versionCache.size > 300) versionCache.delete(versionCache.keys().next().value as string)
  }
  return hit
}

export interface BlameLine {
  label: string
  at?: string
}

/**
 * Per-line attribution for `text` (1-based index into the result array).
 * `null` entries = the line predates all known checkpoints (quiet — no note).
 */
export async function computeTurnBlame(
  workspace: string,
  path: string,
  text: string,
  checkpoints: RepoCheckpoint[], // newest first
): Promise<(BlameLine | null)[] | null> {
  const turns = checkpoints.slice(0, MAX_TURNS)
  const lineCount = text.split('\n').length
  if (!turns.length || lineCount > MAX_LINES) return null

  const versions = await Promise.all(turns.map((c) => versionAt(workspace, c.sha, path)))
  const lines: (BlameLine | null)[] = new Array(lineCount).fill(null)
  // current line number (1-based) → line number in the version being examined
  let carry: (number | null)[] = Array.from({ length: lineCount }, (_, i) => i + 1)

  // newest checkpoint first: lines NOT surviving into it were written since it
  let prevText = text
  for (let vi = 0; vi < versions.length; vi++) {
    const map = mapNewToOld(versions[vi], prevText) // prev-line → version-line
    const next: (number | null)[] = new Array(lineCount).fill(null)
    for (let i = 0; i < lineCount; i++) {
      const inPrev = carry[i]
      if (inPrev == null) continue // already attributed
      const inVersion = map[inPrev - 1] ?? null
      if (inVersion == null) {
        // absent at this snapshot → written AFTER it. Snapshots are taken at
        // each turn's PROMPT, so the introducer is the turn that snapshot
        // belongs to (turns[vi]) — for vi=0 that's the latest turn (or the
        // user's own edits since it; same era, honest enough).
        lines[i] = { label: turns[vi].label, at: turns[vi].at }
      } else {
        next[i] = inVersion
      }
    }
    carry = next
    prevText = versions[vi]
  }
  // survivors of the oldest known snapshot stay null → no note (quiet)
  return lines
}
