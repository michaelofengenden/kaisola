import { memo } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { bridge } from '../lib/bridge'

/** Renders agent output as markdown — bold, code, links, lists, tables, headings. */
export const Markdown = memo(function Markdown({ text }: { text: string }) {
  return (
    <div className="md">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          a: ({ href, children }) => (
            <a
              href={href}
              onClick={(e) => {
                e.preventDefault()
                if (href) bridge.openExternal(href)
              }}
            >
              {children}
            </a>
          ),
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  )
})
