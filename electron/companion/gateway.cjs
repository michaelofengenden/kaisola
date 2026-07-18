'use strict'

const {
  PROTOCOL_MINOR,
  PROTOCOL_VERSION,
  validateCapabilities,
  validateEnvelope,
  validateIdentifier,
} = require('./protocol.cjs')
const { CompanionCommandRouter } = require('./commandRouter.cjs')
const { sanitizeAcpPermissionEvent, sanitizeProjection } = require('./redaction.cjs')
const { createAcpActorCapability } = require('../ipc/acpSessionService.cjs')
const { createAttentionActorCapability } = require('../ipc/attentionService.cjs')

const ACP_ACTOR_CAPABILITIES = new Set(['observe', 'agent-control'])

function grantedCapabilities(device, requested) {
  const granted = new Set(validateCapabilities(device.capabilities ?? []))
  const cleanRequested = validateCapabilities(requested ?? [])
  for (const capability of cleanRequested) {
    if (!granted.has(capability)) throw new Error(`device is not granted ${capability}`)
  }
  if (!granted.has('observe')) throw new Error('device is not granted observe')
  return cleanRequested.filter((capability) => granted.has(capability))
}

function validId(value, label, max = 240) {
  try { return validateIdentifier(value, label, max) } catch { return null }
}

function acpActor(deviceId, projectId, capabilities = ['observe']) {
  const acceptedCapabilities = validateCapabilities(Array.isArray(capabilities) ? capabilities : [])
    .filter((capability) => ACP_ACTOR_CAPABILITIES.has(capability))
  return createAcpActorCapability({
    id: `companion-${deviceId}`,
    surface: 'companion',
    projectId,
    capabilities: acceptedCapabilities,
  })
}

function normalizedText(value, fallback, max) {
  if (typeof value !== 'string') return fallback
  const text = value.replace(/[\0\x08\x0b\x0c\x0e-\x1f\x7f]/g, '').trim()
  return text ? text.slice(0, max) : fallback
}

function tryProjectionEntry(projection, patch, { source, entryId, onDiagnostic } = {}) {
  try {
    return sanitizeProjection({ ...projection, ...patch })
  } catch (error) {
    onDiagnostic?.({ source, entryId, error })
    return null
  }
}

function mergeAcpProjection(projection, acpSessionService, {
  actorId = 'gateway',
  now = Date.now,
  onDiagnostic,
} = {}) {
  if (!acpSessionService?.sessionSummaries || !acpSessionService?.pendingPermissionEvents) return projection
  let merged = projection

  for (const project of projection.projects) {
    let summaries
    let permissionEvents
    try {
      const actor = acpActor(actorId, project.id)
      summaries = acpSessionService.sessionSummaries(actor)
      permissionEvents = acpSessionService.pendingPermissionEvents(actor)
    } catch (error) {
      onDiagnostic?.({ source: 'acp.project', entryId: project.id, error })
      continue
    }

    const withoutRendererPermissions = tryProjectionEntry(merged, {
      permissions: merged.permissions.filter((permission) => permission.projectId !== project.id),
    }, { source: 'acp.permissions', entryId: project.id, onDiagnostic })
    if (withoutRendererPermissions) merged = withoutRendererPermissions

    for (const summary of Array.isArray(summaries) ? summaries : []) {
      if (!summary || summary.projectId !== project.id) continue
      const candidates = [summary.sessionId, summary.targetId]
        .map((id, index) => validId(id, `acp.session.${index}`, 240))
        .filter(Boolean)
      const bySessionId = new Map(merged.sessions.map((session) => [session.id, session]))
      let session = candidates.map((id) => bySessionId.get(id)).find((item) => item?.projectId === project.id)
      let added = false
      if (!session) {
        const id = candidates.find((candidate) => !bySessionId.has(candidate))
        if (!id) continue
        session = {
          id,
          projectId: project.id,
          kind: 'agent',
          title: normalizedText(summary.name, normalizedText(summary.provider, 'Agent', 120), 240),
          status: summary.busy === true ? 'running' : 'idle',
          needsYou: false,
          unread: false,
          updatedAt: Number.isSafeInteger(projection.generatedAt) ? projection.generatedAt : now(),
        }
        added = true
      } else {
        session = { ...session }
      }
      if (summary.busy === true) session.status = 'running'
      else if (session.status === 'running') session.status = 'idle'
      const provider = normalizedText(summary.provider, '', 120)
      const name = normalizedText(summary.name, '', 240)
      if (provider) session.provider = provider
      if (session.title === 'Agent' && name) {
        session.title = name
      }
      const sessions = added
        ? [...merged.sessions, session]
        : merged.sessions.map((item) => item.id === session.id ? session : item)
      const next = tryProjectionEntry(merged, { sessions }, {
        source: 'acp.session',
        entryId: candidates[0] || project.id,
        onDiagnostic,
      })
      if (next) merged = next
    }

    for (const event of Array.isArray(permissionEvents) ? permissionEvents : []) {
      if (!event || event.projectId !== project.id) continue
      const sessionId = [event.attentionSessionId, event.sessionId, event.targetId]
        .map((id, index) => validId(id, `acp.permission.session.${index}`, 240))
        .find((id) => merged.sessions.some((session) => session.id === id && session.projectId === project.id))
      let cleanEvent
      try {
        cleanEvent = sanitizeAcpPermissionEvent(event, {
          projectId: project.id,
          sessionId,
          requestedAt: Number.isSafeInteger(projection.generatedAt) ? projection.generatedAt : now(),
        })
        if (!sessionId) delete cleanEvent.sessionId
      } catch (error) {
        onDiagnostic?.({ source: 'acp.permission', entryId: validId(event.permId, 'acp.permission.permId', 240) || project.id, error })
        continue
      }
      const { type: _type, ...permission } = cleanEvent
      const next = tryProjectionEntry(merged, {
        permissions: [...merged.permissions, permission],
      }, { source: 'acp.permission', entryId: permission.permId, onDiagnostic })
      if (next) merged = next
    }
  }
  return merged
}

function ledgerProjectId(task, projects) {
  if (typeof task?.projectId === 'string' && projects.some((project) => project.id === task.projectId)) return task.projectId
  if (typeof task?.project !== 'string' || !task.project) return null
  const matches = projects.filter((project) => [project.id, project.name, project.repo].includes(task.project))
  return matches.length === 1 ? matches[0].id : null
}

function mergeLedgerProjection(projection, ledgerAdapter, { onDiagnostic } = {}) {
  if (typeof ledgerAdapter?.listTasks !== 'function') return projection
  let tasks
  try { tasks = ledgerAdapter.listTasks() } catch (error) {
    onDiagnostic?.({ source: 'ledger.adapter', entryId: 'list', error })
    return projection
  }
  if (!Array.isArray(tasks)) return projection
  let merged = projection
  for (const task of tasks.slice(0, 200)) {
    if (task?.status !== 'review' && task?.status !== 'blocked') continue
    const projectId = ledgerProjectId(task, merged.projects)
    const taskId = validId(task?.id, 'ledger.taskId', 200)
    if (!projectId || !taskId) continue
    const createdAt = Number.isSafeInteger(task.updatedAt) && task.updatedAt >= 0
      ? task.updatedAt
      : Number.isSafeInteger(task.createdAt) && task.createdAt >= 0 ? task.createdAt : merged.generatedAt
    const fallbackTitle = task.status === 'review' ? 'Review agent result' : 'Agent task blocked'
    const title = normalizedText(task.title, fallbackTitle, 240)
    if (merged.attention.some((item) => item.projectId === projectId && item.kind === task.status && item.title === title && item.createdAt === createdAt)) continue
    const id = validId(`attention-${taskId}`, 'ledger.attentionId', 240)
    if (!id || merged.attention.some((item) => item.id === id)) continue
    const detail = normalizedText(task.result || task.detail, '', 240)
    const item = {
      id,
      projectId,
      kind: task.status,
      title,
      createdAt,
      severity: task.status === 'blocked' ? 'warning' : 'info',
      ...(detail ? { detail } : {}),
    }
    const next = tryProjectionEntry(merged, {
      attention: [...merged.attention, item],
    }, { source: 'ledger.task', entryId: taskId, onDiagnostic })
    if (next) merged = next
  }
  return merged
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
    this.terminalSubscriptions = new Map()
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
      const effectiveDevice = { ...this.device, capabilities: [...this.capabilities] }
      const body = await this.gateway.commandRouter.route({ frame: clean, device: effectiveDevice, session: this })
      this.#send('receipt', body, this.#nextId('receipt'), this.lastSentSeq)
      return body
    }
    throw new Error(`device frame kind ${clean.kind} is not accepted after hello`)
  }

  synchronize() {
    if (!this.connected || this.closed) return false
    return this.#sendSynchronization(this.gateway.synchronize({ epoch: this.gateway.epoch, afterSeq: this.lastSentSeq }))
  }

  close(reason = 'closed') {
    if (this.closed) return false
    this.closed = true
    this.connected = false
    this.gateway.releaseSession(this)
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
      terminalSubscriptions: this.terminalSubscriptions.size,
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
    this.#sendSynchronization(this.gateway.synchronize(cursor))
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
    this.lastSentSeq = result.toSeq
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
  constructor({
    desktopId,
    epoch,
    stateHub,
    commandRouter,
    terminalObserver = null,
    acpSessionService = null,
    attentionService = null,
    ledgerAdapter = null,
    enabledCapabilities = ['observe'],
    now = Date.now,
    logger = console,
  } = {}) {
    this.desktopId = validateIdentifier(desktopId, 'desktopId')
    this.epoch = validateIdentifier(epoch, 'epoch')
    if (!stateHub?.synchronize || !stateHub?.acknowledge) throw new Error('companion state hub is required')
    if (terminalObserver != null && typeof terminalObserver !== 'function') throw new Error('companion terminal observer is invalid')
    if (typeof now !== 'function') throw new Error('companion gateway clock is invalid')
    this.stateHub = stateHub
    this.terminalObserver = terminalObserver
    this.acpSessionService = acpSessionService
    this.attentionService = attentionService
    this.ledgerAdapter = ledgerAdapter
    this.enabledCapabilities = validateCapabilities(enabledCapabilities)
    this.now = now
    this.logger = logger && typeof logger.warn === 'function' ? logger : console
    this.sessions = new Set()
    this.cleanupTasks = new Set()
    this.syncQueued = false
    this.disposed = false
    this.adapterErrors = 0
    this.loggedDiagnostics = new Set()

    this.commandRouter = commandRouter ?? new CompanionCommandRouter({
      enabledCapabilities: this.enabledCapabilities,
      handlers: this.#defaultCommandHandlers(),
    })
    if (!this.commandRouter?.route) throw new Error('companion command router is required')
    this.unsubscribeState = stateHub.subscribe?.(() => this.#queueSynchronization()) ?? null
  }

  attach(transport, device) {
    if (this.disposed) throw new Error('companion gateway is disposed')
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

  synchronize(cursor) {
    const result = this.stateHub.synchronize(cursor)
    if (result.kind !== 'snapshot') return result
    let projection = result.projection
    const onDiagnostic = (diagnostic) => this.#recordAdapterDiagnostic(diagnostic)
    try {
      projection = mergeAcpProjection(projection, this.acpSessionService, {
        actorId: this.desktopId,
        now: this.now,
        onDiagnostic,
      })
    } catch (error) {
      this.#recordAdapterDiagnostic({ source: 'acp.merge', entryId: 'snapshot', error })
    }
    try {
      projection = mergeLedgerProjection(projection, this.ledgerAdapter, { onDiagnostic })
    } catch (error) {
      this.#recordAdapterDiagnostic({ source: 'ledger.merge', entryId: 'snapshot', error })
    }
    return { ...result, projection, revision: projection.revision }
  }

  projectionPublished(windowId, result) {
    return this.stateHub.projectionPublished?.(windowId, result) ?? null
  }

  projectionRemoved(windowId) {
    return this.stateHub.projectionRemoved?.(windowId) ?? null
  }

  acpSessionEvent(event) {
    return this.stateHub.acpSessionEvent?.(event, { recordReplay: this.sessions.size > 0 }) ?? null
  }

  terminalAttention(event) {
    return this.stateHub.terminalAttention?.(event) ?? null
  }

  ledgerEvent(event) {
    return this.stateHub.ledgerEvent?.(event) ?? null
  }

  releaseSession(session) {
    this.sessions.delete(session)
    const subscriptions = [...session.terminalSubscriptions.values()]
    session.terminalSubscriptions.clear()
    for (const subscription of subscriptions) {
      if (typeof subscription?.unsubscribe !== 'function') continue
      this.#trackCleanup(Promise.resolve().then(() => subscription.unsubscribe()))
    }
    return subscriptions.length
  }

  async settle() {
    while (this.cleanupTasks.size) await Promise.allSettled([...this.cleanupTasks])
  }

  async dispose() {
    if (this.disposed) return false
    this.disposed = true
    this.unsubscribeState?.()
    this.unsubscribeState = null
    for (const session of [...this.sessions]) session.close('gateway_disposed')
    await this.settle()
    return true
  }

  stats() {
    return {
      desktopId: this.desktopId,
      epoch: this.epoch,
      sessions: [...this.sessions].filter((session) => !session.closed).length,
      terminalSubscriptions: [...this.sessions].reduce((count, session) => count + session.terminalSubscriptions.size, 0),
      adapters: {
        projection: true,
        terminal: typeof this.terminalObserver === 'function',
        acp: !!this.acpSessionService,
        attention: !!this.attentionService,
        ledger: typeof this.ledgerAdapter?.listTasks === 'function',
      },
      adapterErrors: this.adapterErrors,
      commandRouter: this.commandRouter.stats(),
      stateHub: this.stateHub.stats(),
    }
  }

  #defaultCommandHandlers() {
    const handlers = {
      'attention.ack': ({ device, command }) => this.stateHub.acknowledgeAttention(
        createAttentionActorCapability({
          id: `companion-${device.deviceId}`,
          surface: 'companion',
          projectId: command.projectId,
          capabilities: device.capabilities,
        }),
        { projectId: command.projectId, eventId: command.targetId, reason: 'companion_acknowledged' },
      ),
    }
    if (this.terminalObserver) {
      handlers['stream.subscribe'] = ({ device, command, session }) => this.#subscribeTerminal(session, device, command)
      handlers['stream.unsubscribe'] = ({ command, session }) => this.#unsubscribeTerminal(session, command)
    }
    if (this.acpSessionService) {
      handlers['agent.prompt'] = ({ device, command }) => this.acpSessionService.prompt(
        acpActor(device.deviceId, command.projectId, device.capabilities),
        {
          projectId: command.projectId,
          targetId: command.targetId,
          turnId: command.payload?.turnId ?? command.commandId,
          text: command.payload?.text,
          images: command.payload?.images,
          readOnly: command.payload?.readOnly,
          attentionSessionId: command.payload?.attentionSessionId,
        },
      )
      handlers['agent.steer'] = ({ device, command }) => this.acpSessionService.steer(
        acpActor(device.deviceId, command.projectId, device.capabilities),
        { projectId: command.projectId, targetId: command.targetId, text: command.payload?.text, images: command.payload?.images },
      )
      handlers['agent.cancel'] = ({ device, command }) => this.acpSessionService.cancel(
        acpActor(device.deviceId, command.projectId, device.capabilities),
        { projectId: command.projectId, targetId: command.targetId },
      )
      handlers['permission.respond'] = ({ device, command }) => this.acpSessionService.respondPermission(
        acpActor(device.deviceId, command.projectId, device.capabilities),
        {
          projectId: command.projectId,
          targetId: command.targetId,
          permId: command.payload?.permId,
          expectedRevision: command.expectedRevision ?? command.payload?.expectedRevision,
          optionId: command.payload?.optionId,
          decision: command.payload?.decision,
        },
      )
    }
    return handlers
  }

  async #subscribeTerminal(session, device, command) {
    if (!session || session.closed) return { ok: false, status: 'unavailable', message: 'Companion session is closed.' }
    const key = `${command.projectId}\0${command.targetId}`
    await this.#unsubscribeTerminal(session, command)
    let subscription
    try {
      subscription = await this.terminalObserver({
        id: command.targetId,
        projectId: command.projectId,
        subscriberId: `${device.deviceId}:${session.connectionId}`,
        streamEpoch: command.payload?.streamEpoch,
        afterOffset: command.payload?.afterOffset,
        maxQueueBytes: command.payload?.maxQueueBytes,
        onEvent: (event) => {
          if (session.closed || event?.payload?.id !== command.targetId) return
          this.stateHub.terminalObserverEvent?.(command.projectId, event)
        },
      })
    } catch (error) {
      this.adapterErrors++
      return { ok: false, status: 'rejected', message: String(error?.message || error).slice(0, 800) }
    }
    if (!subscription?.ok) {
      return {
        ok: false,
        status: subscription?.unavailable ? 'unavailable' : 'rejected',
        message: String(subscription?.message || 'Terminal stream is unavailable.').slice(0, 800),
      }
    }
    if (session.closed) {
      if (typeof subscription.unsubscribe === 'function') await subscription.unsubscribe()
      return { ok: false, status: 'unavailable', message: 'Companion session closed while subscribing.' }
    }
    session.terminalSubscriptions.set(key, subscription)
    this.stateHub.terminalObserverSnapshot?.(command.projectId, command.targetId, subscription)
    return { ok: true, status: 'applied', message: 'Terminal stream subscribed.' }
  }

  async #unsubscribeTerminal(session, command) {
    if (!session) return { ok: false, status: 'unavailable', message: 'Companion session is unavailable.' }
    const key = `${command.projectId}\0${command.targetId}`
    const subscription = session.terminalSubscriptions.get(key)
    if (!subscription) return { ok: true, status: 'applied', message: 'Terminal stream was already unsubscribed.' }
    session.terminalSubscriptions.delete(key)
    try {
      if (typeof subscription.unsubscribe === 'function') await subscription.unsubscribe()
      return { ok: true, status: 'applied', message: 'Terminal stream unsubscribed.' }
    } catch (error) {
      this.adapterErrors++
      return { ok: false, status: 'unavailable', message: String(error?.message || error).slice(0, 800) }
    }
  }

  #queueSynchronization() {
    if (this.syncQueued || this.disposed) return
    this.syncQueued = true
    queueMicrotask(() => {
      this.syncQueued = false
      if (this.disposed) return
      for (const session of [...this.sessions]) {
        try { session.synchronize() } catch { session.close('synchronization_failed') }
      }
    })
  }

  #recordAdapterDiagnostic({ source = 'adapter', entryId = 'unknown', error } = {}) {
    this.adapterErrors++
    const cleanSource = normalizedText(String(source), 'adapter', 80).replace(/[^A-Za-z0-9_.:-]/g, '_')
    const cleanEntryId = normalizedText(String(entryId), 'unknown', 160).replace(/[^A-Za-z0-9_.:@-]/g, '_')
    const code = normalizedText(error?.code, 'adapter_error', 80).replace(/[^A-Za-z0-9_.:-]/g, '_')
    const key = `${cleanSource}:${cleanEntryId}:${code}`
    if (this.loggedDiagnostics.has(key) || this.loggedDiagnostics.size >= 32) return
    this.loggedDiagnostics.add(key)
    const detail = normalizedText(error?.message, 'Adapter projection was rejected.', 240)
    try {
      this.logger.warn(`[companion] dropped ${cleanSource} entry ${cleanEntryId} (${code}): ${detail}`.slice(0, 512))
    } catch { /* diagnostics cannot affect companion availability */ }
  }

  #trackCleanup(promise) {
    this.cleanupTasks.add(promise)
    promise.finally(() => this.cleanupTasks.delete(promise)).catch(() => {})
  }
}

module.exports = {
  CompanionGateway,
  CompanionGatewaySession,
  grantedCapabilities,
  mergeAcpProjection,
  mergeLedgerProjection,
}
