import { EditorView } from '@codemirror/view'
import { HighlightStyle, StreamLanguage, type StringStream } from '@codemirror/language'
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
  type LanguageContribution,
} from '../lib/extensions'

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
