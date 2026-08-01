import {
  EditorState,
  Compartment,
} from '@codemirror/state'
import {
  EditorView,
  crosshairCursor,
  drawSelection,
  dropCursor,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightSpecialChars,
  keymap,
  lineNumbers,
  rectangularSelection,
} from '@codemirror/view'
import {
  defaultKeymap,
  indentWithTab,
} from '@codemirror/commands'
import {
  StreamLanguage,
  HighlightStyle,
  bracketMatching,
  foldGutter,
  foldKeymap,
  indentOnInput,
  syntaxHighlighting,
} from '@codemirror/language'
import {
  highlightSelectionMatches,
  searchKeymap,
} from '@codemirror/search'
import {
  autocompletion,
  closeBrackets,
  closeBracketsKeymap,
  completionKeymap,
} from '@codemirror/autocomplete'
import { tags } from '@lezer/highlight'
import { javascript } from '@codemirror/lang-javascript'
import { python } from '@codemirror/lang-python'
import { json } from '@codemirror/lang-json'
import { html } from '@codemirror/lang-html'
import { css } from '@codemirror/lang-css'
import { swift } from '@codemirror/legacy-modes/mode/swift'
import { shell } from '@codemirror/legacy-modes/mode/shell'
import { yaml } from '@codemirror/legacy-modes/mode/yaml'

const languageCompartment = new Compartment()
const appearanceCompartment = new Compartment()
const fontCompartment = new Compartment()

let editor = null
let revision = 0
let documentToken = ''
let applyingSwiftState = false
let pendingScrollReport = false
let fixtureMode = false

function post(message) {
  const bridge = globalThis.webkit?.messageHandlers?.kaisolaEditor
  if (bridge) bridge.postMessage(message)
}

function serializedOffset(state, position) {
  const precedingBreaks = state.doc.lineAt(position).number - 1
  return position + precedingBreaks * (state.lineBreak.length - 1)
}

function serializedDocumentLength(state) {
  return state.doc.length + (state.doc.lines - 1) * (state.lineBreak.length - 1)
}

function selectionJSON(state) {
  const selection = state.selection
  return {
    anchor: serializedOffset(state, selection.main.anchor),
    head: serializedOffset(state, selection.main.head),
  }
}

function sourceChanges(update) {
  const changes = []
  update.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
    changes.push({
      fromA: serializedOffset(update.startState, fromA),
      toA: serializedOffset(update.startState, toA),
      fromB: serializedOffset(update.state, fromB),
      toB: serializedOffset(update.state, toB),
      insert: inserted.sliceString(0, inserted.length, update.state.lineBreak),
    })
  })
  return changes
}

function reportScroll() {
  if (!editor || pendingScrollReport) return
  pendingScrollReport = true
  requestAnimationFrame(() => {
    pendingScrollReport = false
    if (!editor) return
    const scroller = editor.scrollDOM
    const scrollable = Math.max(0, scroller.scrollHeight - scroller.clientHeight)
    post({
      type: 'scroll',
      documentToken,
      fraction: scrollable > 0 ? scroller.scrollTop / scrollable : 0,
    })
  })
}

function requestUndo(type) {
  post({ type, documentToken, revision })
  return true
}

const bridgeKeymap = [
  { key: 'Mod-z', preventDefault: true, run: () => requestUndo('undo') },
  { key: 'Shift-Mod-z', preventDefault: true, run: () => requestUndo('redo') },
  { key: 'Mod-y', preventDefault: true, run: () => requestUndo('redo') },
]

const bridgeUpdates = EditorView.updateListener.of((update) => {
  if (applyingSwiftState || !update.docChanged) {
    if (update.viewportChanged || update.geometryChanged) reportScroll()
    return
  }

  const baseRevision = revision
  revision += 1
  post({
    type: 'change',
    documentToken,
    baseRevision,
    revision,
    changes: sourceChanges(update),
    beforeSelection: selectionJSON(update.startState),
    selection: selectionJSON(update.state),
    documentLength: serializedDocumentLength(update.state),
  })
  if (update.viewportChanged || update.geometryChanged) reportScroll()
})

const lightTheme = EditorView.theme({
  '&': {
    color: '#1c1c1e',
    backgroundColor: '#ffffff',
  },
  '.cm-content': { caretColor: '#007aff' },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: '#007aff' },
  '.cm-selectionBackground, ::selection': { backgroundColor: '#b9d8ff !important' },
  '.cm-gutters': {
    color: '#77777c',
    backgroundColor: '#f7f7f8',
    borderRight: '1px solid #dedee2',
  },
  '.cm-activeLine': { backgroundColor: '#007aff0d' },
  '.cm-activeLineGutter': { backgroundColor: '#007aff14', color: '#3a3a3c' },
}, { dark: false })

const darkTheme = EditorView.theme({
  '&': {
    color: '#f2f2f7',
    backgroundColor: '#1c1c1e',
  },
  '.cm-content': { caretColor: '#64a8ff' },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: '#64a8ff' },
  '.cm-selectionBackground, ::selection': { backgroundColor: '#24558a !important' },
  '.cm-gutters': {
    color: '#a1a1a6',
    backgroundColor: '#242426',
    borderRight: '1px solid #3a3a3c',
  },
  '.cm-activeLine': { backgroundColor: '#64a8ff12' },
  '.cm-activeLineGutter': { backgroundColor: '#64a8ff1a', color: '#f2f2f7' },
}, { dark: true })

const lightHighlightStyle = HighlightStyle.define([
  { tag: [tags.keyword, tags.modifier, tags.controlKeyword], color: '#9b2393' },
  { tag: [tags.typeName, tags.className, tags.namespace], color: '#0b4f79' },
  { tag: [tags.function(tags.variableName), tags.function(tags.propertyName)], color: '#326d74' },
  { tag: [tags.string, tags.character, tags.attributeValue], color: '#c41a16' },
  { tag: [tags.number, tags.bool, tags.null], color: '#1c00cf' },
  { tag: [tags.comment, tags.docComment], color: '#5d6c79', fontStyle: 'italic' },
  { tag: [tags.propertyName, tags.attributeName], color: '#703daa' },
  { tag: [tags.regexp, tags.escape], color: '#c41a16' },
  { tag: [tags.operator, tags.punctuation], color: '#3a3a3c' },
  { tag: tags.invalid, color: '#b00020', textDecoration: 'underline' },
])

const darkHighlightStyle = HighlightStyle.define([
  { tag: [tags.keyword, tags.modifier, tags.controlKeyword], color: '#fc5fa3' },
  { tag: [tags.typeName, tags.className, tags.namespace], color: '#5dd8ff' },
  { tag: [tags.function(tags.variableName), tags.function(tags.propertyName)], color: '#67b7ff' },
  { tag: [tags.string, tags.character, tags.attributeValue], color: '#fc6a5d' },
  { tag: [tags.number, tags.bool, tags.null], color: '#d0bf69' },
  { tag: [tags.comment, tags.docComment], color: '#8a99a6', fontStyle: 'italic' },
  { tag: [tags.propertyName, tags.attributeName], color: '#cda1ff' },
  { tag: [tags.regexp, tags.escape], color: '#fc6a5d' },
  { tag: [tags.operator, tags.punctuation], color: '#d6d6dc' },
  { tag: tags.invalid, color: '#ff6961', textDecoration: 'underline' },
])

function appearance(theme) {
  return theme === 'dark'
    ? [darkTheme, syntaxHighlighting(darkHighlightStyle)]
    : [lightTheme, syntaxHighlighting(lightHighlightStyle)]
}

function fontTheme(fontSize) {
  const size = Number.isFinite(fontSize) ? Math.min(32, Math.max(9, fontSize)) : 13
  return EditorView.theme({
    '&': { height: '100%', fontSize: `${size}px` },
    '.cm-scroller': {
      overflow: 'auto',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
      lineHeight: '1.55',
    },
    '.cm-content': { padding: '10px 0 24px' },
    '.cm-line': { padding: '0 12px' },
  })
}

function languageExtension(language) {
  switch (language) {
    case 'javascript': return javascript({ jsx: true })
    case 'typescript': return javascript({ typescript: true, jsx: false })
    case 'tsx': return javascript({ typescript: true, jsx: true })
    case 'python': return python()
    case 'json': return json()
    case 'html': return html()
    case 'css': return css()
    case 'swift': return StreamLanguage.define(swift)
    case 'shell': return StreamLanguage.define(shell)
    case 'yaml': return StreamLanguage.define(yaml)
    default: return []
  }
}

function baseExtensions() {
  return [
    lineNumbers(),
    highlightActiveLineGutter(),
    highlightSpecialChars(),
    drawSelection(),
    dropCursor(),
    EditorState.allowMultipleSelections.of(true),
    indentOnInput(),
    bracketMatching(),
    closeBrackets(),
    autocompletion(),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    foldGutter(),
    keymap.of([
      ...bridgeKeymap,
      ...closeBracketsKeymap,
      ...defaultKeymap,
      ...searchKeymap,
      ...foldKeymap,
      ...completionKeymap,
      indentWithTab,
    ]),
    EditorView.contentAttributes.of({
      'aria-label': 'Source editor',
      spellcheck: 'false',
      autocapitalize: 'off',
      autocomplete: 'off',
      autocorrect: 'off',
    }),
    bridgeUpdates,
  ]
}

function clampSelection(selection, length) {
  const anchor = Math.min(length, Math.max(0, Number(selection?.anchor) || 0))
  const head = Math.min(length, Math.max(0, Number(selection?.head) || anchor))
  return { anchor, head }
}

function internalOffset(serializedText, lineSeparator, requestedOffset) {
  const offset = Math.min(serializedText.length, Math.max(0, Number(requestedOffset) || 0))
  if (lineSeparator.length < 2) return offset
  let internal = offset
  let cursor = 0
  while (cursor < offset) {
    const next = serializedText.indexOf(lineSeparator, cursor)
    if (next < 0 || next + lineSeparator.length > offset) break
    internal -= lineSeparator.length - 1
    cursor = next + lineSeparator.length
  }
  return internal
}

function internalSelection(selection, serializedText, lineSeparator) {
  const clamped = clampSelection(selection, serializedText.length)
  return {
    anchor: internalOffset(serializedText, lineSeparator, clamped.anchor),
    head: internalOffset(serializedText, lineSeparator, clamped.head),
  }
}

function applyLineTarget(oneBasedLine) {
  if (!editor || !Number.isInteger(oneBasedLine) || oneBasedLine <= 0) return
  const line = editor.state.doc.line(Math.min(oneBasedLine, editor.state.doc.lines))
  applyingSwiftState = true
  try {
    editor.dispatch({
      selection: { anchor: line.from },
      effects: EditorView.scrollIntoView(line.from, { y: 'center' }),
    })
  } finally {
    applyingSwiftState = false
  }
  editor.focus()
}

function restoreScroll(fraction) {
  if (!editor || !Number.isFinite(fraction) || fraction <= 0) return
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (!editor) return
    const scroller = editor.scrollDOM
    const scrollable = Math.max(0, scroller.scrollHeight - scroller.clientHeight)
    scroller.scrollTop = Math.min(1, Math.max(0, fraction)) * scrollable
  }))
}

function initialize(payload) {
  if (editor) editor.destroy()
  revision = Number.isInteger(payload.revision) ? payload.revision : 0
  documentToken = String(payload.documentToken || '')
  fixtureMode = payload.fixtureMode === true
  const text = typeof payload.text === 'string' ? payload.text : ''
  const parent = document.getElementById('editor')
  editor = new EditorView({
    parent,
    state: EditorState.create({
      doc: text,
      extensions: [
        ...baseExtensions(),
        EditorState.lineSeparator.of(
          ['\n', '\r\n', '\r'].includes(payload.lineSeparator) ? payload.lineSeparator : '\n',
        ),
        languageCompartment.of(languageExtension(payload.language)),
        appearanceCompartment.of(appearance(payload.theme)),
        fontCompartment.of(fontTheme(payload.fontSize)),
      ],
    }),
  })
  editor.scrollDOM.addEventListener('scroll', reportScroll, { passive: true })
  editor.contentDOM.addEventListener('beforeinput', (event) => {
    if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
      event.preventDefault()
      requestUndo(event.inputType === 'historyUndo' ? 'undo' : 'redo')
    }
  }, true)
  if (Number.isInteger(payload.line) && payload.line > 0) {
    requestAnimationFrame(() => applyLineTarget(payload.line))
  } else {
    restoreScroll(payload.scrollFraction)
  }
  post({
    type: 'initialized',
    documentToken,
    revision,
    documentLength: serializedDocumentLength(editor.state),
  })
  return true
}

function fixtureInsert(text) {
  if (!fixtureMode || !editor || typeof text !== 'string') return false
  const selection = editor.state.selection.main
  const inserted = text.replaceAll('\n', editor.state.lineBreak)
  const insertedInternalLength = internalOffset(inserted, editor.state.lineBreak, inserted.length)
  editor.dispatch({
    changes: { from: selection.from, to: selection.to, insert: inserted },
    selection: { anchor: selection.from + insertedInternalLength },
  })
  return true
}

function fixtureContains(text) {
  return fixtureMode && !!editor && editor.state.sliceDoc().includes(String(text))
}

function fixtureUndo() {
  return fixtureMode ? requestUndo('undo') : false
}

function fixtureRedo() {
  return fixtureMode ? requestUndo('redo') : false
}

function applySwiftState(payload) {
  if (!editor || String(payload.documentToken || '') !== documentToken) return false
  const effects = [
    languageCompartment.reconfigure(languageExtension(payload.language)),
    appearanceCompartment.reconfigure(appearance(payload.theme)),
    fontCompartment.reconfigure(fontTheme(payload.fontSize)),
  ]
  const specification = { effects }
  const serializedText = typeof payload.text === 'string' ? payload.text : editor.state.sliceDoc()
  if (typeof payload.text === 'string' && payload.text !== editor.state.sliceDoc()) {
    const requestedSelection = payload.selection || selectionJSON(editor.state)
    specification.changes = { from: 0, to: editor.state.doc.length, insert: payload.text }
    specification.selection = internalSelection(
      requestedSelection,
      serializedText,
      editor.state.lineBreak,
    )
  } else if (payload.selection) {
    specification.selection = internalSelection(
      payload.selection,
      serializedText,
      editor.state.lineBreak,
    )
  }
  applyingSwiftState = true
  try {
    editor.dispatch(specification)
    revision = Number.isInteger(payload.revision) ? payload.revision : revision
  } finally {
    applyingSwiftState = false
  }
  if (Number.isInteger(payload.line) && payload.line > 0) {
    requestAnimationFrame(() => applyLineTarget(payload.line))
  } else if (Number.isFinite(payload.scrollFraction)) {
    restoreScroll(payload.scrollFraction)
  }
  return true
}

globalThis.KaisolaEditor = Object.freeze({
  initialize,
  applySwiftState,
  fixtureInsert,
  fixtureContains,
  fixtureUndo,
  fixtureRedo,
})
post({ type: 'ready' })
