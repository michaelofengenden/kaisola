import React from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { PopTerminal } from './components/shell/PopTerminal'
import { POP_TERMINAL_ID, useKaisola, sessionOrderIds } from './store/store'
import { loadUserConfig } from './lib/userConfig'
import { pagerank, rankNodes, buildAgentContext } from './lib/relevance'
import { tournament, compositeScore } from './lib/tournament'
import { verifyCitation, fuzzyContains, offlineEntailment } from './lib/verify'
import { lintProvenanced, lintSeverity } from './lib/lint'
import { extractDoi, reconstructAbstract, normalizeOaId, resolveReferences } from './lib/openalex'
import { parseTei, parseCoords, locateQuote } from './lib/grobid'
import './styles/global.css'
import './styles/shell.css'
import './styles/signature.css'
import './styles/views.css'
import './styles/calm.css'
import './styles/dock.css'
import '@xterm/xterm/css/xterm.css'

// apply persisted/initial theme before first paint
document.documentElement.dataset.theme = useKaisola.getState().theme

// expose the store + pure research libs for debugging / headless smoke tests
;(window as unknown as { __kaisola: typeof useKaisola }).__kaisola = useKaisola
;(window as unknown as { __kaisolaLib: Record<string, unknown> }).__kaisolaLib = {
  pagerank, rankNodes, buildAgentContext, tournament, compositeScore, verifyCitation, fuzzyContains, offlineEntailment,
  lintProvenanced, lintSeverity,
  extractDoi, reconstructAbstract, normalizeOaId, resolveReferences,
  parseTei, parseCoords, locateQuote,
  sessionOrderIds, loadUserConfig,
}

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    {POP_TERMINAL_ID ? <PopTerminal termId={POP_TERMINAL_ID} /> : <App />}
  </React.StrictMode>,
)
