'use strict'

const os = require('node:os')

const MAX_TERMINAL_ID_LENGTH = 240
const TERMINAL_CREATE_LIMITS = Object.freeze({
  argumentCount: 200,
  argumentBytes: 16 * 1024,
  argumentsBytes: 256 * 1024,
  environmentEntries: 256,
  environmentKeyBytes: 1024,
  environmentValueBytes: 64 * 1024,
  environmentBytes: 256 * 1024,
})

/** Protocol-level PTY geometry. A real renderer is far below these ceilings,
 * while 1,000 still leaves ample headroom for large displays and automation.
 * Keeping the bounds here makes create, resize, and manager defense-in-depth
 * consume one documented contract instead of drifting independently. */
const TERMINAL_GEOMETRY_LIMITS = Object.freeze({
  defaultCols: 80,
  defaultRows: 24,
  maxCols: 1_000,
  maxRows: 1_000,
})

function geometryError(field) {
  return {
    ok: false,
    code: 'terminal_geometry_invalid',
    message: `terminal ${field} must be a finite positive integer`,
    field,
    expected: 'finite positive integer',
  }
}

function validatedTerminalGeometry(raw = {}, { defaults = false } = {}) {
  const cols = raw.cols === undefined && defaults
    ? TERMINAL_GEOMETRY_LIMITS.defaultCols
    : raw.cols
  const rows = raw.rows === undefined && defaults
    ? TERMINAL_GEOMETRY_LIMITS.defaultRows
    : raw.rows

  if (typeof cols !== 'number' || !Number.isFinite(cols) || !Number.isInteger(cols) || cols <= 0) {
    return geometryError('cols')
  }
  if (typeof rows !== 'number' || !Number.isFinite(rows) || !Number.isInteger(rows) || rows <= 0) {
    return geometryError('rows')
  }

  return {
    ok: true,
    value: {
      cols: Math.min(cols, TERMINAL_GEOMETRY_LIMITS.maxCols),
      rows: Math.min(rows, TERMINAL_GEOMETRY_LIMITS.maxRows),
    },
  }
}

function payloadTypeError(message, scope, expected, index) {
  return {
    ok: false,
    code: 'terminal_create_payload_type',
    message,
    scope,
    expected,
    ...(index == null ? {} : { index }),
  }
}

function payloadCountError(message, scope, maxCount, actualCount) {
  return {
    ok: false,
    code: 'terminal_create_payload_limit',
    message,
    scope,
    limit: 'entryCount',
    maxCount,
    actualCount,
  }
}

function payloadByteError(message, scope, limit, maxBytes, actualBytes, index) {
  return {
    ok: false,
    code: 'terminal_create_payload_limit',
    message,
    scope,
    limit,
    ...(index == null ? {} : { index }),
    maxBytes,
    actualBytes,
  }
}

/** Validate before ownership lookup or node-pty spawn. Byte ceilings count the
 * exact UTF-8 content bytes supplied by the client, not JavaScript characters
 * or JSON framing, so multibyte input cannot evade the documented limits. */
function validatedArguments(raw) {
  if (raw === undefined) return { ok: true, value: undefined }
  if (!Array.isArray(raw)) {
    return payloadTypeError(
      'terminal arguments must be an array',
      'arguments',
      'array',
    )
  }
  if (raw.length > TERMINAL_CREATE_LIMITS.argumentCount) {
    return payloadCountError(
      `terminal arguments exceed ${TERMINAL_CREATE_LIMITS.argumentCount} entries`,
      'arguments',
      TERMINAL_CREATE_LIMITS.argumentCount,
      raw.length,
    )
  }

  let totalBytes = 0
  for (let index = 0; index < raw.length; index += 1) {
    const argument = raw[index]
    if (typeof argument !== 'string') {
      return payloadTypeError(
        `terminal argument ${index} must be a string`,
        'arguments',
        'string',
        index,
      )
    }
    const actualBytes = Buffer.byteLength(argument)
    if (actualBytes > TERMINAL_CREATE_LIMITS.argumentBytes) {
      return payloadByteError(
        `terminal argument ${index} exceeds ${TERMINAL_CREATE_LIMITS.argumentBytes} UTF-8 bytes`,
        'arguments',
        'itemBytes',
        TERMINAL_CREATE_LIMITS.argumentBytes,
        actualBytes,
        index,
      )
    }
    totalBytes += actualBytes
  }
  if (totalBytes > TERMINAL_CREATE_LIMITS.argumentsBytes) {
    return payloadByteError(
      `terminal arguments exceed ${TERMINAL_CREATE_LIMITS.argumentsBytes} total UTF-8 bytes`,
      'arguments',
      'totalBytes',
      TERMINAL_CREATE_LIMITS.argumentsBytes,
      totalBytes,
    )
  }
  return { ok: true, value: raw }
}

function validatedEnvironment(raw) {
  if (raw === undefined) return { ok: true, value: undefined }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return payloadTypeError(
      'terminal environment must be an object of string values',
      'environment',
      'object',
    )
  }
  const prototype = Object.getPrototypeOf(raw)
  if (prototype !== Object.prototype && prototype !== null) {
    return payloadTypeError(
      'terminal environment must be an object of string values',
      'environment',
      'object',
    )
  }

  const entries = Object.entries(raw)
  if (entries.length > TERMINAL_CREATE_LIMITS.environmentEntries) {
    return payloadCountError(
      `terminal environment exceeds ${TERMINAL_CREATE_LIMITS.environmentEntries} entries`,
      'environment',
      TERMINAL_CREATE_LIMITS.environmentEntries,
      entries.length,
    )
  }

  let totalBytes = 0
  for (let index = 0; index < entries.length; index += 1) {
    const [key, value] = entries[index]
    if (typeof value !== 'string') {
      return payloadTypeError(
        `terminal environment value ${index} must be a string`,
        'environment',
        'string',
        index,
      )
    }
    const keyBytes = Buffer.byteLength(key)
    if (keyBytes > TERMINAL_CREATE_LIMITS.environmentKeyBytes) {
      return payloadByteError(
        `terminal environment key ${index} exceeds ${TERMINAL_CREATE_LIMITS.environmentKeyBytes} UTF-8 bytes`,
        'environment',
        'keyBytes',
        TERMINAL_CREATE_LIMITS.environmentKeyBytes,
        keyBytes,
        index,
      )
    }
    const valueBytes = Buffer.byteLength(value)
    if (valueBytes > TERMINAL_CREATE_LIMITS.environmentValueBytes) {
      return payloadByteError(
        `terminal environment value ${index} exceeds ${TERMINAL_CREATE_LIMITS.environmentValueBytes} UTF-8 bytes`,
        'environment',
        'valueBytes',
        TERMINAL_CREATE_LIMITS.environmentValueBytes,
        valueBytes,
        index,
      )
    }
    totalBytes += keyBytes + valueBytes
  }
  if (totalBytes > TERMINAL_CREATE_LIMITS.environmentBytes) {
    return payloadByteError(
      `terminal environment exceeds ${TERMINAL_CREATE_LIMITS.environmentBytes} total UTF-8 bytes`,
      'environment',
      'totalBytes',
      TERMINAL_CREATE_LIMITS.environmentBytes,
      totalBytes,
    )
  }
  return { ok: true, value: raw }
}

/** Validate raw resize wire values before consulting terminal ownership. The
 * manager repeats the same validation at its node-pty boundary for non-wire
 * callers. */
function terminalResizeRoute({ manager, id, params = {}, requireAllowed }) {
  const geometry = validatedTerminalGeometry(params)
  if (!geometry.ok) return geometry
  requireAllowed(id)
  return manager.resize(id, geometry.value.cols, geometry.value.rows)
}

/** Preserve the manager's typed kill result exactly. Wrapping it in another
 * `ok` property would turn `{ ok: false }` into a truthy wire success. */
function terminalKillRoute({ manager, id, requireAllowed }) {
  requireAllowed(id)
  return manager.kill(id)
}

/** Preserve the typed deletion receipt and cleanup action exactly. A released
 * PTY may still have an artifact whose unlink needs another idempotent call. */
function terminalReleaseRoute({ manager, id, requireAllowed }) {
  requireAllowed(id)
  return manager.release(id)
}

/** Attach is an ownership mutation, so absence must be decided explicitly
 * before setSender can make the caller believe it adopted a terminal. */
function terminalAttachRoute({
  manager,
  id,
  owner,
  clientInstanceId,
  requireAllowed,
  brokerPid = process.pid,
  now = Date.now,
}) {
  // Authorize first so an unauthorized caller cannot use the distinct missing
  // result as an existence oracle for another project's terminal.
  requireAllowed(id, true)
  if (!manager.has(id)) {
    return {
      id,
      ok: false,
      code: 'terminal_not_found',
      message: 'terminal is no longer available',
    }
  }

  const continuity = manager.setSender(id, owner)
  const previousInstance = continuity?.previousOwner?.split('|')[0]
  const continuation = continuity && previousInstance && previousInstance !== clientInstanceId
    ? { ...continuity, acrossRestart: true, reattachedAt: now(), brokerPid }
    : null
  return {
    ...manager.snapshot(id),
    // Seal the authority-bearing fields after the snapshot so a future
    // snapshot extension cannot accidentally override the attach contract.
    id,
    ok: true,
    continuation,
  }
}

/** The authenticated `terminal.create` operation after access selection. Kept
 * separate from the executable broker so the additive resurrection wire can
 * be contract-tested without binding its AF_UNIX listener. */
function terminalCreateRoute({
  manager,
  params = {},
  owner,
  clientInstanceId,
  requireAllowed,
  brokerPid = process.pid,
  now = Date.now,
}) {
  const id = String(params.id || '')
  if (!id) return { ok: false, message: 'terminal id required' }
  if (id.length > MAX_TERMINAL_ID_LENGTH) {
    return {
      ok: false,
      code: 'terminal_id_too_long',
      message: `terminal id exceeds ${MAX_TERMINAL_ID_LENGTH} characters`,
      maxLength: MAX_TERMINAL_ID_LENGTH,
      actualLength: id.length,
    }
  }
  const args = validatedArguments(params.args)
  if (!args.ok) return args
  const env = validatedEnvironment(params.env)
  if (!env.ok) return env
  const geometry = validatedTerminalGeometry(params, { defaults: true })
  if (!geometry.ok) return geometry
  if (manager.has(id)) requireAllowed(id, true)

  const existed = manager.isLive(id)
  const restore = params.restore === true
  if (restore && !manager.has(id)) {
    // A restore for an id this broker process no longer remembers must still
    // prove project ownership before any retained spool is served:
    // `requireAllowed` has nothing to check against after a broker restart,
    // and the retained spool may hold another project's transcript. The id
    // embeds its project (`term-<project>-<hex8>`), so bind the claim there.
    const embedded = /^term-(.+)-[0-9a-f]{8}$/.exec(id)
    const requested = String(params.projectId ?? '')
    if (!embedded || !requested || embedded[1] !== requested) {
      return { ok: false, message: 'terminal restore denied: project mismatch' }
    }
  }
  let rec
  try {
    rec = manager.spawn({
      id,
      command: typeof params.command === 'string' ? params.command : undefined,
      args: args.value,
      cwd: typeof params.cwd === 'string' ? params.cwd : os.homedir(),
      env: env.value,
      outputByteLimit: Number.isFinite(Number(params.outputByteLimit))
        ? Math.max(0, Math.min(Math.floor(Number(params.outputByteLimit)), 8 * 1024 * 1024))
        : undefined,
      cols: geometry.value.cols,
      rows: geometry.value.rows,
      sender: owner,
      restore,
    })
  } catch (error) {
    if (error?.code !== 'TERMINAL_CAPACITY_EXCEEDED'
        || !Number.isSafeInteger(error.maximumLiveTerminals)
        || error.maximumLiveTerminals < 1) {
      throw error
    }
    return {
      ok: false,
      code: 'terminal_capacity_exceeded',
      message: 'broker terminal capacity reached',
      maximumLiveTerminals: error.maximumLiveTerminals,
    }
  }
  if (!rec) {
    return manager.available()
      ? { ok: false, message: 'could not start terminal' }
      : { ok: false, message: 'node-pty unavailable in session broker' }
  }

  const continuity = manager.setSender(id, owner)
  const previousInstance = continuity?.previousOwner?.split('|')[0]
  const continuation = continuity && previousInstance && previousInstance !== clientInstanceId
    ? { ...continuity, acrossRestart: true, reattachedAt: now(), brokerPid, terminalPid: rec.pty?.pid }
    : null
  return {
    ok: true,
    existed,
    pid: rec.pty?.pid ?? null,
    continuation,
    ...manager.snapshot(id),
    recovered: null,
  }
}

module.exports = {
  terminalAttachRoute,
  terminalCreateRoute,
  terminalKillRoute,
  terminalReleaseRoute,
  terminalResizeRoute,
  validatedTerminalGeometry,
  TERMINAL_CREATE_LIMITS,
  TERMINAL_GEOMETRY_LIMITS,
}
