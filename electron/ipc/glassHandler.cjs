// Wallpaper sampling for the painted glass wash. The renderer asks for the
// desktop picture under its window and gets back the average color (retints
// the chrome veils) plus a pre-blurred copy (the painted mode background).
// Every failure returns { ok: false } — the renderer keeps the theme-tint
// defaults, which are exactly the pre-sampling look. Never a toast.
const { nativeImage, BrowserWindow, screen, nativeTheme } = require('electron')
const { execFile } = require('node:child_process')
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

// nativeImage can't decode HEIC (Apple's dynamic wallpapers) — sips converts
// once per source into a temp cache, downsampled: sampling needs no pixels
// beyond ~1200 wide.
async function loadWallpaper(p) {
  let img = nativeImage.createFromPath(p)
  if (!img.isEmpty()) return img
  const cached = path.join(os.tmpdir(), `kaisola-wp-${Buffer.from(p).toString('base64url').slice(0, 24)}.png`)
  if (!fs.existsSync(cached)) {
    const ok = await exec('/usr/bin/sips', ['-s', 'format', 'png', '--resampleWidth', '1200', p, '--out', cached], 15000)
    if (ok == null) return null
  }
  img = nativeImage.createFromPath(cached)
  return img.isEmpty() ? null : img
}

function sampleForWindow(win, img) {
  const disp = screen.getDisplayMatching(win.getBounds())
  const { width: iw, height: ih } = img.getSize()
  const db = disp.bounds
  // aspect-fill mapping of the wallpaper onto the display (macOS default)
  const scale = Math.max(db.width / iw, db.height / ih)
  const visW = db.width / scale
  const visH = db.height / scale
  const offX = (iw - visW) / 2
  const offY = (ih - visH) / 2
  const wb = win.getBounds()
  const rect = {
    x: Math.round(offX + Math.max(0, wb.x - db.x) / scale),
    y: Math.round(offY + Math.max(0, wb.y - db.y) / scale),
    width: Math.max(1, Math.round(Math.min(wb.width, db.width) / scale)),
    height: Math.max(1, Math.round(Math.min(wb.height, db.height) / scale)),
  }
  rect.x = Math.max(0, Math.min(rect.x, iw - rect.width))
  rect.y = Math.max(0, Math.min(rect.y, ih - rect.height))
  const px = img.crop(rect).resize({ width: 1, height: 1 }).toBitmap() // BGRA
  const avg = { r: px[2], g: px[1], b: px[0] }
  // pre-blurred copy for the painted layer: a heavy downscale IS the blur
  // (the renderer re-scales it to screen size under a static CSS blur)
  const blurDataUrl = 'data:image/jpeg;base64,' + img.resize({ width: 120 }).toJPEG(70).toString('base64')
  return { ok: true, avg, blurDataUrl, screen: { x: db.x, y: db.y, w: db.width, h: db.height } }
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

module.exports = { registerGlassHandlers, wireGlassEvents }
