// Headless LaTeX builds for LaTeX mode. The old design booted `latexmk` in a
// terminal card — layout churn plus a wall of TeX log spew. Now the build runs
// here, the log is PARSED (file:line errors, warnings, missing packages), and
// the renderer gets a compact result it can render as clickable rows. No
// terminal is ever opened for a build.
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')
const { agentEnv } = require('./shellEnv.cjs')

const BUILD_TIMEOUT_MS = 600_000
const MAX_LOG = 8 * 1024 * 1024

// engines in preference order; each entry builds the argv for a given file
const ENGINES = [
  { name: 'latexmk', args: (base, opts = {}) => ['-pdf', ...(opts.force ? ['-g'] : []), '-interaction=nonstopmode', '-synctex=1', '-file-line-error', base] },
  { name: 'tectonic', args: (base) => ['--synctex', base] },
  { name: 'pdflatex', args: (base) => ['-interaction=nonstopmode', '-synctex=1', '-file-line-error', base] },
]

function run(cmd, args, cwd, timeoutMs = BUILD_TIMEOUT_MS) {
  return new Promise((resolve) => {
    let out = ''
    let settled = false
    let timedOut = false
    const finish = (result) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(result)
    }
    const append = (chunk) => {
      out += chunk.toString('utf8')
      if (out.length > MAX_LOG) out = out.slice(-MAX_LOG)
    }
    const child = spawn(cmd, args, {
      cwd,
      env: agentEnv(),
      stdio: ['ignore', 'pipe', 'pipe'],
      // own process group: latexmk is a Perl wrapper that forks the TeX engine —
      // killing only latexmk on timeout would orphan the runaway pdflatex
      detached: true,
    })
    const timer = setTimeout(() => {
      timedOut = true
      try { process.kill(-child.pid, 'SIGKILL') } catch { try { child.kill('SIGKILL') } catch { /* already gone */ } }
    }, timeoutMs)
    child.stdout.on('data', append)
    child.stderr.on('data', append)
    child.on('error', (err) => {
      finish({
        enoent: err && err.code === 'ENOENT',
        timedOut: false,
        code: err && err.code ? err.code : 1,
        out,
      })
    })
    child.on('close', (code, signal) => {
      finish({
        enoent: false,
        timedOut,
        code: code ?? (signal ? 1 : 0),
        out,
      })
    })
  })
}

/**
 * Pull the actionable lines out of a TeX log. With -file-line-error, errors
 * look like `./main.tex:12: Undefined control sequence.`; tectonic prints
 * `error: main.tex:12: …`. Everything else in the log is noise.
 */
function parseLog(out, texDir) {
  const errors = []
  const warnings = []
  const seen = new Set()
  const push = (list, item) => {
    const key = `${item.file ?? ''}:${item.line ?? ''}:${item.message}`
    if (!seen.has(key) && list.length < 20) {
      seen.add(key)
      list.push(item)
    }
  }
  const lines = out.split('\n')
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    // ./main.tex:12: Undefined control sequence.   |   error: main.tex:12: …
    const fl = line.match(/^(?:error: )?(\.?\/?[^:\s]+\.tex):(\d+):\s*(.+)$/)
    if (fl) {
      // the offending source snippet usually follows on the next 1-2 lines
      const detail = (lines[i + 1] ?? '').trim()
      push(errors, {
        file: path.resolve(texDir, fl[1]),
        line: Number(fl[2]),
        message: fl[3].trim() + (detail && detail.length < 90 && !detail.startsWith('!') ? ` — ${detail}` : ''),
      })
      continue
    }
    // ! LaTeX Error: File `foo.sty' not found.  →  the missing-package case
    const bang = line.match(/^!\s*(.+)$/)
    if (bang && !/^Emergency stop|^ ==>/.test(bang[1])) {
      const pkg = bang[1].match(/File [`']([^`']+\.(?:sty|cls))'? not found/)
      push(errors, {
        message: bang[1].trim(),
        hint: pkg ? `Missing package — try: tlmgr install ${pkg[1].replace(/\.(sty|cls)$/, '')}` : undefined,
      })
      continue
    }
    const warn = line.match(/^(?:LaTeX|Package \S+|Class \S+) Warning:\s*(.+)$/)
    if (warn) push(warnings, { message: warn[1].trim() })
  }
  return { errors, warnings }
}

function parseSynctexEdit(out, pdfDir) {
  const input = out.match(/^Input:\s*(.+)$/m)?.[1]?.trim()
  const line = Number(out.match(/^Line:\s*(\d+)$/m)?.[1])
  const columnRaw = out.match(/^Column:\s*(-?\d+)$/m)?.[1]
  if (!input || !Number.isFinite(line) || line < 1) return null
  const resolved = path.isAbsolute(input) ? path.normalize(input) : path.resolve(pdfDir, input)
  let file = resolved
  try {
    const realDir = fs.realpathSync(pdfDir)
    const realFile = fs.realpathSync(resolved)
    if (realFile === realDir || realFile.startsWith(`${realDir}${path.sep}`)) {
      file = path.join(pdfDir, path.relative(realDir, realFile))
    }
  } catch {
    // Fall back to the raw resolved path; the caller checks it exists.
  }
  return {
    file,
    line,
    column: columnRaw == null ? undefined : Number(columnRaw),
  }
}

function registerLatexHandlers(ipcMain) {
  ipcMain.handle('latex:build', async (_e, { texPath } = {}) => {
    if (typeof texPath !== 'string' || !texPath.endsWith('.tex') || !fs.existsSync(texPath)) {
      return { ok: false, message: 'Pick a .tex file to build.' }
    }
    const dir = path.dirname(texPath)
    const base = path.basename(texPath)
    const pdfPath = path.join(dir, base.replace(/\.tex$/, '.pdf'))
    const stem = pdfPath.replace(/\.pdf$/i, '')
    const force = fs.existsSync(pdfPath) && !fs.existsSync(`${stem}.synctex.gz`) && !fs.existsSync(`${stem}.synctex`)

    let last = null
    for (const engine of ENGINES) {
      let r = await run(engine.name, engine.args(base, { force }), dir)
      if (r.enoent) continue // engine not installed — try the next one
      // latexmk/tectonic re-run to convergence themselves; bare pdflatex needs
      // extra passes or \ref/\cite/TOC stay "??" in an ok:true build
      if (engine.name === 'pdflatex') {
        for (let pass = 1; pass < 3 && !r.timedOut && /Rerun to get|Label\(s\) may have changed|There were undefined references/.test(r.out); pass++) {
          r = await run(engine.name, engine.args(base, { force }), dir)
        }
      }
      last = { engine: engine.name, ...r }
      break
    }
    if (!last) {
      return {
        ok: false,
        missing: true,
        message: 'No LaTeX engine found (latexmk / tectonic / pdflatex).',
        hint: 'brew install tectonic — light, fetches packages on demand. Or the full distribution: brew install --cask mactex-no-gui.',
      }
    }
    if (last.timedOut) {
      return { ok: false, engine: last.engine, message: `${last.engine} timed out after ${BUILD_TIMEOUT_MS / 1000}s.` }
    }
    const { errors, warnings } = parseLog(last.out, dir)
    const pdf = fs.existsSync(pdfPath) ? pdfPath : undefined
    const ok = last.code === 0 && !!pdf
    return {
      ok,
      engine: last.engine,
      pdf, // may exist from an earlier run even when this build failed
      errors,
      warnings: warnings.slice(0, 8),
      logTail: ok ? undefined : last.out.slice(-4000),
      message: ok ? undefined : errors[0]?.message ?? `${last.engine} exited with code ${last.code}`,
    }
  })

  ipcMain.handle('latex:syncFromPdf', async (_e, { pdfPath, page, x, y } = {}) => {
    if (typeof pdfPath !== 'string' || !pdfPath.endsWith('.pdf') || !fs.existsSync(pdfPath)) {
      return { ok: false, message: 'Pick a built PDF to sync from.' }
    }
    const p = Math.max(1, Math.floor(Number(page) || 1))
    const px = Math.max(0, Number(x) || 0)
    const py = Math.max(0, Number(y) || 0)
    const stem = pdfPath.replace(/\.pdf$/i, '')
    if (!fs.existsSync(`${stem}.synctex.gz`) && !fs.existsSync(`${stem}.synctex`)) {
      return { ok: false, message: 'No SyncTeX data for this PDF. Build the LaTeX file first.' }
    }
    const dir = path.dirname(pdfPath)
    // an interactive double-click lookup — 10s, not the 600s build timeout
    const r = await run('synctex', ['edit', '-o', `${p}:${px}:${py}:${pdfPath}`], dir, 10_000)
    if (r.enoent) return { ok: false, message: 'SyncTeX is not installed.' }
    if (r.timedOut) return { ok: false, message: 'SyncTeX lookup timed out.' }
    const hit = parseSynctexEdit(r.out, dir)
    if (!hit || !fs.existsSync(hit.file)) return { ok: false, message: 'Could not map that PDF position back to a source line.' }
    return { ok: true, page: p, ...hit }
  })
}

module.exports = { registerLatexHandlers }
