import { memo } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { bridge } from '../lib/bridge'
import { resolveLocalFileLink } from '../lib/fileLinks'
import { useKaisola } from '../store/store'

/** Renders agent output as markdown — bold, code, links, lists, tables, headings. */
export const Markdown = memo(function Markdown({ text }: { text: string }) {
  const workspacePath = useKaisola((s) => s.workspacePath)
  const requestFile = useKaisola((s) => s.requestFile)
  const requestScroll = useKaisola((s) => s.requestScroll)
  return (
    <div className="md">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          a: ({ href, children }) => {
            const local = resolveLocalFileLink(href, workspacePath)
            return (
              <a
                href={href}
                data-local-file={local ? 'true' : undefined}
                title={local ? `Open ${local.path}${local.line ? ` at line ${local.line}` : ''} in Files` : undefined}
                onClick={(e) => {
                  e.preventDefault()
                  if (local) {
                    requestFile(local.path)
                    if (local.line) window.setTimeout(() => requestScroll(local.path, local.line!), 180)
                  } else if (href) {
                    bridge.openExternal(href)
                  }
                }}
              >
                {children}
              </a>
            )
          },
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  )
})
