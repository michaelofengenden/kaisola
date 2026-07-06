import {
  Children,
  cloneElement,
  isValidElement,
  memo,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactElement,
  type ReactNode,
} from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { bridge, type FsReadResult } from '../lib/bridge'

export type DocumentPreviewKind = 'markdown' | 'html'

interface DocumentPreviewProps {
  text: string
  kind: DocumentPreviewKind
  sourcePath?: string
  highlight?: string
  onEdit?: () => void
  /** Outline jump for the RENDERED surface: scroll to the nth heading. */
  scrollHeading?: { index: number; seq: number } | null
}

const BLOCKED_HTML = 'script, style, link, meta, base, iframe, object, embed, form, input, button, textarea, select, option, canvas, video, audio'
const SKIP_HIGHLIGHT = 'code, pre, kbd, samp, script, style, textarea'

function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

export function countMatches(text: string, query: string) {
  const q = query.trim()
  if (!q) return 0
  return text.match(new RegExp(escapeRegExp(q), 'gi'))?.length ?? 0
}

function highlightText(value: string, query: string): ReactNode {
  const q = query.trim()
  if (!q) return value
  const re = new RegExp(escapeRegExp(q), 'gi')
  const out: ReactNode[] = []
  let last = 0
  let i = 0
  value.replace(re, (match, offset: number) => {
    if (offset > last) out.push(value.slice(last, offset))
    out.push(<mark className="doc-mark" key={`${offset}-${i++}`}>{match}</mark>)
    last = offset + match.length
    return match
  })
  if (last < value.length) out.push(value.slice(last))
  return out.length ? out : value
}

function highlightChildren(children: ReactNode, query: string): ReactNode {
  if (!query.trim()) return children
  return Children.map(children, (child) => {
    if (typeof child === 'string') return highlightText(child, query)
    if (typeof child === 'number') return highlightText(String(child), query)
    if (isValidElement<{ children?: ReactNode }>(child)) {
      if (child.type === 'code' || child.type === 'pre') return child
      return cloneElement(child as ReactElement<{ children?: ReactNode }>, undefined, highlightChildren(child.props.children, query))
    }
    return child
  })
}

function markdownComponent(Tag: keyof JSX.IntrinsicElements, highlight: string) {
  const Component = ({ children, ...props }: { children?: ReactNode; [key: string]: unknown }) => {
    const T = Tag as keyof JSX.IntrinsicElements
    return <T {...props}>{highlightChildren(children, highlight)}</T>
  }
  return Component
}

function isSafeUrl(value: string, forImage = false) {
  const trimmed = value.trim()
  if (!trimmed) return false
  if (trimmed.startsWith('#')) return true
  if (forImage && trimmed.startsWith('data:image/')) return true
  try {
    const url = new URL(trimmed, window.location.href)
    return url.protocol === 'http:' || url.protocol === 'https:' || url.protocol === 'mailto:' || url.protocol === 'tel:'
  } catch {
    return trimmed.startsWith('/') || trimmed.startsWith('./') || trimmed.startsWith('../')
  }
}

function isRemoteOrDataImage(value: string) {
  const trimmed = value.trim()
  if (trimmed.startsWith('data:image/')) return true
  try {
    const url = new URL(trimmed)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}

function dirname(value: string) {
  const normalized = value.replace(/\\/g, '/')
  const at = normalized.lastIndexOf('/')
  return at <= 0 ? '/' : normalized.slice(0, at)
}

function safeDecode(value: string) {
  try {
    return decodeURIComponent(value)
  } catch {
    return value
  }
}

function stripUrlDecorations(value: string) {
  const hash = value.indexOf('#')
  const query = value.indexOf('?')
  const cut = Math.min(...[hash, query].filter((n) => n >= 0))
  return Number.isFinite(cut) ? value.slice(0, cut) : value
}

function resolveMarkdownAsset(sourcePath: string | undefined, src: string | undefined) {
  // no stripping here: '#' and '?' are legal filename characters on macOS —
  // callers decide whether a URL-style stripped variant is worth a retry
  const raw = String(src ?? '').trim()
  if (!raw || raw.startsWith('#') || isRemoteOrDataImage(raw)) return null
  const decoded = safeDecode(raw).replace(/\\/g, '/')
  const parts = (decoded.startsWith('/') ? decoded : `${dirname(sourcePath ?? '')}/${decoded}`)
    .split('/')
    .filter((part, index) => part || index === 0)
  const out: string[] = []
  for (const part of parts) {
    if (!part || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return `/${out.join('/')}`.replace(/^\/+/, '/')
}

function sanitizeHtml(raw: string, query: string) {
  if (typeof document === 'undefined') return ''
  const parsed = new DOMParser().parseFromString(raw, 'text/html')
  const root = parsed.body || parsed.createElement('body')

  root.querySelectorAll(BLOCKED_HTML).forEach((el) => el.remove())
  root.querySelectorAll('*').forEach((el) => {
    const tag = el.tagName.toLowerCase()
    for (const attr of Array.from(el.attributes)) {
      const name = attr.name.toLowerCase()
      const value = attr.value
      if (name.startsWith('on') || name === 'style' || name === 'srcdoc' || name === 'srcset') {
        el.removeAttribute(attr.name)
        continue
      }
      if (name === 'href' || name.endsWith(':href')) {
        if (!isSafeUrl(value)) el.removeAttribute(attr.name)
      }
      if (name === 'src' || name === 'poster') {
        if (!isSafeUrl(value, tag === 'img')) el.removeAttribute(attr.name)
      }
    }
    if (tag === 'a') {
      el.setAttribute('target', '_blank')
      el.setAttribute('rel', 'noreferrer noopener')
    }
    if (tag === 'img') {
      el.setAttribute('loading', 'lazy')
      el.setAttribute('decoding', 'async')
    }
  })

  highlightDom(root, query)
  return root.innerHTML
}

function highlightDom(root: HTMLElement, query: string) {
  const q = query.trim()
  if (!q) return
  const re = new RegExp(escapeRegExp(q), 'gi')
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      const parent = node.parentElement
      if (!parent || parent.closest(SKIP_HIGHLIGHT)) return NodeFilter.FILTER_REJECT
      re.lastIndex = 0
      return re.test(node.nodeValue ?? '') ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP
    },
  })
  const nodes: Text[] = []
  while (walker.nextNode()) nodes.push(walker.currentNode as Text)
  nodes.forEach((node) => {
    const value = node.nodeValue ?? ''
    const fragment = document.createDocumentFragment()
    let last = 0
    re.lastIndex = 0
    value.replace(re, (match, offset: number) => {
      if (offset > last) fragment.append(value.slice(last, offset))
      const mark = document.createElement('mark')
      mark.className = 'doc-mark'
      mark.textContent = match
      fragment.append(mark)
      last = offset + match.length
      return match
    })
    if (last < value.length) fragment.append(value.slice(last))
    node.parentNode?.replaceChild(fragment, node)
  })
}

function openPreviewLink(e: React.MouseEvent<HTMLElement>) {
  const target = e.target as HTMLElement | null
  const link = target?.closest('a[href]') as HTMLAnchorElement | null
  if (!link) return
  e.preventDefault()
  const href = link.getAttribute('href') || ''
  if (!href) return
  if (href.startsWith('#')) {
    const root = e.currentTarget
    const id = href.slice(1)
    const found = Array.from(root.querySelectorAll<HTMLElement>('[id], a[name]')).find((el) => el.id === id || el.getAttribute('name') === id)
    found?.scrollIntoView({ block: 'start', behavior: 'smooth' })
    return
  }
  bridge.openExternal(link.href || href)
}

/** The image payload of a read, if it has one (svg arrives as editable text). */
function imageUrlFrom(r: FsReadResult): string | null {
  if (!r.ok) return null
  if (r.mediaKind === 'image' && r.dataUrl) return r.dataUrl
  if (r.mediaKind === 'text' && r.mime === 'image/svg+xml' && r.content) {
    return `data:image/svg+xml;utf8,${encodeURIComponent(r.content)}`
  }
  return null
}

function MarkdownImage({ src, alt, title, sourcePath }: { src?: string; alt?: string; title?: string; sourcePath?: string }) {
  const [resolved, setResolved] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)
  const direct = src && isRemoteOrDataImage(src) && isSafeUrl(src, true) ? src : null
  // resolve the src verbatim first; if that file doesn't exist, retry with
  // URL-style decorations stripped (img.png?raw=true style links)
  const localPath = direct ? null : resolveMarkdownAsset(sourcePath, src)
  const strippedSrc = src == null ? src : stripUrlDecorations(src)
  const fallbackPath = direct || strippedSrc === src ? null : resolveMarkdownAsset(sourcePath, strippedSrc)

  useEffect(() => {
    let cancelled = false
    setResolved(null)
    // nothing local to load and no remote URL (empty src, '#anchor') — that's
    // "unavailable", not a load forever in flight
    setFailed(!direct && !localPath)
    if (!localPath) return () => { cancelled = true }
    void bridge.fs.read(localPath).then(async (r) => {
      if (cancelled) return
      let url = imageUrlFrom(r)
      if (!url && fallbackPath) {
        const retry = await bridge.fs.read(fallbackPath)
        if (cancelled) return
        url = imageUrlFrom(retry)
      }
      if (url) setResolved(url)
      else setFailed(true)
    })
    return () => { cancelled = true }
  }, [direct, localPath, fallbackPath])

  const imageSrc = direct ?? resolved
  if (imageSrc) return <img src={imageSrc} alt={alt ?? ''} title={title} loading="lazy" decoding="async" />
  return (
    <span className="fx-md-image-missing" title={localPath ?? src}>
      {failed ? 'Image unavailable' : 'Loading image...'}
      {alt ? <span>{alt}</span> : null}
    </span>
  )
}

export const DocumentPreview = memo(function DocumentPreview({ text, kind, sourcePath, highlight = '', onEdit, scrollHeading }: DocumentPreviewProps) {
  const html = useMemo(() => (kind === 'html' ? sanitizeHtml(text, highlight) : ''), [kind, text, highlight])
  const rootRef = useRef<HTMLDivElement>(null)

  // outline click → scroll the RENDERED page to that heading
  useEffect(() => {
    if (!scrollHeading || scrollHeading.index < 0) return
    const headings = rootRef.current?.querySelectorAll('h1, h2, h3, h4, h5, h6')
    headings?.[scrollHeading.index]?.scrollIntoView({ block: 'start', behavior: 'smooth' })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scrollHeading?.seq])

  if (kind === 'html') {
    return (
      <div ref={rootRef} className="fx-doc fx-doc-html" onClickCapture={openPreviewLink} onDoubleClick={onEdit}>
        <article className="fx-doc-page fx-html-body" dangerouslySetInnerHTML={{ __html: html }} />
      </div>
    )
  }

  const rich = (tag: keyof JSX.IntrinsicElements) => markdownComponent(tag, highlight) as never
  return (
    <div ref={rootRef} className="fx-doc fx-doc-markdown" onDoubleClick={onEdit}>
      <article className="fx-doc-page md">
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
                {highlightChildren(children, highlight)}
              </a>
            ),
            img: ({ src, alt, title }) => (
              <MarkdownImage src={src} alt={alt} title={title} sourcePath={sourcePath} />
            ),
            p: rich('p'),
            li: rich('li'),
            h1: rich('h1'),
            h2: rich('h2'),
            h3: rich('h3'),
            h4: rich('h4'),
            h5: rich('h5'),
            h6: rich('h6'),
            td: rich('td'),
            th: rich('th'),
            blockquote: rich('blockquote'),
            strong: rich('strong'),
            em: rich('em'),
          }}
        >
          {text}
        </ReactMarkdown>
      </article>
    </div>
  )
})
