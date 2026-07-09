// Window-mode reapply probe — proves the "Apply now" chip's contract: a
// perfMode switch across the transparency boundary recreates the WINDOW, not
// the app, and everything in the main process rides through. Boots the REAL
// main.cjs against isolated userData, spawns a pty, flips shell-prefs, calls
// shell:reapply-window from the renderer, then asserts:
//   swapped   — one window after, new webContents, flipped __kaisolaSolid
//   ptyAlive  — a pty spawned BEFORE the swap still answers AFTER it
//   appAlive  — the app never quit (window-all-closed guard held)
// Run: vite build && electron electron/reapplyprobe.cjs   (smoke leaves dist/)
const { app, BrowserWindow } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fsx = require('node:fs')

process.env.KAISOLA_SMOKE = '1'
const USER_DATA = path.join(os.tmpdir(), 'kaisola-reapplyprobe')
try { fsx.rmSync(USER_DATA, { recursive: true, force: true }) } catch { /* fresh */ }
fsx.mkdirSync(USER_DATA, { recursive: true })
// start TRANSPARENT (glass) — the swap crosses to solid (painted/eco)
fsx.writeFileSync(path.join(USER_DATA, 'shell-prefs.json'), JSON.stringify({ solidWindow: false }))

const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const fail = (why) => { console.log('REAPPLY_RESULT=FAIL ' + why); app.exit(1) }

require('./main.cjs') // the real app — creates the first window on ready
// AFTER main.cjs: its legacy-rename shim points userData at the real
// ~/Library dir when one exists — isolate ourselves once it has run (every
// prefs/db read is lazy, so this probe dir is what actually gets used)
app.setPath('userData', USER_DATA)

app.whenReady().then(async () => {
  await wait(2500) // let the shell finish loading dist
  const before = BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed())
  if (before.length !== 1) return fail(`expected 1 window, got ${before.length}`)
  const w1 = before[0]
  const id1 = w1.webContents.id
  if (w1.__kaisolaSolid !== false) return fail(`first window should be transparent (got ${JSON.stringify(w1.__kaisolaSolid)}, prefs=${fsx.readFileSync(path.join(USER_DATA, 'shell-prefs.json'), 'utf8')})`)

  // a pty in the main process — the thing that must survive the swap
  const mgr = require('./ipc/terminalManager.cjs')
  mgr.spawn({ id: 'reapply-pty', sender: w1.webContents })
  await wait(900)
  mgr.write('reapply-pty', 'echo pty-rode-through\r')

  // the renderer's own Settings path: persist the flip, then apply in place
  const swapped = await w1.webContents.executeJavaScript(
    `window.kaisola.windowMode({ solidWindow: true }).then(() => window.kaisola.reapplyWindow())`,
  )
  if (!swapped || !swapped.ok) return fail('reapplyWindow refused: ' + JSON.stringify(swapped))

  await wait(3000) // old window closes, new one loads dist
  const after = BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed())
  const w2 = after[0]
  const results = {
    swapped: after.length === 1 && !!w2 && w2.webContents.id !== id1 && w2.__kaisolaSolid === true,
    ptyAlive: false,
    appAlive: true, // reaching this line means window-all-closed didn't quit us
  }
  const snap = mgr.snapshot('reapply-pty')
  results.ptyAlive = !!snap && /pty-rode-through/.test(snap.output || '') && snap.exitStatus == null
  console.log('REAPPLY=' + JSON.stringify(results))
  console.log('REAPPLY_RESULT=' + (Object.values(results).every(Boolean) ? 'PASS' : 'FAIL'))
  app.exit(Object.values(results).every(Boolean) ? 0 : 1)
}).catch((e) => fail(String((e && e.message) || e)))
