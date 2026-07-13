// The shared agent-task ledger — the coordination substrate for agent↔agent
// work. Design (from the Traycer deep-dive): a BLACKBOARD WITH ONE WRITER.
// Agents never message each other directly; they post/claim/update rows here
// (via the Kaisola MCP server), Kaisola is the only process that touches the
// database, and every change is broadcast to the renderer's activity feed —
// so agent-to-agent traffic is inherently visible to the human. Rows are
// coordination state ONLY: nothing here ever mutates project/research state,
// which stays behind the proposal gate.
const { app, BrowserWindow } = require('electron')
const path = require('node:path')
const fs = require('node:fs')

const STATUSES = new Set(['open', 'claimed', 'in_progress', 'blocked', 'review', 'done', 'rejected'])
let db = null // better-sqlite3, or null → JSON-file fallback
let jsonPath = null
let seq = 0

function dbPath() {
  return path.join(app.getPath('userData'), 'kaisola-ledger.sqlite3')
}

function init() {
  if (db || jsonPath) return
  try {
    const Database = require('better-sqlite3')
    db = new Database(dbPath())
    db.pragma('journal_mode = WAL')
    db.exec(`CREATE TABLE IF NOT EXISTS agent_tasks (
      id TEXT PRIMARY KEY,
      project TEXT,
      title TEXT NOT NULL,
      detail TEXT,
      status TEXT NOT NULL DEFAULT 'open',
      owner TEXT,
      created_by TEXT,
      depends_on TEXT,
      result TEXT,
      created_at INTEGER,
      updated_at INTEGER
    )`)
  } catch {
    // native ABI mismatch — same fallback posture as dbHandler
    jsonPath = path.join(app.getPath('userData'), 'kaisola-ledger.json')
  }
}

function readJson() {
  try { return JSON.parse(fs.readFileSync(jsonPath, 'utf8')) } catch { return [] }
}
function writeJson(rows) {
  try { fs.writeFileSync(jsonPath, JSON.stringify(rows)) } catch { /* next write retries */ }
}

function broadcast(event) {
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win.webContents.isDestroyed()) win.webContents.send('ledger:event', event)
  }
}

const rowOut = (r) => ({
  id: r.id, project: r.project, title: r.title, detail: r.detail || undefined,
  status: r.status, owner: r.owner || undefined, createdBy: r.created_by || undefined,
  dependsOn: r.depends_on ? JSON.parse(r.depends_on) : [],
  result: r.result || undefined, createdAt: r.created_at, updatedAt: r.updated_at,
})

function listTasks({ project, status } = {}) {
  init()
  let rows
  if (db) {
    const conds = []
    const args = []
    if (project) { conds.push('project = ?'); args.push(project) }
    if (status && STATUSES.has(status)) { conds.push('status = ?'); args.push(status) }
    const where = conds.length ? ` WHERE ${conds.join(' AND ')}` : ''
    rows = db.prepare(`SELECT * FROM agent_tasks${where} ORDER BY created_at DESC LIMIT 200`).all(...args)
  } else {
    rows = readJson()
      .filter((r) => (!project || r.project === project) && (!status || r.status === status))
      .sort((a, b) => b.created_at - a.created_at)
      .slice(0, 200)
  }
  return rows.map(rowOut)
}

function postTask({ project, title, detail, createdBy, owner, dependsOn } = {}) {
  init()
  const t = String(title || '').trim().slice(0, 300)
  if (!t) return { ok: false, message: 'title is required' }
  const now = Date.now()
  const row = {
    id: `task-${now.toString(36)}-${(++seq).toString(36)}`,
    project: typeof project === 'string' ? project : null,
    title: t,
    detail: typeof detail === 'string' ? detail.slice(0, 8000) : null,
    status: 'open',
    owner: typeof owner === 'string' ? owner.slice(0, 120) : null,
    created_by: typeof createdBy === 'string' ? createdBy.slice(0, 120) : null,
    depends_on: Array.isArray(dependsOn) ? JSON.stringify(dependsOn.map(String).slice(0, 20)) : null,
    result: null,
    created_at: now,
    updated_at: now,
  }
  if (db) {
    db.prepare(`INSERT INTO agent_tasks (id, project, title, detail, status, owner, created_by, depends_on, result, created_at, updated_at)
      VALUES (@id, @project, @title, @detail, @status, @owner, @created_by, @depends_on, @result, @created_at, @updated_at)`).run(row)
  } else {
    const rows = readJson(); rows.push(row); writeJson(rows)
  }
  const out = rowOut(row)
  broadcast({ type: 'posted', task: out })
  return { ok: true, task: out }
}

function updateTask({ id, status, owner, result, detail, project } = {}) {
  init()
  if (typeof id !== 'string' || !id) return { ok: false, message: 'id is required' }
  if (status != null && !STATUSES.has(status)) return { ok: false, message: `status must be one of: ${[...STATUSES].join(', ')}` }
  const now = Date.now()
  let row
  if (db) {
    row = db.prepare('SELECT * FROM agent_tasks WHERE id = ?').get(id)
    if (!row) return { ok: false, message: 'no such task' }
    if (typeof project === 'string' && row.project !== project) return { ok: false, message: 'no such task in this project' }
    if (status != null) row.status = status
    if (typeof owner === 'string') row.owner = owner.slice(0, 120)
    if (typeof result === 'string') row.result = result.slice(0, 8000)
    if (typeof detail === 'string') row.detail = detail.slice(0, 8000)
    row.updated_at = now
    db.prepare(`UPDATE agent_tasks SET status=@status, owner=@owner, result=@result, detail=@detail, updated_at=@updated_at WHERE id=@id`).run(row)
  } else {
    const rows = readJson()
    row = rows.find((r) => r.id === id)
    if (!row) return { ok: false, message: 'no such task' }
    if (typeof project === 'string' && row.project !== project) return { ok: false, message: 'no such task in this project' }
    if (status != null) row.status = status
    if (typeof owner === 'string') row.owner = owner.slice(0, 120)
    if (typeof result === 'string') row.result = result.slice(0, 8000)
    if (typeof detail === 'string') row.detail = detail.slice(0, 8000)
    row.updated_at = now
    writeJson(rows)
  }
  const out = rowOut(row)
  broadcast({ type: 'updated', task: out })
  return { ok: true, task: out }
}

function registerLedgerHandlers(ipcMain) {
  ipcMain.handle('ledger:list', (_e, args) => ({ ok: true, tasks: listTasks(args || {}) }))
  ipcMain.handle('ledger:post', (_e, args) => postTask(args || {}))
  ipcMain.handle('ledger:update', (_e, args) => updateTask(args || {}))
}

module.exports = { registerLedgerHandlers, listTasks, postTask, updateTask }
