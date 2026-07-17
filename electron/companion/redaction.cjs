'use strict'

const path = require('node:path')
const { isPlainObject, validateIdentifier } = require('./protocol.cjs')

const PROJECTION_KIND = 'kaisola.companion.projection'
const MAX_PROJECTION_BYTES = 512 * 1024
const MAX_PROJECTS = 64
const MAX_SESSIONS = 500
const MAX_ATTENTION = 200
const MAX_PERMISSIONS = 50
const MAX_TURNS_PER_SESSION = 40
const MAX_TURN_TEXT = 16 * 1024
const MAX_DIFF_TEXT = 16 * 1024
const MAX_DISPLAY = 240

const FORBIDDEN_KEYS = new Set([
  'apikey',
  'accesstoken',
  'authtoken',
  'claudeconfigdir',
  'codexhome',
  'environment',
  'env',
  'filebuffers',
  'idtoken',
  'mcp',
  'mcpservers',
  'password',
  'refreshtoken',
  'resumecommand',
  'secret',
  'settings',
  'terminaloutput',
  'token',
  'unsavedbuffers',
  'workspacepath',
])
const PROJECT_CONNECTIONS = new Set(['live', 'stale', 'offline'])
const SESSION_KINDS = new Set(['agent', 'terminal', 'panel'])
const SESSION_STATUSES = new Set(['idle', 'running', 'waiting', 'done', 'failed'])
const TURN_KINDS = new Set(['user', 'assistant', 'thought', 'tool'])
const ATTENTION_KINDS = new Set(['permission', 'question', 'review', 'blocked', 'failed', 'completed'])
const SEVERITIES = new Set(['info', 'warning', 'critical'])

class CompanionProjectionError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CompanionProjectionError'
    this.code = code
  }
}

function projectionFail(code, message) {
  throw new CompanionProjectionError(code, message)
}

function keyFingerprint(key) {
  return String(key).replace(/[^a-z0-9]/gi, '').toLowerCase()
}

function assertNoForbiddenKeys(value, seen = new Set()) {
  if (!value || typeof value !== 'object') return
  if (seen.has(value)) projectionFail('invalid_projection', 'projection contains a cycle')
  seen.add(value)
  if (Array.isArray(value)) {
    for (const item of value) assertNoForbiddenKeys(item, seen)
  } else {
    for (const [key, child] of Object.entries(value)) {
      if (FORBIDDEN_KEYS.has(keyFingerprint(key))) projectionFail('forbidden_projection_key', `projection contains forbidden key: ${key}`)
      assertNoForbiddenKeys(child, seen)
    }
  }
  seen.delete(value)
}

function plain(value, label) {
  if (!isPlainObject(value)) projectionFail('invalid_projection', `${label} must be an object`)
  return value
}

function safeId(value, label, max = 240) {
  try { return validateIdentifier(value, label, max) } catch { projectionFail('invalid_projection', `${label} is invalid`) }
}

function safeString(value, label, max = MAX_DISPLAY, { optional = false } = {}) {
  if (value == null && optional) return undefined
  if (typeof value !== 'string') projectionFail('invalid_projection', `${label} must be text`)
  const text = value.replace(/[\0\x08\x0b\x0c\x0e-\x1f\x7f]/g, '').trim()
  if (!text && !optional) projectionFail('invalid_projection', `${label} is empty`)
  return text.slice(0, max) || undefined
}

function safeTime(value, label, { optional = false } = {}) {
  if (value == null && optional) return undefined
  if (!Number.isSafeInteger(value) || value < 0) projectionFail('invalid_projection', `${label} is invalid`)
  return value
}

function safeBool(value) {
  return value === true
}

function safeRelativePath(value, label) {
  const text = safeString(value, label, 1024)
  if (!text || path.isAbsolute(text) || text.split(/[\\/]/).includes('..')) {
    projectionFail('unsafe_path', `${label} must be workspace-relative`)
  }
  return text.replace(/\\/g, '/')
}

function normalizedStatus(session) {
  const requested = SESSION_STATUSES.has(session.status) ? session.status : 'idle'
  if (safeBool(session.needsYou) || requested === 'waiting') return 'waiting'
  return requested
}

function boardLaneFor(session) {
  if (session.needsYou || session.status === 'waiting' || session.status === 'failed') return 'waiting'
  if (session.status === 'running') return 'running'
  if (session.status === 'done') return 'done'
  return null
}

function sanitizeTurn(raw, sessionId, index) {
  const turn = plain(raw, `sessions.${sessionId}.turns.${index}`)
  if (!TURN_KINDS.has(turn.kind)) projectionFail('invalid_projection', `sessions.${sessionId}.turns.${index}.kind is invalid`)
  return {
    kind: turn.kind,
    text: safeString(turn.text, `sessions.${sessionId}.turns.${index}.text`, MAX_TURN_TEXT) ?? '',
    ...(turn.status == null ? {} : { status: safeString(turn.status, 'turn.status', 80, { optional: true }) }),
    ...(turn.at == null ? {} : { at: safeTime(turn.at, 'turn.at', { optional: true }) }),
  }
}

function sanitizeSession(raw, index, projects) {
  const session = plain(raw, `sessions.${index}`)
  const id = safeId(session.id, `sessions.${index}.id`)
  const projectId = safeId(session.projectId, `sessions.${index}.projectId`)
  if (!projects.has(projectId)) projectionFail('unknown_project', `session ${id} names an unknown project`)
  if (!SESSION_KINDS.has(session.kind)) projectionFail('invalid_projection', `session ${id} kind is invalid`)
  const status = normalizedStatus(session)
  const clean = {
    id,
    projectId,
    kind: session.kind,
    title: safeString(session.title, `sessions.${index}.title`),
    status,
    needsYou: safeBool(session.needsYou),
    unread: safeBool(session.unread),
    updatedAt: safeTime(session.updatedAt, `sessions.${index}.updatedAt`),
  }
  clean.boardLane = boardLaneFor(clean)
  if (session.provider != null) clean.provider = safeString(session.provider, 'session.provider', 120, { optional: true })
  if (session.model != null) clean.model = safeString(session.model, 'session.model', 120, { optional: true })
  if (session.mode != null) clean.mode = safeString(session.mode, 'session.mode', 80, { optional: true })
  if (session.branch != null) clean.branch = safeString(session.branch, 'session.branch', 240, { optional: true })
  if (session.summary != null) clean.summary = safeString(session.summary, 'session.summary', MAX_DISPLAY, { optional: true })
  if (session.startedAt != null) clean.startedAt = safeTime(session.startedAt, 'session.startedAt', { optional: true })
  if (Array.isArray(session.turns)) {
    clean.turns = session.turns.slice(-MAX_TURNS_PER_SESSION).map((turn, turnIndex) => sanitizeTurn(turn, id, turnIndex))
  }
  return clean
}

function sanitizeAttention(raw, index, projects, sessions) {
  const item = plain(raw, `attention.${index}`)
  const id = safeId(item.id, `attention.${index}.id`)
  const projectId = safeId(item.projectId, `attention.${index}.projectId`)
  if (!projects.has(projectId)) projectionFail('unknown_project', `attention ${id} names an unknown project`)
  if (!ATTENTION_KINDS.has(item.kind)) projectionFail('invalid_projection', `attention ${id} kind is invalid`)
  const clean = {
    id,
    projectId,
    kind: item.kind,
    title: safeString(item.title, `attention.${index}.title`),
    createdAt: safeTime(item.createdAt, `attention.${index}.createdAt`),
    severity: SEVERITIES.has(item.severity) ? item.severity : 'info',
  }
  if (item.sessionId != null) {
    const sessionId = safeId(item.sessionId, `attention.${index}.sessionId`)
    const session = sessions.get(sessionId)
    if (!session || session.projectId !== projectId) projectionFail('unknown_session', `attention ${id} names an unknown session`)
    clean.sessionId = sessionId
  }
  if (item.detail != null) clean.detail = safeString(item.detail, `attention.${index}.detail`, MAX_DISPLAY, { optional: true })
  return clean
}

function sanitizePermission(raw, index, projects, sessions) {
  const item = plain(raw, `permissions.${index}`)
  const permId = safeId(item.permId, `permissions.${index}.permId`)
  const projectId = safeId(item.projectId, `permissions.${index}.projectId`)
  if (!projects.has(projectId)) projectionFail('unknown_project', `permission ${permId} names an unknown project`)
  const clean = {
    permId,
    projectId,
    agent: safeString(item.agent, `permissions.${index}.agent`, 120),
    title: safeString(item.title, `permissions.${index}.title`),
    requestedAt: safeTime(item.requestedAt, `permissions.${index}.requestedAt`),
  }
  if (item.sessionId != null) {
    const sessionId = safeId(item.sessionId, `permissions.${index}.sessionId`)
    const session = sessions.get(sessionId)
    if (!session || session.projectId !== projectId) projectionFail('unknown_session', `permission ${permId} names an unknown session`)
    clean.sessionId = sessionId
  }
  if (item.kind != null) clean.kind = safeString(item.kind, 'permission.kind', 80, { optional: true })
  clean.options = (Array.isArray(item.options) ? item.options : []).slice(0, 12).map((rawOption, optionIndex) => {
    const option = plain(rawOption, `permissions.${index}.options.${optionIndex}`)
    return {
      id: safeId(option.id, `permissions.${index}.options.${optionIndex}.id`, 120),
      label: safeString(option.label, `permissions.${index}.options.${optionIndex}.label`, 160),
    }
  })
  clean.diffs = (Array.isArray(item.diffs) ? item.diffs : []).slice(0, 8).map((rawDiff, diffIndex) => {
    const diff = plain(rawDiff, `permissions.${index}.diffs.${diffIndex}`)
    return {
      relativePath: safeRelativePath(diff.relativePath, `permissions.${index}.diffs.${diffIndex}.relativePath`),
      oldText: safeString(diff.oldText ?? '', 'permission.diff.oldText', MAX_DIFF_TEXT, { optional: true }) ?? '',
      newText: safeString(diff.newText ?? '', 'permission.diff.newText', MAX_DIFF_TEXT, { optional: true }) ?? '',
    }
  })
  return clean
}

function countsFor(projectId, sessions) {
  const counts = { running: 0, waiting: 0, done: 0, failed: 0 }
  for (const session of sessions) {
    if (session.projectId !== projectId) continue
    if (session.status === 'failed') counts.failed++
    if (session.boardLane) counts[session.boardLane]++
  }
  return counts
}

function sessionCard(session) {
  return {
    id: session.id,
    type: 'session',
    projectId: session.projectId,
    title: session.title,
    status: session.status,
    needsYou: session.needsYou,
    updatedAt: session.updatedAt,
    ...(session.provider ? { provider: session.provider } : {}),
    ...(session.summary ? { summary: session.summary } : {}),
  }
}

function attentionCard(item) {
  return {
    id: item.id,
    type: 'attention',
    projectId: item.projectId,
    title: item.title,
    status: item.kind === 'failed' ? 'failed' : 'waiting',
    needsYou: true,
    updatedAt: item.createdAt,
    attentionKind: item.kind,
    ...(item.detail ? { summary: item.detail } : {}),
  }
}

function buildBoard(sessions, attention) {
  const byLane = { running: [], waiting: [], done: [] }
  const waitingSessions = new Set()
  for (const session of sessions) {
    if (!session.boardLane) continue
    byLane[session.boardLane].push(sessionCard(session))
    if (session.boardLane === 'waiting') waitingSessions.add(session.id)
  }
  for (const item of attention) {
    if (item.sessionId && waitingSessions.has(item.sessionId)) continue
    if (item.kind !== 'completed') byLane.waiting.push(attentionCard(item))
  }
  for (const cards of Object.values(byLane)) cards.sort((a, b) => b.updatedAt - a.updatedAt || a.id.localeCompare(b.id))
  return {
    columns: [
      { id: 'running', title: 'Running', count: byLane.running.length, cards: byLane.running },
      { id: 'waiting', title: 'Needs You', sourceLabel: 'Waiting for review', count: byLane.waiting.length, cards: byLane.waiting },
      { id: 'done', title: 'Done', count: byLane.done.length, cards: byLane.done },
    ],
  }
}

function sanitizeProjection(input) {
  const raw = plain(input, 'projection')
  if (raw.projectionKind !== PROJECTION_KIND) projectionFail('not_normalized', 'only a normalized companion projection is accepted')
  assertNoForbiddenKeys(raw)
  const revision = safeTime(raw.revision, 'projection.revision')
  const generatedAt = safeTime(raw.generatedAt, 'projection.generatedAt')
  if (!Array.isArray(raw.projects) || raw.projects.length > MAX_PROJECTS) projectionFail('invalid_projection', 'projects are invalid')
  if (!Array.isArray(raw.sessions) || raw.sessions.length > MAX_SESSIONS) projectionFail('invalid_projection', 'sessions are invalid')

  const projects = raw.projects.map((rawProject, index) => {
    const project = plain(rawProject, `projects.${index}`)
    const id = safeId(project.id, `projects.${index}.id`)
    return {
      id,
      name: safeString(project.name, `projects.${index}.name`),
      connection: PROJECT_CONNECTIONS.has(project.connection) ? project.connection : 'offline',
      lastContactAt: safeTime(project.lastContactAt, `projects.${index}.lastContactAt`),
      ...(project.repo == null ? {} : { repo: safeString(project.repo, `projects.${index}.repo`, 240, { optional: true }) }),
      ...(project.branch == null ? {} : { branch: safeString(project.branch, `projects.${index}.branch`, 240, { optional: true }) }),
    }
  })
  const projectMap = new Map()
  for (const project of projects) {
    if (projectMap.has(project.id)) projectionFail('duplicate_id', `duplicate project id: ${project.id}`)
    projectMap.set(project.id, project)
  }

  const sessions = raw.sessions.map((session, index) => sanitizeSession(session, index, projectMap))
  const sessionMap = new Map()
  for (const session of sessions) {
    if (sessionMap.has(session.id)) projectionFail('duplicate_id', `duplicate session id: ${session.id}`)
    sessionMap.set(session.id, session)
  }
  const attention = (Array.isArray(raw.attention) ? raw.attention : []).slice(0, MAX_ATTENTION)
    .map((item, index) => sanitizeAttention(item, index, projectMap, sessionMap))
  const permissions = (Array.isArray(raw.permissions) ? raw.permissions : []).slice(0, MAX_PERMISSIONS)
    .map((item, index) => sanitizePermission(item, index, projectMap, sessionMap))

  const clean = {
    projectionKind: PROJECTION_KIND,
    revision,
    generatedAt,
    freshness: raw.freshness === 'live' ? 'live' : 'stale',
    projects: projects.map((project) => ({ ...project, counts: countsFor(project.id, sessions) })),
    sessions,
    attention,
    permissions,
    board: buildBoard(sessions, attention),
  }
  if (Buffer.byteLength(JSON.stringify(clean), 'utf8') > MAX_PROJECTION_BYTES) {
    projectionFail('projection_too_large', 'projection exceeds the companion limit')
  }
  return clean
}

module.exports = {
  CompanionProjectionError,
  MAX_PROJECTION_BYTES,
  PROJECTION_KIND,
  assertNoForbiddenKeys,
  boardLaneFor,
  buildBoard,
  safeRelativePath,
  sanitizeProjection,
}

