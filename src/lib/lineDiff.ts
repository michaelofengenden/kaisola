/**
 * Minimal line diff for permission cards: old/new text → hunks of
 * kept/added/removed lines with a little context. Myers O(ND) on lines —
 * plenty for the capped payloads the cards receive (≤40KB per side).
 * The heavyweight review surface stays @codemirror/merge; this is for the
 * glanceable "what is the agent about to do" moment.
 */

export interface DiffLine {
  kind: 'ctx' | 'add' | 'del'
  text: string
}

export interface DiffHunk {
  header: string // e.g. "@@ 12 @@" — the 1-based old-file line the hunk starts at
  lines: DiffLine[]
}

/** Longest-common-subsequence table walk (lines). Falls back to whole-file
 * replace when inputs are huge — the card truncates anyway. */
function diffLines(oldText: string, newText: string): DiffLine[] {
  const a = oldText.split('\n')
  const b = newText.split('\n')
  if (a.length * b.length > 4_000_000) {
    return [
      ...a.map((text) => ({ kind: 'del' as const, text })),
      ...b.map((text) => ({ kind: 'add' as const, text })),
    ]
  }
  // LCS via dynamic programming (fine at card scale)
  const n = a.length
  const m = b.length
  const dp: Uint32Array[] = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1])
    }
  }
  const out: DiffLine[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      out.push({ kind: 'ctx', text: a[i] })
      i++
      j++
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.push({ kind: 'del', text: a[i] })
      i++
    } else {
      out.push({ kind: 'add', text: b[j] })
      j++
    }
  }
  while (i < n) out.push({ kind: 'del', text: a[i++] })
  while (j < m) out.push({ kind: 'add', text: b[j++] })
  return out
}

/** Group a raw line diff into hunks with `context` lines around changes. */
export function diffHunks(oldText: string, newText: string, context = 2, maxLines = 160): DiffHunk[] {
  const lines = diffLines(oldText, newText)
  const keep = new Array<boolean>(lines.length).fill(false)
  lines.forEach((l, idx) => {
    if (l.kind === 'ctx') return
    for (let k = Math.max(0, idx - context); k <= Math.min(lines.length - 1, idx + context); k++) keep[k] = true
  })
  const hunks: DiffHunk[] = []
  let current: DiffHunk | null = null
  let oldLine = 1
  let emitted = 0
  for (let idx = 0; idx < lines.length; idx++) {
    const l = lines[idx]
    if (keep[idx] && emitted < maxLines) {
      if (!current) {
        current = { header: `@@ ${oldLine} @@`, lines: [] }
        hunks.push(current)
      }
      current.lines.push(l)
      emitted++
    } else {
      current = null
    }
    if (l.kind !== 'add') oldLine++
  }
  return hunks
}

/** +N −M counts for a summary chip. */
export function diffStat(oldText: string, newText: string): { add: number; del: number } {
  const lines = diffLines(oldText, newText)
  return {
    add: lines.filter((l) => l.kind === 'add').length,
    del: lines.filter((l) => l.kind === 'del').length,
  }
}

/** For each NEW-text line (1-based array), the OLD-text line it survived from,
 * or null when the line was introduced in the new text. Drives turn blame. */
export function mapNewToOld(oldText: string, newText: string): (number | null)[] {
  const lines = diffLines(oldText, newText)
  const out: (number | null)[] = []
  let oldLine = 1
  for (const l of lines) {
    if (l.kind === 'ctx') {
      out.push(oldLine)
      oldLine++
    } else if (l.kind === 'add') {
      out.push(null)
    } else {
      oldLine++
    }
  }
  return out
}

/** Changed positions in NEW-text line numbers (scrollbar marks): added/changed
 * lines mark themselves; a pure deletion marks the line it happened at. */
export function changedNewLines(oldText: string, newText: string, cap = 400): { line: number; kind: 'add' | 'del' }[] {
  const lines = diffLines(oldText, newText)
  const out: { line: number; kind: 'add' | 'del' }[] = []
  let newLine = 1
  for (const l of lines) {
    if (out.length >= cap) break
    if (l.kind === 'add') {
      out.push({ line: newLine, kind: 'add' })
      newLine++
    } else if (l.kind === 'del') {
      if (!out.length || out[out.length - 1].line !== newLine) out.push({ line: Math.max(1, newLine), kind: 'del' })
    } else {
      newLine++
    }
  }
  return out
}
