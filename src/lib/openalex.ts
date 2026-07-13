/**
 * OpenAlex (CC0) as a second literature source behind Semantic Scholar — useful
 * for DOI-addressed papers and the citation graph (`cited_by_count`). Best-effort
 * and graceful: any failure returns null and the caller falls back.
 *
 * The two parsing helpers are pure + deterministic (and unit-tested in the
 * smoke): DOI extraction and reconstructing OpenAlex's abstract, which it serves
 * as an inverted index (`{ word: [positions] }`) rather than plain text.
 *
 * ⚠️ OpenAlex's access terms now mention a required key + a daily free credit —
 * confirm current terms before relying on this in production (see docs/UPGRADE.md).
 */

const DOI_RE = /\b(10\.\d{4,9}\/[-._;()/:a-z0-9]+)/i

/** Pull a bare DOI out of a URL or string (e.g. doi.org/10.1145/… → 10.1145/…). */
export function extractDoi(input: string): string | null {
  const m = input.match(DOI_RE)
  return m ? m[1].replace(/[).]+$/, '') : null
}

/** Reconstruct plain-text from OpenAlex's abstract_inverted_index. */
export function reconstructAbstract(inverted: Record<string, number[]> | null | undefined): string {
  if (!inverted) return ''
  const slots: string[] = []
  for (const [word, positions] of Object.entries(inverted)) {
    for (const pos of positions) slots[pos] = word
  }
  return slots.filter((w) => w !== undefined).join(' ').replace(/\s+/g, ' ').trim()
}

export interface OpenAlexResult {
  title: string
  authors: string[]
  abstract?: string
  year?: number
  venue?: string
  citedBy?: number
  doi?: string
  /** Normalized OpenAlex id, e.g. "W2741809807". */
  openAlexId?: string
  /** Raw OpenAlex ids of the works this paper cites (referenced_works). */
  referencedWorks?: string[]
  ok: true
}

interface OpenAlexWork {
  id?: string
  title?: string
  display_name?: string
  publication_year?: number
  cited_by_count?: number
  abstract_inverted_index?: Record<string, number[]>
  authorships?: { author?: { display_name?: string } }[]
  primary_location?: { source?: { display_name?: string } }
  referenced_works?: string[]
  doi?: string
}

/** Normalize an OpenAlex id/URL ("https://openalex.org/W123" | "W123") → "W123". */
export function normalizeOaId(id: string): string {
  const m = id.match(/W\d+/i)
  return m ? m[0].toUpperCase() : id
}

/**
 * Pure: map a work's referenced_works (raw OA ids) to corpus paper ids, using a
 * normalized OA-id → paper-id index. Deterministic; the heart of the citation
 * graph and verified offline.
 */
export function resolveReferences(referencedWorks: string[], oaIdToPaperId: Record<string, string>): string[] {
  const out = new Set<string>()
  for (const w of referencedWorks) {
    const pid = oaIdToPaperId[normalizeOaId(w)]
    if (pid) out.add(pid)
  }
  return [...out]
}

const mailtoParam = (mailto?: string) => (mailto ? `&mailto=${encodeURIComponent(mailto)}` : '')

/** Look a paper up in OpenAlex by DOI. Network — resolves null on any failure. */
export async function lookupOpenAlex(doi: string, mailto?: string): Promise<OpenAlexResult | null> {
  return fetchWork(`https://api.openalex.org/works/https://doi.org/${encodeURIComponent(doi)}?select=id,title,display_name,publication_year,cited_by_count,abstract_inverted_index,authorships,primary_location,referenced_works,doi${mailtoParam(mailto)}`)
}

/** Look a paper up by arXiv id (OpenAlex indexes arXiv as a DOI 10.48550/arXiv.<id>). */
export async function lookupOpenAlexByArxiv(arxivId: string, mailto?: string): Promise<OpenAlexResult | null> {
  return lookupOpenAlex(`10.48550/arXiv.${arxivId}`, mailto)
}

async function fetchWork(url: string): Promise<OpenAlexResult | null> {
  try {
    const res = await fetch(url, { headers: { Accept: 'application/json' } })
    if (!res.ok) return null
    const w = (await res.json()) as OpenAlexWork
    const title = w.title || w.display_name
    if (!title) return null
    return {
      title,
      authors: (w.authorships ?? []).flatMap((authorship) => {
        const name = authorship.author?.display_name
        return name ? [name] : []
      }),
      abstract: reconstructAbstract(w.abstract_inverted_index) || undefined,
      year: w.publication_year,
      venue: w.primary_location?.source?.display_name,
      citedBy: w.cited_by_count,
      doi: w.doi,
      openAlexId: w.id ? normalizeOaId(w.id) : undefined,
      referencedWorks: w.referenced_works,
      ok: true,
    }
  } catch {
    return null
  }
}
