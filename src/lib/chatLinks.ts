import { bridge } from './bridge'
import { useKaisola } from '../store/store'
import { terminalFileLinkCandidates, type TerminalFileLinkCandidate } from './terminalFileLinks'

const URL_PATTERN = /https?:\/\/[^\s<>"'`]+/g
const TRAILING_PROSE = /[),.;!?\]}]+$/

export interface ChatLinkSegment {
  text: string
  kind: 'plain' | 'url' | 'file'
  candidate?: TerminalFileLinkCandidate
}

/** Open a workspace-relative or absolute path in the file preview, falling
 *  back to a Finder reveal for directories and a toast when nothing exists. */
export function openLocalCandidate(candidate: Pick<TerminalFileLinkCandidate, 'path' | 'line'>, baseOverride?: string) {
  const state = useKaisola.getState()
  const base = baseOverride ?? state.workspacePath ?? undefined
  void bridge.fs.resolvePath(candidate.path, base).then((resolved) => {
    if (!resolved.ok || !resolved.path) {
      state.pushToast('warn', `File not found: ${candidate.path}`)
      return
    }
    if (resolved.dir) {
      void bridge.fs.reveal(resolved.path)
      return
    }
    state.requestFile(resolved.path)
    if (candidate.line) window.setTimeout(() => state.requestScroll(resolved.path!, candidate.line!), 180)
  })
}

/** Split free text into plain/url/file segments for click affordances. */
export function chatLinkSegments(text: string): ChatLinkSegment[] {
  interface Span { start: number; end: number; segment: ChatLinkSegment }
  const spans: Span[] = []

  URL_PATTERN.lastIndex = 0
  let match: RegExpExecArray | null
  while ((match = URL_PATTERN.exec(text))) {
    const raw = match[0].replace(TRAILING_PROSE, '')
    if (!raw) continue
    spans.push({ start: match.index, end: match.index + raw.length, segment: { text: raw, kind: 'url' } })
  }
  for (const candidate of terminalFileLinkCandidates(text)) {
    if (spans.some((span) => candidate.start < span.end && span.start < candidate.end)) continue
    spans.push({
      start: candidate.start,
      end: candidate.end,
      segment: { text: candidate.text, kind: 'file', candidate },
    })
  }
  spans.sort((a, b) => a.start - b.start)

  const segments: ChatLinkSegment[] = []
  let cursor = 0
  for (const span of spans) {
    if (span.start < cursor) continue
    if (span.start > cursor) segments.push({ text: text.slice(cursor, span.start), kind: 'plain' })
    segments.push(span.segment)
    cursor = span.end
  }
  if (cursor < text.length) segments.push({ text: text.slice(cursor), kind: 'plain' })
  return segments
}
