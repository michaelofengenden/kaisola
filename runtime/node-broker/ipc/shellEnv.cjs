// Resolve the user's REAL PATH. macOS GUI apps (a double-clicked .app) launch
// with a stripped PATH (/usr/bin:/bin) that lacks Homebrew, nvm, ~/.local/bin,
// etc., so spawned agents like `gemini`/`codex`/`npx` aren't found. We ask the
// login shell for its PATH once and merge it with common locations.
const { execFileSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const DEFAULT_SHELLS = Object.freeze(['/bin/zsh', '/bin/bash', '/bin/sh'])
const SAFE_EXECUTABLE_PATH = /^\/(?:[A-Za-z0-9._+@%=-]+\/)*[A-Za-z0-9._+@%=-]+$/
const PATH_COMMAND = 'printf "PZPATH:%s" "$PATH"'

let cachedPath // undefined = not computed; null = failed

function validatedExecutablePath(candidate) {
  if (typeof candidate !== 'string' || !path.isAbsolute(candidate)) return null
  // SHELL is an environment trust boundary. Restrict it to ordinary pathname
  // characters before touching the filesystem so whitespace and shell syntax
  // can never become executable selection or command-parsing input.
  if (!SAFE_EXECUTABLE_PATH.test(candidate)) return null

  try {
    const resolved = fs.realpathSync(candidate)
    if (!path.isAbsolute(resolved) || !SAFE_EXECUTABLE_PATH.test(resolved)) return null
    if (!fs.statSync(resolved).isFile()) return null
    fs.accessSync(resolved, fs.constants.X_OK)
    return resolved
  } catch {
    return null
  }
}

function resolveLoginShell(shell = process.env.SHELL, { fallbackShells = DEFAULT_SHELLS } = {}) {
  const candidates = [shell, ...fallbackShells]
  const seen = new Set()
  for (const candidate of candidates) {
    if (seen.has(candidate)) continue
    seen.add(candidate)
    const executable = validatedExecutablePath(candidate)
    if (executable) return executable
  }
  return null
}

function discoverLoginShellPath({
  shell = process.env.SHELL,
  fallbackShells = DEFAULT_SHELLS,
  run = execFileSync,
} = {}) {
  const executable = resolveLoginShell(shell, { fallbackShells })
  if (!executable) return null

  try {
    // `-i` loads .zshrc (where PATH edits usually live) but also makes zsh print
    // "Saving session…/…truncating history files" to stderr on exit — inherited
    // by our main process, it looked like a crash in the dev console. Ignore the
    // child's stderr; PATH still comes back on stdout (parsed by the PZPATH tag).
    const out = run(executable, ['-lic', PATH_COMMAND], {
      timeout: 5000,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
    const m = out.match(/PZPATH:(.+)/)
    return m ? m[1].trim() : null
  } catch {
    return null
  }
}

function loginShellPath() {
  if (cachedPath !== undefined) return cachedPath
  cachedPath = discoverLoginShellPath()
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

module.exports = { agentEnv, discoverLoginShellPath, resolveLoginShell }
