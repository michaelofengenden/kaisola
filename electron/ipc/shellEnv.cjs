// Resolve the user's REAL PATH. macOS GUI apps (a double-clicked .app) launch
// with a stripped PATH (/usr/bin:/bin) that lacks Homebrew, nvm, ~/.local/bin,
// etc., so spawned agents like `gemini`/`codex`/`npx` aren't found. We ask the
// login shell for its PATH once and merge it with common locations.
const { execSync } = require('node:child_process')
const os = require('node:os')

let cachedPath // undefined = not computed; null = failed

function loginShellPath() {
  if (cachedPath !== undefined) return cachedPath
  try {
    const shell = process.env.SHELL || '/bin/zsh'
    // `-i` loads .zshrc (where PATH edits usually live) but also makes zsh print
    // "Saving session…/…truncating history files" to stderr on exit — inherited
    // by our main process, it looked like a crash in the dev console. Ignore the
    // child's stderr; PATH still comes back on stdout (parsed by the PZPATH tag).
    const out = execSync(`${shell} -lic 'printf "PZPATH:%s" "$PATH"'`, {
      timeout: 5000,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
    const m = out.match(/PZPATH:(.+)/)
    cachedPath = m ? m[1].trim() : null
  } catch {
    cachedPath = null
  }
  return cachedPath
}

/** process.env merged with the login-shell PATH + common bin dirs (+ extra env). */
function agentEnv(extra) {
  const home = os.homedir()
  const common = [
    loginShellPath(),
    process.env.PATH,
    '/opt/homebrew/bin',
    '/opt/homebrew/sbin',
    '/usr/local/bin',
    '/Library/TeX/texbin', // MacTeX/BasicTeX (latexmk, pdflatex)
    `${home}/.local/bin`,
    `${home}/.npm-global/bin`,
    `${home}/.bun/bin`,
    '/usr/bin',
    '/bin',
    '/usr/sbin',
    '/sbin',
  ].filter(Boolean)
  const seen = new Set()
  const PATH = common
    .join(':')
    .split(':')
    .filter((p) => p && !seen.has(p) && seen.add(p))
    .join(':')
  return { ...process.env, ...(extra || {}), PATH }
}

module.exports = { agentEnv }
