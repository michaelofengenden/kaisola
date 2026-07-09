// Filesystem access for the workspace file explorer (VSCode-like): list + read + write.
const fsp = require('node:fs/promises')
const fs = require('node:fs')
const path = require('node:path')
const { Readable } = require('node:stream')
const crypto = require('node:crypto')
const os = require('node:os')
const { execFile } = require('node:child_process')
const { shell, protocol, nativeImage } = require('electron')
const { agentEnv } = require('./shellEnv.cjs')

const HIDE = new Set(['node_modules', '.git', '.DS_Store', '.next', 'dist', '.cache'])
const SEARCH_LIMIT = 120
const VISIT_LIMIT = 6000
const INDEX_LIMIT = 8000
const TEXT_LIMIT = 2_000_000
const DATA_URL_PREVIEW_LIMIT = 40_000_000
const PREVIEW_SCHEME = 'kaisola-preview'
const watchers = new Map() // subscriber id → { root, sender, chan, seq, events, timer, … }
// One OS watcher per ROOT, fanned out to every subscriber of that root — the
// rail, git panel and files view all watch the same workspace, and recursive
// fs.watch is an OS-level FSEvents stream over the whole subtree; three
// identical streams tripled the delivered-event volume for every build.
const osWatchers = new Map() // root → { watcher, recursive, ids: Set<subscriber id> }
const previewTokens = new Map()
const previewPaths = new Map()
// long sessions preview many files/pages — every map here is bounded (FIFO)
const PREVIEW_TOKEN_LIMIT = 1024
const PDF_INFO_CACHE_LIMIT = 64
const PNG_SIZE_CACHE_LIMIT = 512
const pdfInfoCache = new Map() // path\0size\0mtime → parsed pdfinfo
const pngSizeCache = new Map() // rendered png path → { width, height }
// Concurrent fs:pdfPage calls for the same zoom bucket derive one output path;
// collapse them onto a single in-flight render so only one pdftoppm runs and no
// caller ever decodes another render's partially written PNG.
const pdfRenderInFlight = new Map() // png path → Promise<{ ok, width, height, … }>
let pdfRenderSeq = 0 // monotonic — gives every render a unique temp-file path
let previewProtocolRegistered = false
const PDF_RENDER_TIMEOUT_MS = 30_000
const PDF_RENDER_MIN_DPI = 96
const PDF_RENDER_MAX_DPI = 288
const PDF_CACHE_DIR = path.join(os.tmpdir(), 'kaisola-pdf-render-cache')

try {
  protocol.registerSchemesAsPrivileged([{
    scheme: PREVIEW_SCHEME,
    privileges: {
      standard: true,
      secure: true,
      stream: true,
      supportFetchAPI: true,
      corsEnabled: false,
    },
  }])
} catch {
  // Electron only allows this once and only before ready; duplicate imports in
  // tests should never make file browsing fail.
}

const PREVIEW_TYPES = new Map([
  ['pdf', { mediaKind: 'pdf', mime: 'application/pdf' }],
  ['png', { mediaKind: 'image', mime: 'image/png' }],
  ['apng', { mediaKind: 'image', mime: 'image/apng' }],
  ['jpg', { mediaKind: 'image', mime: 'image/jpeg' }],
  ['jpeg', { mediaKind: 'image', mime: 'image/jpeg' }],
  ['jfif', { mediaKind: 'image', mime: 'image/jpeg' }],
  ['pjpeg', { mediaKind: 'image', mime: 'image/jpeg' }],
  ['pjp', { mediaKind: 'image', mime: 'image/jpeg' }],
  ['gif', { mediaKind: 'image', mime: 'image/gif' }],
  ['webp', { mediaKind: 'image', mime: 'image/webp' }],
  ['avif', { mediaKind: 'image', mime: 'image/avif' }],
  ['bmp', { mediaKind: 'image', mime: 'image/bmp' }],
  ['ico', { mediaKind: 'image', mime: 'image/x-icon' }],
  ['svg', { mediaKind: 'image', mime: 'image/svg+xml' }],
])

function isHiddenRelative(rel) {
  if (!rel) return false
  return rel.split(/[\\/]/).some((part) => HIDE.has(part))
}

function extname(p) {
  return path.extname(String(p || '')).replace(/^\./, '').toLowerCase()
}

function isProbablyBinary(buffer) {
  const len = Math.min(buffer.length, 8192)
  if (!len) return false
  // UTF-16 BOM — text, even though every other byte is NUL
  if (len >= 2 && ((buffer[0] === 0xff && buffer[1] === 0xfe) || (buffer[0] === 0xfe && buffer[1] === 0xff))) return false
  let suspicious = 0
  for (let i = 0; i < len; i += 1) {
    const byte = buffer[i]
    if (byte === 0) return true // NUL never appears in text
    // \t \n \v \f \r and ESC (ANSI colors in logs/transcripts) are ordinary
    // text; other C0 controls only mean binary when they dominate the sample
    if (byte < 32 && (byte < 9 || byte > 13) && byte !== 27) suspicious += 1
  }
  return suspicious > len / 16
}

function previewUrlFor(filePath, mime) {
  let token = previewPaths.get(filePath)
  if (!token) {
    token = crypto.randomUUID()
    previewPaths.set(filePath, token)
  }
  previewTokens.set(token, { path: filePath, mime })
  // an evicted preview 404s and re-mints its token on the next fs:read/fs:pdfPage
  while (previewTokens.size > PREVIEW_TOKEN_LIMIT) {
    const oldest = previewTokens.keys().next().value
    const evicted = previewTokens.get(oldest)
    previewTokens.delete(oldest)
    if (evicted && previewPaths.get(evicted.path) === oldest) previewPaths.delete(evicted.path)
  }
  return `${PREVIEW_SCHEME}://${token}/${encodeURIComponent(path.basename(filePath))}`
}

function runTool(cmd, args, cwd) {
  return new Promise((resolve) => {
    execFile(cmd, args, {
      cwd,
      env: agentEnv(),
      timeout: PDF_RENDER_TIMEOUT_MS,
      maxBuffer: 1024 * 1024,
    }, (err, stdout, stderr) => {
      resolve({
        ok: !err,
        enoent: err && err.code === 'ENOENT',
        timedOut: err && (err.killed || err.signal === 'SIGTERM'),
        code: err && typeof err.code === 'number' ? err.code : 0,
        out: `${stdout || ''}${stderr || ''}`,
      })
    })
  })
}

function parsePdfInfo(out) {
  const pages = Number(out.match(/^Pages:\s*(\d+)\s*$/m)?.[1])
  const size = out.match(/^Page size:\s*([0-9.]+)\s+x\s+([0-9.]+)\s+pts\b/m)
  const width = size ? Number(size[1]) : 612
  const height = size ? Number(size[2]) : 792
  if (!Number.isFinite(pages) || pages < 1) return null
  return {
    pages,
    width: Number.isFinite(width) && width > 0 ? width : 612,
    height: Number.isFinite(height) && height > 0 ? height : 792,
  }
}

async function readPdfInfo(pdfPath) {
  const r = await runTool('pdfinfo', [pdfPath], path.dirname(pdfPath))
  if (r.enoent) return { ok: false, missing: true, message: 'pdfinfo is not installed.' }
  if (!r.ok) return { ok: false, message: r.out.trim() || 'Could not inspect this PDF.' }
  const info = parsePdfInfo(r.out)
  if (!info) return { ok: false, message: 'Could not read PDF page information.' }
  return { ok: true, ...info }
}

async function statPdfPath(p) {
  if (typeof p !== 'string' || !p || extname(p) !== 'pdf') return { ok: false, message: 'Pick a PDF file.' }
  const stat = await fsp.stat(p)
  if (!stat.isFile()) return { ok: false, message: 'Pick a PDF file.' }
  return { ok: true, stat }
}

function pdfRenderKey(pdfPath, stat, page, dpi) {
  return crypto.createHash('sha1')
    .update(path.resolve(pdfPath))
    .update('\0')
    .update(String(stat.size))
    .update('\0')
    .update(String(Math.round(stat.mtimeMs)))
    .update('\0')
    .update(String(page))
    .update('\0')
    .update(String(dpi))
    .digest('hex')
}

// Render page → PNG with two guarantees the bare existsSync guard lacked:
// (1) same-path renders share one in-flight promise, so a slight zoom mid-render
// can't fire a second pdftoppm at the same file; (2) pdftoppm writes to a unique
// temp path that's atomically renamed into place, so nativeImage never decodes a
// half-written PNG. Resolves to a size on success or a failure {ok:false,…}.
async function renderPdfPage(png, prefix, pdfPath, pageNo, dpi) {
  const pending = pdfRenderInFlight.get(png)
  if (pending) return pending
  const task = (async () => {
    if (!fs.existsSync(png)) {
      await fsp.mkdir(PDF_CACHE_DIR, { recursive: true })
      const tmpPrefix = `${prefix}.tmp.${process.pid}.${pdfRenderSeq++}`
      const tmpPng = `${tmpPrefix}.png`
      const r = await runTool('pdftoppm', ['-f', String(pageNo), '-l', String(pageNo), '-singlefile', '-png', '-r', String(dpi), pdfPath, tmpPrefix], path.dirname(pdfPath))
      if (r.enoent) return { ok: false, missing: true, message: 'pdftoppm is not installed.' }
      if (!r.ok || !fs.existsSync(tmpPng)) {
        try { fs.rmSync(tmpPng, { force: true }) } catch { /* nothing to clean up */ }
        return { ok: false, message: r.out.trim() || 'Could not render this PDF page.' }
      }
      try {
        fs.renameSync(tmpPng, png)
      } catch (err) {
        try { fs.rmSync(tmpPng, { force: true }) } catch { /* raced */ }
        return { ok: false, message: String((err && err.message) || err) }
      }
      trimPdfCache()
    }
    let size = pngSizeCache.get(png)
    if (!size) {
      const image = nativeImage.createFromPath(png)
      // a fully rendered page that still decodes empty is a real failure — never
      // cache {0,0}; drop the file so a later call re-renders instead of being
      // served a blank page forever from a poisoned cache
      if (image.isEmpty()) {
        try { fs.rmSync(png, { force: true }) } catch { /* raced */ }
        return { ok: false, message: 'Could not render this PDF page.' }
      }
      size = image.getSize()
      pngSizeCache.set(png, size)
      while (pngSizeCache.size > PNG_SIZE_CACHE_LIMIT) pngSizeCache.delete(pngSizeCache.keys().next().value)
    }
    return { ok: true, width: size.width, height: size.height }
  })()
  pdfRenderInFlight.set(png, task)
  try {
    return await task
  } finally {
    pdfRenderInFlight.delete(png)
  }
}

function parseRange(header, size) {
  const m = String(header || '').match(/^bytes=(\d*)-(\d*)$/)
  if (!m) return null
  const startRaw = m[1]
  const endRaw = m[2]
  if (!startRaw && !endRaw) return null
  if (!startRaw) {
    const suffix = Number(endRaw)
    if (!Number.isFinite(suffix) || suffix <= 0) return null
    return { start: Math.max(0, size - suffix), end: size - 1 }
  }
  const start = Number(startRaw)
  const end = endRaw ? Number(endRaw) : size - 1
  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < start || start >= size) return null
  return { start, end: Math.min(end, size - 1) }
}

function responseFromFile(filePath, mime, request) {
  const stat = fs.statSync(filePath)
  if (!stat.isFile()) return new Response('Not found', { status: 404 })
  if (stat.size === 0) {
    return new Response('', {
      status: 200,
      headers: {
        'content-type': mime,
        'content-length': '0',
        'accept-ranges': 'bytes',
        'cache-control': 'no-store',
      },
    })
  }
  const range = parseRange(request.headers.get('range'), stat.size)
  const start = range?.start ?? 0
  const end = range?.end ?? Math.max(0, stat.size - 1)
  const length = Math.max(0, end - start + 1)
  const body = length > 0
    ? Readable.toWeb(fs.createReadStream(filePath, { start, end }))
    : new ReadableStream({ start(controller) { controller.close() } })
  const headers = {
    'content-type': mime,
    'content-length': String(length),
    'accept-ranges': 'bytes',
    'cache-control': 'no-store',
  }
  if (range) headers['content-range'] = `bytes ${start}-${end}/${stat.size}`
  return new Response(body, { status: range ? 206 : 200, headers })
}

function registerPreviewProtocol() {
  if (previewProtocolRegistered) return
  previewProtocolRegistered = true
  protocol.handle(PREVIEW_SCHEME, async (request) => {
    try {
      const url = new URL(request.url)
      const token = url.hostname || url.pathname.replace(/^\/+/, '').split('/')[0]
      const item = previewTokens.get(token)
      if (!item) return new Response('Not found', { status: 404 })
      return responseFromFile(item.path, item.mime, request)
    } catch (err) {
      return new Response(String((err && err.message) || err), { status: 404 })
    }
  })
}

function closeWatcher(id) {
  const state = watchers.get(id)
  if (!state) return
  watchers.delete(id)
  if (state.timer) clearTimeout(state.timer)
  try {
    if (state.destroyListener && !state.sender.isDestroyed()) state.sender.removeListener('destroyed', state.destroyListener)
  } catch { /* sender already gone */ }
  // release the shared OS watcher; close it with the last subscriber
  const os = osWatchers.get(state.root)
  if (os) {
    os.ids.delete(id)
    if (!os.ids.size) {
      osWatchers.delete(state.root)
      try { os.watcher.close() } catch { /* already closed */ }
    }
  }
}

/** Get (or start) the single OS watcher for a root. Events fan out to every
 * subscriber's own batch/debounce state, so per-subscriber behavior — its
 * channel, seq, 90ms coalescing — is exactly what a private watcher gave. */
function acquireOsWatcher(root) {
  let os = osWatchers.get(root)
  if (os) return os
  const onEvent = (eventType, filename) => {
    const rel = filename ? String(filename) : ''
    if (isHiddenRelative(rel)) return
    const entry = osWatchers.get(root)
    if (!entry) return
    for (const id of entry.ids) {
      const sub = watchers.get(id)
      if (!sub) continue
      sub.events.push({
        eventType: String(eventType || 'change'),
        name: rel ? path.basename(rel) : '',
        path: rel ? path.join(root, rel) : root,
      })
      if (sub.timer) clearTimeout(sub.timer)
      sub.timer = setTimeout(() => sendWatchBatch(id), 90)
    }
  }
  let recursive = true
  let watcher
  try {
    watcher = fs.watch(root, { recursive: true, persistent: false }, onEvent)
  } catch {
    recursive = false
    watcher = fs.watch(root, { persistent: false }, onEvent)
  }
  watcher.on('error', (err) => {
    const entry = osWatchers.get(root)
    if (!entry) return
    for (const id of Array.from(entry.ids)) {
      const sub = watchers.get(id)
      if (sub && !sub.sender.isDestroyed())
        sub.sender.send(sub.chan, { root, seq: ++sub.seq, events: [], error: String((err && err.message) || err) })
      closeWatcher(id)
    }
  })
  os = { watcher, recursive, ids: new Set() }
  osWatchers.set(root, os)
  return os
}

function sendWatchBatch(id) {
  const state = watchers.get(id)
  if (!state) return
  state.timer = null
  const events = state.events.splice(0)
  if (!events.length || state.sender.isDestroyed()) return
  state.sender.send(state.chan, { root: state.root, seq: ++state.seq, events })
}

function registerFsHandlers(ipcMain) {
  registerPreviewProtocol()

  ipcMain.handle('fs:list', async (_e, { dir } = {}) => {
    try {
      const entries = await fsp.readdir(dir, { withFileTypes: true })
      const items = entries
        .filter((e) => !HIDE.has(e.name))
        .map((e) => ({ name: e.name, path: path.join(dir, e.name), dir: e.isDirectory() }))
        .sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1))
      return { ok: true, entries: items }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('fs:search', async (_e, { root, query } = {}) => {
    try {
      if (typeof root !== 'string' || !root) return { ok: false, message: 'no root' }
      const q = String(query ?? '').trim().toLowerCase()
      if (!q) return { ok: true, entries: [] }
      const entries = []
      let visited = 0
      const walk = async (dir) => {
        if (entries.length >= SEARCH_LIMIT || visited >= VISIT_LIMIT) return
        let items
        try {
          items = await fsp.readdir(dir, { withFileTypes: true })
        } catch {
          return
        }
        for (const item of items) {
          if (entries.length >= SEARCH_LIMIT || visited >= VISIT_LIMIT) return
          if (HIDE.has(item.name) || item.isSymbolicLink()) continue
          const p = path.join(dir, item.name)
          visited++
          if (item.isDirectory()) {
            await walk(p)
            continue
          }
          const rel = path.relative(root, p)
          if (item.name.toLowerCase().includes(q) || rel.toLowerCase().includes(q)) {
            entries.push({ name: item.name, path: p, dir: false })
          }
        }
      }
      await walk(root)
      return { ok: true, entries, truncated: entries.length >= SEARCH_LIMIT || visited >= VISIT_LIMIT }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  // Flat list of every (non-hidden) file under root — the ⌘P fuzzy finder's
  // candidate set. One IPC per palette open; matching happens in the renderer.
  ipcMain.handle('fs:index', async (_e, { root } = {}) => {
    try {
      if (typeof root !== 'string' || !root) return { ok: false, message: 'no root' }
      const files = []
      const walk = async (dir) => {
        if (files.length >= INDEX_LIMIT) return
        let items
        try {
          items = await fsp.readdir(dir, { withFileTypes: true })
        } catch {
          return
        }
        for (const item of items) {
          if (files.length >= INDEX_LIMIT) return
          if (HIDE.has(item.name) || item.name.startsWith('.') || item.isSymbolicLink()) continue
          const p = path.join(dir, item.name)
          if (item.isDirectory()) await walk(p)
          else files.push(path.relative(root, p))
        }
      }
      await walk(root)
      return { ok: true, files, truncated: files.length >= INDEX_LIMIT }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  // ── file management (tree context menu): create / rename / trash ──
  ipcMain.handle('fs:create', async (_e, { path: p, dir } = {}) => {
    try {
      if (typeof p !== 'string' || !p) return { ok: false, message: 'no path' }
      if (fs.existsSync(p)) return { ok: false, message: 'Already exists.' }
      if (dir) await fsp.mkdir(p, { recursive: true })
      else {
        await fsp.mkdir(path.dirname(p), { recursive: true })
        await fsp.writeFile(p, '', { flag: 'wx' })
      }
      return { ok: true }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('fs:rename', async (_e, { from, to } = {}) => {
    try {
      if (typeof from !== 'string' || typeof to !== 'string' || !from || !to) return { ok: false, message: 'bad paths' }
      if (fs.existsSync(to)) {
        // case-only renames on macOS's case-insensitive APFS resolve `to` to the
        // SAME file as `from` — only a genuinely different target is a collision
        let same = false
        try {
          const a = fs.statSync(from)
          const b = fs.statSync(to)
          same = a.ino === b.ino && a.dev === b.dev
        } catch { /* stat raced — treat as a collision */ }
        if (!same) return { ok: false, message: 'Target already exists.' }
      }
      await fsp.rename(from, to)
      return { ok: true }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  // Delete = macOS Trash, never rm — every tree deletion stays recoverable.
  ipcMain.handle('fs:trash', async (_e, { path: p } = {}) => {
    try {
      if (typeof p !== 'string' || !p) return { ok: false, message: 'no path' }
      await shell.trashItem(p)
      return { ok: true }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('fs:reveal', async (_e, { path: p } = {}) => {
    if (typeof p === 'string' && p) shell.showItemInFolder(p)
    return { ok: true }
  })

  ipcMain.handle('fs:pdfInfo', async (_e, { path: p } = {}) => {
    try {
      const checked = await statPdfPath(p)
      if (!checked.ok) return checked
      const info = await readPdfInfo(p)
      return info.ok ? { ok: true, path: p, ...info } : info
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('fs:pdfPage', async (_e, { path: p, page, scale } = {}) => {
    try {
      const checked = await statPdfPath(p)
      if (!checked.ok) return checked
      // pdfinfo is a subprocess — cache it per file VERSION so cache hits below
      // don't pay a spawn just to clamp an already-validated page number
      const infoKey = `${path.resolve(p)}\0${checked.stat.size}\0${Math.round(checked.stat.mtimeMs)}`
      let info = pdfInfoCache.get(infoKey)
      if (!info) {
        info = await readPdfInfo(p)
        if (!info.ok) return info
        pdfInfoCache.set(infoKey, info)
        while (pdfInfoCache.size > PDF_INFO_CACHE_LIMIT) pdfInfoCache.delete(pdfInfoCache.keys().next().value)
      }
      const pageNo = Math.min(info.pages, Math.max(1, Math.floor(Number(page) || 1)))
      // quantize zoom to quarter steps — a continuous pinch would otherwise mint
      // ~150 distinct dpi variants per page and defeat the render cache
      const quantScale = Math.round((Number(scale) || 1) * 4) / 4
      const dpi = Math.min(PDF_RENDER_MAX_DPI, Math.max(PDF_RENDER_MIN_DPI, Math.round(quantScale * 144)))
      const key = pdfRenderKey(p, checked.stat, pageNo, dpi)
      const prefix = path.join(PDF_CACHE_DIR, key)
      const png = `${prefix}.png`
      const rendered = await renderPdfPage(png, prefix, p, pageNo, dpi)
      if (!rendered.ok) return rendered
      return {
        ok: true,
        page: pageNo,
        url: previewUrlFor(png, 'image/png'),
        width: rendered.width,
        height: rendered.height,
        scale: dpi / 72,
      }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('fs:read', async (_e, { path: p } = {}) => {
    try {
      if (typeof p !== 'string' || !p) return { ok: false, message: 'no path' }
      const stat = await fsp.stat(p)
      if (stat.isDirectory()) return { ok: false, message: 'This is a folder.' }

      const preview = PREVIEW_TYPES.get(extname(p))
      if (preview) {
        if (preview.mediaKind === 'pdf') {
          return {
            ok: true,
            content: '',
            binary: true,
            size: stat.size,
            // previewUrl is a stable per-path token — mtimeMs is the renderer's
            // signal that the bytes changed (rebuilds must re-render pages)
            mtimeMs: Math.round(stat.mtimeMs),
            previewUrl: previewUrlFor(p, preview.mime),
            ...preview,
          }
        }
        if (stat.size > DATA_URL_PREVIEW_LIMIT) {
          return { ok: true, content: '', tooLarge: true, binary: true, size: stat.size, ...preview }
        }
        const buffer = await fsp.readFile(p)
        // svg is source code as much as an image: serve small ones as TEXT so
        // they stay editable — the viewer renders its own live image preview
        if (preview.mime === 'image/svg+xml' && stat.size <= TEXT_LIMIT) {
          return { ok: true, content: buffer.toString('utf8'), mediaKind: 'text', mime: preview.mime, size: stat.size }
        }
        return {
          ok: true,
          content: '',
          binary: true,
          size: stat.size,
          dataUrl: `data:${preview.mime};base64,${buffer.toString('base64')}`,
          ...preview,
        }
      }

      if (stat.size > TEXT_LIMIT) return { ok: true, content: '', tooLarge: true, mediaKind: 'text', size: stat.size }
      const buffer = await fsp.readFile(p)
      if (isProbablyBinary(buffer)) {
        return { ok: true, content: '', binary: true, unsupported: true, mediaKind: 'binary', mime: 'application/octet-stream', size: stat.size }
      }
      return { ok: true, content: buffer.toString('utf8'), mediaKind: 'text', size: stat.size }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  // An image attachment's bytes, base64 — the agent chat sends these as ACP
  // image content blocks so a dropped screenshot reaches the model as pixels
  // (the path alone is useless to an agent that can't read local files).
  ipcMain.handle('fs:readImage', async (_e, { path: p } = {}) => {
    try {
      if (typeof p !== 'string' || !p) return { ok: false, message: 'no path' }
      // NB: this file's extname() is dot-less + lowercased ("png", not ".png")
      const mime = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp' }[extname(p)]
      if (!mime) return { ok: false, message: 'Not a supported image type.' }
      const stat = await fsp.stat(p)
      // prompts are JSON over stdio — keep inline blocks sane (8 MB of pixels
      // ≈ 11 MB of base64); bigger images still ride as a path in the text
      if (stat.size > 8 * 1024 * 1024) return { ok: false, message: 'Image is larger than the 8 MB inline cap.' }
      const buf = await fsp.readFile(p)
      return { ok: true, mimeType: mime, data: buf.toString('base64'), size: stat.size }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  // Save manual edits back to a workspace file (the IDE's edit path).
  ipcMain.handle('fs:write', async (_e, { path: p, content } = {}) => {
    try {
      if (typeof p !== 'string' || !p) return { ok: false, message: 'no path' }
      // Symmetric with the 2MB read cap — never accept an unbounded write.
      if (typeof content === 'string' && Buffer.byteLength(content, 'utf8') > TEXT_LIMIT)
        return { ok: false, message: 'too large to save' }
      await fsp.writeFile(p, content ?? '', 'utf8')
      return { ok: true }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('fs:watch', async (e, { id, root } = {}) => {
    try {
      if (typeof id !== 'string' || !id) return { ok: false, message: 'no watcher id' }
      if (typeof root !== 'string' || !root) return { ok: false, message: 'no root' }
      const stat = await fsp.stat(root)
      if (!stat.isDirectory()) return { ok: false, message: 'root is not a directory' }
      closeWatcher(id)

      const os = acquireOsWatcher(root)
      const destroyListener = () => closeWatcher(id)
      const state = {
        root,
        recursive: os.recursive,
        sender: e.sender,
        chan: `fs:event:${id}`,
        seq: 0,
        events: [],
        timer: null,
        destroyListener,
      }
      watchers.set(id, state)
      os.ids.add(id)
      e.sender.once('destroyed', destroyListener)

      return { ok: true, recursive: os.recursive }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('fs:unwatch', async (_e, { id } = {}) => {
    closeWatcher(id)
    return { ok: true }
  })
}

// Rendered page PNGs accumulate one file per (pdf version, page, dpi) — cap the
// directory so a long writing session can't grow tmp without bound.
const PDF_CACHE_MAX_FILES = 600
function trimPdfCache() {
  try {
    const names = fs.readdirSync(PDF_CACHE_DIR)
    if (names.length <= PDF_CACHE_MAX_FILES) return
    const stated = names
      .map((name) => {
        const p = path.join(PDF_CACHE_DIR, name)
        try { return { p, mtime: fs.statSync(p).mtimeMs } } catch { return null }
      })
      .filter(Boolean)
      .sort((a, b) => a.mtime - b.mtime)
    for (const f of stated.slice(0, stated.length - PDF_CACHE_MAX_FILES)) {
      try { fs.rmSync(f.p); pngSizeCache.delete(f.p) } catch { /* raced */ }
    }
  } catch { /* cache dir missing — nothing to trim */ }
}

function disposeFs() {
  for (const id of Array.from(watchers.keys())) closeWatcher(id)
  // renders are cheap to redo — drop the whole cache with the process
  try { fs.rmSync(PDF_CACHE_DIR, { recursive: true, force: true }) } catch { /* tmp cleanup is best-effort */ }
}

module.exports = { registerFsHandlers, disposeFs }
