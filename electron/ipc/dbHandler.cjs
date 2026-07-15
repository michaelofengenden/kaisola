// Durable persistence — moves the project off the renderer's localStorage (≈5MB
// cap, lost with the profile) into the main process.
//
//   - Primary: better-sqlite3 (synchronous, durable, in userData/pasola.db).
//   - Fallback: a plain JSON file (userData/pasola-store.json) when the native
//     module isn't built for this Electron ABI — so a failed rebuild DEGRADES
//     gracefully instead of bricking the app.
//
// The FILENAMES keep the pre-rename "pasola" spelling on purpose: they are the
// on-disk store existing installs already have, and renaming them would orphan
// every user's data. Only the row KEYS moved to kaisola-* (with a read fallback
// in the renderer's storage shim).
//
// A single key→value table mirrors the zustand persist contract. `db:get-sync`
// is intentionally synchronous (ipcMain.on + e.returnValue) so the store can
// rehydrate without an async flash, exactly as localStorage did.
const path = require('path')
const fs = require('fs')
const { app } = require('electron')

let backend = null

function init() {
  if (backend) return backend
  const dir = app.getPath('userData')
  try {
    const Database = require('better-sqlite3')
    const db = new Database(path.join(dir, 'pasola.db'))
    db.pragma('journal_mode = WAL')
    db.exec('CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)')
    const getStmt = db.prepare('SELECT value FROM kv WHERE key = ?')
    const setStmt = db.prepare('INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    const delStmt = db.prepare('DELETE FROM kv WHERE key = ?')
    const keysStmt = db.prepare('SELECT key FROM kv')
    const mutate = db.transaction(({ set = {}, delete: deleted = [] } = {}) => {
      for (const [key, value] of Object.entries(set)) setStmt.run(key, value)
      for (const key of deleted) delStmt.run(key)
    })
    backend = {
      kind: 'sqlite',
      get: (k) => { const r = getStmt.get(k); return r ? r.value : null },
      set: (k, v) => { setStmt.run(k, v) },
      del: (k) => { delStmt.run(k) },
      keys: () => keysStmt.all().map((row) => row.key),
      mutate,
    }
  } catch (err) {
    const file = path.join(dir, 'pasola-store.json')
    const read = (strict = false) => {
      try { return JSON.parse(fs.readFileSync(file, 'utf8')) }
      catch (readError) {
        if (readError?.code === 'ENOENT') return {}
        if (strict) throw readError
        return {}
      }
    }
    // atomic write (temp + rename) so a crash mid-write can't corrupt the store
    const write = (obj, strict = false) => {
      try {
        const tmp = `${file}.${process.pid}.tmp`
        fs.writeFileSync(tmp, JSON.stringify(obj))
        fs.renameSync(tmp, file)
      } catch (writeError) {
        if (strict) throw writeError
      }
    }
    backend = {
      kind: 'json',
      reason: String((err && err.message) || err),
      get: (k) => { const o = read(); return k in o ? o[k] : null },
      set: (k, v) => { const o = read(); o[k] = v; write(o) },
      del: (k) => { const o = read(); delete o[k]; write(o) },
      keys: () => Object.keys(read(true)),
      mutate: ({ set = {}, delete: deleted = [] } = {}) => {
        const next = read(true)
        for (const [key, value] of Object.entries(set)) next[key] = value
        for (const key of deleted) delete next[key]
        write(next, true)
      },
    }
  }
  return backend
}

function registerDbHandlers(ipcMain) {
  const b = init()
  ipcMain.on('db:get-sync', (e, key) => {
    try { e.returnValue = b.get(key) } catch { e.returnValue = null }
  })
  // synchronous write — used to flush the last state on quit (pagehide) so we
  // keep localStorage's old no-lost-write guarantee despite async writes.
  ipcMain.on('db:set-sync', (e, { key, value } = {}) => {
    try { b.set(key, value); e.returnValue = true } catch { e.returnValue = false }
  })
  ipcMain.handle('db:set', (_e, { key, value } = {}) => {
    try { b.set(key, value); return { ok: true } } catch (err) { return { ok: false, message: String((err && err.message) || err) } }
  })
  ipcMain.handle('db:del', (_e, { key } = {}) => {
    try { b.del(key); return { ok: true } } catch { return { ok: false } }
  })
  ipcMain.handle('db:kind', () => ({ kind: b.kind, reason: b.reason }))
}

// main-side read (e.g. picking a free window slot) — same backend, no IPC
module.exports = {
  registerDbHandlers,
  dbGet: (key) => init().get(key),
  dbSet: (key, value) => init().set(key, value),
  dbDel: (key) => init().del(key),
  dbKeys: () => init().keys(),
  dbMutate: (mutation) => init().mutate(mutation),
}
