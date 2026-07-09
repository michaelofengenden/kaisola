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

export type DocumentPreviewKind = 'markdown' | 'html' | 'csv' | 'json'

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

interface ParsedTable { rows: string[][]; truncated: boolean; error?: string }

/** RFC-4180-ish parser with strict display caps so a giant dataset stays calm. */
function parseTable(text: string, delimiter: ',' | '\t'): ParsedTable {
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false
  let truncated = false
  const source = text.slice(0, 4_000_000)
  if (source.length < text.length) truncated = true
  for (let i = 0; i < source.length; i += 1) {
    const char = source[i]
    if (quoted) {
      if (char === '"' && source[i + 1] === '"') { cell += '"'; i += 1 }
      else if (char === '"') quoted = false
      else cell += char
      continue
    }
    if (char === '"' && cell.length === 0) { quoted = true; continue }
    if (char === delimiter) { row.push(cell); cell = ''; continue }
    if (char === '\n' || char === '\r') {
      if (char === '\r' && source[i + 1] === '\n') i += 1
      row.push(cell); cell = ''
      rows.push(row.slice(0, 200)); row = []
      if (rows.length >= 2_000) { truncated = true; break }
      continue
    }
    cell += char
  }
  if (quoted) return { rows, truncated, error: 'The file ends inside a quoted cell.' }
  if (cell || row.length) { row.push(cell); rows.push(row.slice(0, 200)) }
  return { rows, truncated }
}

type PreviewJsonNode =
  | { kind: 'leaf'; value: unknown }
  | { kind: 'array' | 'object'; total: number; children: Array<{ name: string; node: PreviewJsonNode }>; truncated: boolean }

const JSON_NODE_LIMIT = 5_000
const JSON_DEPTH_LIMIT = 32
const JSON_CHILD_LIMIT = 200

/**
 * Build a bounded, non-recursive projection before React sees the data. This
 * makes the worst-case DOM finite even when a small JSON file contains a very
 * broad or deeply nested structure.
 */
export function buildPreviewJsonTree(value: unknown): { root: PreviewJsonNode; truncated: boolean; nodes: number } {
  const makeNode = (item: unknown): PreviewJsonNode => {
    if (Array.isArray(item)) return { kind: 'array', total: item.length, children: [], truncated: false }
    if (item !== null && typeof item === 'object') return { kind: 'object', total: Object.keys(item as object).length, children: [], truncated: false }
    return { kind: 'leaf', value: item }
  }
  const root = makeNode(value)
  const work: Array<{ source: unknown; node: PreviewJsonNode; depth: number }> = [{ source: value, node: root, depth: 0 }]
  let nodes = 1
  let truncated = false

  while (work.length) {
    const current = work.pop()!
    if (current.node.kind === 'leaf') continue
    if (current.depth >= JSON_DEPTH_LIMIT) {
      current.node.truncated = current.node.total > 0
      truncated ||= current.node.truncated
      continue
    }
    const source = current.source
    const names = Array.isArray(source)
      ? Array.from({ length: Math.min(source.length, JSON_CHILD_LIMIT) }, (_, index) => String(index))
      : Object.keys(source as Record<string, unknown>).slice(0, JSON_CHILD_LIMIT)
    for (const name of names) {
      if (nodes >= JSON_NODE_LIMIT) {
        current.node.truncated = true
        truncated = true
        break
      }
      const childValue = Array.isArray(source) ? source[Number(name)] : (source as Record<string, unknown>)[name]
      const child = makeNode(childValue)
      current.node.children.push({ name, node: child })
      nodes += 1
      if (child.kind !== 'leaf') work.push({ source: childValue, node: child, depth: current.depth + 1 })
    }
    if (current.node.children.length < current.node.total) {
      current.node.truncated = true
      truncated = true
    }
  }
  return { root, truncated, nodes }
}

function JsonNode({ name, node, depth = 0 }: { name?: string; node: PreviewJsonNode; depth?: number }) {
  const [expanded, setExpanded] = useState(depth < 2)
  const prefix = name == null ? null : <span className="fx-json-key">{name}</span>
  if (node.kind === 'leaf') {
    const value = node.value
    if (value === null) return <div className="fx-json-leaf">{prefix}<span className="fx-json-null">null</span></div>
    if (typeof value === 'string') return <div className="fx-json-leaf">{prefix}<span className="fx-json-string">{JSON.stringify(value)}</span></div>
    if (typeof value === 'number') return <div className="fx-json-leaf">{prefix}<span className="fx-json-number">{String(value)}</span></div>
    if (typeof value === 'boolean') return <div className="fx-json-leaf">{prefix}<span className="fx-json-bool">{String(value)}</span></div>
    return <div className="fx-json-leaf">{prefix}<span>{String(value)}</span></div>
  }
  const omitted = node.total - node.children.length
  return (
    <details className="fx-json-node" open={expanded} onToggle={(event) => setExpanded(event.currentTarget.open)}>
      <summary>{prefix}<span className="fx-json-shape">{node.kind === 'array' ? 'Array' : 'Object'}({node.total})</span></summary>
      {expanded && (
        <div className="fx-json-children">
          {node.children.map((child) => <JsonNode key={child.name} name={child.name} node={child.node} depth={depth + 1} />)}
          {(node.truncated || omitted > 0) && <div className="fx-json-more">… {Math.max(omitted, 0)} more {node.kind === 'array' ? 'items' : 'properties'} (preview limit)</div>}
        </div>
      )}
    </details>
  )
}

function parseJsonPreview(text: string, sourcePath?: string): { tree?: PreviewJsonNode; error?: string; truncated?: boolean } {
  if (text.length > 4_000_000) return { error: 'This JSON file is over the 4 MB preview limit.', truncated: true }
  try {
    let value: unknown
    let sourceTruncated = false
    if (sourcePath?.toLowerCase().endsWith('.jsonl')) {
      const lines = text.split(/\r?\n/).filter((line) => line.trim())
      const visible = lines.slice(0, 2_000).map((line) => JSON.parse(line))
      value = visible
      sourceTruncated = visible.length < lines.length
    } else {
      value = JSON.parse(text)
    }
    const projected = buildPreviewJsonTree(value)
    return { tree: projected.root, truncated: sourceTruncated || projected.truncated }
  } catch (error) {
    return { error: String((error as Error)?.message ?? error) }
  }
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
  const table = useMemo(() => kind === 'csv' ? parseTable(text, sourcePath?.toLowerCase().endsWith('.tsv') ? '\t' : ',') : null, [kind, text, sourcePath])
  const jsonTree = useMemo(() => kind === 'json' ? parseJsonPreview(text, sourcePath) : null, [kind, text, sourcePath])
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

  if (kind === 'csv' && table) {
    const [head = [], ...body] = table.rows
    return (
      <div ref={rootRef} className="fx-doc fx-doc-table" onDoubleClick={onEdit}>
        <div className="fx-table-wrap">
          {table.error && <div className="fx-preview-error">{table.error}</div>}
          <table>
            <thead><tr><th className="fx-row-number">#</th>{head.map((cell, index) => <th key={index}>{highlightText(cell || `Column ${index + 1}`, highlight)}</th>)}</tr></thead>
            <tbody>
              {body.map((row, rowIndex) => (
                <tr key={rowIndex}>
                  <th className="fx-row-number">{rowIndex + 1}</th>
                  {Array.from({ length: Math.max(head.length, row.length) }, (_, cellIndex) => <td key={cellIndex}>{highlightText(row[cellIndex] ?? '', highlight)}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
          {table.truncated && <div className="fx-preview-limit">Preview capped at 2,000 rows, 200 columns, or 4 MB. The source file is unchanged.</div>}
        </div>
      </div>
    )
  }

  if (kind === 'json' && jsonTree) {
    return (
      <div ref={rootRef} className="fx-doc fx-doc-json" onDoubleClick={onEdit}>
        <article className="fx-doc-page fx-json-tree">
          {jsonTree.error ? <div className="fx-preview-error"><strong>JSON preview unavailable</strong><span>{jsonTree.error}</span></div> : jsonTree.tree ? <JsonNode node={jsonTree.tree} /> : null}
          {jsonTree.truncated && <div className="fx-preview-limit">Preview capped for responsiveness. The source file is unchanged.</div>}
        </article>
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
