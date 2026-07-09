import { useEffect, useRef } from 'react'
import { EditorState, Compartment, StateField, Annotation, type Extension } from '@codemirror/state'
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLine,
  highlightActiveLineGutter,
  drawSelection,
  highlightSpecialChars,
  Decoration,
  WidgetType,
  ViewPlugin,
  showTooltip,
  type Tooltip,
} from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands'
import { unifiedMergeView } from '@codemirror/merge'
import {
  bracketMatching,
  indentOnInput,
  syntaxHighlighting,
  HighlightStyle,
  foldGutter,
  foldKeymap,
  foldService,
  StreamLanguage,
  syntaxTree,
  type StringStream,
} from '@codemirror/language'
import { tags as t } from '@lezer/highlight'
import { markdown } from '@codemirror/lang-markdown'
import { javascript } from '@codemirror/lang-javascript'
import { json } from '@codemirror/lang-json'
import { css as cssLang } from '@codemirror/lang-css'
import { html } from '@codemirror/lang-html'
import { python } from '@codemirror/lang-python'
import { yaml } from '@codemirror/lang-yaml'
import {
  isExtensionInstalled,
  languageContributionFor,
  useExtensionRevision,
  type LanguageContribution,
} from '../lib/extensions'

/**
 * A small, elegant CodeMirror 6 editor themed entirely through Kaisola's CSS
 * design tokens — so it follows the dark/light theme automatically (the syntax
 * palette lives in tokens.css as `--cm-*` vars). No external editor theme dep.
 */

interface SimpleLanguageState { blockEnd: string | null }
const contributedLanguages = new WeakMap<LanguageContribution, ReturnType<typeof StreamLanguage.define<SimpleLanguageState>>>()

/** A safe declarative grammar: comments, strings, numbers, keywords, atoms. */
function simpleLanguage(contribution: LanguageContribution) {
  const cached = contributedLanguages.get(contribution)
  if (cached) return cached
  const grammar = contribution.grammar
  const keywords = new Set(grammar.keywords ?? [])
  const atoms = new Set(grammar.atoms ?? [])
  const lineComments = [...(grammar.lineComments ?? [])].sort((a, b) => b.length - a.length)
  const blockComments = [...(grammar.blockComments ?? [])].sort((a, b) => b[0].length - a[0].length)
  const language = StreamLanguage.define<SimpleLanguageState>({
    name: contribution.id,
    startState: () => ({ blockEnd: null }),
    token(stream: StringStream, state: SimpleLanguageState) {
      if (state.blockEnd) {
        if (stream.skipTo(state.blockEnd)) {
          stream.match(state.blockEnd)
          state.blockEnd = null
        } else stream.skipToEnd()
        return 'comment'
      }
      if (stream.eatSpace()) return null
      for (const [start, end] of blockComments) {
        if (!stream.match(start, false)) continue
        stream.match(start)
        if (stream.skipTo(end)) stream.match(end)
        else { stream.skipToEnd(); state.blockEnd = end }
        return 'comment'
      }
      for (const marker of lineComments) {
        if (!stream.match(marker, false)) continue
        stream.skipToEnd()
        return 'comment'
      }
      if (stream.match(/^(?:r#*)?"(?:\\.|[^"\\])*"?/)) return 'string'
      if (stream.match(/^'(?:\\.|[^'\\])*'?/)) return 'string'
      if (stream.match(/^(?:0x[\da-f]+|0b[01]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?)(?:_[\da-f]+)*/i)) return 'number'
      const matchedWord = stream.match(/^[A-Za-z_$][\w$-]*/)
      const word = Array.isArray(matchedWord) ? matchedWord[0] : undefined
      if (word) {
        if (keywords.has(word)) return 'keyword'
        if (atoms.has(word)) return 'bool'
        if (/^[A-Z]/.test(word)) return 'typeName'
        return 'variableName'
      }
      if (stream.match(/^(?:=>|->|::|==|!=|<=|>=|&&|\|\||[+*/%=<>!&|^-]+)/)) return 'operator'
      stream.next()
      return null
    },
    languageData: {
      commentTokens: {
        line: lineComments[0],
        block: blockComments[0] ? { open: blockComments[0][0], close: blockComments[0][1] } : undefined,
      },
    },
  })
  contributedLanguages.set(contribution, language)
  return language
}

export function languageFor(ext?: string) {
  const contributed = languageContributionFor(ext)
  if (contributed) return simpleLanguage(contributed)
  switch ((ext ?? '').toLowerCase()) {
    case 'md':
    case 'markdown':
    case 'mdx':
      return isExtensionInstalled('kaisola.markdown') ? markdown() : []
    case 'ts':
    case 'tsx':
      return isExtensionInstalled('kaisola.javascript-typescript') ? javascript({ typescript: true, jsx: true }) : []
    case 'js':
    case 'jsx':
    case 'mjs':
    case 'cjs':
      return isExtensionInstalled('kaisola.javascript-typescript') ? javascript({ jsx: true }) : []
    case 'json':
    case 'jsonl':
      return isExtensionInstalled('kaisola.json-yaml') ? json() : []
    case 'css':
    case 'scss':
    case 'less':
      return cssLang()
    case 'html':
    case 'htm':
    case 'xml':
    case 'svg':
      return isExtensionInstalled('kaisola.html') ? html() : []
    case 'py':
      return isExtensionInstalled('kaisola.python') ? python() : []
    case 'yml':
    case 'yaml':
      return isExtensionInstalled('kaisola.json-yaml') ? yaml() : []
    default:
      return []
  }
}

/** Wrap long lines for prose-ish files; keep code horizontally scrollable. */
function wrapsFor(ext?: string) {
  const e = (ext ?? '').toLowerCase()
  return e === 'md' || e === 'markdown' || e === 'mdx' || e === 'tex' || e === 'latex' || e === 'txt' || e === ''
}

// ── section folding for prose ────────────────────────────────────────────────
// Markdown headings fold to the next same-or-higher heading (via the syntax
// tree, so `#` inside fenced code never folds); LaTeX \section family folds
// by regex (no lezer grammar for TeX).
const MD_HEADING = /^ATXHeading(\d)$/
const TEX_SECTION = /^\\(sub)*section\*?\{/

function markdownSectionFold(): Extension {
  return foldService.of((state, lineStart, lineEnd) => {
    const tree = syntaxTree(state)
    let level = 0
    tree.iterate({
      from: lineStart,
      to: lineEnd,
      enter: (n) => {
        const m = MD_HEADING.exec(n.name)
        if (m && n.from >= lineStart) level = Number(m[1])
      },
    })
    if (!level) return null
    let end = state.doc.length
    tree.iterate({
      from: lineEnd,
      to: state.doc.length,
      enter: (n) => {
        const m = MD_HEADING.exec(n.name)
        if (m && Number(m[1]) <= level && n.from > lineEnd && end === state.doc.length) {
          end = state.doc.lineAt(n.from).from - 1
        }
      },
    })
    return end > lineEnd ? { from: lineEnd, to: Math.max(lineEnd, end) } : null
  })
}

function texSectionFold(): Extension {
  const depth = (text: string) => {
    const m = TEX_SECTION.exec(text)
    return m ? (m[0].match(/sub/g)?.length ?? 0) + 1 : 0
  }
  return foldService.of((state, lineStart, lineEnd) => {
    const line = state.doc.lineAt(lineStart)
    const level = depth(line.text)
    if (!level) return null
    for (let n = line.number + 1; n <= state.doc.lines; n++) {
      const d = depth(state.doc.line(n).text)
      if (d && d <= level) return { from: lineEnd, to: state.doc.line(n - 1).to }
    }
    return { from: lineEnd, to: state.doc.length }
  })
}

function sectionFoldFor(ext?: string): Extension {
  const e = (ext ?? '').toLowerCase()
  if (e === 'md' || e === 'markdown' || e === 'mdx') return markdownSectionFold()
  if (e === 'tex' || e === 'latex') return texSectionFold()
  return []
}

// ── scrollbar change marks ───────────────────────────────────────────────────
// A slim right-edge track with a colored tick per marked line — Zed's
// "scrollbar marks on, minimap off" posture. Data comes in as {line, color}.
export interface ScrollMark {
  line: number
  color: string
}

function scrollMarksExtension(marks: ScrollMark[]): Extension {
  if (!marks.length) return []
  return ViewPlugin.define((view) => {
    const track = document.createElement('div')
    track.className = 'cm-scrollmarks'
    const render = () => {
      const lines = Math.max(1, view.state.doc.lines)
      track.textContent = ''
      for (const m of marks) {
        if (m.line < 1 || m.line > lines) continue
        const tick = document.createElement('div')
        tick.className = 'cm-scrollmark'
        tick.style.top = `${((m.line - 1) / lines) * 100}%`
        tick.style.background = m.color
        track.appendChild(tick)
      }
    }
    render()
    view.dom.appendChild(track)
    return {
      update: (u) => {
        if (u.docChanged) render()
      },
      destroy: () => track.remove(),
    }
  })
}

// ── current-line note (agent-turn blame) ─────────────────────────────────────
class LineNoteWidget extends WidgetType {
  constructor(readonly text: string) {
    super()
  }
  eq(other: LineNoteWidget) {
    return other.text === this.text
  }
  toDOM() {
    const el = document.createElement('span')
    el.className = 'cm-turn-blame'
    el.textContent = this.text
    return el
  }
  ignoreEvent() {
    return true
  }
}

function lineNoteExtension(note: { line: number; text: string } | null): Extension {
  if (!note) return []
  return EditorView.decorations.compute(['doc'], (state) => {
    if (note.line < 1 || note.line > state.doc.lines) return Decoration.none
    const pos = state.doc.line(note.line).to
    return Decoration.set([
      Decoration.widget({ widget: new LineNoteWidget(note.text), side: 1 }).range(pos),
    ])
  })
}

// ── annotations: highlights + the selection popup ────────────────────────────
export interface AnnotationRange {
  id: string
  from: number
  to: number
  color: string
}

/** The selection-first quote popup (Zotero's loop): colors annotate, ⧉ copies. */
export type QuoteAction = { kind: 'annotate'; color: string } | { kind: 'copy' }

const ANNOT_COLORS = ['var(--accent)', 'var(--warn)', 'var(--info)']

function annotationDecorations(ranges: AnnotationRange[]): Extension {
  if (!ranges.length) return []
  return EditorView.decorations.compute(['doc'], (state) => {
    const sorted = ranges
      .filter((r) => r.from < r.to && r.to <= state.doc.length)
      .sort((a, b) => a.from - b.from)
    return Decoration.set(
      sorted.map((r) =>
        Decoration.mark({
          class: 'cm-annot',
          attributes: { style: `--annot-color: ${r.color}`, 'data-annot': r.id },
        }).range(r.from, r.to),
      ),
    )
  })
}

function quotePopupExtension(
  onQuote: (action: QuoteAction, sel: { from: number; to: number; text: string }) => void,
): Extension {
  const field = StateField.define<Tooltip | null>({
    create: () => null,
    update: (tip, tr) => {
      if (!tr.selection && !tr.docChanged) return tip
      const sel = tr.state.selection.main
      if (sel.empty || sel.to - sel.from < 4 || sel.to - sel.from > 4000) return null
      return {
        pos: sel.head,
        above: true,
        strictSide: false,
        arrow: false,
        create: () => {
          const dom = document.createElement('div')
          dom.className = 'cm-quote-popup'
          const grab = () => ({
            from: tr.state.selection.main.from,
            to: tr.state.selection.main.to,
            text: tr.state.sliceDoc(tr.state.selection.main.from, tr.state.selection.main.to),
          })
          for (const color of ANNOT_COLORS) {
            const b = document.createElement('button')
            b.className = 'cm-quote-color'
            b.style.background = color
            b.title = 'Highlight & save as quote'
            b.onmousedown = (e) => {
              e.preventDefault()
              onQuote({ kind: 'annotate', color }, grab())
            }
            dom.appendChild(b)
          }
          const copy = document.createElement('button')
          copy.className = 'cm-quote-copy'
          copy.textContent = '⧉'
          copy.title = 'Copy as quote with source'
          copy.onmousedown = (e) => {
            e.preventDefault()
            onQuote({ kind: 'copy' }, grab())
          }
          dom.appendChild(copy)
          return { dom }
        },
      }
    },
    provide: (f) => showTooltip.from(f),
  })
  return field
}

// Syntax colors are pulled from CSS variables so the editor re-themes with the app.
export const highlightStyle = HighlightStyle.define([
  { tag: [t.keyword, t.moduleKeyword, t.controlKeyword, t.operatorKeyword], color: 'var(--cm-keyword)' },
  { tag: [t.string, t.special(t.string), t.regexp], color: 'var(--cm-string)' },
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: 'var(--cm-comment)', fontStyle: 'italic' },
  { tag: [t.number, t.bool, t.null, t.atom], color: 'var(--cm-number)' },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.labelName], color: 'var(--cm-function)' },
  { tag: [t.variableName, t.self], color: 'var(--cm-variable)' },
  { tag: [t.typeName, t.className, t.namespace, t.definition(t.typeName)], color: 'var(--cm-type)' },
  { tag: [t.operator, t.derefOperator, t.arithmeticOperator, t.logicOperator], color: 'var(--cm-operator)' },
  { tag: [t.propertyName, t.attributeValue], color: 'var(--cm-property)' },
  { tag: [t.tagName, t.angleBracket], color: 'var(--cm-tag)' },
  { tag: [t.attributeName], color: 'var(--cm-attr)' },
  { tag: [t.punctuation, t.separator, t.bracket, t.brace, t.paren], color: 'var(--cm-punctuation)' },
  { tag: [t.link, t.url], color: 'var(--cm-link)', textDecoration: 'underline' },
  { tag: [t.heading, t.heading1, t.heading2, t.heading3], color: 'var(--cm-heading)', fontWeight: '600' },
  { tag: t.quote, color: 'var(--text-2)', fontStyle: 'italic' },
  { tag: [t.strong], fontWeight: '700', color: 'var(--text-0)' },
  { tag: [t.emphasis], fontStyle: 'italic' },
  { tag: [t.strikethrough], textDecoration: 'line-through' },
  { tag: [t.invalid], color: 'var(--danger)' },
  { tag: [t.meta, t.processingInstruction], color: 'var(--text-3)' },
])

// Layout/chrome theme — colors come from tokens; this only governs structure.
export const baseTheme = EditorView.theme({
  '&': { color: 'var(--text-1)', backgroundColor: 'var(--bg-inset)', height: '100%' },
  '.cm-scroller': {
    fontFamily: 'var(--font-mono)',
    fontSize: 'var(--fx-code-font, 13px)',
    lineHeight: '1.6',
    overflow: 'auto',
  },
  '.cm-content': { padding: 'var(--sp-5) 0', caretColor: 'var(--accent)' },
  '.cm-line': { padding: '0 var(--sp-6)' },
  '&.cm-focused': { outline: 'none' },
  '.cm-gutters': {
    backgroundColor: 'transparent',
    color: 'var(--text-3)',
    border: 'none',
    fontFamily: 'var(--font-mono)',
    fontSize: 'var(--fx-code-font, 13px)',
    lineHeight: '1.6',
    paddingRight: 'var(--sp-2)',
  },
  '.cm-gutterElement': { boxSizing: 'border-box', lineHeight: '1.6' },
  '.cm-lineNumbers .cm-gutterElement': {
    padding: '0 var(--sp-2) 0 var(--sp-5)',
    minWidth: '2.8em',
    textAlign: 'right',
  },
  '.cm-foldGutter .cm-gutterElement': { color: 'var(--text-3)', paddingLeft: 'var(--sp-2)' },
  '.cm-activeLine': { backgroundColor: 'color-mix(in srgb, var(--text-0) 4%, transparent)' },
  '.cm-activeLineGutter': { backgroundColor: 'transparent', color: 'var(--text-1)' },
  '&.cm-focused .cm-cursor': { borderLeftColor: 'var(--accent)', borderLeftWidth: '2px' },
  '.cm-selectionBackground, .cm-content ::selection': { backgroundColor: 'var(--accent-soft)' },
  '&.cm-focused .cm-selectionBackground': { backgroundColor: 'var(--accent-soft)' },
  '.cm-matchingBracket, &.cm-focused .cm-matchingBracket': {
    backgroundColor: 'var(--accent-soft)',
    outline: '1px solid var(--accent-line)',
    color: 'inherit',
  },
  // ── unified merge view (checkpoint review): additions green, deletions red ──
  '.cm-changedLine': { backgroundColor: 'color-mix(in srgb, var(--success) 9%, transparent)' },
  '.cm-changedText': { background: 'color-mix(in srgb, var(--success) 22%, transparent)' },
  '.cm-deletedChunk': {
    backgroundColor: 'color-mix(in srgb, var(--danger) 8%, transparent)',
    textDecoration: 'none',
  },
  '.cm-deletedChunk del': { textDecoration: 'none', background: 'color-mix(in srgb, var(--danger) 18%, transparent)' },
  '.cm-chunkButtons': { backgroundColor: 'transparent' },
  '.cm-chunkButtons button': {
    color: 'var(--text-2)',
    background: 'var(--bg-2)',
    border: '1px solid var(--border-faint)',
    borderRadius: '5px',
    padding: '0 6px',
    marginLeft: '4px',
    cursor: 'pointer',
    fontSize: '11px',
  },
  '.cm-chunkButtons button:hover': { color: 'var(--text-0)', borderColor: 'var(--border)' },
  // ── scrollbar change marks ──
  '.cm-scrollmarks': {
    position: 'absolute',
    top: '0',
    right: '1px',
    bottom: '0',
    width: '4px',
    zIndex: '10',
    pointerEvents: 'none',
  },
  '.cm-scrollmark': {
    position: 'absolute',
    right: '0',
    width: '4px',
    height: '3px',
    borderRadius: '2px',
    opacity: '0.8',
  },
  // ── agent-turn blame (current line, faint, italic) ──
  '.cm-turn-blame': {
    color: 'var(--text-3)',
    fontSize: '11px',
    fontStyle: 'italic',
    fontFamily: 'var(--font-ui)',
    marginLeft: '2.5em',
    pointerEvents: 'none',
    whiteSpace: 'nowrap',
  },
  // ── annotation highlights (quote layer) ──
  '.cm-annot': {
    background: 'color-mix(in srgb, var(--annot-color, var(--accent)) 16%, transparent)',
    borderBottom: '1.5px solid color-mix(in srgb, var(--annot-color, var(--accent)) 50%, transparent)',
    borderRadius: '2px',
  },
  // ── the selection quote popup ──
  '.cm-tooltip:has(.cm-quote-popup)': {
    background: 'var(--bg-2)',
    border: '1px solid var(--border)',
    borderRadius: '8px',
    boxShadow: 'var(--shadow-2)',
    overflow: 'hidden',
  },
  '.cm-quote-popup': {
    display: 'flex',
    alignItems: 'center',
    gap: '6px',
    padding: '5px 8px',
  },
  '.cm-quote-color': {
    width: '14px',
    height: '14px',
    borderRadius: '999px',
    border: '1px solid rgba(0,0,0,0.15)',
    cursor: 'pointer',
    padding: '0',
  },
  '.cm-quote-color:hover': { transform: 'scale(1.15)' },
  '.cm-quote-copy': {
    color: 'var(--text-2)',
    background: 'transparent',
    border: 'none',
    fontSize: '13px',
    cursor: 'pointer',
    padding: '0 2px',
  },
  '.cm-quote-copy:hover': { color: 'var(--text-0)' },
})

// Marks the programmatic doc replacement in the external-`value` effect so the
// change listener can tell it apart from a real user edit (and skip onChange).
const externalSync = Annotation.define<boolean>()

export function CodeEditor({
  value,
  ext,
  readOnly,
  textZoom = 1,
  mergeBase,
  marks,
  inlineNote,
  annotations,
  scrollRequest,
  initialLine,
  onChange,
  onSave,
  onCursorLine,
  onQuote,
}: {
  value: string
  ext?: string
  readOnly?: boolean
  textZoom?: number
  /** When set, show a unified diff against this base text — deleted lines
   * inline, per-chunk revert arrows (the checkpoint review surface). */
  mergeBase?: string | null
  /** Right-edge scrollbar ticks (unsaved changes, diff chunks…). */
  marks?: ScrollMark[]
  /** A faint end-of-line note on ONE line (agent-turn blame). */
  inlineNote?: { line: number; text: string } | null
  /** Highlighted quote ranges (the annotation layer). */
  annotations?: AnnotationRange[]
  /** Scroll+place the cursor at a line when seq changes (outline/quote jumps). */
  scrollRequest?: { line: number; seq: number } | null
  /** Restore the cursor to this 1-based line on mount (session continuity). */
  initialLine?: number
  onChange?: (next: string) => void
  onSave?: () => void
  /** Debounced 1-based cursor line reports (outline follow, blame). */
  onCursorLine?: (line: number) => void
  /** Selection-first quote popup action. */
  onQuote?: (action: QuoteAction, sel: { from: number; to: number; text: string }) => void
}) {
  const extensionRevision = useExtensionRevision()
  const host = useRef<HTMLDivElement>(null)
  const view = useRef<EditorView | null>(null)
  const langC = useRef(new Compartment())
  const roC = useRef(new Compartment())
  const wrapC = useRef(new Compartment())
  const mergeC = useRef(new Compartment())
  const foldC = useRef(new Compartment())
  const marksC = useRef(new Compartment())
  const noteC = useRef(new Compartment())
  const annotC = useRef(new Compartment())
  const quoteC = useRef(new Compartment())
  // keep latest callbacks without rebuilding the editor
  const onChangeRef = useRef(onChange)
  const onSaveRef = useRef(onSave)
  const onCursorLineRef = useRef(onCursorLine)
  const onQuoteRef = useRef(onQuote)
  const cursorTimer = useRef<number | null>(null)
  onChangeRef.current = onChange
  onSaveRef.current = onSave
  onCursorLineRef.current = onCursorLine
  onQuoteRef.current = onQuote

  // Build the editor once.
  useEffect(() => {
    if (!host.current) return
    const saveKey = keymap.of([
      {
        key: 'Mod-s',
        preventDefault: true,
        run: () => {
          onSaveRef.current?.()
          return true
        },
      },
    ])
    const state = EditorState.create({
      doc: value,
      extensions: [
        lineNumbers(),
        highlightActiveLineGutter(),
        highlightActiveLine(),
        highlightSpecialChars(),
        history(),
        foldGutter(),
        drawSelection(),
        indentOnInput(),
        bracketMatching(),
        syntaxHighlighting(highlightStyle),
        saveKey,
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
        baseTheme,
        wrapC.current.of(wrapsFor(ext) ? EditorView.lineWrapping : []),
        langC.current.of(languageFor(ext)),
        roC.current.of(EditorState.readOnly.of(!!readOnly)),
        mergeC.current.of(mergeBase != null ? unifiedMergeView({ original: mergeBase, mergeControls: true }) : []),
        foldC.current.of(sectionFoldFor(ext)),
        keymap.of(foldKeymap),
        marksC.current.of(scrollMarksExtension(marks ?? [])),
        noteC.current.of(lineNoteExtension(inlineNote ?? null)),
        annotC.current.of(annotationDecorations(annotations ?? [])),
        quoteC.current.of(
          onQuote ? quotePopupExtension((a, s) => onQuoteRef.current?.(a, s)) : [],
        ),
        EditorView.updateListener.of((u) => {
          if (u.docChanged && !u.transactions.some((tr) => tr.annotation(externalSync)))
            onChangeRef.current?.(u.state.doc.toString())
          if ((u.selectionSet || u.docChanged) && onCursorLineRef.current) {
            if (cursorTimer.current !== null) window.clearTimeout(cursorTimer.current)
            cursorTimer.current = window.setTimeout(() => {
              cursorTimer.current = null
              const v2 = view.current
              if (v2) onCursorLineRef.current?.(v2.state.doc.lineAt(v2.state.selection.main.head).number)
            }, 140)
          }
        }),
      ],
    })
    const v = new EditorView({ state, parent: host.current })
    view.current = v
    // continue where you left off: restore the cursor without stealing focus
    if (initialLine != null && initialLine > 1 && initialLine <= v.state.doc.lines) {
      const pos = v.state.doc.line(initialLine).from
      v.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'center' }) })
    }
    return () => {
      if (cursorTimer.current !== null) window.clearTimeout(cursorTimer.current)
      v.destroy()
      view.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // External value changes (file switch, revert) → replace doc if different.
  useEffect(() => {
    const v = view.current
    if (!v) return
    if (value !== v.state.doc.toString()) {
      v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: value }, annotations: externalSync.of(true) })
    }
  }, [value])

  // Language + wrapping + section folding follow the file extension.
  useEffect(() => {
    view.current?.dispatch({
      effects: [
        langC.current.reconfigure(languageFor(ext)),
        wrapC.current.reconfigure(wrapsFor(ext) ? EditorView.lineWrapping : []),
        foldC.current.reconfigure(sectionFoldFor(ext)),
      ],
    })
  }, [ext, extensionRevision])

  // Live layers: scrollbar marks, the blame note, annotation highlights.
  useEffect(() => {
    view.current?.dispatch({ effects: marksC.current.reconfigure(scrollMarksExtension(marks ?? [])) })
  }, [marks])
  useEffect(() => {
    view.current?.dispatch({ effects: noteC.current.reconfigure(lineNoteExtension(inlineNote ?? null)) })
  }, [inlineNote])
  useEffect(() => {
    view.current?.dispatch({ effects: annotC.current.reconfigure(annotationDecorations(annotations ?? [])) })
  }, [annotations])

  // Outline / quote-list jumps: scroll to a 1-based line and park the cursor.
  useEffect(() => {
    const v = view.current
    if (!v || !scrollRequest || scrollRequest.line < 1) return
    const line = Math.min(scrollRequest.line, v.state.doc.lines)
    const pos = v.state.doc.line(line).from
    v.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'center' }) })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scrollRequest?.seq])

  // Read-only toggles between view/edit modes.
  useEffect(() => {
    view.current?.dispatch({ effects: roC.current.reconfigure(EditorState.readOnly.of(!!readOnly)) })
  }, [readOnly])

  // Diff review on/off (or a new checkpoint base) without rebuilding the editor.
  useEffect(() => {
    view.current?.dispatch({
      effects: mergeC.current.reconfigure(
        mergeBase != null ? unifiedMergeView({ original: mergeBase, mergeControls: true }) : [],
      ),
    })
  }, [mergeBase])

  // CodeMirror measures line/gutter geometry. When the Files pane changes the
  // font-size CSS variable, ask it to recompute so line numbers stay aligned.
  useEffect(() => {
    const v = view.current
    if (!v) return
    const raf = window.requestAnimationFrame(() => v.requestMeasure())
    return () => window.cancelAnimationFrame(raf)
  }, [textZoom])

  return <div ref={host} className="cm-host" />
}
