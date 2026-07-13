import { memo, type ReactNode } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { bridge } from '../lib/bridge'
import { resolveLocalFileLink } from '../lib/fileLinks'
import { useKaisola } from '../store/store'

/** Renders agent output as markdown — bold, code, links, lists, tables, headings. */
function MarkdownLink({ href, children }: { href?: string; children?: ReactNode }) {
  const workspacePath = useKaisola((s) => s.workspacePath)
  const requestFile = useKaisola((s) => s.requestFile)
  const requestScroll = useKaisola((s) => s.requestScroll)
  const local = resolveLocalFileLink(href, workspacePath)
  const open = (event: React.MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault()
    if (local) {
      requestFile(local.path)
      if (local.line) window.setTimeout(() => requestScroll(local.path, local.line!), 180)
    } else if (href) {
      bridge.openExternal(href)
    }
  }
  return (
    <a
      href={href}
      data-local-file={local ? 'true' : undefined}
      title={local ? `Open ${local.path}${local.line ? ` at line ${local.line}` : ''} in Files` : undefined}
      onClick={open}
    >
      {children}
    </a>
  )
}

/** Renders agent output as markdown — bold, code, links, lists, tables, headings. */
export const Markdown = memo(function Markdown({ text }: { text: string }) {
  return (
    <div className="md">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          a: MarkdownLink,
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  )
})
