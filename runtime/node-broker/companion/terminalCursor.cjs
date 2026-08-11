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

function safeUnicodeRepair(value) {
  if (value == null) return undefined
  if (!isPlainObject(value)) fail('invalid_unicode_repair', 'unicodeRepair must be an object')
  const keys = Object.keys(value).sort()
  if (keys.join(',') !== 'code,replacements,sourceBytes' || value.code !== 'invalid_unicode_repaired') {
    fail('invalid_unicode_repair', 'unicodeRepair is invalid')
  }
  if (!Number.isSafeInteger(value.replacements) || value.replacements < 1 ||
      !Number.isSafeInteger(value.sourceBytes) || value.sourceBytes < value.replacements) {
    fail('invalid_unicode_repair', 'unicodeRepair counts are invalid')
  }
  return {
    code: 'invalid_unicode_repaired',
    replacements: value.replacements,
    sourceBytes: value.sourceBytes,
  }
}

function combinedUnicodeRepair(first, second) {
  const a = safeUnicodeRepair(first)
  const b = safeUnicodeRepair(second)
  if (!a) return b
  if (!b) return a
  const replacements = a.replacements + b.replacements
  const sourceBytes = a.sourceBytes + b.sourceBytes
  if (!Number.isSafeInteger(replacements) || !Number.isSafeInteger(sourceBytes)) {
    fail('invalid_unicode_repair', 'unicodeRepair counts overflowed')
  }
  return { code: 'invalid_unicode_repaired', replacements, sourceBytes }
}

function replacementBytes(length) {
  // U+FFFD is the clearest visible repair marker and itself occupies three
  // UTF-8 bytes. A corrupt span that is not divisible by three receives a
  // trailing `?` for each remaining byte. This is intentionally byte-length
  // preserving: cursor offsets describe the original persisted byte stream,
  // so growing a one-byte error into a three-byte marker would misroute every
  // later resume cursor.
  return Buffer.from('\uFFFD'.repeat(Math.floor(length / 3)) + '?'.repeat(length % 3), 'utf8')
}

function validUtf8ScalarLength(buffer, offset) {
  const first = buffer[offset]
  if (first <= 0x7f) return 1
  if (first >= 0xc2 && first <= 0xdf) {
    return offset + 1 < buffer.length && (buffer[offset + 1] & 0xc0) === 0x80 ? 2 : 0
  }
  if (first >= 0xe0 && first <= 0xef) {
    if (offset + 2 >= buffer.length) return 0
    const second = buffer[offset + 1]
    const third = buffer[offset + 2]
    if ((third & 0xc0) !== 0x80) return 0
    if (first === 0xe0) return second >= 0xa0 && second <= 0xbf ? 3 : 0
    if (first === 0xed) return second >= 0x80 && second <= 0x9f ? 3 : 0
    return (second & 0xc0) === 0x80 ? 3 : 0
  }
  if (first >= 0xf0 && first <= 0xf4) {
    if (offset + 3 >= buffer.length) return 0
    const second = buffer[offset + 1]
    const third = buffer[offset + 2]
    const fourth = buffer[offset + 3]
    if ((third & 0xc0) !== 0x80 || (fourth & 0xc0) !== 0x80) return 0
    if (first === 0xf0) return second >= 0x90 && second <= 0xbf ? 4 : 0
    if (first === 0xf4) return second >= 0x80 && second <= 0x8f ? 4 : 0
    return (second & 0xc0) === 0x80 ? 4 : 0
  }
  return 0
}

function repairedByteBuffer(input) {
  const parts = []
  let validStart = 0
  let offset = 0
  let replacements = 0
  let sourceBytes = 0
  while (offset < input.length) {
    const validLength = validUtf8ScalarLength(input, offset)
    if (validLength) {
      offset += validLength
      continue
    }

    if (validStart < offset) parts.push(input.subarray(validStart, offset))
    const corruptStart = offset
    offset += 1
    // Continuation bytes following a rejected or truncated lead belong to the
    // same corrupt scalar. Stop before ASCII or a plausible new scalar so its
    // bytes remain exactly intact.
    while (offset < input.length && (input[offset] & 0xc0) === 0x80) offset += 1
    const corruptLength = offset - corruptStart
    parts.push(replacementBytes(corruptLength))
    replacements += 1
    sourceBytes += corruptLength
    validStart = offset
  }
  if (validStart < input.length) parts.push(input.subarray(validStart))
  if (!replacements) return { buffer: input }
  return {
    buffer: Buffer.concat(parts),
    unicodeRepair: { code: 'invalid_unicode_repaired', replacements, sourceBytes },
  }
}

/** Whether the string carries a surrogate that is not half of a valid pair.
 *
 * One pass, no allocation, no concatenation. The repair below rebuilds the
 * whole string a code unit at a time and then encodes the rebuilt copy, which
 * is far too expensive to run over output needing no repair — and needing
 * repair is the rare case, arising only when a pty chunk splits a scalar. This
 * runs on every chunk of every terminal, so it is the difference between a
 * scan and a full rebuild per burst of agent output.
 *
 * `charCodeAt` past the end returns NaN and every comparison against NaN is
 * false, so a high surrogate in the final position falls through to `true`
 * rather than reading past the string. */
function hasLoneSurrogate(value) {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index)
    if (code < 0xd800 || code > 0xdfff) continue
    if (code <= 0xdbff) {
      const following = value.charCodeAt(index + 1)
      if (following >= 0xdc00 && following <= 0xdfff) {
        index += 1
        continue
      }
    }
    return true
  }
  return false
}

function repairedStringBuffer(value) {
  // With nothing to replace the loop below reconstructs `value` exactly, so
  // encoding the original yields the same bytes without the intermediate copy.
  if (!hasLoneSurrogate(value)) return { buffer: Buffer.from(value, 'utf8') }
  let repaired = ''
  let replacements = 0
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index)
    if (code >= 0xd800 && code <= 0xdbff) {
      const following = value.charCodeAt(index + 1)
      if (following >= 0xdc00 && following <= 0xdfff) {
        repaired += value[index] + value[index + 1]
        index += 1
      } else {
        repaired += '\uFFFD'
        replacements += 1
      }
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      repaired += '\uFFFD'
      replacements += 1
    } else {
      repaired += value[index]
    }
  }
  const buffer = Buffer.from(repaired, 'utf8')
  return replacements
    ? {
        buffer,
        unicodeRepair: {
          code: 'invalid_unicode_repaired',
          replacements,
          // Node encodes each lone UTF-16 surrogate as one three-byte U+FFFD.
          sourceBytes: replacements * 3,
        },
      }
    : { buffer }
}

function repairedUtf8(value, label = 'output') {
  if (typeof value === 'string') return repairedStringBuffer(value)
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) {
    return repairedByteBuffer(Buffer.from(value))
  }
  fail('invalid_utf8', `${label} must be UTF-8 text or bytes`)
}

function utf8Buffer(value, label = 'output') {
  return repairedUtf8(value, label).buffer
}

function isUtf8Boundary(buffer, offset) {
  return offset === 0 || offset === buffer.length || (buffer[offset] & 0xc0) !== 0x80
}

function utf8Tail(value, maxBytes) {
  const repaired = repairedUtf8(value)
  const buffer = repaired.buffer
  safeByteLimit(maxBytes)
  let start = Math.max(0, buffer.length - maxBytes)
  while (start < buffer.length && !isUtf8Boundary(buffer, start)) start++
  const tail = buffer.subarray(start)
  return {
    text: tail.toString('utf8'),
    bytes: tail.length,
    droppedBytes: start,
    truncated: start > 0,
    ...(repaired.unicodeRepair ? { unicodeRepair: repaired.unicodeRepair } : {}),
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
  unicodeRepair,
}) {
  const epoch = safeEpoch(streamEpoch)
  const end = safeOffset(endOffset, 'endOffset')
  safeByteLimit(maxBytes)
  const repaired = repairedUtf8(output)
  const buffer = repaired.buffer
  if (buffer.length > end) fail('invalid_offset', 'output is longer than endOffset')
  let start = Math.max(0, buffer.length - maxBytes)
  while (start < buffer.length && !isUtf8Boundary(buffer, start)) start++
  const tailBuffer = buffer.subarray(start)
  const repair = combinedUnicodeRepair(unicodeRepair, repaired.unicodeRepair)
  const startOffset = end - tailBuffer.length
  const cleanExitStatus = sanitizeExitStatus(exitStatus)
  return {
    streamEpoch: epoch,
    output: tailBuffer.toString('utf8'),
    startOffset,
    endOffset: end,
    truncated: truncated === true || start > 0 || startOffset > 0,
    exited: exited === true,
    ...(cleanExitStatus ? { exitStatus: cleanExitStatus } : {}),
    ...(repair ? { unicodeRepair: repair } : {}),
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
    unicodeRepair: snapshot.unicodeRepair,
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
  if (offset === clean.endOffset) {
    return {
      kind: 'current',
      streamEpoch: clean.streamEpoch,
      offset,
      ...(clean.unicodeRepair ? { unicodeRepair: clean.unicodeRepair } : {}),
    }
  }

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
      unicodeRepair: clean.unicodeRepair,
    }),
  }
}

class TerminalCursor {
  constructor({ streamEpoch, startOffset = 0 }) {
    this.streamEpoch = safeEpoch(streamEpoch)
    this.nextOffset = safeOffset(startOffset, 'startOffset')
  }

  append(data) {
    const repaired = repairedUtf8(data, 'data')
    const buffer = repaired.buffer
    const startOffset = this.nextOffset
    const endOffset = startOffset + buffer.length
    if (!Number.isSafeInteger(endOffset)) fail('offset_overflow', 'terminal byte offset overflowed')
    this.nextOffset = endOffset
    return {
      streamEpoch: this.streamEpoch,
      data: buffer.toString('utf8'),
      startOffset,
      endOffset,
      ...(repaired.unicodeRepair ? { unicodeRepair: repaired.unicodeRepair } : {}),
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
