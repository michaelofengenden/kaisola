/**
 * Relevance ranking — the Aider repo-map idea applied to the research substrate.
 *
 * Instead of dumping the whole project at an agent, we PageRank the claim graph
 * for structural importance, blend in lexical relevance to the current research
 * question/stage and a trust bonus, then fit the most relevant slice into a
 * fixed character budget. Pure + deterministic — no model, no network.
 */
import type { Project, GraphNode, ClaimGraph, TrajectoryStage, Paper } from '../domain/types'

const STOP = new Set([
  'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'with', 'is',
  'are', 'be', 'do', 'does', 'how', 'what', 'why', 'can', 'this', 'that', 'from',
])

export function tokenize(text: string): string[] {
  return (text.toLowerCase().match(/[a-z0-9]+/g) ?? []).filter((t) => t.length > 2 && !STOP.has(t))
}

/**
 * PageRank over the claim graph (edges treated as directed source→target).
 * Dangling nodes redistribute their mass uniformly. Returns id → score.
 */
export function pagerank(graph: ClaimGraph, opts?: { damping?: number; iters?: number }): Record<string, number> {
  const d = opts?.damping ?? 0.85
  const iters = opts?.iters ?? 40
  const nodes = graph.nodes.map((n) => n.id)
  const N = nodes.length
  if (N === 0) return {}
  const idx = new Map(nodes.map((id, i) => [id, i]))
  const out: number[][] = nodes.map(() => [])
  const outDeg = new Array(N).fill(0)
  for (const e of graph.edges) {
    const s = idx.get(e.source)
    const t = idx.get(e.target)
    if (s == null || t == null) continue
    out[s].push(t)
    outDeg[s]++
  }
  let rank = new Array(N).fill(1 / N)
  for (let it = 0; it < iters; it++) {
    let dangling = 0
    for (let i = 0; i < N; i++) if (outDeg[i] === 0) dangling += rank[i]
    const next = new Array(N).fill((1 - d) / N + (d * dangling) / N)
    for (let i = 0; i < N; i++) {
      if (outDeg[i] === 0) continue
      const share = (d * rank[i]) / outDeg[i]
      for (const t of out[i]) next[t] += share
    }
    rank = next
  }
  const res: Record<string, number> = {}
  nodes.forEach((id, i) => (res[id] = rank[i]))
  return res
}

export interface RankedNode {
  node: GraphNode
  score: number
}

/**
 * Rank claim-graph nodes by importance (PageRank) blended with lexical
 * relevance to a query and a small trust bonus. Highest first.
 */
export function rankNodes(graph: ClaimGraph, query: string): RankedNode[] {
  const pr = pagerank(graph)
  const prValues = Object.values(pr)
  const maxPr = prValues.length ? Math.max(...prValues) : 1
  const terms = tokenize(query)
  return graph.nodes
    .map((node) => {
      const prN = maxPr > 0 ? (pr[node.id] ?? 0) / maxPr : 0
      const text = `${node.label} ${node.detail ?? ''}`.toLowerCase()
      const lex = terms.length ? terms.filter((t) => text.includes(t)).length / terms.length : 0
      const trustBonus = node.trust === 'high' ? 0.15 : node.trust === 'medium' ? 0.08 : 0
      return { node, score: 0.5 * prN + 0.4 * lex + trustBonus }
    })
    .sort((a, b) => b.score - a.score)
}

/**
 * Rank corpus papers by a blend of global citation count, lexical relevance, and
 * in-corpus centrality (how many other corpus papers cite this one, via the
 * OpenAlex-built `references` graph). Centrality is 0 until the citation graph is built.
 */
export function rankPapers(papers: Paper[], query: string): Paper[] {
  const terms = tokenize(query)
  const maxCites = Math.max(1, ...papers.map((p) => p.citedBy ?? 0))
  const inDeg: Record<string, number> = {}
  for (const p of papers) for (const ref of p.references ?? []) inDeg[ref] = (inDeg[ref] ?? 0) + 1
  const maxDeg = Math.max(1, ...Object.values(inDeg))
  return [...papers].sort((a, b) => paperScore(b) - paperScore(a))
  function paperScore(p: Paper): number {
    const cite = (p.citedBy ?? 0) / maxCites
    const central = (inDeg[p.id] ?? 0) / maxDeg
    const text = `${p.title} ${p.abstract ?? ''} ${p.topics.join(' ')}`.toLowerCase()
    const lex = terms.length ? terms.filter((t) => text.includes(t)).length / terms.length : 0
    return 0.4 * cite + 0.4 * lex + 0.2 * central
  }
}

/**
 * Build a compact, relevance-ranked context string for an agent, fit into a
 * character budget. This is what grounds every agent prompt — the top papers,
 * the most relevant claims, the open questions and the selected hypothesis,
 * ranked, not dumped.
 */
export function buildAgentContext(project: Project, stage: TrajectoryStage, budgetChars = 2400): string {
  const q = project.question || ''
  const focus = `${q} ${stage}`
  const lines: string[] = [`# Research project: ${project.name || 'Untitled'}`]
  if (q) lines.push(`Headline question: ${q}`)
  lines.push(`Current stage: ${stage}`)

  const papers = project.corpus.filter((s): s is Paper => s.kind === 'paper')
  if (papers.length) {
    lines.push('\n## Corpus (most relevant)')
    rankPapers(papers, focus).slice(0, 8).forEach((p) =>
      lines.push(`- ${p.title}${p.citedBy ? ` (${p.citedBy} cites)` : ''}${p.org && p.org !== 'other' ? ` · ${p.org}` : ''}`),
    )
  }

  const ranked = rankNodes(project.claimGraph, focus).slice(0, 10)
  if (ranked.length) {
    lines.push('\n## Most relevant claims & knowledge')
    ranked.forEach(({ node }) =>
      lines.push(`- [${node.type}] ${node.label}${node.detail ? ` — ${node.detail}` : ''} (trust: ${node.trust})`),
    )
  }

  const openQs = project.questions.filter((x) => x.status === 'open' || x.status === 'in-progress')
  if (openQs.length) {
    lines.push('\n## Open questions')
    openQs.slice(0, 6).forEach((x) => lines.push(`- ${x.label}`))
  }

  const selected = project.hypotheses.find((h) => h.status === 'selected') ?? project.hypotheses[0]
  if (selected) {
    lines.push('\n## Working hypothesis')
    lines.push(`- ${selected.title}: ${selected.claim}`)
  }

  let out = lines.join('\n')
  if (out.length > budgetChars) out = `${out.slice(0, budgetChars - 1)}…`
  return out
}
