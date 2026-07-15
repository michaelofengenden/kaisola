import {
  Children,
  cloneElement,
  isValidElement,
  memo,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type DragEvent,
  type ClipboardEvent as ReactClipboardEvent,
  type ReactElement,
  type ReactNode,
} from 'react'
import ReactMarkdown from 'react-markdown'
import { renderToStaticMarkup } from 'react-dom/server'
import remarkGfm from 'remark-gfm'
import TurndownService from 'turndown'
import { bridge, type FsReadResult } from '../lib/bridge'
import { useKaisola } from '../store/store'
import { Icon } from './Icon'

export type DocumentPreviewKind = 'markdown' | 'html' | 'csv' | 'json'

interface DocumentPreviewProps {
  text: string
  kind: DocumentPreviewKind
  sourcePath?: string
  highlight?: string
  onEdit?: () => void
  editable?: boolean
  onChange?: (text: string) => void
  /** Outline jump for the RENDERED surface: scroll to the nth heading. */
  scrollHeading?: { index: number; seq: number } | null
}

const BLOCKED_HTML = 'script, style, link, meta, base, iframe, object, embed, form, input, button, textarea, select, option, canvas, video, audio'
const SKIP_HIGHLIGHT = 'code, pre, kbd, samp, script, style, textarea'

function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

// countMatches lives in lib/format.ts — importing it from here would drag
// this whole lazy markdown chunk back into the main bundle.

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

type MarkdownSelectionState = {
  block: 'p' | 'h1' | 'h2' | 'h3' | 'blockquote' | 'pre'
  bold: boolean
  italic: boolean
  strike: boolean
  unordered: boolean
  ordered: boolean
}

const EMPTY_MARKDOWN_SELECTION: MarkdownSelectionState = {
  block: 'p',
  bold: false,
  italic: false,
  strike: false,
  unordered: false,
  ordered: false,
}

function sanitizeMarkdownHtml(text: string) {
  // ReactMarkdown escapes raw HTML by default. Run its serialized output
  // through the same allowlist sanitizer as HTML previews as a second trust
  // boundary before either contentEditable HTML sink receives it. Destinations
  // are stashed FIRST: under a packaged file: origin the sanitizer strips the
  // document's own relative src/href (correct for live URLs, fatal for the
  // save round-trip), so Turndown reads the inert data-markdown-* copy back.
  return sanitizeHtml(preserveMarkdownDestinations(renderToStaticMarkup(<ReactMarkdown remarkPlugins={[remarkGfm]}>{text}</ReactMarkdown>)), '')
}

/** Markdown-destination policy, independent of the window origin. isSafeUrl
 * resolves against location.href, so in the packaged app (file: origin) every
 * relative destination becomes an unsafe file: URL — right answer for live
 * DOM sinks, wrong one for the document's own text. A destination passing
 * this check is preserved as markdown TEXT only; rendering it still goes
 * through the unchanged sanitizer and bridge.fs reads. */
function isSafeMarkdownDestination(value: string, forImage = false) {
  const trimmed = value.trim()
  if (!trimmed) return false
  if (trimmed.startsWith('#')) return true
  if (trimmed.startsWith('//')) return false // scheme-relative — not a document path
  const scheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.exec(trimmed)?.[0].toLowerCase()
  if (!scheme) return true // relative or root-absolute path — the document's own asset space
  if (forImage && scheme === 'data:') return trimmed.startsWith('data:image/')
  return scheme === 'http:' || scheme === 'https:' || scheme === 'mailto:' || scheme === 'tel:'
}

/** Copy each valid markdown destination onto its node before sanitizeHtml can
 * strip it. The stash is an inert data attribute — file:, javascript:, and
 * unapproved data: destinations are never stashed, so nothing the sanitizer
 * blocks gains a second life. */
function preserveMarkdownDestinations(html: string) {
  const parsed = new DOMParser().parseFromString(html, 'text/html')
  const root = parsed.body || parsed.createElement('body')
  root.querySelectorAll('img[src]').forEach((image) => {
    const src = image.getAttribute('src') ?? ''
    if (isSafeMarkdownDestination(src, true)) image.setAttribute('data-markdown-src', src)
  })
  root.querySelectorAll('a[href]').forEach((anchor) => {
    const href = anchor.getAttribute('href') ?? ''
    if (isSafeMarkdownDestination(href)) anchor.setAttribute('data-markdown-href', href)
  })
  return root.innerHTML
}

/** CommonMark inline destinations cannot carry whitespace (ASCII spaces,
 * U+202F in macOS screenshot names…) or stray parens/angle brackets.
 * Percent-encode exactly those code points; existing %-escapes untouched. */
function encodeMarkdownDestination(value: string) {
  return value.replace(/[\s()<>]/g, (ch) =>
    Array.from(new TextEncoder().encode(ch), (byte) => `%${byte.toString(16).toUpperCase().padStart(2, '0')}`).join(''))
}

function selectionBlock(node: Node | null, root: HTMLElement): MarkdownSelectionState['block'] {
  const element = node instanceof Element ? node : node?.parentElement
  const block = element?.closest('h1, h2, h3, blockquote, pre, p')
  if (!block || !root.contains(block)) return 'p'
  const tag = block.tagName.toLowerCase()
  return ['h1', 'h2', 'h3', 'blockquote', 'pre'].includes(tag) ? tag as MarkdownSelectionState['block'] : 'p'
}

function markdownSelectionEqual(a: MarkdownSelectionState, b: MarkdownSelectionState) {
  return a.block === b.block && a.bold === b.bold && a.italic === b.italic && a.strike === b.strike && a.unordered === b.unordered && a.ordered === b.ordered
}

async function hydrateEditableImages(root: HTMLElement, sourcePath?: string) {
  // no [src] filter: under a file: origin the sanitizer strips relative srcs,
  // leaving the destination only in the data-markdown-src stash
  const images = Array.from(root.querySelectorAll<HTMLImageElement>('img'))
  await Promise.all(images.map(async (image) => {
    const original = image.dataset.markdownSrc ?? image.getAttribute('src') ?? ''
    if (!original || image.dataset.markdownHydrated === 'true' || isRemoteOrDataImage(original)) return
    const localPath = resolveMarkdownAsset(sourcePath, original)
    if (!localPath) return
    image.dataset.markdownSrc = original
    image.dataset.markdownHydrated = 'true'
    const first = await bridge.fs.read(localPath)
    let url = imageUrlFrom(first)
    if (!url) {
      const stripped = stripUrlDecorations(original)
      const fallback = stripped === original ? null : resolveMarkdownAsset(sourcePath, stripped)
      if (fallback) url = imageUrlFrom(await bridge.fs.read(fallback))
    }
    if (url) image.src = url
    else image.dataset.markdownHydrated = 'failed'
  }))
}

function EditableMarkdownSurface({
  text,
  sourcePath,
  onChange,
  onMediaPaste,
}: {
  text: string
  sourcePath?: string
  onChange?: (text: string) => void
  onMediaPaste?: (event: ReactClipboardEvent<HTMLElement>) => void
}) {
  // contentEditable must own its descendants while the user types. Giving
  // React a static HTML snapshot keeps reconciliation from replacing the
  // browser's live selection or undo stack after each onInput state update.
  const sanitizedMarkup = useRef<string | null>(null)
  if (sanitizedMarkup.current === null) sanitizedMarkup.current = sanitizeMarkdownHtml(text)
  const surfaceRef = useRef<HTMLElement>(null)
  const savedRange = useRef<Range | null>(null)
  const emittedText = useRef(text)
  const [selectionState, setSelectionState] = useState<MarkdownSelectionState>(EMPTY_MARKDOWN_SELECTION)
  const turndown = useMemo(() => {
    const service = new TurndownService({
      headingStyle: 'atx',
      bulletListMarker: '-',
      codeBlockStyle: 'fenced',
      emDelimiter: '*',
      strongDelimiter: '**',
    })
    service.addRule('strikethrough', {
      filter: ['del', 's'],
      replacement: (content) => `~~${content}~~`,
    })
    // Local images are hydrated to a data URL for the editing surface. Keep
    // their original markdown path on the node so saving never expands the
    // file into a multi-megabyte data URI.
    service.addRule('kaisola-image', {
      filter: 'img',
      replacement: (_content, node) => {
        const element = node as HTMLElement
        const src = element.dataset.markdownSrc ?? element.getAttribute('src') ?? ''
        const alt = (element.getAttribute('alt') ?? '').replace(/\]/g, '\\]')
        const title = element.getAttribute('title')
        return src ? `![${alt}](${encodeMarkdownDestination(src)}${title ? ` \"${title.replace(/\"/g, '\\\"')}\"` : ''})` : ''
      },
    })
    // Links mirror images: the live href may be sanitizer-stripped (relative
    // destinations under a file: origin), so the markdown destination rides
    // in data-markdown-href and wins over whatever the DOM still carries.
    service.addRule('kaisola-link', {
      filter: (node) => node.nodeName === 'A' && Boolean((node as HTMLElement).dataset.markdownHref ?? node.getAttribute('href')),
      replacement: (content, node) => {
        const element = node as HTMLElement
        const href = element.dataset.markdownHref ?? element.getAttribute('href') ?? ''
        const title = element.getAttribute('title')
        return `[${content}](${encodeMarkdownDestination(href)}${title ? ` \"${title.replace(/\"/g, '\\\"')}\"` : ''})`
      },
    })
    return service
  }, [])

  const syncMarkdown = useCallback(() => {
    const surface = surfaceRef.current
    if (!surface) return
    const next = turndown.turndown(surface.innerHTML).replace(/\n{3,}/g, '\n\n').trimEnd()
    const markdown = next ? `${next}\n` : ''
    emittedText.current = markdown
    onChange?.(markdown)
    void hydrateEditableImages(surface, sourcePath)
  }, [onChange, sourcePath, turndown])

  const captureSelection = useCallback(() => {
    const surface = surfaceRef.current
    const selection = window.getSelection()
    if (!surface || !selection?.rangeCount || !selection.anchorNode || !surface.contains(selection.anchorNode)) return
    savedRange.current = selection.getRangeAt(0).cloneRange()
    const next: MarkdownSelectionState = {
      block: selectionBlock(selection.anchorNode, surface),
      bold: document.queryCommandState('bold'),
      italic: document.queryCommandState('italic'),
      strike: document.queryCommandState('strikeThrough'),
      unordered: document.queryCommandState('insertUnorderedList'),
      ordered: document.queryCommandState('insertOrderedList'),
    }
    setSelectionState((current) => markdownSelectionEqual(current, next) ? current : next)
  }, [])

  useEffect(() => {
    const surface = surfaceRef.current
    if (surface) void hydrateEditableImages(surface, sourcePath)
  }, [sourcePath])

  useEffect(() => {
    document.addEventListener('selectionchange', captureSelection)
    return () => document.removeEventListener('selectionchange', captureSelection)
  }, [captureSelection])

  // Watcher-driven changes can land while Edit is open. Reconcile them when
  // this surface did not originate the update and the user is not typing.
  useEffect(() => {
    const surface = surfaceRef.current
    if (!surface || text === emittedText.current || surface.contains(document.activeElement)) return
    const next = sanitizeMarkdownHtml(text)
    surface.innerHTML = next
    sanitizedMarkup.current = next
    emittedText.current = text
    void hydrateEditableImages(surface, sourcePath)
  }, [sourcePath, text])

  const restoreSelection = () => {
    const surface = surfaceRef.current
    const selection = window.getSelection()
    if (!surface || !selection) return false
    surface.focus()
    selection.removeAllRanges()
    const range = savedRange.current
    if (range && surface.contains(range.startContainer)) selection.addRange(range)
    else {
      const end = document.createRange()
      end.selectNodeContents(surface)
      end.collapse(false)
      selection.addRange(end)
    }
    return true
  }

  const runCommand = (command: string, value?: string) => {
    if (!restoreSelection()) return
    document.execCommand(command, false, value)
    syncMarkdown()
    captureSelection()
  }

  const createLink = () => {
    if (!restoreSelection()) return
    const href = window.prompt('Link URL')?.trim()
    if (!href) return
    // the markdown policy, not isSafeUrl: a relative link is valid document
    // text even when the packaged file: origin makes it an unsafe live URL
    if (!isSafeMarkdownDestination(href)) {
      useKaisola.getState().pushToast('warn', 'Use an http(s), mail, anchor, or relative link.')
      return
    }
    const selection = window.getSelection()
    if (selection && !selection.isCollapsed) document.execCommand('createLink', false, href)
    else document.execCommand('insertHTML', false, `<a href="${escapeAttr(href)}" data-markdown-href="${escapeAttr(href)}">${escapeAttr(href)}</a>`)
    syncMarkdown()
    captureSelection()
  }

  return (
    <>
      <div className="fx-md-toolbar" role="toolbar" aria-label="Markdown formatting">
        <button type="button" onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('undo')} title="Undo  ⌘Z" aria-label="Undo">
          <Icon name="Undo2" size={14} />
        </button>
        <button type="button" onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('redo')} title="Redo  ⇧⌘Z" aria-label="Redo">
          <Icon name="Redo2" size={14} />
        </button>
        <span className="fx-md-toolbar-sep" />
        <select
          value={selectionState.block}
          aria-label="Text style"
          title="Text style"
          onMouseDown={captureSelection}
          onChange={(event) => runCommand('formatBlock', `<${event.target.value}>`)}
        >
          <option value="p">Body</option>
          <option value="h1">Heading 1</option>
          <option value="h2">Heading 2</option>
          <option value="h3">Heading 3</option>
          <option value="blockquote">Quote</option>
          <option value="pre">Code block</option>
        </select>
        <span className="fx-md-toolbar-sep" />
        <button type="button" data-active={selectionState.bold || undefined} onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('bold')} title="Bold  ⌘B" aria-label="Bold">
          <Icon name="Bold" size={14} />
        </button>
        <button type="button" data-active={selectionState.italic || undefined} onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('italic')} title="Italic  ⌘I" aria-label="Italic">
          <Icon name="Italic" size={14} />
        </button>
        <button type="button" data-active={selectionState.strike || undefined} onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('strikeThrough')} title="Strikethrough" aria-label="Strikethrough">
          <Icon name="Strikethrough" size={14} />
        </button>
        <button type="button" onMouseDown={(event) => event.preventDefault()} onClick={createLink} title="Add link" aria-label="Add link">
          <Icon name="Link2" size={14} />
        </button>
        <span className="fx-md-toolbar-sep" />
        <button type="button" data-active={selectionState.unordered || undefined} onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('insertUnorderedList')} title="Bulleted list" aria-label="Bulleted list">
          <Icon name="List" size={14} />
        </button>
        <button type="button" data-active={selectionState.ordered || undefined} onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('insertOrderedList')} title="Numbered list" aria-label="Numbered list">
          <Icon name="ListOrdered" size={14} />
        </button>
        <button type="button" onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('formatBlock', '<blockquote>')} title="Quote" aria-label="Quote">
          <Icon name="Quote" size={14} />
        </button>
        <button type="button" onMouseDown={(event) => event.preventDefault()} onClick={() => runCommand('formatBlock', '<pre>')} title="Code block" aria-label="Code block">
          <Icon name="Code2" size={14} />
        </button>
        <span className="fx-md-editing"><span /> Editing Markdown</span>
      </div>
      <article
        ref={surfaceRef}
        className="fx-doc-page md"
        contentEditable
        suppressContentEditableWarning
        role="textbox"
        aria-multiline="true"
        aria-label="Edit Markdown document"
        spellCheck
        dangerouslySetInnerHTML={{ __html: sanitizedMarkup.current }}
        onInput={syncMarkdown}
        onPaste={onMediaPaste}
        onKeyUp={captureSelection}
        onMouseUp={captureSelection}
        onKeyDown={(event) => {
          if (event.key !== 'Tab') return
          event.preventDefault()
          const selection = window.getSelection()
          const inList = selection?.anchorNode && (selection.anchorNode instanceof Element ? selection.anchorNode : selection.anchorNode.parentElement)?.closest('li')
          document.execCommand(inList ? (event.shiftKey ? 'outdent' : 'indent') : 'insertText', false, inList ? undefined : '  ')
          syncMarkdown()
        }}
      />
    </>
  )
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

// ── drop-to-attach: images/videos dropped on a markdown document copy into a
// sibling `<stem>-media/` folder (BACKLOG.md → backlog-media/) and link at the
// caret. Non-media drops bubble to the window handler (open as tab). ──
const IMAGE_DROP = /\.(png|jpe?g|gif|webp|svg|avif|heic)$/i
const VIDEO_DROP = /\.(mov|mp4|m4v|webm|avi|mkv)$/i

interface MediaImport {
  name: string
  path?: string
  file?: File
}

function assetDirFor(sourcePath: string) {
  const dir = dirname(sourcePath)
  const stem = sourcePath.slice(dir.length + 1).replace(/\.[^.]+$/, '')
  const slug = stem.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'doc'
  return { abs: `${dir}/${slug}-media`, rel: `${slug}-media` }
}

function isImageMedia(file: File) {
  return file.type.startsWith('image/') || IMAGE_DROP.test(stripUrlDecorations(file.name))
}

function isVideoMedia(file: File) {
  return file.type.startsWith('video/') || VIDEO_DROP.test(stripUrlDecorations(file.name))
}

function droppedMedia(event: DragEvent): MediaImport[] {
  return Array.from(event.dataTransfer?.files ?? []).flatMap((file) => {
    if (!isImageMedia(file) && !isVideoMedia(file)) return []
    return [{ name: file.name, path: bridge.pathForFile?.(file) || undefined, file }]
  })
}

function pastedMedia(event: ReactClipboardEvent<HTMLElement>): MediaImport[] {
  return Array.from(event.clipboardData.files).flatMap((file, index) => {
    if (!isImageMedia(file) && !isVideoMedia(file)) return []
    const fallbackExt = file.type.split('/')[1]?.replace('quicktime', 'mov') || (isVideoMedia(file) ? 'mp4' : 'png')
    const name = file.name || `pasted-${isVideoMedia(file) ? 'video' : 'image'}-${index + 1}.${fallbackExt}`
    return [{ name, file }]
  })
}

function escapeAttr(value: string) {
  return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

/** Restore the drop-point caret inside the contentEditable surface and insert
 *  html there — Turndown converts it back to markdown via the onInput sync. */
function insertHtmlAtPoint(root: HTMLElement | null, range: Range | null, htmlChunk: string) {
  const surface = root?.querySelector<HTMLElement>('article[contenteditable]')
  const selection = window.getSelection()
  if (!surface || !selection) return false
  surface.focus()
  selection.removeAllRanges()
  if (range && surface.contains(range.startContainer)) selection.addRange(range)
  else {
    const end = document.createRange()
    end.selectNodeContents(surface)
    end.collapse(false)
    selection.addRange(end)
  }
  const inserted = document.execCommand('insertHTML', false, htmlChunk)
  if (inserted) surface.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertFromDrop' }))
  return inserted
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
function buildPreviewJsonTree(value: unknown): { root: PreviewJsonNode; truncated: boolean; nodes: number } {
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

function MarkdownVideo({ href, children, sourcePath }: { href?: string; children?: ReactNode; sourcePath?: string }) {
  const [resolved, setResolved] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)
  const direct = href && isSafeUrl(href) && /^https?:/i.test(href) ? href : null
  const localPath = direct ? null : resolveMarkdownAsset(sourcePath, href)
  const strippedHref = href == null ? href : stripUrlDecorations(href)
  const fallbackPath = direct || strippedHref === href ? null : resolveMarkdownAsset(sourcePath, strippedHref)

  useEffect(() => {
    let cancelled = false
    setResolved(null)
    setFailed(!direct && !localPath)
    if (!localPath) return () => { cancelled = true }
    void bridge.fs.read(localPath).then(async (result) => {
      if (cancelled) return
      let url = result.ok && result.mediaKind === 'video' ? result.previewUrl ?? result.dataUrl ?? null : null
      if (!url && fallbackPath) {
        const retry = await bridge.fs.read(fallbackPath)
        if (cancelled) return
        url = retry.ok && retry.mediaKind === 'video' ? retry.previewUrl ?? retry.dataUrl ?? null : null
      }
      if (url) setResolved(url)
      else setFailed(true)
    })
    return () => { cancelled = true }
  }, [direct, fallbackPath, localPath])

  const videoSrc = direct ?? resolved
  return (
    <span className="fx-md-video">
      {videoSrc ? (
        <video src={videoSrc} controls preload="metadata" playsInline />
      ) : (
        <span className="fx-md-video-missing">{failed ? 'Video unavailable' : 'Loading video...'}</span>
      )}
      {children ? <span className="fx-md-video-caption">{children}</span> : null}
    </span>
  )
}

function MarkdownPreviewLink({ href, children, highlight }: { href?: string; children?: ReactNode; highlight: string }) {
  const open = (event: React.MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault()
    if (href) bridge.openExternal(href)
  }
  return <a href={href} onClick={open}>{highlightChildren(children, highlight)}</a>
}

export const DocumentPreview = memo(function DocumentPreview({ text, kind, sourcePath, highlight = '', onEdit, editable = false, onChange, scrollHeading }: DocumentPreviewProps) {
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

  const onMediaDragOver = (event: DragEvent) => {
    if (sourcePath && event.dataTransfer?.types.includes('Files')) event.preventDefault()
  }

  const attachMedia = async (media: MediaImport[], range: Range | null) => {
    if (!sourcePath) return
    const { pushToast } = useKaisola.getState()
    const { abs, rel } = assetDirFor(sourcePath)
    const chunks: string[] = []
    const imported = await Promise.all(media.map(async (item) => {
      try {
        const copied = item.path
          ? await bridge.fs.importAsset(item.path, abs, item.name)
          : item.file
            ? await bridge.fs.importAssetData(new Uint8Array(await item.file.arrayBuffer()), abs, item.name)
            : { ok: false, message: 'No readable file data.' }
        return { item, copied }
      } catch (error) {
        return { item, copied: { ok: false, message: String((error as Error)?.message ?? error) } }
      }
    }))
    for (const { item, copied } of imported) {
      if (!copied?.ok || !copied.name) {
        pushToast('error', `Could not attach ${item.name}: ${copied?.message ?? 'copy failed'}`)
      } else {
        const href = escapeAttr(encodeURI(`${rel}/${copied.name}`))
        const label = escapeAttr(copied.name.replace(/\.[^.]+$/, ''))
        // stash the destination at insert time — under a file: origin the live
        // src/href can't load (and may be stripped), but the save path reads
        // the data-markdown-* copy regardless of hydration timing
        chunks.push(IMAGE_DROP.test(stripUrlDecorations(copied.name))
          ? `<img src="${href}" data-markdown-src="${href}" alt="${label}">`
          : `<a href="${href}" data-markdown-href="${href}">${label}</a>`)
      }
    }
    if (!chunks.length) return
    if (!insertHtmlAtPoint(rootRef.current, range, chunks.join('<br>'))) {
      pushToast('warn', `Saved to ${rel}/ — link it manually; the caret was lost.`)
    }
  }

  const onMediaDrop = (event: DragEvent) => {
    if (!sourcePath) return
    const media = droppedMedia(event)
    if (!media.length) return
    event.preventDefault()
    event.stopPropagation()
    const { pushToast } = useKaisola.getState()
    if (!editable) {
      pushToast('info', 'Switch to Edit to attach media to this document.')
      return
    }
    const range = document.caretRangeFromPoint?.(event.clientX, event.clientY) ?? null
    void attachMedia(media, range)
  }

  const onMediaPaste = (event: ReactClipboardEvent<HTMLElement>) => {
    if (!sourcePath) return
    const media = pastedMedia(event)
    if (!media.length) return
    event.preventDefault()
    event.stopPropagation()
    const selection = window.getSelection()
    const range = selection?.rangeCount ? selection.getRangeAt(0).cloneRange() : null
    void attachMedia(media, range)
  }

  const rich = (tag: keyof JSX.IntrinsicElements) => markdownComponent(tag, editable ? '' : highlight) as never
  return (
    <div
      ref={rootRef}
      className="fx-doc fx-doc-markdown"
      data-editing={editable || undefined}
      onDoubleClick={editable ? undefined : onEdit}
      onDragOver={onMediaDragOver}
      onDrop={onMediaDrop}
    >
      {editable ? (
        <EditableMarkdownSurface text={text} sourcePath={sourcePath} onChange={onChange} onMediaPaste={onMediaPaste} />
      ) : (
        <article className="fx-doc-page md">
        <ReactMarkdown
          remarkPlugins={[remarkGfm]}
          components={{
            a: ({ href, children }) => href && VIDEO_DROP.test(stripUrlDecorations(href))
              ? <MarkdownVideo href={href} sourcePath={sourcePath}>{children}</MarkdownVideo>
              : <MarkdownPreviewLink href={href} highlight={highlight}>{children}</MarkdownPreviewLink>,
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
      )}
    </div>
  )
})
