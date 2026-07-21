'use strict'

const MUX_VERSION = 1
const MUX_OPEN = 1
const MUX_DATA = 2
const MUX_CLOSE = 3
const MAX_RELAY_MESSAGE_BYTES = 2 * 1024 * 1024
const CHANNEL_ID_BYTES = 22
const CHANNEL_RE = new RegExp(`^[A-Za-z0-9_-]{${CHANNEL_ID_BYTES}}$`)
// Bytes the relay adds when wrapping a device payload into a mux frame toward
// the desktop: a 3-byte header (version + type + channelLength) plus the
// channel id. Reserved as a conservative round margin so a device never emits
// a payload that, once framed, exceeds MAX_RELAY_MESSAGE_BYTES.
const MUX_FRAME_OVERHEAD = 64
const MAX_RELAY_DEVICE_PAYLOAD_BYTES = MAX_RELAY_MESSAGE_BYTES - MUX_FRAME_OVERHEAD

function asBuffer(value) {
  if (Buffer.isBuffer(value)) return value
  if (value instanceof ArrayBuffer) return Buffer.from(value)
  if (ArrayBuffer.isView(value)) return Buffer.from(value.buffer, value.byteOffset, value.byteLength)
  return null
}

function encodeMuxFrame(type, channelId, payload = Buffer.alloc(0)) {
  if (![MUX_OPEN, MUX_DATA, MUX_CLOSE].includes(type) || typeof channelId !== 'string' || !CHANNEL_RE.test(channelId)) {
    throw new Error('invalid relay multiplex frame')
  }
  const channel = Buffer.from(channelId, 'utf8')
  const body = asBuffer(payload)
  if (!body || 3 + channel.length + body.length > MAX_RELAY_MESSAGE_BYTES) throw new Error('invalid relay multiplex frame')
  return Buffer.concat([Buffer.from([MUX_VERSION, type, channel.length]), channel, body])
}

function decodeMuxFrame(value) {
  const bytes = asBuffer(value)
  if (!bytes || bytes.length < 4 || bytes.length > MAX_RELAY_MESSAGE_BYTES) throw new Error('invalid relay multiplex frame')
  const channelLength = bytes[2]
  if (bytes[0] !== MUX_VERSION || ![MUX_OPEN, MUX_DATA, MUX_CLOSE].includes(bytes[1])
      || channelLength < 1 || 3 + channelLength > bytes.length) throw new Error('invalid relay multiplex frame')
  const channelId = bytes.subarray(3, 3 + channelLength).toString('utf8')
  if (!CHANNEL_RE.test(channelId)) throw new Error('invalid relay multiplex frame')
  return { type: bytes[1], channelId, payload: bytes.subarray(3 + channelLength) }
}

module.exports = {
  CHANNEL_ID_BYTES,
  MAX_RELAY_DEVICE_PAYLOAD_BYTES,
  MAX_RELAY_MESSAGE_BYTES,
  MUX_CLOSE,
  MUX_DATA,
  MUX_FRAME_OVERHEAD,
  MUX_OPEN,
  MUX_VERSION,
  decodeMuxFrame,
  encodeMuxFrame,
}
