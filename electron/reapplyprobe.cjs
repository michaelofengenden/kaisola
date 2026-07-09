// Window-mode reapply probe — proves the Apply-now contract: a perfMode
// switch across the transparency boundary recreates the renderer WINDOW, not
// the app, and everything in main rides through.
//
// Run: vite build && electron electron/reapplyprobe.cjs
const { app, BrowserWindow } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fsx = require('node:fs')

process.env.KAISOLA_SMOKE = '1'
const USER_DATA = path.join(os.tmpdir(), 'kaisola-reapplyprobe')
try { fsx.rmSync(USER_DATA, { recursive: true, force: true }) } catch { /* fresh */ }
fsx.mkdirSync(USER_DATA, { recursive: true })
fsx.writeFileSync(path.join(USER_DATA, 'shell-prefs.json'), JSON.stringify({ solidWindow: false }))
// Set the isolated profile BEFORE main acquires its single-instance/ledger
// ownership lock; the probe must never collide with an installed Kaisola.
app.setPath('appData', USER_DATA)
app.setPath('userData', USER_DATA)

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const fail = (why) => { console.log('REAPPLY_RESULT=FAIL ' + why); app.exit(1) }

require('./main.cjs')

app.whenReady().then(async () => {
  await wait(2500)
  const before = BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed())
  if (before.length !== 1) return fail(`expected one window, got ${before.length}`)
  const first = before[0]
  const firstId = first.webContents.id
  if (first.__kaisolaSolid !== false) return fail('first window should be transparent')

  // A real PTY in main — it must remain the SAME process through the renderer
  // swap, not merely restart from a persisted command.
  const mgr = require('./ipc/terminalManager.cjs')
  mgr.spawn({ id: 'reapply-pty', sender: first.webContents })
  await wait(900)
  mgr.write('reapply-pty', 'echo pty-rode-through\r')

  const swapped = await first.webContents.executeJavaScript(
    `window.kaisola.windowMode({ solidWindow: true }).then(() => window.kaisola.reapplyWindow())`,
  )
  if (!swapped?.ok) return fail('reapplyWindow refused: ' + JSON.stringify(swapped))

  await wait(3000)
  const after = BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed())
  const next = after[0]
  const snap = mgr.snapshot('reapply-pty')
  const material = next
    ? await next.webContents.executeJavaScript(`window.kaisola.glass()`)
    : null
  const results = {
    swapped: after.length === 1 && !!next && next.webContents.id !== firstId && next.__kaisolaSolid === true,
    ptyAlive: !!snap && /pty-rode-through/.test(snap.output || '') && snap.exitStatus == null,
    appAlive: true,
    solidHasNoNativeGlass: material?.active === false && material?.fallback === 'solid',
  }
  console.log('REAPPLY=' + JSON.stringify(results))
  console.log('REAPPLY_RESULT=' + (Object.values(results).every(Boolean) ? 'PASS' : 'FAIL'))
  app.exit(Object.values(results).every(Boolean) ? 0 : 1)
}).catch((error) => fail(String(error?.message || error)))
