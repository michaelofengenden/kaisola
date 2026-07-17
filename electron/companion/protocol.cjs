'use strict'

const PROTOCOL_VERSION = 1
const PROTOCOL_MINOR = 0
const MAX_FRAME_BYTES = 1024 * 1024
const MAX_ID_LENGTH = 160
const MAX_ERROR_MESSAGE = 800

const KINDS = new Set(['hello', 'event', 'command', 'receipt', 'snapshot', 'ack', 'error'])
const CAPABILITIES = new Set(['observe', 'agent-control', 'terminal-control'])
const EVENT_TYPES = new Set([
  'desktop.status',
  'project.updated',
  'session.updated',
  'attention.raised',
  'attention.cleared',
  'agent.turn.delta',
  'agent.turn.completed',
  'agent.permission.requested',
  'agent.permission.resolved',
  'terminal.snapshot',
  'terminal.output',
  'terminal.exit',
  'ledger.task.updated',
])
const SNAPSHOT_TYPES = new Set(['snapshot.projects', 'terminal.snapshot'])
const COMMAND_CAPABILITIES = Object.freeze({
  'agent.prompt': 'agent-control',
  'agent.steer': 'agent-control',
  'agent.cancel': 'agent-control',
  'permission.respond': 'agent-control',
  'terminal.write': 'terminal-control',
  'terminal.resize': 'terminal-control',
  'terminal.interrupt': 'terminal-control',
  'terminal.release-control': 'terminal-control',
})
const RECEIPT_STATUSES = new Set(['accepted', 'applied', 'rejected', 'stale', 'unavailable', 'timed_out'])
const TOP_LEVEL_FIELDS = new Set(['v', 'kind', 'desktopId', 'deviceId', 'connectionId', 'epoch', 'seq', 'id', 'sentAt', 'body'])
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._:@-]*$/

class CompanionProtocolError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CompanionProtocolError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CompanionProtocolError(code, message)
}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const proto = Object.getPrototypeOf(value)
  return proto === Object.prototype || proto === null
}

function assertPlainObject(value, label) {
  if (!isPlainObject(value)) fail('invalid_shape', `${label} must be an object`)
  return value
}

function validateIdentifier(value, label = 'id', max = MAX_ID_LENGTH) {
  if (typeof value !== 'string' || value.length < 1 || value.length > max || !ID_RE.test(value)) {
    fail('invalid_id', `${label} is invalid`)
  }
  return value
}

function safeInteger(value, label, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  if (!Number.isSafeInteger(value) || value < min || value > max) fail('invalid_number', `${label} is invalid`)
  return value
}

function encoded(value) {
  try {
    return JSON.stringify(value)
  } catch {
    fail('invalid_json', 'frame must be JSON serializable')
  }
}

function encodedBytes(value) {
  return Buffer.byteLength(encoded(value), 'utf8')
}

function assertAllowedKeys(value, allowed, label) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail('unknown_field', `${label}.${key} is not allowed`)
  }
}

function validateCapabilities(value, label = 'capabilities') {
  if (!Array.isArray(value) || value.length > CAPABILITIES.size) fail('invalid_capability', `${label} is invalid`)
  const unique = new Set()
  for (const capability of value) {
    if (!CAPABILITIES.has(capability) || unique.has(capability)) fail('invalid_capability', `${label} is invalid`)
    unique.add(capability)
  }
  return [...unique]
}

function validateHello(body) {
  if (body.type !== 'hello') fail('unknown_type', 'hello frame type is invalid')
  if (body.role !== 'desktop' && body.role !== 'device') fail('invalid_role', 'hello role is invalid')
  if (body.protocolMinor != null) safeInteger(body.protocolMinor, 'body.protocolMinor', { max: 10_000 })
  if (body.lastAck != null) safeInteger(body.lastAck, 'body.lastAck')
  validateCapabilities(body.capabilities ?? [])
}

function validateEvent(body) {
  if (!EVENT_TYPES.has(body.type)) fail('unknown_type', `unsupported event type: ${String(body.type || '')}`)
}

function validateSnapshot(body) {
  if (!SNAPSHOT_TYPES.has(body.type)) fail('unknown_type', `unsupported snapshot type: ${String(body.type || '')}`)
  if (body.revision != null) safeInteger(body.revision, 'body.revision')
}

function validateCommand(body, frameId) {
  const expected = COMMAND_CAPABILITIES[body.type]
  if (!expected) fail('unknown_command', `unsupported command type: ${String(body.type || '')}`)
  validateIdentifier(body.commandId, 'body.commandId')
  if (body.commandId !== frameId) fail('command_identity_mismatch', 'command id does not match envelope id')
  validateIdentifier(body.projectId, 'body.projectId', 240)
  validateIdentifier(body.targetId, 'body.targetId', 240)
  if (body.capability !== expected) fail('invalid_capability', `${body.type} requires ${expected}`)
  if (body.expectedRevision != null) safeInteger(body.expectedRevision, 'body.expectedRevision')
  if (body.payload != null) assertPlainObject(body.payload, 'body.payload')
}

function validateReceipt(body) {
  if (body.type !== 'command.receipt') fail('unknown_type', 'receipt frame type is invalid')
  validateIdentifier(body.commandId, 'body.commandId')
  if (!RECEIPT_STATUSES.has(body.status)) fail('invalid_receipt', 'receipt status is invalid')
  if (body.message != null && (typeof body.message !== 'string' || body.message.length > MAX_ERROR_MESSAGE)) {
    fail('invalid_receipt', 'receipt message is invalid')
  }
}

function validateAck(body) {
  if (body.type !== 'ack') fail('unknown_type', 'ack frame type is invalid')
  safeInteger(body.ackSeq, 'body.ackSeq')
}

function validateError(body) {
  if (body.type !== 'error') fail('unknown_type', 'error frame type is invalid')
  validateIdentifier(body.code, 'body.code', 80)
  if (typeof body.message !== 'string' || body.message.length < 1 || body.message.length > MAX_ERROR_MESSAGE) {
    fail('invalid_error', 'error message is invalid')
  }
}

function validateEnvelope(input, { version = PROTOCOL_VERSION } = {}) {
  const frame = assertPlainObject(input, 'frame')
  const serialized = encoded(frame)
  if (Buffer.byteLength(serialized, 'utf8') > MAX_FRAME_BYTES) fail('frame_too_large', 'frame exceeds the companion limit')
  assertAllowedKeys(frame, TOP_LEVEL_FIELDS, 'frame')
  if (frame.v !== version) fail('protocol_mismatch', `protocol ${String(frame.v)} is not supported`)
  if (!KINDS.has(frame.kind)) fail('unknown_kind', `unsupported frame kind: ${String(frame.kind || '')}`)
  validateIdentifier(frame.desktopId, 'desktopId')
  validateIdentifier(frame.deviceId, 'deviceId')
  validateIdentifier(frame.connectionId, 'connectionId')
  validateIdentifier(frame.epoch, 'epoch')
  validateIdentifier(frame.id, 'id')
  safeInteger(frame.seq, 'seq')
  safeInteger(frame.sentAt, 'sentAt')
  const body = assertPlainObject(frame.body, 'body')
  if (typeof body.type !== 'string') fail('unknown_type', 'body.type is required')

  switch (frame.kind) {
    case 'hello': validateHello(body); break
    case 'event': validateEvent(body); break
    case 'snapshot': validateSnapshot(body); break
    case 'command': validateCommand(body, frame.id); break
    case 'receipt': validateReceipt(body); break
    case 'ack': validateAck(body); break
    case 'error': validateError(body); break
    default: fail('unknown_kind', 'unsupported frame kind')
  }

  return JSON.parse(serialized)
}

function decodeEnvelope(value, options) {
  const bytes = Buffer.isBuffer(value) ? value.length : Buffer.byteLength(String(value ?? ''), 'utf8')
  if (!bytes || bytes > MAX_FRAME_BYTES) fail('frame_too_large', 'encoded frame is empty or too large')
  let parsed
  try {
    parsed = JSON.parse(Buffer.isBuffer(value) ? value.toString('utf8') : String(value))
  } catch {
    fail('invalid_json', 'encoded frame is not valid JSON')
  }
  return validateEnvelope(parsed, options)
}

function makeEnvelope(fields, options) {
  return validateEnvelope({ v: PROTOCOL_VERSION, ...fields }, options)
}

function requiredCapability(commandType) {
  return COMMAND_CAPABILITIES[commandType] ?? null
}

module.exports = {
  CAPABILITIES,
  COMMAND_CAPABILITIES,
  CompanionProtocolError,
  EVENT_TYPES,
  KINDS,
  MAX_FRAME_BYTES,
  PROTOCOL_MINOR,
  PROTOCOL_VERSION,
  RECEIPT_STATUSES,
  SNAPSHOT_TYPES,
  assertPlainObject,
  decodeEnvelope,
  encodedBytes,
  isPlainObject,
  makeEnvelope,
  requiredCapability,
  validateCapabilities,
  validateEnvelope,
  validateIdentifier,
}
