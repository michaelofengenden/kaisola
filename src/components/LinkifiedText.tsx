import { memo } from 'react'
import { bridge } from '../lib/bridge'
import { chatLinkSegments, openLocalCandidate } from '../lib/chatLinks'

/** Plain agent/tool text with click affordances: bare URLs open the browser,
 *  filesystem-looking tokens open the file preview at their line. */
export const LinkifiedText = memo(function LinkifiedText({ text }: { text: string }) {
  const segments = chatLinkSegments(text)
  if (!segments.some((segment) => segment.kind !== 'plain')) return <>{text}</>
  return (
    <>
      {segments.map((segment, index) => {
        if (segment.kind === 'url') {
          return (
            <a
              key={index}
              href={segment.text}
              onClick={(event) => {
                event.preventDefault()
                event.stopPropagation()
                void bridge.openExternal(segment.text)
              }}
            >
              {segment.text}
            </a>
          )
        }
        if (segment.kind === 'file' && segment.candidate) {
          const candidate = segment.candidate
          return (
            <a
              key={index}
              href="#"
              data-local-file="true"
              title={`Open ${candidate.path}${candidate.line ? ` at line ${candidate.line}` : ''} in Files`}
              onClick={(event) => {
                event.preventDefault()
                event.stopPropagation()
                openLocalCandidate(candidate)
              }}
            >
              {segment.text}
            </a>
          )
        }
        return <span key={index}>{segment.text}</span>
      })}
    </>
  )
})
