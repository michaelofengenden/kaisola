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
import { words, changedWords, lineHunks, applyHunks } from './lib/wordDiff'
import './styles/global.css'
import './styles/shell.css'
import './styles/signature.css'
import './styles/calm.css'
import './styles/dock.css'
import './styles/extensions.css'
import './styles/onboarding.css'
import '@xterm/xterm/css/xterm.css'

// apply persisted/initial theme + appearance-energy mode before first paint
document.documentElement.dataset.theme = useKaisola.getState().theme
document.documentElement.dataset.perf = useKaisola.getState().perfMode
document.documentElement.dataset.tabLayout = useKaisola.getState().tabLayout
document.documentElement.dataset.termbg = useKaisola.getState().termBackground
// solid Eco windows: main created this window opaque — square the custom
// corners to the native clip before first paint (global.css)
if (new URLSearchParams(location.search).get('solidwin') === '1') {
  document.documentElement.dataset.solidwin = 'true'
}

// expose the store + pure research libs for debugging / headless smoke tests
;(window as unknown as { __kaisola: typeof useKaisola }).__kaisola = useKaisola
;(window as unknown as { __kaisolaLib: Record<string, unknown> }).__kaisolaLib = {
  pagerank, rankNodes, buildAgentContext, tournament, compositeScore, verifyCitation, fuzzyContains, offlineEntailment,
  lintProvenanced, lintSeverity,
  extractDoi, reconstructAbstract, normalizeOaId, resolveReferences,
  parseTei, parseCoords, locateQuote,
  sessionOrderIds, loadUserConfig,
  words, changedWords, lineHunks, applyHunks,
}

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    {POP_TERMINAL_ID ? <PopTerminal termId={POP_TERMINAL_ID} /> : <App />}
  </React.StrictMode>,
)
