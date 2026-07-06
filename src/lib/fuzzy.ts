/**
 * Subsequence fuzzy matching for the command palette and the ⌘P file finder.
 * Zed/VS Code-style: every query char must appear in order; scoring prefers
 * word-boundary and camelCase hits, consecutive runs, and matches near the
 * end of a path (the filename). Returns matched indices for highlighting.
 */

export interface FuzzyHit {
  score: number
  /** Indices into the candidate string that matched (for highlighting). */
  indices: number[]
}

const BOUNDARY = new Set(['/', '\\', '-', '_', '.', ' '])

/** Match `query` against `text`; null when it isn't a subsequence. */
export function fuzzyMatch(query: string, text: string): FuzzyHit | null {
  const q = query.toLowerCase()
  const t = text.toLowerCase()
  if (!q) return { score: 0, indices: [] }
  if (q.length > t.length) return null

  // Greedy left-to-right pass with a per-char bonus; good enough in practice
  // and O(n) — the palette rescans thousands of paths per keystroke.
  const indices: number[] = []
  let score = 0
  let ti = 0
  let streak = 0
  for (let qi = 0; qi < q.length; qi++) {
    const c = q[qi]
    let found = -1
    for (let i = ti; i < t.length; i++) {
      if (t[i] === c) { found = i; break }
    }
    if (found < 0) return null
    const prev = found > 0 ? text[found - 1] : ''
    const boundary = found === 0 || BOUNDARY.has(prev)
    const camel = prev !== '' && prev === prev.toLowerCase() && text[found] === text[found].toUpperCase() && /[a-z]/i.test(prev)
    streak = indices.length && found === indices[indices.length - 1] + 1 ? streak + 1 : 0
    score += 1 + (boundary ? 8 : 0) + (camel ? 6 : 0) + streak * 4 - Math.min(found - ti, 20) * 0.15
    indices.push(found)
    ti = found + 1
  }
  // filename affinity: matches clustered after the last '/' are worth more
  const lastSlash = text.lastIndexOf('/')
  if (lastSlash >= 0) {
    const inName = indices.filter((i) => i > lastSlash).length
    score += inName * 3
    if (indices[0] > lastSlash) score += 10 // the whole match lives in the filename
  }
  // shorter candidates win ties
  score -= text.length * 0.01
  return { score, indices }
}

export interface RankedItem<T> {
  item: T
  hit: FuzzyHit
}

/** Rank `items` by fuzzy score against `query`; drops non-matches, caps output. */
export function fuzzyRank<T>(
  query: string,
  items: T[],
  textOf: (item: T) => string,
  limit = 50,
): RankedItem<T>[] {
  const out: RankedItem<T>[] = []
  for (const item of items) {
    const hit = fuzzyMatch(query, textOf(item))
    if (hit) out.push({ item, hit })
  }
  out.sort((a, b) => b.hit.score - a.hit.score)
  return out.slice(0, limit)
}

/** Split `text` into plain/highlighted runs from matched indices. */
export function highlightRuns(text: string, indices: number[]): { text: string; hit: boolean }[] {
  if (!indices.length) return [{ text, hit: false }]
  const set = new Set(indices)
  const runs: { text: string; hit: boolean }[] = []
  let cur = ''
  let curHit = set.has(0)
  for (let i = 0; i < text.length; i++) {
    const hit = set.has(i)
    if (hit === curHit) cur += text[i]
    else {
      if (cur) runs.push({ text: cur, hit: curHit })
      cur = text[i]
      curHit = hit
    }
  }
  if (cur) runs.push({ text: cur, hit: curHit })
  return runs
}
