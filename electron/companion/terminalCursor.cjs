'use strict'

const { isPlainObject, validateIdentifier } = require('./protocol.cjs')

const DEFAULT_SNAPSHOT_BYTES = 256 * 1024

class CompanionTerminalCursorError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'CompanionTerminalCursorError'
    this.code = code
  }
}

function fail(code, message) {
  throw new CompanionTerminalCursorError(code, message)
}

function safeEpoch(value) {
  try {
    return validateIdentifier(value, 'streamEpoch')
  } catch {
    fail('invalid_stream_epoch', 'streamEpoch is invalid')
  }
}

function safeOffset(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) fail('invalid_offset', `${label} is invalid`)
  return value
}

function safeByteLimit(value) {
  if (!Number.isSafeInteger(value) || value < 1) fail('invalid_limit', 'maxBytes must be positive')
  return value
}

function utf8Buffer(value, label = 'output') {
  let buffer
  if (typeof value === 'string') buffer = Buffer.from(value, 'utf8')
  else if (Buffer.isBuffer(value) || value instanceof Uint8Array) buffer = Buffer.from(value)
  else fail('invalid_utf8', `${label} must be UTF-8 text or bytes`)
  if (!Buffer.from(buffer.toString('utf8'), 'utf8').equals(buffer)) fail('invalid_utf8', `${label} is not valid UTF-8`)
  return buffer
}

function isUtf8Boundary(buffer, offset) {
  return offset === 0 || offset === buffer.length || (buffer[offset] & 0xc0) !== 0x80
}

function utf8Tail(value, maxBytes) {
  const buffer = utf8Buffer(value)
  safeByteLimit(maxBytes)
  let start = Math.max(0, buffer.length - maxBytes)
  while (start < buffer.length && !isUtf8Boundary(buffer, start)) start++
  const tail = buffer.subarray(start)
  return {
    text: tail.toString('utf8'),
    bytes: tail.length,
    droppedBytes: start,
    truncated: start > 0,
  }
}

function sanitizeExitStatus(value) {
  if (value == null) return undefined
  if (!isPlainObject(value)) fail('invalid_exit_status', 'exitStatus must be an object')
  for (const key of Object.keys(value)) {
    if (key !== 'exitCode' && key !== 'signal') fail('invalid_exit_status', `exitStatus.${key} is not allowed`)
  }
  const clean = {}
  if (value.exitCode != null) {
    if (!Number.isSafeInteger(value.exitCode)) fail('invalid_exit_status', 'exitStatus.exitCode is invalid')
    clean.exitCode = value.exitCode
  }
  if (value.signal != null) {
    if (typeof value.signal !== 'string' || !/^[A-Z0-9_-]{1,32}$/.test(value.signal)) {
      fail('invalid_exit_status', 'exitStatus.signal is invalid')
    }
    clean.signal = value.signal
  }
  return clean
}

function makeBoundedSnapshot({
  streamEpoch,
  output,
  endOffset,
  maxBytes = DEFAULT_SNAPSHOT_BYTES,
  truncated = false,
  exited = false,
  exitStatus,
}) {
  const epoch = safeEpoch(streamEpoch)
  const end = safeOffset(endOffset, 'endOffset')
  safeByteLimit(maxBytes)
  const buffer = utf8Buffer(output)
  if (buffer.length > end) fail('invalid_offset', 'output is longer than endOffset')
  const tail = utf8Tail(buffer, maxBytes)
  const startOffset = end - tail.bytes
  const cleanExitStatus = sanitizeExitStatus(exitStatus)
  return {
    streamEpoch: epoch,
    output: tail.text,
    startOffset,
    endOffset: end,
    truncated: truncated === true || tail.truncated || startOffset > 0,
    exited: exited === true,
    ...(cleanExitStatus ? { exitStatus: cleanExitStatus } : {}),
  }
}

function normalizeSnapshot(snapshot) {
  if (!isPlainObject(snapshot)) fail('invalid_snapshot', 'snapshot must be an object')
  const outputBytes = utf8Buffer(snapshot.output).length
  const clean = makeBoundedSnapshot({
    streamEpoch: snapshot.streamEpoch,
    output: snapshot.output,
    endOffset: snapshot.endOffset,
    maxBytes: Math.max(1, outputBytes),
    truncated: snapshot.truncated,
    exited: snapshot.exited,
    exitStatus: snapshot.exitStatus,
  })
  if (snapshot.startOffset !== clean.startOffset) fail('invalid_snapshot', 'snapshot offsets do not match its UTF-8 bytes')
  return clean
}

function classifyResume(snapshot, cursor) {
  const clean = normalizeSnapshot(snapshot)
  if (!isPlainObject(cursor)) fail('invalid_cursor', 'cursor must be an object')
  const cursorEpoch = safeEpoch(cursor.streamEpoch)
  const offset = safeOffset(cursor.offset, 'cursor.offset')

  if (cursorEpoch !== clean.streamEpoch) return { kind: 'reset', reason: 'epoch_mismatch', snapshot: clean }
  if (offset > clean.endOffset) return { kind: 'reset', reason: 'cursor_ahead', snapshot: clean }
  if (offset < clean.startOffset) return { kind: 'snapshot', reason: 'event_gap', snapshot: clean }
  if (offset === clean.endOffset) return { kind: 'current', streamEpoch: clean.streamEpoch, offset }

  const buffer = utf8Buffer(clean.output)
  const relativeOffset = offset - clean.startOffset
  if (!isUtf8Boundary(buffer, relativeOffset)) {
    return { kind: 'reset', reason: 'invalid_utf8_boundary', snapshot: clean }
  }
  const suffix = buffer.subarray(relativeOffset)
  return {
    kind: 'snapshot',
    reason: 'available_suffix',
    snapshot: makeBoundedSnapshot({
      streamEpoch: clean.streamEpoch,
      output: suffix,
      endOffset: clean.endOffset,
      maxBytes: Math.max(1, suffix.length),
      truncated: clean.truncated || offset > 0,
      exited: clean.exited,
      exitStatus: clean.exitStatus,
    }),
  }
}

class TerminalCursor {
  constructor({ streamEpoch, startOffset = 0 }) {
    this.streamEpoch = safeEpoch(streamEpoch)
    this.nextOffset = safeOffset(startOffset, 'startOffset')
  }

  append(data) {
    const buffer = utf8Buffer(data, 'data')
    const startOffset = this.nextOffset
    const endOffset = startOffset + buffer.length
    if (!Number.isSafeInteger(endOffset)) fail('offset_overflow', 'terminal byte offset overflowed')
    this.nextOffset = endOffset
    return {
      streamEpoch: this.streamEpoch,
      data: buffer.toString('utf8'),
      startOffset,
      endOffset,
    }
  }

  position() {
    return { streamEpoch: this.streamEpoch, offset: this.nextOffset }
  }
}

module.exports = {
  CompanionTerminalCursorError,
  DEFAULT_SNAPSHOT_BYTES,
  TerminalCursor,
  classifyResume,
  isUtf8Boundary,
  makeBoundedSnapshot,
  utf8Tail,
}

