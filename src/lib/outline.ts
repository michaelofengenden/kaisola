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
  for (let i = 0; i < lines.length && out.length < 200; i++) {
    const line = lines[i]
    if (md) {
      if (/^(```|~~~)/.test(line.trimStart())) {
        inFence = !inFence
        continue
      }
      if (inFence) continue
      const m = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line)
      if (m) out.push({ level: m[1].length, text: m[2].trim(), line: i + 1 })
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
