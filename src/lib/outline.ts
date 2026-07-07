/**
 * Heading extraction for the sidebar outline. Markdown `#` headings
 * (fence-aware — a `# comment` inside ``` blocks is not a heading) and
 * LaTeX \section family. Pure and fast enough to run debounced per edit.
 */
import type { OutlineItem } from '../store/store'

const TEX_LEVELS: Array<[RegExp, number]> = [
  [/^\\section\*?\{(.+?)\}/, 1],
  [/^\\subsection\*?\{(.+?)\}/, 2],
  [/^\\subsubsection\*?\{(.+?)\}/, 3],
]

export function extractOutline(text: string, ext?: string): OutlineItem[] {
  const e = (ext ?? '').toLowerCase()
  const md = e === 'md' || e === 'markdown' || e === 'mdx'
  const tex = e === 'tex' || e === 'latex'
  if (!md && !tex) return []
  const out: OutlineItem[] = []
  const lines = text.split('\n')
  let inFence = false
  // setext heading tracking: a paragraph underlined with === (h1) or --- (h2)
  // renders as a real <hN>. We only treat an underline as setext when the run
  // above it is a genuine paragraph (blank/start-preceded, not a list / table /
  // blockquote / indented-code block) so the outline matches the rendered DOM
  // heading order 1:1 — the preview scrolls by heading position, not line.
  let paraStart = -1 // first line index of the current clean paragraph, else -1 (none) / -2 (non-paragraph block)
  let blankBefore = true // previous line was blank or start-of-doc
  const blockMarker = /^\s*(>|[-*+]\s|\d+[.)]\s|\||#)/
  for (let i = 0; i < lines.length && out.length < 200; i++) {
    const line = lines[i]
    if (md) {
      if (/^(```|~~~)/.test(line.trimStart())) { inFence = !inFence; paraStart = -1; blankBefore = false; continue }
      if (inFence) { blankBefore = false; continue }
      if (!line.trim()) { paraStart = -1; blankBefore = true; continue }
      const m = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line)
      if (m) { out.push({ level: m[1].length, text: m[2].trim(), line: i + 1 }); paraStart = -1; blankBefore = false; continue }
      // a setext underline (allowing 0–3 leading spaces, as CommonMark does)
      // closes the paragraph above it into a heading — but only a real paragraph
      const setext = /^ {0,3}=+\s*$/.test(line) ? 1 : /^ {0,3}-+\s*$/.test(line) ? 2 : 0
      if (setext && paraStart >= 0) {
        out.push({ level: setext, text: lines.slice(paraStart, i).join(' ').trim(), line: paraStart + 1 })
        paraStart = -1; blankBefore = false; continue
      }
      if (paraStart === -1) {
        // a clean paragraph begins only right after a blank line and only when the
        // line isn't indented code or a list/table/blockquote/ATX marker; anything
        // else opens a non-paragraph block (-2) that a setext underline must not close
        paraStart = blankBefore && !/^(\t| {4,})/.test(line) && !blockMarker.test(line) ? i : -2
      }
      blankBefore = false
    } else {
      for (const [re, level] of TEX_LEVELS) {
        const m = re.exec(line.trim())
        if (m) {
          out.push({ level, text: m[1].trim(), line: i + 1 })
          break
        }
      }
    }
  }
  return out
}
