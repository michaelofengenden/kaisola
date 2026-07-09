// Standalone reproduction of the PAINTED-mode wallpaper pipeline
// (glassHandler.cjs sampleForWindow + shell.css .app-wallpaper), rendered
// against static local HTML pages instead of the full app boot chain.
// No osascript involved: the source frame is a real aerial-wallpaper
// thumbnail already cached on disk by macOS (same file the shipped app
// would fall back to on this machine's aerial-video wallpaper setup).
const { app, BrowserWindow } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fsx = require('node:fs')

const USER_DATA = path.join(os.tmpdir(), 'kaisola-wallpaperprobe')
try { fsx.rmSync(USER_DATA, { recursive: true, force: true }) } catch {}
fsx.mkdirSync(USER_DATA, { recursive: true })
app.setPath('userData', USER_DATA)

const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const SHOTS = process.argv[2]
const PAGES = fsx.readdirSync(SHOTS)
  .filter((f) => f.startsWith('page_') && f.endsWith('.html'))
  .map((f) => f.slice('page_'.length, -'.html'.length))
  .sort()

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    show: true, width: 1728, height: 1117, frame: false,
    webPreferences: { backgroundThrottling: false },
  })
  for (const name of PAGES) {
    const file = path.join(SHOTS, `page_${name}.html`)
    await win.loadFile(file)
    await wait(500)
    win.webContents.invalidate()
    await wait(600)
    const img = await win.webContents.capturePage()
    fsx.writeFileSync(path.join(SHOTS, `shot_${name}.png`), img.toPNG())
    console.log('captured', name, img.getSize())
  }
  app.exit(0)
})
