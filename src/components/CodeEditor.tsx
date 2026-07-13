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
  foldGutter,
  foldKeymap,
  foldService,
  syntaxTree,
} from '@codemirror/language'
import { useExtensionRevision } from '../lib/extensions'
import { baseTheme, highlightStyle, languageFor } from './codeEditorConfig'

/**
 * A small, elegant CodeMirror 6 editor themed entirely through Kaisola's CSS
 * design tokens — so it follows the dark/light theme automatically (the syntax
 * palette lives in tokens.css as `--cm-*` vars). No external editor theme dep.
 */

function useCompartmentRef() {
  const ref = useRef<Compartment | null>(null)
  if (ref.current === null) ref.current = new Compartment()
  return ref as { current: Compartment }
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
  const langC = useCompartmentRef()
  const roC = useCompartmentRef()
  const wrapC = useCompartmentRef()
  const mergeC = useCompartmentRef()
  const foldC = useCompartmentRef()
  const marksC = useCompartmentRef()
  const noteC = useCompartmentRef()
  const annotC = useCompartmentRef()
  const quoteC = useCompartmentRef()
  // keep latest callbacks without rebuilding the editor
  const onChangeRef = useRef(onChange)
  const onSaveRef = useRef(onSave)
  const onCursorLineRef = useRef(onCursorLine)
  const onQuoteRef = useRef(onQuote)
  const cursorTimer = useRef<number | null>(null)

  useEffect(() => {
    onChangeRef.current = onChange
    onSaveRef.current = onSave
    onCursorLineRef.current = onCursorLine
    onQuoteRef.current = onQuote
  }, [onChange, onSave, onCursorLine, onQuote])

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
  }, [ext, extensionRevision, langC, wrapC, foldC])

  // Live layers: scrollbar marks, the blame note, annotation highlights.
  useEffect(() => {
    view.current?.dispatch({ effects: marksC.current.reconfigure(scrollMarksExtension(marks ?? [])) })
  }, [marks, marksC])
  useEffect(() => {
    view.current?.dispatch({ effects: noteC.current.reconfigure(lineNoteExtension(inlineNote ?? null)) })
  }, [inlineNote, noteC])
  useEffect(() => {
    view.current?.dispatch({ effects: annotC.current.reconfigure(annotationDecorations(annotations ?? [])) })
  }, [annotations, annotC])

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
  }, [readOnly, roC])

  // Diff review on/off (or a new checkpoint base) without rebuilding the editor.
  useEffect(() => {
    view.current?.dispatch({
      effects: mergeC.current.reconfigure(
        mergeBase != null ? unifiedMergeView({ original: mergeBase, mergeControls: true }) : [],
      ),
    })
  }, [mergeBase, mergeC])

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
