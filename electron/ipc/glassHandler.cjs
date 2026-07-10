// Wallpaper average sampling for Live Glass chrome. The renderer receives only
// three RGB bytes; a tiny thumbnail lives on disk and no desktop raster stays
// retained in Electron memory.
// Every failure returns { ok: false } — the renderer keeps the theme-tint
// defaults, which are exactly the pre-sampling look. Never a toast.
const { nativeImage, BrowserWindow, screen, nativeTheme } = require('electron')
const { execFile } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const exec = (cmd, args, timeout = 4000) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout }, (err, stdout) => resolve(err ? null : String(stdout).trim()))
  })

// Wallpaper path WITHOUT an Automation permission prompt: macOS 14+ keeps the
// wallpaper config in com.apple.wallpaper/Store/Index.plist (read as xml1 —
// its <data> blobs make plutil's json conversion fail). Image wallpapers give
// a plain file URL. Aerial (video) wallpapers give an asset/category UUID —
// the local thumbnail cache has a representative still; rotating categories
// fall back to the newest downloaded video's thumbnail. Last resort:
// AppleScript (one-time OS consent, denial degrades silently). Probes/CI
// (KAISOLA_SMOKE) never run osascript.
async function wallpaperPath() {
  const home = os.homedir()
  const plist = path.join(home, 'Library/Application Support/com.apple.wallpaper/Store/Index.plist')
  if (fs.existsSync(plist)) {
    const xml = await exec('/usr/bin/plutil', ['-convert', 'xml1', '-o', '-', plist])
    if (xml) {
      const m = xml.match(/file:\/\/[^<"]+/)
      if (m) {
        try {
          const p = decodeURIComponent(m[0].replace('file://', ''))
          if (fs.existsSync(p) && fs.statSync(p).isFile()) return p
        } catch { /* keep going */ }
      }
      if (xml.includes('aerials')) {
        const aerials = path.join(home, 'Library/Application Support/com.apple.wallpaper/aerials')
        const uuidOf = (b64) => {
          try {
            return (Buffer.from(b64, 'base64').toString('latin1')
              .match(/[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/) || [])[0]
          } catch { return null }
        }
        for (const data of xml.match(/<data>[\s\S]*?<\/data>/g) || []) {
          const uuid = uuidOf(data.replace(/<\/?data>/g, '').replace(/\s+/g, ''))
          const thumb = uuid && path.join(aerials, 'thumbnails', `${uuid}.png`)
          if (thumb && fs.existsSync(thumb)) return thumb
        }
        try {
          const dir = path.join(aerials, 'videos')
          const vids = fs.readdirSync(dir)
            .filter((f) => f.endsWith('.mov'))
            .map((f) => ({ f, t: fs.statSync(path.join(dir, f)).mtimeMs }))
            .sort((a, b) => b.t - a.t)
          for (const { f } of vids) {
            const thumb = path.join(aerials, 'thumbnails', f.replace(/\.mov$/, '.png'))
            if (fs.existsSync(thumb)) return thumb
          }
        } catch { /* fall through */ }
      }
    }
  }
  if (process.env.KAISOLA_SMOKE || process.env.PASOLA_SMOKE) return null
  const out = await exec('/usr/bin/osascript', ['-e', 'tell application "System Events" to get POSIX path of (get picture of desktop 1)'])
  return out && fs.existsSync(out) ? out : null
}

// Decode/downsample in a short-lived native helper before Electron touches the
// pixels. A full 6K/8K PNG can otherwise transiently add 100–250MB to main.
// Ninety-six pixels is ample for a local average and keeps the nativeImage well
// below 100KB; the thumbnail is reusable disk cache, not renderer heap.
async function loadWallpaper(p) {
  let stat
  try { stat = fs.statSync(p) } catch { return null }
  const cacheKey = `${p}:${stat.mtimeMs}:${stat.size}`
  const digest = crypto.createHash('sha256').update(cacheKey).digest('hex').slice(0, 24)
  const cached = path.join(os.tmpdir(), `kaisola-wp-avg96-${digest}.jpg`)
  if (!fs.existsSync(cached)) {
    const ok = await exec('/usr/bin/sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '72', '--resampleWidth', '96', p, '--out', cached], 15000)
    if (ok == null) {
      // Non-mac/test fallback: still cap the retained nativeImage immediately.
      const direct = nativeImage.createFromPath(p)
      if (direct.isEmpty()) return null
      const size = direct.getSize()
      return size.width > 96 ? direct.resize({ width: 96 }) : direct
    }
  }
  const img = nativeImage.createFromPath(cached)
  if (img.isEmpty()) return null
  return img
}

/**
 * Source rectangle macOS displays when an image is aspect-filled into a
 * display. Keeping this calculation in main means the renderer receives an
 * already-correct display frame instead of stretching the wallpaper to the
 * screen's aspect ratio (the old painted-mode distortion bug).
 */
function aspectFillRect(imageSize, displaySize) {
  const iw = Math.max(1, imageSize.width)
  const ih = Math.max(1, imageSize.height)
  const dw = Math.max(1, displaySize.width)
  const dh = Math.max(1, displaySize.height)
  const scale = Math.max(dw / iw, dh / ih)
  const visW = Math.min(iw, dw / scale)
  const visH = Math.min(ih, dh / scale)
  const width = Math.max(1, Math.min(iw, Math.round(visW)))
  const height = Math.max(1, Math.min(ih, Math.round(visH)))
  return {
    x: Math.max(0, Math.min(iw - width, Math.round((iw - visW) / 2))),
    y: Math.max(0, Math.min(ih - height, Math.round((ih - visH) / 2))),
    width,
    height,
  }
}

function sampleForWindow(win, img) {
  const disp = screen.getDisplayMatching(win.getBounds())
  const { width: iw, height: ih } = img.getSize()
  const db = disp.bounds
  // aspect-fill mapping of the wallpaper onto the display (macOS default)
  const displayRect = aspectFillRect({ width: iw, height: ih }, db)
  const scaleX = db.width / displayRect.width
  const scaleY = db.height / displayRect.height
  const wb = win.getBounds()
  // A window can hang off an edge or straddle displays. Sample only the part
  // actually on the selected display so the average never clamps a too-large
  // crop onto an unrelated wallpaper region.
  const left = Math.max(wb.x, db.x)
  const top = Math.max(wb.y, db.y)
  const right = Math.min(wb.x + wb.width, db.x + db.width)
  const bottom = Math.min(wb.y + wb.height, db.y + db.height)
  const rect = {
    x: Math.round(displayRect.x + Math.max(0, left - db.x) / scaleX),
    y: Math.round(displayRect.y + Math.max(0, top - db.y) / scaleY),
    width: Math.max(1, Math.round(Math.max(1, right - left) / scaleX)),
    height: Math.max(1, Math.round(Math.max(1, bottom - top) / scaleY)),
  }
  rect.x = Math.max(0, Math.min(rect.x, iw - rect.width))
  rect.y = Math.max(0, Math.min(rect.y, ih - rect.height))
  const px = img.crop(rect).resize({ width: 1, height: 1 }).toBitmap() // BGRA
  const avg = { r: px[2], g: px[1], b: px[0] }
  return { ok: true, avg }
}

function registerGlassHandlers(ipcMain) {
  ipcMain.handle('glass:sample', async (e) => {
    try {
      if (process.platform !== 'darwin') return { ok: false }
      const win = BrowserWindow.fromWebContents(e.sender)
      if (!win || win.isDestroyed()) return { ok: false }
      const p = await wallpaperPath()
      if (!p) return { ok: false }
      const img = await loadWallpaper(p)
      if (!img) return { ok: false }
      return sampleForWindow(win, img)
    } catch {
      return { ok: false }
    }
  })
}

// nudge this window's renderer to re-sample when the answer may have changed
function wireGlassEvents(win) {
  if (process.platform !== 'darwin') return
  let t = null
  const nudge = () => {
    clearTimeout(t)
    t = setTimeout(() => {
      if (!win.isDestroyed() && !win.webContents.isDestroyed()) win.webContents.send('glass:refresh')
    }, 450)
  }
  win.on('moved', nudge)
  win.on('resize', nudge)
  const iv = setInterval(nudge, 5 * 60 * 1000) // dynamic wallpapers drift with the day
  if (iv.unref) iv.unref()
  screen.on('display-metrics-changed', nudge)
  nativeTheme.on('updated', nudge)
  win.on('closed', () => {
    clearTimeout(t)
    clearInterval(iv)
    screen.removeListener('display-metrics-changed', nudge)
    nativeTheme.removeListener('updated', nudge)
  })
}

module.exports = { registerGlassHandlers, wireGlassEvents, __test: { aspectFillRect } }
