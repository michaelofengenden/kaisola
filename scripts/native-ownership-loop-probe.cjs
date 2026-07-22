#!/usr/bin/env node
'use strict'
// Replicates EXACTLY what the native app's BrokerControlClient + AppModel do,
// against the live dev broker, to prove the full ownership loop:
//   create (owner) -> write -> echo observed -> detach (quit) -> reattach
//   (relaunch) with SAME pid and continuous scrollback -> write again -> kill.
const fs = require('node:fs')
const net = require('node:net')
const os = require('node:os')
const path = require('node:path')
const crypto = require('node:crypto')

const info = JSON.parse(fs.readFileSync(
  path.join(os.homedir(), 'Library/Application Support/Kaisola Dev/session-broker/broker.json'), 'utf8'))
const OWNER = 'native-' + crypto.randomUUID()          // stable per-install id (NativeSessionStore.ownerID)
const PROJECT = 'nproj_' + crypto.randomBytes(3).toString('hex')
const TERMINAL = `term-${PROJECT}-${crypto.randomUUID().slice(0, 8)}`
const wait = (ms) => new Promise((r) => setTimeout(r, ms))

function connect(access) {
  const socket = net.createConnection(info.socketPath)
  socket.setNoDelay(true)
  const iid = crypto.randomUUID()               // UUID-shaped, as the broker requires
  let buf = ''; let seq = 0
  const pending = new Map(); const events = []
  const ready = new Promise((resolve, reject) => {
    socket.once('connect', () => socket.write(JSON.stringify({
      type: 'hello', protocol: 2, token: info.token, instanceId: iid, appVersion: 'fullloop', access,
    }) + '\n'))
    socket.on('data', (c) => {
      buf += c
      let n
      while ((n = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, n); buf = buf.slice(n + 1)
        if (!line) continue
        const f = JSON.parse(line)
        if (f.type === 'hello') f.ok ? resolve(f) : reject(new Error(f.message))
        else if (f.type === 'response') {
          const e = pending.get(f.id); if (!e) continue
          pending.delete(f.id); f.ok ? e.resolve(f.result) : e.reject(new Error(f.message))
        } else if (f.type === 'event') events.push(f)
      }
    })
    socket.once('error', reject)
  })
  return {
    ready, events,
    req(method, params) {
      const id = `${iid}:${++seq}`
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject })
        socket.write(JSON.stringify({ type: 'request', id, method, params }) + '\n')
      })
    },
    close() { socket.destroy() },
  }
}

const owned = (extra = {}) => ({ ownerId: OWNER, projectId: PROJECT, id: TERMINAL, ...extra })

;(async () => {
  const log = (step, detail) => console.log(`  ${step.padEnd(34)} ${detail}`)
  console.log('NATIVE OWNERSHIP FULL LOOP')

  // 1) CREATE — the app's createTerminal(inDirectory:)
  const controller = connect('controller'); await controller.ready
  const created = await controller.req('terminal.create', owned({
    command: '/bin/zsh', args: ['-il'], cwd: os.homedir(), cols: 100, rows: 30,
  }))
  const pid = created.pid
  log('1. create owned terminal', `pid=${pid} ok=${created.ok !== false}`)

  // 2) WRITE — the app's sendInput
  await controller.req('terminal.write', owned({ data: 'echo native-owns-$((7*6))\r' }))
  await wait(1200)

  // 3) OBSERVE the echo on a separate observer connection (the app's stream lane)
  const observer = connect('observer'); await observer.ready
  const sub1 = await observer.req('terminal.subscribe', owned({ ownerId: 'obs', maxQueueBytes: 262144 }))
  const out1 = sub1.snapshot.output
  log('2. write + echo observed', out1.includes('native-owns-42') ? 'saw "native-owns-42" ✓' : 'MISSING ECHO')
  const offsetBeforeQuit = sub1.snapshot.endOffset
  await observer.req('terminal.unsubscribe', owned({ ownerId: 'obs' }))
  observer.close()

  // 4) QUIT — the app's releaseOwnedSessionsForQuit: detachOwner then disconnect.
  await controller.req('terminal.detachOwner', owned())
  controller.close()
  log('3. quit (detach + disconnect)', 'controller connection closed')
  await wait(500)

  // 5) RELAUNCH — restoreOwnedSessions: new controller, same OWNER, attach by project.
  const relaunched = connect('controller'); await relaunched.ready
  await relaunched.req('terminal.attach', owned())
  log('4. relaunch + reattach', 'attached to the same terminal by project capability')

  // 6) PROVE CONTINUITY — same pid, offset only grew, and a NEW write reaches the SAME shell.
  const diag = await relaunched.req('terminal.diagnostics', { ownerId: '0' })
  const row = diag.find((t) => t.id === TERMINAL)
  log('5. pid survived relaunch', row && row.pid === pid ? `pid=${row.pid} unchanged ✓` : `CHANGED ${row && row.pid}`)
  await relaunched.req('terminal.write', owned({ data: 'echo still-the-same-shell-$$\r' }))
  await wait(1000)
  const observer2 = connect('observer'); await observer2.ready
  const sub2 = await observer2.req('terminal.subscribe', owned({ ownerId: 'obs2', maxQueueBytes: 262144 }))
  const out2 = sub2.snapshot.output
  const continuous = out2.includes('native-owns-42') && out2.includes('still-the-same-shell')
  const grew = sub2.snapshot.endOffset > offsetBeforeQuit
  log('6. scrollback continuous', continuous ? 'pre-quit AND post-relaunch output present ✓' : 'DISCONTINUOUS')
  log('   offset monotonic', grew ? `${offsetBeforeQuit} -> ${sub2.snapshot.endOffset} ✓` : 'REGRESSED')
  await observer2.req('terminal.unsubscribe', owned({ ownerId: 'obs2' }))
  observer2.close()

  // 7) END SESSION — the app's endSession: kill removes the PTY for good.
  await relaunched.req('terminal.kill', owned())
  await wait(500)
  const diag2 = await relaunched.req('terminal.diagnostics', { ownerId: '0' })
  const gone = diag2.find((t) => t.id === TERMINAL)
  log('7. end session (kill)', gone?.exited ? 'terminal exited ✓' : 'STILL LIVE')
  relaunched.close()

  const pass = out1.includes('native-owns-42') && row?.pid === pid && continuous && grew && gone?.exited
  console.log(pass ? '\nFULL LOOP: PASS' : '\nFULL LOOP: FAIL')
  process.exit(pass ? 0 : 1)
})().catch((e) => { console.error(String(e)); process.exit(1) })
