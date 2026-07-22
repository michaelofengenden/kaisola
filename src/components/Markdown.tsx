import { memo, type ReactNode } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { bridge } from '../lib/bridge'
import { openLocalCandidate } from '../lib/chatLinks'
import { resolveLocalFileLink } from '../lib/fileLinks'
import { terminalFileLinkCandidates } from '../lib/terminalFileLinks'
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

/** Inline code that is exactly one filesystem-looking token (agents' favorite
 *  way to cite `src/foo.ts:12`) opens the file preview on click. Block code
 *  and everything else renders untouched. */
function MarkdownCode({ className, children }: { className?: string; children?: ReactNode }) {
  const content = typeof children === 'string' ? children : null
  const inline = content != null && !content.includes('\n') && !className
  const candidate = inline ? terminalFileLinkCandidates(content) : []
  const single = candidate.length === 1 && candidate[0].text.length === content?.trim().length ? candidate[0] : null
  if (!single) return <code className={className}>{children}</code>
  return (
    <code
      className={className}
      data-local-file="true"
      role="link"
      tabIndex={0}
      title={`Open ${single.path}${single.line ? ` at line ${single.line}` : ''} in Files`}
      style={{ cursor: 'pointer', textDecoration: 'underline' }}
      onClick={() => openLocalCandidate(single)}
    >
      {children}
    </code>
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
          code: MarkdownCode,
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  )
})
