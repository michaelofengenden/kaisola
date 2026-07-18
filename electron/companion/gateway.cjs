'use strict'

const {
  PROTOCOL_MINOR,
  PROTOCOL_VERSION,
  validateCapabilities,
  validateEnvelope,
  validateIdentifier,
} = require('./protocol.cjs')
const { CompanionCommandRouter } = require('./commandRouter.cjs')
const { createAttentionActorCapability } = require('../ipc/attentionService.cjs')

function grantedCapabilities(device, requested) {
  const granted = new Set(validateCapabilities(device.capabilities ?? []))
  const cleanRequested = validateCapabilities(requested ?? [])
  for (const capability of cleanRequested) {
    if (!granted.has(capability)) throw new Error(`device is not granted ${capability}`)
  }
  if (!granted.has('observe')) throw new Error('device is not granted observe')
  return cleanRequested.filter((capability) => granted.has(capability))
}

class CompanionGatewaySession {
  constructor({ gateway, transport, device }) {
    this.gateway = gateway
    this.transport = transport
    this.device = device
    this.connectionId = null
    this.capabilities = []
    this.connected = false
    this.closed = false
    this.lastSentSeq = 0
    this.frameCounter = 0
  }

  async receive(frame) {
    if (this.closed) throw new Error('companion session is closed')
    const clean = validateEnvelope(frame)
    if (clean.desktopId !== this.gateway.desktopId || clean.deviceId !== this.device.deviceId) {
      throw new Error('companion envelope identity mismatch')
    }
    if (!this.connected) return this.#hello(clean)
    if (clean.connectionId !== this.connectionId || clean.epoch !== this.gateway.epoch) {
      throw new Error('companion connection identity mismatch')
    }
    if (clean.kind === 'ack') {
      this.gateway.stateHub.acknowledge(this.device.deviceId, clean.body.ackSeq)
      return { ok: true, acknowledged: clean.body.ackSeq }
    }
    if (clean.kind === 'command') {
      const body = await this.gateway.commandRouter.route({ frame: clean, device: this.device })
      this.#send('receipt', body, this.#nextId('receipt'), this.lastSentSeq)
      return body
    }
    throw new Error(`device frame kind ${clean.kind} is not accepted after hello`)
  }

  synchronize() {
    if (!this.connected || this.closed) return false
    const result = this.gateway.stateHub.synchronize({ epoch: this.gateway.epoch, afterSeq: this.lastSentSeq })
    return this.#sendSynchronization(result)
  }

  close(reason = 'closed') {
    if (this.closed) return false
    this.closed = true
    this.connected = false
    this.gateway.stateHub.disconnect(this.device.deviceId)
    this.transport.close(reason)
    return true
  }

  stats() {
    return {
      connected: this.connected,
      closed: this.closed,
      deviceId: this.device.deviceId,
      connectionId: this.connectionId,
      capabilities: [...this.capabilities],
      lastSentSeq: this.lastSentSeq,
      transport: this.transport.stats?.(),
    }
  }

  #hello(frame) {
    if (frame.kind !== 'hello' || frame.body.role !== 'device') throw new Error('device hello is required')
    this.connectionId = frame.connectionId
    this.capabilities = grantedCapabilities(this.device, frame.body.capabilities)
    this.connected = true
    this.#send('hello', {
      type: 'hello',
      role: 'desktop',
      protocolMinor: PROTOCOL_MINOR,
      capabilities: this.capabilities,
    }, this.#nextId('hello'), 0)
    const cursor = frame.body.lastAck == null ? null : { epoch: frame.epoch, afterSeq: frame.body.lastAck }
    this.#sendSynchronization(this.gateway.stateHub.synchronize(cursor))
    return { ok: true, capabilities: [...this.capabilities] }
  }

  #sendSynchronization(result) {
    if (result.kind === 'snapshot') {
      const sent = this.#send('snapshot', {
        type: 'snapshot.projects',
        revision: result.revision,
        reason: result.reason,
        projection: result.projection,
      }, this.#nextId('snapshot'), result.currentSeq)
      if (sent) this.lastSentSeq = result.currentSeq
      return sent
    }
    for (const event of result.events) {
      const sent = this.#send('event', { ...event.payload, type: event.type }, event.id, event.seq, event.at)
      if (!sent) return false
      this.lastSentSeq = event.seq
    }
    return true
  }

  #send(kind, body, id, seq, sentAt = this.gateway.now()) {
    const frame = validateEnvelope({
      v: PROTOCOL_VERSION,
      kind,
      desktopId: this.gateway.desktopId,
      deviceId: this.device.deviceId,
      connectionId: this.connectionId,
      epoch: this.gateway.epoch,
      seq,
      id,
      sentAt,
      body,
    })
    if (this.transport.sendToDevice(frame)) return true
    this.close('slow_consumer')
    return false
  }

  #nextId(prefix) {
    this.frameCounter++
    return `${prefix}-${this.frameCounter}`
  }
}

class CompanionGateway {
  constructor({ desktopId, epoch, stateHub, commandRouter, now = Date.now } = {}) {
    this.desktopId = validateIdentifier(desktopId, 'desktopId')
    this.epoch = validateIdentifier(epoch, 'epoch')
    if (!stateHub?.synchronize || !stateHub?.acknowledge) throw new Error('companion state hub is required')
    if (typeof now !== 'function') throw new Error('companion gateway clock is invalid')
    this.stateHub = stateHub
    this.commandRouter = commandRouter ?? new CompanionCommandRouter({
      enabledCapabilities: ['observe'],
      handlers: {
        'attention.ack': ({ device, command }) => stateHub.acknowledgeAttention(
          createAttentionActorCapability({
            id: `companion-${device.deviceId}`,
            surface: 'companion',
            projectId: command.projectId,
            capabilities: device.capabilities,
          }),
          { projectId: command.projectId, eventId: command.targetId, reason: 'companion_acknowledged' },
        ),
      },
    })
    if (!this.commandRouter?.route) throw new Error('companion command router is required')
    this.now = now
    this.sessions = new Set()
    this.syncQueued = false
    this.unsubscribeState = stateHub.subscribe?.((event) => {
      if (event?.type !== 'attention.raised' && event?.type !== 'attention.cleared') return
      if (this.syncQueued) return
      this.syncQueued = true
      queueMicrotask(() => {
        this.syncQueued = false
        for (const session of this.sessions) session.synchronize()
      })
    }) ?? null
  }

  attach(transport, device) {
    if (!transport?.bindGateway || !transport?.sendToDevice || !transport?.close) throw new Error('companion transport is invalid')
    const cleanDevice = {
      deviceId: validateIdentifier(device?.deviceId, 'deviceId'),
      capabilities: validateCapabilities(device?.capabilities ?? []),
    }
    const session = new CompanionGatewaySession({ gateway: this, transport, device: cleanDevice })
    transport.bindGateway((frame) => session.receive(frame))
    this.sessions.add(session)
    return session
  }

  stats() {
    return {
      desktopId: this.desktopId,
      epoch: this.epoch,
      sessions: [...this.sessions].filter((session) => !session.closed).length,
      commandRouter: this.commandRouter.stats(),
      stateHub: this.stateHub.stats(),
    }
  }
}

module.exports = { CompanionGateway, CompanionGatewaySession, grantedCapabilities }
