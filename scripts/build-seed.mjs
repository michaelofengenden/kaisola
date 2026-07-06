// Transform the existing 2898-paper tracker dataset into a focused corpus subset
// for Kaisola's flagship demo project: "Time-awareness in LLM agents".
//
//   node scripts/build-seed.mjs
//
// Reads ResearchPubs/data/papers.json (the old static tracker) and writes
// src/data/corpus.seed.json — a curated ~50-paper corpus mapped to Kaisola's
// Paper type. The hand-authored trajectory (questions/ideas/experiment/runs/
// draft/reviews) lives in src/data/seed.ts and references these by id.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, '..')

const RAW = join(root, 'ResearchPubs', 'data', 'papers.json')
const OUT = join(root, 'src', 'data', 'corpus.seed.json')

const { papers } = JSON.parse(readFileSync(RAW, 'utf8'))

// Relevance to the demo project: agentic behaviour, evaluation/benchmarks,
// reasoning, and anything touching time / deadlines / latency / tool use.
const TOPICS = new Set(['Agents', 'Evaluations'])
const AGENTIC = /\b(agent|agentic|tool[- ]?use|tool use|benchmark|swe-?bench|webarena|osworld|agentbench|long[- ]?horizon|planning)\b/i
const TIME = /\b(deadline|wall[- ]?clock|elapsed|latency|time-?aware|temporal|budget(ed)?|horizon|time)\b/i

function score(p) {
  const text = `${p.title} ${p.abstract || ''} ${p.summary || ''}`
  let s = 0
  // must be topically agentic/eval to count at all
  const topical = (p.topics || []).some((t) => TOPICS.has(t))
  if (topical) s += 2
  if (AGENTIC.test(text)) s += 4
  if (AGENTIC.test(p.title || '')) s += 3 // agentic framing in the title itself
  // the heart of the demo: time / deadline / latency / budget
  if (TIME.test(text)) s += 5
  if (TIME.test(p.title || '')) s += 3
  if (p.cited_by) s += Math.min(2, Math.log10(p.cited_by + 1)) // mild recency/impact nudge
  // require at least one real signal beyond citations
  if (!topical && !AGENTIC.test(text) && !TIME.test(text)) return 0
  return s
}

const mapPaper = (p) => ({
  id: `pap_${p.id}`,
  kind: 'paper',
  title: p.title,
  authors: p.authors || [],
  org: p.org || 'other',
  date: p.date,
  url: p.url,
  pdfUrl: p.pdf_url,
  arxivId: p.arxiv_id,
  abstract: p.abstract,
  summary: p.summary,
  topics: p.topics || [],
  venue: p.venue,
  citedBy: p.cited_by,
  addedAt: '2026-06-09T09:00:00Z',
  tags: [],
  extracted: false,
})

const ranked = papers
  .filter((p) => p.title && p.date)
  .map((p) => ({ p, s: score(p) }))
  .filter((x) => x.s >= 9)
  .sort((a, b) => b.s - a.s)
  .slice(0, 50)
  .map((x) => mapPaper(x.p))

mkdirSync(dirname(OUT), { recursive: true })
writeFileSync(OUT, JSON.stringify(ranked, null, 2))
console.log(`Wrote ${ranked.length} papers → ${OUT}`)
console.log('Top 6:')
ranked.slice(0, 6).forEach((p) => console.log(`  · ${p.title.slice(0, 78)}`))
