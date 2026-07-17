'use strict'

const DEFAULT_LOOPBACK_QUEUE_BYTES = 1024 * 1024

function cloneFrame(frame) {
  const encoded = JSON.stringify(frame)
  if (encoded === undefined) throw new Error('loopback frame must be JSON serializable')
  return { frame: JSON.parse(encoded), bytes: Buffer.byteLength(encoded, 'utf8') }
}

/** Deterministic in-memory transport for gateway probes and the fixture app.
 * It deliberately has no socket, port, EventEmitter, or ambient IPC surface. */
class LoopbackCompanionTransport {
  constructor({ maxQueueBytes = DEFAULT_LOOPBACK_QUEUE_BYTES } = {}) {
    if (!Number.isSafeInteger(maxQueueBytes) || maxQueueBytes < 1) throw new Error('loopback queue limit is invalid')
    this.maxQueueBytes = maxQueueBytes
    this.queue = []
    this.queuedBytes = 0
    this.receiver = null
    this.closed = false
    this.closeReason = null
  }

  bindGateway(receiver) {
    if (this.receiver || typeof receiver !== 'function') throw new Error('loopback gateway receiver is invalid')
    this.receiver = receiver
  }

  async sendFromDevice(frame) {
    if (this.closed) throw new Error('loopback transport is closed')
    if (!this.receiver) throw new Error('loopback gateway is not attached')
    return this.receiver(cloneFrame(frame).frame)
  }

  sendToDevice(frame) {
    if (this.closed) return false
    const clean = cloneFrame(frame)
    if (clean.bytes > this.maxQueueBytes || this.queuedBytes + clean.bytes > this.maxQueueBytes) return false
    this.queue.push(clean)
    this.queuedBytes += clean.bytes
    return true
  }

  receiveForDevice() {
    const frames = this.queue.map((item) => item.frame)
    this.queue = []
    this.queuedBytes = 0
    return frames
  }

  close(reason = 'closed') {
    if (this.closed) return false
    this.closed = true
    this.closeReason = String(reason)
    this.queue = []
    this.queuedBytes = 0
    return true
  }

  stats() {
    return {
      closed: this.closed,
      closeReason: this.closeReason,
      queuedFrames: this.queue.length,
      queuedBytes: this.queuedBytes,
      maxQueueBytes: this.maxQueueBytes,
    }
  }
}

module.exports = { DEFAULT_LOOPBACK_QUEUE_BYTES, LoopbackCompanionTransport }
