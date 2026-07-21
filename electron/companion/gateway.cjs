'use strict'

const {
  PROTOCOL_MINOR,
  PROTOCOL_VERSION,
  validateCapabilities,
  validateEnvelope,
  validateIdentifier,
  validateTransportHint,
} = require('./protocol.cjs')
const { CompanionCommandRouter } = require('./commandRouter.cjs')
const { sanitizeAcpPermissionEvent, sanitizeProjection } = require('./redaction.cjs')
const { DEFAULT_SNAPSHOT_BYTES, classifyResume, makeBoundedSnapshot } = require('./terminalCursor.cjs')
const { createAcpActorCapability } = require('../ipc/acpSessionService.cjs')
const { createAttentionActorCapability } = require('../ipc/attentionService.cjs')
const { CompanionTerminalControl } = require('./terminalControl.cjs')

const ACP_ACTOR_CAPABILITIES = new Set(['observe', 'agent-control'])
const MAX_TERMINAL_OBSERVERS = 8
const TERMINAL_EVENT_TYPES = new Set(['terminal.snapshot', 'terminal.output', 'terminal.exit'])

function grantedCapabilities(device, requested) {
  const granted = new Set(validateCapabilities(device.capabilities ?? []))
  const cleanRequested = validateCapabilities(requested ?? [])
  const negotiated = cleanRequested.filter((capability) => granted.has(capability))
  if (!negotiated.includes('observe')) throw new Error('device is not granted observe')
  return negotiated
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

    // The lookup map must reflect merged.sessions AFTER sanitization (session
    // objects are rewritten by tryProjectionEntry), so it can only be reused
    // across summaries that did not change the projection — rebuild lazily on
    // the first summary after an applied change instead of on every summary.
    let bySessionId = null
    for (const summary of Array.isArray(summaries) ? summaries : []) {
      if (!summary || summary.projectId !== project.id) continue
      const candidates = [summary.sessionId, summary.targetId]
        .map((id, index) => validId(id, `acp.session.${index}`, 240))
        .filter(Boolean)
      if (!bySessionId) bySessionId = new Map(merged.sessions.map((session) => [session.id, session]))
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
      if (next) {
        merged = next
        bySessionId = null
      }
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
    this.terminalGenerations = new Map()
    this.acpSubscriptions = new Map()
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
      acpSubscriptions: this.acpSubscriptions.size,
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
      ...this.gateway.currentTransportHint(),
    }, this.#nextId('hello'), 0)
    const cursor = frame.body.lastAck == null ? null : { epoch: frame.epoch, afterSeq: frame.body.lastAck }
    const synchronization = this.gateway.synchronize(cursor)
    this.gateway.reconcileAcpSubscriptions(this, synchronization)
    this.#sendSynchronization(synchronization)
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
      if (!this.#acceptsEvent(event)) continue
      const sent = this.#send('event', { ...event.payload, type: event.type }, event.id, event.seq, event.at)
      if (!sent) return false
      this.lastSentSeq = event.seq
    }
    this.lastSentSeq = result.toSeq
    return true
  }

  #acceptsEvent(event) {
    if (event.audience && event.audience !== this.connectionId) return false
    if (!TERMINAL_EVENT_TYPES.has(event.type)
      && !(event.type === 'session.updated' && event.payload?.streamEpoch && event.payload?.sessionId)) return true
    const terminalId = event.payload?.terminalId ?? event.payload?.sessionId
    const subscription = this.terminalSubscriptions.get(`${event.payload?.projectId}\0${terminalId}`)
    return !!subscription && event.seq > subscription.afterSeq
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
    terminalControlAdapter = null,
    acpSessionService = null,
    attentionService = null,
    ledgerAdapter = null,
    enabledCapabilities = ['observe'],
    transportHintProvider = null,
    now = Date.now,
    logger = console,
  } = {}) {
    this.desktopId = validateIdentifier(desktopId, 'desktopId')
    this.epoch = validateIdentifier(epoch, 'epoch')
    if (!stateHub?.synchronize || !stateHub?.acknowledge) throw new Error('companion state hub is required')
    if (terminalObserver != null && typeof terminalObserver !== 'function') throw new Error('companion terminal observer is invalid')
    if (typeof now !== 'function') throw new Error('companion gateway clock is invalid')
    if (transportHintProvider != null && typeof transportHintProvider !== 'function') throw new Error('companion transport hint provider is invalid')
    this.stateHub = stateHub
    this.terminalObserver = terminalObserver
    this.terminalControl = terminalControlAdapter
      ? new CompanionTerminalControl({ terminalAdapter: terminalControlAdapter, now })
      : null
    this.acpSessionService = acpSessionService
    this.attentionService = attentionService
    this.ledgerAdapter = ledgerAdapter
    this.enabledCapabilities = validateCapabilities(enabledCapabilities)
    this.transportHintProvider = transportHintProvider
    this.now = now
    this.logger = logger && typeof logger.warn === 'function' ? logger : console
    this.sessions = new Set()
    this.terminalStreams = new Map()
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

  currentTransportHint() {
    if (!this.transportHintProvider) return {}
    try {
      return { transportHint: validateTransportHint(this.transportHintProvider()) }
    } catch {
      return {}
    }
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
    const published = this.stateHub.projectionPublished?.(windowId, result) ?? null
    this.#reconcileAllAcpSubscriptions()
    return published
  }

  projectionRemoved(windowId) {
    const removed = this.stateHub.projectionRemoved?.(windowId) ?? null
    this.#reconcileAllAcpSubscriptions()
    return removed
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

  reconcileAcpSubscriptions(session, synchronization) {
    if (!session || session.closed || !session.connected || !this.acpSessionService?.subscribe) return 0
    const source = synchronization?.kind === 'snapshot'
      ? synchronization.projection?.projects?.map((project) => project.id)
      : this.stateHub.projectIds?.()
    const desired = new Set()
    if (session.capabilities.includes('observe')) {
      for (const projectId of Array.isArray(source) ? source : []) {
        const clean = validId(projectId, 'acp.subscription.projectId', 240)
        if (clean) desired.add(clean)
      }
    }
    for (const [projectId, unsubscribe] of session.acpSubscriptions) {
      if (desired.has(projectId)) continue
      session.acpSubscriptions.delete(projectId)
      try { unsubscribe() } catch { /* fail closed on stale subscriber cleanup */ }
    }
    for (const projectId of desired) {
      if (session.acpSubscriptions.has(projectId)) continue
      try {
        const unsubscribe = this.acpSessionService.subscribe(
          acpActor(session.device.deviceId, projectId, ['observe']),
          { onEvent: () => {} },
        )
        session.acpSubscriptions.set(projectId, unsubscribe)
      } catch (error) {
        this.#recordAdapterDiagnostic({ source: 'acp.subscription', entryId: projectId, error })
      }
    }
    return session.acpSubscriptions.size
  }

  releaseSession(session) {
    this.sessions.delete(session)
    for (const key of session.terminalGenerations.keys()) {
      session.terminalGenerations.set(key, (session.terminalGenerations.get(key) ?? 0) + 1)
    }
    const terminalKeys = [...session.terminalSubscriptions.keys()]
    for (const key of terminalKeys) this.#trackCleanup(this.#detachTerminalMember(session, key))
    for (const stream of this.terminalStreams.values()) {
      for (const interest of [...stream.interests]) {
        if (interest.session === session) stream.interests.delete(interest)
      }
      this.#maybeDisposeTerminalStream(stream)
    }
    for (const unsubscribe of session.acpSubscriptions.values()) {
      try { unsubscribe() } catch { /* one subscription cannot block disconnect */ }
    }
    session.acpSubscriptions.clear()
    if (this.terminalControl) this.#trackCleanup(this.terminalControl.releaseSession(session))
    return terminalKeys.length
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
    await this.terminalControl?.dispose()
    await this.settle()
    return true
  }

  stats() {
    return {
      desktopId: this.desktopId,
      epoch: this.epoch,
      sessions: [...this.sessions].filter((session) => !session.closed).length,
      terminalSubscriptions: [...this.sessions].reduce((count, session) => count + session.terminalSubscriptions.size, 0),
      terminalStreams: this.terminalStreams.size,
      acpSubscriptions: [...this.sessions].reduce((count, session) => count + session.acpSubscriptions.size, 0),
      adapters: {
        projection: true,
        terminal: typeof this.terminalObserver === 'function',
        acp: !!this.acpSessionService,
        attention: !!this.attentionService,
        ledger: typeof this.ledgerAdapter?.listTasks === 'function',
      },
      adapterErrors: this.adapterErrors,
      commandRouter: this.commandRouter.stats(),
      terminalControl: this.terminalControl?.stats() ?? null,
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
      handlers['agent.prompt'] = ({ device, command }) => this.#promptAgent(device, command)
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
    if (this.terminalControl) Object.assign(handlers, this.terminalControl.handlers())
    return handlers
  }

  async #promptAgent(device, command) {
    const pending = this.acpSessionService.prompt(
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
    const immediate = await Promise.race([
      Promise.resolve(pending).then((value) => ({ settled: true, value })),
      new Promise((resolve) => setImmediate(() => resolve({ settled: false }))),
    ])
    if (immediate.settled) return immediate.value
    Promise.resolve(pending).catch((error) => {
      this.#recordAdapterDiagnostic({ source: 'acp.prompt', entryId: command.targetId, error })
    })
    return { ok: true, status: 'accepted', message: 'Message accepted by the Mac.' }
  }

  async #subscribeTerminal(session, device, command) {
    if (!session || session.closed) return { ok: false, status: 'unavailable', message: 'Companion session is closed.' }
    const key = `${command.projectId}\0${command.targetId}`
    const generation = (session.terminalGenerations.get(key) ?? 0) + 1
    session.terminalGenerations.set(key, generation)
    await this.#detachTerminalMember(session, key)
    let stream
    try {
      stream = await this.#terminalStreamFor(key, command, device)
    } catch (error) {
      this.adapterErrors++
      return { ok: false, status: 'rejected', message: String(error?.message || error).slice(0, 800) }
    }
    if (session.closed || session.terminalGenerations.get(key) !== generation) {
      await this.#maybeDisposeTerminalStream(stream)
      return { ok: false, status: 'unavailable', message: 'Terminal subscription was superseded.' }
    }

    const interest = { session, generation }
    stream.interests.add(interest)
    let subscription
    try { subscription = await stream.setup } catch (error) {
      subscription = { ok: false, message: String(error?.message || error) }
    } finally {
      stream.interests.delete(interest)
    }
    if (!subscription?.ok) {
      await this.#maybeDisposeTerminalStream(stream)
      return {
        ok: false,
        status: subscription?.unavailable ? 'unavailable' : 'rejected',
        message: String(subscription?.message || 'Terminal stream is unavailable.').slice(0, 800),
      }
    }
    if (session.closed || session.terminalGenerations.get(key) !== generation) {
      await this.#maybeDisposeTerminalStream(stream)
      return { ok: false, status: 'unavailable', message: 'Terminal subscription was superseded.' }
    }
    if (stream.members.size >= MAX_TERMINAL_OBSERVERS) {
      await this.#maybeDisposeTerminalStream(stream)
      return { ok: false, status: 'rejected', message: `Terminal observer limit of ${MAX_TERMINAL_OBSERVERS} reached.` }
    }

    let resume
    try {
      resume = this.#terminalResume(stream, command.payload)
    } catch (error) {
      await this.#maybeDisposeTerminalStream(stream)
      return { ok: false, status: 'rejected', message: String(error?.message || error).slice(0, 800) }
    }
    const currentSeq = this.stateHub.stats?.()?.eventLog?.currentSeq
    const afterSeq = Number.isSafeInteger(currentSeq) && currentSeq >= 0 ? currentSeq : 0
    stream.members.add(session)
    session.terminalSubscriptions.set(key, { stream, generation, afterSeq })
    this.stateHub.terminalObserverSnapshot?.(
      command.projectId,
      command.targetId,
      resume,
      { audience: session.connectionId },
    )
    return { ok: true, status: 'applied', message: 'Terminal stream subscribed.' }
  }

  async #unsubscribeTerminal(session, command) {
    if (!session) return { ok: false, status: 'unavailable', message: 'Companion session is unavailable.' }
    const key = `${command.projectId}\0${command.targetId}`
    session.terminalGenerations.set(key, (session.terminalGenerations.get(key) ?? 0) + 1)
    const hadSubscription = session.terminalSubscriptions.has(key)
    try {
      await this.#detachTerminalMember(session, key)
      return {
        ok: true,
        status: 'applied',
        message: hadSubscription ? 'Terminal stream unsubscribed.' : 'Terminal stream was already unsubscribed.',
      }
    } catch (error) {
      this.adapterErrors++
      return { ok: false, status: 'unavailable', message: String(error?.message || error).slice(0, 800) }
    }
  }

  async #terminalStreamFor(key, command, device) {
    let current = this.terminalStreams.get(key)
    if (current?.closing) {
      await current.disposePromise
      current = this.terminalStreams.get(key)
    }
    if (current) return current

    const stream = {
      key,
      projectId: command.projectId,
      terminalId: command.targetId,
      members: new Set(),
      interests: new Set(),
      pendingEvents: [],
      pendingOverflow: false,
      snapshot: null,
      subscription: null,
      closing: false,
      disposePromise: null,
      setup: null,
    }
    this.terminalStreams.set(key, stream)
    stream.setup = (async () => {
      let result
      try {
        result = await this.terminalObserver({
          id: command.targetId,
          projectId: command.projectId,
          subscriberId: `gateway:${this.desktopId}:${device.deviceId}:${command.targetId}`,
          maxQueueBytes: command.payload?.maxQueueBytes,
          onEvent: (event) => this.#handleTerminalStreamEvent(stream, event),
        })
        if (!result?.ok) return result
        stream.subscription = result
        stream.snapshot = this.#terminalSnapshot(result)
        if (stream.pendingOverflow) throw new Error('Terminal observer emitted too many events during setup.')
        for (const event of stream.pendingEvents.splice(0)) this.#applyTerminalStreamEvent(stream, event)
        return result
      } catch (error) {
        if (typeof result?.unsubscribe === 'function') {
          try { await result.unsubscribe() } catch { /* setup failure still closes the observer */ }
        }
        throw error
      }
    })()
    return stream
  }

  #terminalSnapshot(result) {
    if (result?.mode === 'snapshot' && result.snapshot) {
      const snapshot = makeBoundedSnapshot({
        streamEpoch: result.snapshot.streamEpoch,
        output: result.snapshot.output ?? '',
        endOffset: result.snapshot.endOffset,
        maxBytes: DEFAULT_SNAPSHOT_BYTES,
        truncated: result.snapshot.truncated,
        exited: result.snapshot.exited,
        exitStatus: result.snapshot.exitStatus,
      })
      if (Number.isSafeInteger(result.snapshot.startOffset) && result.snapshot.startOffset !== snapshot.startOffset) {
        throw new Error('Terminal snapshot offsets are inconsistent.')
      }
      return snapshot
    }
    if (result?.mode === 'current' && result.cursor) {
      return makeBoundedSnapshot({
        streamEpoch: result.cursor.streamEpoch,
        output: '',
        endOffset: result.cursor.offset,
        maxBytes: DEFAULT_SNAPSHOT_BYTES,
        truncated: result.cursor.offset > 0,
        exited: false,
      })
    }
    throw new Error('Terminal observer did not return a bounded cursor snapshot.')
  }

  #terminalResume(stream, payload = {}) {
    if (!stream.snapshot) throw new Error('Terminal stream snapshot is unavailable.')
    const hasEpoch = payload?.streamEpoch != null
    const hasOffset = payload?.afterOffset != null
    if (hasEpoch !== hasOffset) throw new Error('Terminal observer cursor is incomplete.')
    if (!hasEpoch) return { mode: 'snapshot', snapshot: stream.snapshot }
    const classified = classifyResume(stream.snapshot, {
      streamEpoch: payload.streamEpoch,
      offset: payload.afterOffset,
    })
    if (classified.kind === 'current') {
      return { mode: 'current', cursor: { streamEpoch: classified.streamEpoch, offset: classified.offset } }
    }
    return { mode: 'snapshot', resetReason: classified.reason, snapshot: classified.snapshot }
  }

  #handleTerminalStreamEvent(stream, event) {
    if (this.terminalStreams.get(stream.key) !== stream || stream.closing) return
    if (!stream.snapshot) {
      if (stream.pendingEvents.length < 64) stream.pendingEvents.push(event)
      else stream.pendingOverflow = true
      return
    }
    this.#applyTerminalStreamEvent(stream, event)
  }

  #applyTerminalStreamEvent(stream, event) {
    if (!event || event?.payload?.id !== stream.terminalId) return
    try {
      if (event.channel === 'terminal:observer-snapshot') {
        stream.snapshot = this.#terminalSnapshot({ mode: 'snapshot', snapshot: event.payload })
      } else if (event.channel === 'terminal:observer-output') {
        const payload = event.payload
        const dataBytes = Buffer.byteLength(typeof payload.data === 'string' ? payload.data : '', 'utf8')
        if (!dataBytes || payload.endOffset - payload.startOffset !== dataBytes) throw new Error('Terminal output offsets are invalid.')
        if (payload.streamEpoch === stream.snapshot.streamEpoch && payload.endOffset <= stream.snapshot.endOffset) return
        if (payload.streamEpoch !== stream.snapshot.streamEpoch || payload.startOffset !== stream.snapshot.endOffset) {
          throw new Error('Terminal output cursor is not contiguous.')
        }
        stream.snapshot = makeBoundedSnapshot({
          streamEpoch: payload.streamEpoch,
          output: stream.snapshot.output + payload.data,
          endOffset: payload.endOffset,
          maxBytes: DEFAULT_SNAPSHOT_BYTES,
          truncated: stream.snapshot.truncated || payload.startOffset > 0,
          exited: false,
        })
      } else if (event.channel === 'terminal:observer-exit') {
        const payload = event.payload
        if (payload.streamEpoch !== stream.snapshot.streamEpoch || payload.offset !== stream.snapshot.endOffset) {
          throw new Error('Terminal exit cursor is invalid.')
        }
        stream.snapshot = makeBoundedSnapshot({
          ...stream.snapshot,
          endOffset: payload.offset,
          maxBytes: DEFAULT_SNAPSHOT_BYTES,
          exited: true,
          exitStatus: payload.exitStatus,
        })
      }
    } catch (error) {
      this.#recordAdapterDiagnostic({ source: 'terminal.stream', entryId: stream.terminalId, error })
      return
    }
    if (stream.members.size > 0) {
      if (event.channel === 'terminal:observer-snapshot') {
        this.stateHub.terminalObserverSnapshot?.(
          stream.projectId,
          stream.terminalId,
          { mode: 'snapshot', snapshot: stream.snapshot },
        )
      } else this.stateHub.terminalObserverEvent?.(stream.projectId, event)
    }
  }

  async #detachTerminalMember(session, key) {
    const marker = session.terminalSubscriptions.get(key)
    if (!marker) return false
    session.terminalSubscriptions.delete(key)
    marker.stream.members.delete(session)
    await this.#maybeDisposeTerminalStream(marker.stream)
    return true
  }

  #maybeDisposeTerminalStream(stream) {
    if (!stream || stream.members.size > 0 || stream.interests.size > 0) return Promise.resolve(false)
    if (stream.closing) return stream.disposePromise
    stream.closing = true
    stream.disposePromise = (async () => {
      try {
        await stream.setup
        if (typeof stream.subscription?.unsubscribe === 'function') await stream.subscription.unsubscribe()
      } catch (error) {
        // Tearing down a dead or never-established observer must not reject:
        // #subscribeTerminal awaits this promise unguarded, and an escaped
        // rejection rides the frame-processing chain all the way to
        // #closeState('authentication_failed'), dropping the phone's whole
        // authenticated connection over one transient broker hiccup — the
        // exact broker-restart window the product is designed to survive.
        this.#recordAdapterDiagnostic({ source: 'terminal.dispose', entryId: stream.key, error })
      } finally {
        if (this.terminalStreams.get(stream.key) === stream) this.terminalStreams.delete(stream.key)
      }
      return true
    })()
    this.#trackCleanup(stream.disposePromise)
    return stream.disposePromise
  }

  #queueSynchronization() {
    if (this.syncQueued || this.disposed) return
    this.syncQueued = true
    queueMicrotask(() => {
      this.syncQueued = false
      if (this.disposed) return
      this.#reconcileAllAcpSubscriptions()
      for (const session of [...this.sessions]) {
        try { session.synchronize() } catch { session.close('synchronization_failed') }
      }
    })
  }

  #reconcileAllAcpSubscriptions() {
    for (const session of this.sessions) this.reconcileAcpSubscriptions(session)
  }

  #recordAdapterDiagnostic({ source = 'adapter', entryId = 'unknown', error } = {}) {
    this.adapterErrors++
    const cleanSource = normalizedText(String(source), 'adapter', 80).replace(/[^A-Za-z0-9_.:-]/g, '_')
    const cleanEntryId = normalizedText(String(entryId), 'unknown', 160).replace(/[^A-Za-z0-9_.:@-]/g, '_')
    const code = normalizedText(error?.code, 'adapter_error', 80).replace(/[^A-Za-z0-9_.:-]/g, '_')
    const key = `${cleanSource}:${cleanEntryId}:${code}`
    if (this.loggedDiagnostics.has(key)) return
    // Bound the dedup set by evicting the oldest key instead of permanently
    // silencing all future diagnostics once 32 distinct keys have been seen.
    if (this.loggedDiagnostics.size >= 32) {
      this.loggedDiagnostics.delete(this.loggedDiagnostics.values().next().value)
    }
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
