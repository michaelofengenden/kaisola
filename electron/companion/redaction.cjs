'use strict'

const path = require('node:path')
const { isPlainObject, validateIdentifier } = require('./protocol.cjs')
// One home for the projection size limits, shared with the renderer builder
// (src/lib/companionProjection.ts) so the values the renderer applies and the
// values this sanitizer fail-closes on can never drift apart.
const LIMITS = require('./projectionLimits.json')

const PROJECTION_KIND = 'kaisola.companion.projection'
const MAX_PROJECTION_BYTES = 512 * 1024
const {
  MAX_PROJECTS, MAX_SESSIONS, MAX_ATTENTION, MAX_PERMISSIONS,
  MAX_TURNS_PER_SESSION, MAX_TURN_TEXT, MAX_DIFF_TEXT, MAX_DISPLAY,
  MAX_PERMISSION_OPTIONS, MAX_PERMISSION_DIFFS, MAX_PATH,
} = LIMITS
const MAX_ACP_COLLECTION = 64
const MAX_ACP_EVENT_BYTES = 512 * 1024

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
const PERMISSION_COMPLETENESS = new Set(['complete', 'truncated', 'redacted', 'unavailable'])
const PERMISSION_COMPLETENESS_RANK = Object.freeze({ complete: 0, truncated: 1, redacted: 2, unavailable: 3 })
const ACP_EVENT_TYPES = new Set([
  'agent.turn.delta',
  'agent.turn.completed',
  'agent.permission.requested',
  'agent.permission.resolved',
])
const ACP_CONTENT_UPDATES = new Set(['user_message_chunk', 'agent_message_chunk', 'agent_thought_chunk'])
const ACP_TOOL_KINDS = new Set(['read', 'edit', 'delete', 'move', 'search', 'execute', 'think', 'fetch', 'switch_mode', 'other'])
const ACP_TOOL_STATUSES = new Set(['pending', 'in_progress', 'completed', 'failed'])
const ACP_PLAN_PRIORITIES = new Set(['high', 'medium', 'low'])
const ACP_PLAN_STATUSES = new Set(['pending', 'in_progress', 'completed'])
const ACP_STOP_REASONS = new Set(['end_turn', 'max_tokens', 'max_turn_requests', 'refusal', 'cancelled'])

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

function assertAllowedKeys(value, allowed, label) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) projectionFail('unknown_projection_field', `${label}.${key} is not allowed`)
  }
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

function unsafePath(text) {
  return path.isAbsolute(text)
    || path.win32.isAbsolute(text)
    || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(text)
    || /^~(?:[\\/]|$)/.test(text)
    || text.split(/[\\/]/).includes('..')
}

function safeRelativePath(value, label) {
  const text = safeString(value, label, MAX_PATH)
  if (!text || unsafePath(text)) {
    projectionFail('unsafe_path', `${label} must be workspace-relative`)
  }
  return text.replace(/\\/g, '/')
}

function optionalId(value, label, max = 240) {
  if (value == null) return undefined
  try { return safeId(value, label, max) } catch { return undefined }
}

function displayText(value, fallback, label, max = MAX_DISPLAY) {
  if (typeof value !== 'string') return fallback
  return safeString(value, label, max, { optional: true }) ?? fallback
}

function strictText(value, label, max, { optional = false, empty = false } = {}) {
  if (value == null && optional) return undefined
  if (typeof value !== 'string' || /[\0\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)) {
    projectionFail('invalid_projection', `${label} must be safe text`)
  }
  if ((!empty && value.length === 0) || Buffer.byteLength(value, 'utf8') > max) {
    projectionFail('invalid_projection', `${label} exceeds its bound`)
  }
  return value
}

function strictRelativePath(value, label) {
  const text = strictText(value, label, MAX_PATH)
  if (unsafePath(text)) {
    projectionFail('unsafe_path', `${label} must be workspace-relative`)
  }
  return text.replace(/\\/g, '/')
}

function strictFinite(value, label, { integer = false, min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  if (!Number.isFinite(value) || (integer && !Number.isSafeInteger(value)) || value < min || value > max) {
    projectionFail('invalid_projection', `${label} is invalid`)
  }
  return value
}

function strictArray(value, label, max = MAX_ACP_COLLECTION) {
  if (!Array.isArray(value) || value.length > max) projectionFail('invalid_projection', `${label} is invalid`)
  return value
}

function boundedAcpEvent(value) {
  if (Buffer.byteLength(JSON.stringify(value), 'utf8') > MAX_ACP_EVENT_BYTES) {
    projectionFail('projection_too_large', 'ACP event exceeds the companion limit')
  }
  return value
}

function sanitizeAcpTextContent(raw, label) {
  const content = plain(raw, label)
  assertAllowedKeys(content, new Set(['type', 'text']), label)
  if (content.type != null && content.type !== 'text') projectionFail('invalid_projection', `${label}.type is unsupported`)
  return { type: 'text', text: strictText(content.text, `${label}.text`, MAX_TURN_TEXT, { empty: true }) }
}

function sanitizeAcpPlanEntries(value, label) {
  return strictArray(value, label).map((raw, index) => {
    const entryLabel = `${label}.${index}`
    const entry = plain(raw, entryLabel)
    assertAllowedKeys(entry, new Set(['content', 'priority', 'status']), entryLabel)
    if (!ACP_PLAN_PRIORITIES.has(entry.priority) || !ACP_PLAN_STATUSES.has(entry.status)) {
      projectionFail('invalid_projection', `${entryLabel} has an invalid state`)
    }
    return {
      content: strictText(entry.content, `${entryLabel}.content`, 2_000),
      priority: entry.priority,
      status: entry.status,
    }
  })
}

function sanitizeAcpToolContent(raw, label) {
  const item = plain(raw, label)
  if (item.type === 'content') {
    assertAllowedKeys(item, new Set(['type', 'content']), label)
    return { type: 'content', content: sanitizeAcpTextContent(item.content, `${label}.content`) }
  }
  if (item.type === 'diff') {
    assertAllowedKeys(item, new Set(['type', 'path', 'oldText', 'newText']), label)
    return {
      type: 'diff',
      path: strictRelativePath(item.path, `${label}.path`),
      ...(item.oldText == null ? {} : { oldText: strictText(item.oldText, `${label}.oldText`, MAX_DIFF_TEXT, { empty: true }) }),
      newText: strictText(item.newText, `${label}.newText`, MAX_DIFF_TEXT, { empty: true }),
    }
  }
  if (item.type === 'terminal') {
    assertAllowedKeys(item, new Set(['type', 'terminalId']), label)
    return { type: 'terminal', terminalId: safeId(item.terminalId, `${label}.terminalId`) }
  }
  projectionFail('invalid_projection', `${label}.type is unsupported`)
}

function sanitizeAcpToolUpdate(raw, label) {
  const update = plain(raw, label)
  assertAllowedKeys(update, new Set(['sessionUpdate', 'toolCallId', 'title', 'kind', 'status', 'content', 'locations']), label)
  const clean = {
    sessionUpdate: update.sessionUpdate,
    toolCallId: safeId(update.toolCallId, `${label}.toolCallId`),
  }
  if (update.sessionUpdate === 'tool_call') clean.title = strictText(update.title, `${label}.title`, 500)
  else if (update.title != null) clean.title = strictText(update.title, `${label}.title`, 500)
  if (update.kind != null) {
    if (!ACP_TOOL_KINDS.has(update.kind)) projectionFail('invalid_projection', `${label}.kind is invalid`)
    clean.kind = update.kind
  }
  if (update.status != null) {
    if (!ACP_TOOL_STATUSES.has(update.status)) projectionFail('invalid_projection', `${label}.status is invalid`)
    clean.status = update.status
  }
  if (update.content != null) {
    clean.content = strictArray(update.content, `${label}.content`, 32)
      .map((item, index) => sanitizeAcpToolContent(item, `${label}.content.${index}`))
  }
  if (update.locations != null) {
    clean.locations = strictArray(update.locations, `${label}.locations`, 32).map((rawLocation, index) => {
      const locationLabel = `${label}.locations.${index}`
      const location = plain(rawLocation, locationLabel)
      assertAllowedKeys(location, new Set(['path', 'line']), locationLabel)
      return {
        path: strictRelativePath(location.path, `${locationLabel}.path`),
        ...(location.line == null ? {} : { line: strictFinite(location.line, `${locationLabel}.line`, { integer: true }) }),
      }
    })
  }
  return clean
}

function sanitizeAcpAvailableCommands(value, label) {
  return strictArray(value, label).map((raw, index) => {
    const commandLabel = `${label}.${index}`
    const command = plain(raw, commandLabel)
    assertAllowedKeys(command, new Set(['name', 'description', 'input']), commandLabel)
    const clean = {
      name: strictText(command.name, `${commandLabel}.name`, 120),
      description: strictText(command.description, `${commandLabel}.description`, 500, { empty: true }),
    }
    if (command.input != null) {
      const input = plain(command.input, `${commandLabel}.input`)
      assertAllowedKeys(input, new Set(['hint']), `${commandLabel}.input`)
      clean.input = { hint: strictText(input.hint, `${commandLabel}.input.hint`, 240, { empty: true }) }
    }
    return clean
  })
}

function sanitizeAcpConfigSelectOptions(value, label, depth = 0) {
  return strictArray(value, label, 32).map((raw, index) => {
    const optionLabel = `${label}.${index}`
    const option = plain(raw, optionLabel)
    if (Object.hasOwn(option, 'group')) {
      if (depth >= 1) projectionFail('invalid_projection', `${optionLabel} exceeds the group depth limit`)
      assertAllowedKeys(option, new Set(['group', 'name', 'options']), optionLabel)
      return {
        group: safeId(option.group, `${optionLabel}.group`, 120),
        name: strictText(option.name, `${optionLabel}.name`, 160),
        options: sanitizeAcpConfigSelectOptions(option.options, `${optionLabel}.options`, depth + 1),
      }
    }
    assertAllowedKeys(option, new Set(['value', 'name', 'description']), optionLabel)
    return {
      value: safeId(option.value, `${optionLabel}.value`, 160),
      name: strictText(option.name, `${optionLabel}.name`, 160),
      ...(option.description == null ? {} : { description: strictText(option.description, `${optionLabel}.description`, 300, { empty: true }) }),
    }
  })
}

function sanitizeAcpConfigOptions(value, label) {
  return strictArray(value, label, 32).map((raw, index) => {
    const optionLabel = `${label}.${index}`
    const option = plain(raw, optionLabel)
    assertAllowedKeys(option, new Set(['type', 'id', 'name', 'description', 'category', 'currentValue', 'options']), optionLabel)
    if (option.type !== 'select' && option.type !== 'boolean') projectionFail('invalid_projection', `${optionLabel}.type is invalid`)
    const clean = {
      type: option.type,
      id: safeId(option.id, `${optionLabel}.id`, 160),
      name: strictText(option.name, `${optionLabel}.name`, 160),
      ...(option.description == null ? {} : { description: strictText(option.description, `${optionLabel}.description`, 300, { empty: true }) }),
      ...(option.category == null ? {} : { category: strictText(option.category, `${optionLabel}.category`, 120) }),
    }
    if (option.type === 'boolean') {
      if (typeof option.currentValue !== 'boolean' || option.options != null) projectionFail('invalid_projection', `${optionLabel} is invalid`)
      clean.currentValue = option.currentValue
    } else {
      clean.currentValue = safeId(option.currentValue, `${optionLabel}.currentValue`, 160)
      clean.options = sanitizeAcpConfigSelectOptions(option.options, `${optionLabel}.options`)
    }
    return clean
  })
}

function sanitizeAcpDelta(raw) {
  if (typeof raw === 'string') return strictText(raw, 'agent.turn.delta.delta', MAX_TURN_TEXT, { empty: true })
  const update = plain(raw, 'agent.turn.delta.delta')
  assertNoForbiddenKeys(update)
  if (update.sessionUpdate == null) {
    assertAllowedKeys(update, new Set(['text']), 'agent.turn.delta.delta')
    return { text: strictText(update.text, 'agent.turn.delta.delta.text', MAX_TURN_TEXT, { empty: true }) }
  }
  const kind = update.sessionUpdate
  if (ACP_CONTENT_UPDATES.has(kind)) {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'content', 'text', 'messageId']), 'agent.turn.delta.delta')
    if ((update.content == null) === (update.text == null)) {
      projectionFail('invalid_projection', 'agent.turn.delta.delta must contain exactly one text source')
    }
    return {
      sessionUpdate: kind,
      content: update.content == null
        ? { type: 'text', text: strictText(update.text, 'agent.turn.delta.delta.text', MAX_TURN_TEXT, { empty: true }) }
        : sanitizeAcpTextContent(update.content, 'agent.turn.delta.delta.content'),
      ...(update.messageId == null ? {} : { messageId: safeId(update.messageId, 'agent.turn.delta.delta.messageId') }),
    }
  }
  if (kind === 'tool_call' || kind === 'tool_call_update') return sanitizeAcpToolUpdate(update, 'agent.turn.delta.delta')
  if (kind === 'plan') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'entries']), 'agent.turn.delta.delta')
    return { sessionUpdate: kind, entries: sanitizeAcpPlanEntries(update.entries, 'agent.turn.delta.delta.entries') }
  }
  if (kind === 'plan_update') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'plan']), 'agent.turn.delta.delta')
    const plan = plain(update.plan, 'agent.turn.delta.delta.plan')
    if (plan.type === 'items') {
      assertAllowedKeys(plan, new Set(['type', 'planId', 'entries']), 'agent.turn.delta.delta.plan')
      return { sessionUpdate: kind, plan: { type: 'items', planId: safeId(plan.planId, 'agent.turn.delta.delta.plan.planId'), entries: sanitizeAcpPlanEntries(plan.entries, 'agent.turn.delta.delta.plan.entries') } }
    }
    if (plan.type === 'markdown') {
      assertAllowedKeys(plan, new Set(['type', 'planId', 'content']), 'agent.turn.delta.delta.plan')
      return { sessionUpdate: kind, plan: { type: 'markdown', planId: safeId(plan.planId, 'agent.turn.delta.delta.plan.planId'), content: strictText(plan.content, 'agent.turn.delta.delta.plan.content', MAX_TURN_TEXT, { empty: true }) } }
    }
    if (plan.type === 'file') {
      assertAllowedKeys(plan, new Set(['type', 'planId', 'uri']), 'agent.turn.delta.delta.plan')
      return { sessionUpdate: kind, plan: { type: 'file', planId: safeId(plan.planId, 'agent.turn.delta.delta.plan.planId'), uri: strictRelativePath(plan.uri, 'agent.turn.delta.delta.plan.uri') } }
    }
    projectionFail('invalid_projection', 'agent.turn.delta.delta.plan.type is unsupported')
  }
  if (kind === 'plan_removed') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'planId']), 'agent.turn.delta.delta')
    return { sessionUpdate: kind, planId: safeId(update.planId, 'agent.turn.delta.delta.planId') }
  }
  if (kind === 'available_commands_update') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'availableCommands']), 'agent.turn.delta.delta')
    return { sessionUpdate: kind, availableCommands: sanitizeAcpAvailableCommands(update.availableCommands, 'agent.turn.delta.delta.availableCommands') }
  }
  if (kind === 'current_mode_update') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'currentModeId', 'modeId']), 'agent.turn.delta.delta')
    return { sessionUpdate: kind, currentModeId: safeId(update.currentModeId ?? update.modeId, 'agent.turn.delta.delta.currentModeId') }
  }
  if (kind === 'current_model_update') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'currentModelId', 'modelId']), 'agent.turn.delta.delta')
    return { sessionUpdate: kind, currentModelId: safeId(update.currentModelId ?? update.modelId, 'agent.turn.delta.delta.currentModelId') }
  }
  if (kind === 'config_option_update') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'configOptions']), 'agent.turn.delta.delta')
    return { sessionUpdate: kind, configOptions: sanitizeAcpConfigOptions(update.configOptions, 'agent.turn.delta.delta.configOptions') }
  }
  if (kind === 'session_info_update') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'title', 'updatedAt']), 'agent.turn.delta.delta')
    return {
      sessionUpdate: kind,
      ...(update.title == null ? {} : { title: strictText(update.title, 'agent.turn.delta.delta.title', 500, { empty: true }) }),
      ...(update.updatedAt == null ? {} : { updatedAt: strictText(update.updatedAt, 'agent.turn.delta.delta.updatedAt', 64) }),
    }
  }
  if (kind === 'usage_update') {
    assertAllowedKeys(update, new Set(['sessionUpdate', 'used', 'size', 'usedTokens', 'maxTokens', 'contextWindow', 'cost']), 'agent.turn.delta.delta')
    let contextWindow
    if (update.contextWindow != null) {
      contextWindow = plain(update.contextWindow, 'agent.turn.delta.delta.contextWindow')
      assertAllowedKeys(contextWindow, new Set(['used', 'size']), 'agent.turn.delta.delta.contextWindow')
    }
    const clean = {
      sessionUpdate: kind,
      used: strictFinite(update.used ?? update.usedTokens ?? contextWindow?.used, 'agent.turn.delta.delta.used', { integer: true }),
      size: strictFinite(update.size ?? update.maxTokens ?? contextWindow?.size, 'agent.turn.delta.delta.size', { integer: true, min: 1 }),
    }
    if (update.cost != null) {
      const cost = plain(update.cost, 'agent.turn.delta.delta.cost')
      assertAllowedKeys(cost, new Set(['amount', 'currency']), 'agent.turn.delta.delta.cost')
      clean.cost = {
        amount: strictFinite(cost.amount, 'agent.turn.delta.delta.cost.amount', { max: 1_000_000_000 }),
        currency: strictText(cost.currency, 'agent.turn.delta.delta.cost.currency', 8),
      }
    }
    return clean
  }
  projectionFail('invalid_projection', `agent.turn.delta.delta update type is unsupported: ${String(kind || '')}`)
}

function sanitizeAcpSessionEvent(raw, { requestedAt = Date.now() } = {}) {
  const event = plain(raw, 'ACP event')
  assertNoForbiddenKeys(event)
  if (!ACP_EVENT_TYPES.has(event.type)) projectionFail('invalid_projection', 'ACP event type is invalid')
  if (event.type === 'agent.permission.requested') {
    return boundedAcpEvent(sanitizeAcpPermissionEvent(event, { requestedAt }))
  }

  const baseKeys = ['type', 'projectId', 'targetId', 'sessionId']
  const clean = {
    type: event.type,
    projectId: safeId(event.projectId, 'acp.event.projectId'),
    ...(event.targetId == null ? {} : { targetId: safeId(event.targetId, 'acp.event.targetId') }),
    ...(event.sessionId == null ? {} : { sessionId: safeId(event.sessionId, 'acp.event.sessionId') }),
  }
  if (!clean.targetId && !clean.sessionId) projectionFail('invalid_projection', 'ACP event target is missing')

  if (event.type === 'agent.turn.delta') {
    assertAllowedKeys(event, new Set([...baseKeys, 'turnId', 'delta']), 'agent.turn.delta')
    return boundedAcpEvent({ ...clean, turnId: safeId(event.turnId, 'agent.turn.delta.turnId'), delta: sanitizeAcpDelta(event.delta) })
  }
  if (event.type === 'agent.turn.completed') {
    assertAllowedKeys(event, new Set([...baseKeys, 'attentionSessionId', 'turnId', 'ok', 'agent', 'stopReason']), 'agent.turn.completed')
    if (typeof event.ok !== 'boolean') projectionFail('invalid_projection', 'agent.turn.completed.ok is invalid')
    if (event.stopReason != null && !ACP_STOP_REASONS.has(event.stopReason)) projectionFail('invalid_projection', 'agent.turn.completed.stopReason is invalid')
    return boundedAcpEvent({
      ...clean,
      ...(event.attentionSessionId == null ? {} : { attentionSessionId: safeId(event.attentionSessionId, 'agent.turn.completed.attentionSessionId') }),
      turnId: safeId(event.turnId, 'agent.turn.completed.turnId'),
      ok: event.ok,
      ...(event.agent == null ? {} : { agent: strictText(event.agent, 'agent.turn.completed.agent', 160) }),
      ...(event.stopReason == null ? {} : { stopReason: event.stopReason }),
    })
  }

  assertAllowedKeys(event, new Set([...baseKeys, 'permId', 'revision', 'resolution', 'actorId']), 'agent.permission.resolved')
  return boundedAcpEvent({
    ...clean,
    permId: safeId(event.permId, 'agent.permission.resolved.permId'),
    ...(event.revision == null ? {} : { revision: safeTime(event.revision, 'agent.permission.resolved.revision') }),
    ...(event.resolution == null ? {} : { resolution: strictText(event.resolution, 'agent.permission.resolved.resolution', 80) }),
    ...(event.actorId == null ? {} : { actorId: safeId(event.actorId, 'agent.permission.resolved.actorId') }),
  })
}

/** Normalize the authoritative ACP permission event once for both snapshot and
 * live-event delivery. Provider-only fields stay desktop-side, unsafe paths are
 * omitted, and any context loss is reflected in completeness. */
function sanitizeAcpPermissionEvent(raw, {
  projectId = raw?.projectId,
  sessionId,
  requestedAt = Date.now(),
} = {}) {
  const event = plain(raw, 'agent.permission.requested')
  if (event.type !== 'agent.permission.requested') projectionFail('invalid_projection', 'ACP permission event type is invalid')
  assertNoForbiddenKeys(event)
  assertAllowedKeys(event, new Set([
    'type', 'permId', 'revision', 'completeness', 'projectId', 'targetId', 'sessionId',
    'attentionSessionId', 'key', 'agent', 'title', 'kind', 'sensitive', 'requestedAt',
    'options', 'diffs',
  ]), 'agent.permission.requested')

  const cleanProjectId = safeId(projectId, 'acp.permission.projectId')
  const permId = safeId(event.permId, 'acp.permission.permId')
  let contextReduced = false
  let completeness = PERMISSION_COMPLETENESS.has(event.completeness) ? event.completeness : 'unavailable'
  const mark = (state) => {
    if (PERMISSION_COMPLETENESS_RANK[state] > PERMISSION_COMPLETENESS_RANK[completeness]) completeness = state
  }

  const rawDiffs = Array.isArray(event.diffs) ? event.diffs : []
  if (!Array.isArray(event.diffs) || rawDiffs.length > MAX_PERMISSION_DIFFS) mark(rawDiffs.length > MAX_PERMISSION_DIFFS ? 'truncated' : 'redacted')
  const diffs = []
  for (const [index, rawDiff] of rawDiffs.slice(0, MAX_PERMISSION_DIFFS).entries()) {
    if (!isPlainObject(rawDiff)) { contextReduced = true; continue }
    assertAllowedKeys(rawDiff, new Set(['type', 'path', 'relativePath', 'oldText', 'newText']), `agent.permission.requested.diffs.${index}`)
    let relativePath
    try {
      relativePath = safeRelativePath(rawDiff.relativePath ?? rawDiff.path, `acp.permission.diffs.${index}.relativePath`)
    } catch {
      contextReduced = true
      continue
    }
    const oldText = typeof rawDiff.oldText === 'string'
      ? safeString(rawDiff.oldText, 'acp.permission.diff.oldText', MAX_DIFF_TEXT, { optional: true }) ?? ''
      : ''
    const newText = typeof rawDiff.newText === 'string'
      ? safeString(rawDiff.newText, 'acp.permission.diff.newText', MAX_DIFF_TEXT, { optional: true }) ?? ''
      : ''
    if (typeof rawDiff.oldText !== 'string' || typeof rawDiff.newText !== 'string') contextReduced = true
    if (rawDiff.oldText?.length > MAX_DIFF_TEXT || rawDiff.newText?.length > MAX_DIFF_TEXT) mark('truncated')
    diffs.push({ relativePath, oldText, newText })
  }

  const rawOptions = Array.isArray(event.options) ? event.options : []
  if (!Array.isArray(event.options) || rawOptions.length > MAX_PERMISSION_OPTIONS) mark(rawOptions.length > MAX_PERMISSION_OPTIONS ? 'truncated' : 'redacted')
  const options = []
  for (const [index, rawOption] of rawOptions.slice(0, MAX_PERMISSION_OPTIONS).entries()) {
    if (!isPlainObject(rawOption)) { contextReduced = true; continue }
    assertAllowedKeys(rawOption, new Set(['id', 'optionId', 'label', 'name', 'kind']), `agent.permission.requested.options.${index}`)
    const id = optionalId(rawOption.id ?? rawOption.optionId, `acp.permission.options.${index}.id`, 120)
    if (!id) { contextReduced = true; continue }
    options.push({
      id,
      label: displayText(rawOption.label ?? rawOption.name, id, `acp.permission.options.${index}.label`, 160),
    })
  }
  if (contextReduced) mark('redacted')

  const cleanSessionId = optionalId(
    sessionId ?? event.attentionSessionId ?? event.sessionId ?? event.targetId,
    'acp.permission.sessionId',
  )
  const targetId = optionalId(event.targetId, 'acp.permission.targetId')
  const fallbackRequestedAt = Number.isSafeInteger(requestedAt) && requestedAt >= 0 ? requestedAt : Date.now()
  return {
    type: 'agent.permission.requested',
    permId,
    projectId: cleanProjectId,
    ...(targetId ? { targetId } : {}),
    ...(cleanSessionId ? { sessionId: cleanSessionId } : {}),
    agent: displayText(event.agent, 'Agent', 'acp.permission.agent', 120),
    title: displayText(event.title, 'Agent action', 'acp.permission.title'),
    requestedAt: Number.isSafeInteger(event.requestedAt) && event.requestedAt >= 0 ? event.requestedAt : fallbackRequestedAt,
    ...(Number.isSafeInteger(event.revision) && event.revision >= 0 ? { revision: event.revision } : {}),
    completeness,
    ...(typeof event.kind === 'string' && safeString(event.kind, 'acp.permission.kind', 80, { optional: true })
      ? { kind: safeString(event.kind, 'acp.permission.kind', 80, { optional: true }) }
      : {}),
    options,
    diffs,
  }
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
  if (session.windowId != null) clean.windowId = safeId(session.windowId, 'session.windowId', 160)
  clean.boardLane = boardLaneFor(clean)
  if (session.provider != null) clean.provider = safeString(session.provider, 'session.provider', 120, { optional: true })
  if (session.model != null) clean.model = safeString(session.model, 'session.model', 120, { optional: true })
  if (session.mode != null) clean.mode = safeString(session.mode, 'session.mode', 80, { optional: true })
  if (session.branch != null) clean.branch = safeString(session.branch, 'session.branch', 240, { optional: true })
  if (session.summary != null) clean.summary = safeString(session.summary, 'session.summary', MAX_DISPLAY, { optional: true })
  if (session.startedAt != null) clean.startedAt = safeTime(session.startedAt, 'session.startedAt', { optional: true })
  if (session.completedAt != null) clean.completedAt = safeTime(session.completedAt, 'session.completedAt', { optional: true })
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
  if (item.targetId != null) clean.targetId = safeId(item.targetId, `permissions.${index}.targetId`, 240)
  if (item.revision != null) clean.revision = safeTime(item.revision, `permissions.${index}.revision`)
  if (item.completeness != null) {
    clean.completeness = PERMISSION_COMPLETENESS.has(item.completeness) ? item.completeness : 'unavailable'
  }
  if (item.sessionId != null) {
    const sessionId = safeId(item.sessionId, `permissions.${index}.sessionId`)
    const session = sessions.get(sessionId)
    if (!session || session.projectId !== projectId) projectionFail('unknown_session', `permission ${permId} names an unknown session`)
    clean.sessionId = sessionId
  }
  if (item.kind != null) clean.kind = safeString(item.kind, 'permission.kind', 80, { optional: true })
  clean.options = (Array.isArray(item.options) ? item.options : []).slice(0, MAX_PERMISSION_OPTIONS).map((rawOption, optionIndex) => {
    const option = plain(rawOption, `permissions.${index}.options.${optionIndex}`)
    return {
      id: safeId(option.id, `permissions.${index}.options.${optionIndex}.id`, 120),
      label: safeString(option.label, `permissions.${index}.options.${optionIndex}.label`, 160),
    }
  })
  clean.diffs = (Array.isArray(item.diffs) ? item.diffs : []).slice(0, MAX_PERMISSION_DIFFS).map((rawDiff, diffIndex) => {
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
      ...(project.windowId == null ? {} : { windowId: safeId(project.windowId, `projects.${index}.windowId`, 160) }),
      ...(project.windowName == null ? {} : { windowName: safeString(project.windowName, `projects.${index}.windowName`, 240, { optional: true }) }),
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
  sanitizeAcpPermissionEvent,
  sanitizeAcpSessionEvent,
  sanitizeProjection,
}
