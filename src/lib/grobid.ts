/**
 * GROBID TEI parsing — the moat upgrade: a PDF becomes structured full text with
 * per-sentence PDF coordinates, so a citation's quote can link to the exact
 * rectangle in the source PDF (`CitationProvenance.bbox`).
 *
 * The live PDF→TEI conversion runs in the main process (electron/ipc/
 * grobidHandler.cjs) against a GROBID REST service; THIS module is the pure,
 * deterministic parser of the returned TEI XML (verified offline). It uses
 * `getElementsByTagNameNS('*', …)` so the TEI default namespace is a non-issue.
 */
import type { PdfBox } from '../domain/types'
import { fuzzyContains } from './verify'

export interface GrobidSentence {
  text: string
  bbox?: PdfBox
}
export interface GrobidDoc {
  title?: string
  abstract?: string
  fullText: string
  sentences: GrobidSentence[]
}

/** Parse a GROBID coords attribute ("page,x,y,w,h;…") → the first box. */
export function parseCoords(attr?: string | null): PdfBox | undefined {
  if (!attr) return undefined
  const parts = attr.split(';')[0].split(',').map(Number)
  if (parts.length < 5 || parts.some((n) => Number.isNaN(n))) return undefined
  const [page, x, y, w, h] = parts
  return { page, x, y, w, h }
}

export function parseTei(xml: string): GrobidDoc {
  const doc = new DOMParser().parseFromString(xml, 'application/xml')
  const byTag = (tag: string) => Array.from(doc.getElementsByTagNameNS('*', tag))
  const clean = (s?: string | null) => s?.replace(/\s+/g, ' ').trim() || undefined
  const title = clean(byTag('title')[0]?.textContent)
  const abstract = clean(byTag('abstract')[0]?.textContent)
  const sentences: GrobidSentence[] = []
  for (const s of byTag('s')) {
    const text = clean(s.textContent)
    if (text) sentences.push({ text, bbox: parseCoords(s.getAttribute('coords')) })
  }
  return { title, abstract, fullText: sentences.map((s) => s.text).join(' '), sentences }
}

/** Find the GROBID sentence a quote came from (to attach its bbox). */
export function locateQuote(doc: GrobidDoc, quote: string): GrobidSentence | undefined {
  const q = quote.toLowerCase().replace(/\s+/g, ' ').trim()
  if (!q) return undefined
  return doc.sentences.find((s) => s.text.toLowerCase().includes(q)) ?? doc.sentences.find((s) => fuzzyContains(s.text, quote))
}
