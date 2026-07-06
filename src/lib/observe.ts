/**
 * The Literature agent's "observe a link" capability. You post a bare URL; the
 * agent fetches what it can and returns a normalized paper. Today this hits
 * Semantic Scholar (CORS-friendly, works in the browser and in Electron); the
 * MCP-host upgrade later swaps this for Zotero / arXiv / a browser tool behind
 * the same shape. Always resolves — a network miss still yields a minimal,
 * editable stub so the flow never dead-ends.
 */

export interface Observed {
  title: string
  authors: string[]
  org: string
  date: string
  url: string
  pdfUrl?: string
  arxivId?: string
  abstract?: string
  venue?: string
  citedBy?: number
  topics: string[]
  ok: boolean
}

import { extractDoi, lookupOpenAlex } from './openalex'

const ARXIV_RE = /arxiv\.org\/(?:abs|pdf)\/([0-9]{4}\.[0-9]{4,5})(v\d+)?/i
const ARXIV_BARE = /(?:^|\s)(\d{4}\.\d{4,5})(?:v\d+)?(?:\s|$)/

export function extractArxivId(input: string): string | null {
  const m = input.match(ARXIV_RE) ?? input.match(ARXIV_BARE)
  return m ? m[1] : null
}

function hostName(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, '')
  } catch {
    return 'link'
  }
}

function inferOrg(authorsAffil: string): string {
  const s = authorsAffil.toLowerCase()
  if (s.includes('anthropic')) return 'anthropic'
  if (s.includes('openai')) return 'openai'
  if (s.includes('deepmind') || s.includes('google')) return 'deepmind'
  return 'other'
}

export async function observe(rawUrl: string): Promise<Observed> {
  const url = rawUrl.trim()
  const arxivId = extractArxivId(url)
  const fallback: Observed = {
    title: arxivId ? `arXiv:${arxivId}` : hostName(url),
    authors: [],
    org: 'other',
    date: new Date().toISOString().slice(0, 10),
    url: url.startsWith('http') ? url : `https://${url}`,
    arxivId: arxivId ?? undefined,
    pdfUrl: arxivId ? `https://arxiv.org/pdf/${arxivId}` : undefined,
    topics: [],
    ok: false,
  }

  // OpenAlex fallback (DOI-addressed papers) when Semantic Scholar can't help.
  const doi = extractDoi(url)
  const viaOpenAlex = async (): Promise<Observed> => {
    if (!doi) return fallback
    const oa = await lookupOpenAlex(doi)
    if (!oa) return fallback
    return {
      title: oa.title,
      authors: oa.authors,
      org: inferOrg(oa.authors.join(' ')),
      date: oa.year ? `${oa.year}-01-01` : fallback.date,
      url: fallback.url,
      arxivId: arxivId ?? undefined,
      abstract: oa.abstract,
      venue: oa.venue,
      citedBy: oa.citedBy,
      topics: [],
      ok: true,
    }
  }

  const lookup = arxivId ? `arXiv:${arxivId}` : url.startsWith('http') ? `URL:${url}` : null
  if (!lookup) return viaOpenAlex()

  try {
    const fields = 'title,authors,abstract,year,venue,citationCount,externalIds,fieldsOfStudy'
    const res = await fetch(
      `https://api.semanticscholar.org/graph/v1/paper/${encodeURIComponent(lookup)}?fields=${fields}`,
      { headers: { Accept: 'application/json' } },
    )
    if (!res.ok) return viaOpenAlex()
    const d = (await res.json()) as {
      title?: string
      authors?: { name: string }[]
      abstract?: string
      year?: number
      venue?: string
      citationCount?: number
      externalIds?: { ArXiv?: string; DOI?: string }
      fieldsOfStudy?: string[]
    }
    const authors = (d.authors ?? []).map((a) => a.name)
    const ax = d.externalIds?.ArXiv ?? arxivId ?? undefined
    return {
      title: d.title ?? fallback.title,
      authors,
      org: inferOrg(authors.join(' ')),
      date: d.year ? `${d.year}-01-01` : fallback.date,
      url: fallback.url,
      pdfUrl: ax ? `https://arxiv.org/pdf/${ax}` : undefined,
      arxivId: ax,
      abstract: d.abstract ?? undefined,
      venue: d.venue || undefined,
      citedBy: d.citationCount,
      topics: (d.fieldsOfStudy ?? []).slice(0, 3),
      ok: true,
    }
  } catch {
    return viaOpenAlex()
  }
}
