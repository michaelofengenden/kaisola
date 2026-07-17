'use strict'

const { randomUUID } = require('node:crypto')

const ACTOR_CAPABILITY = Symbol('kaisola.acp.actor-capability')
const ACTOR_CAPABILITIES = new Set(['observe', 'agent-control'])
const PERMISSION_COMPLETENESS = Object.freeze(['complete', 'truncated', 'redacted', 'unavailable'])
const COMPLETENESS_RANK = Object.freeze({ complete: 0, truncated: 1, redacted: 2, unavailable: 3 })
const MAX_PERMISSION_TITLE = 500
const MAX_PERMISSION_KIND = 100
const MAX_PERMISSION_AGENT = 160
const MAX_PERMISSION_OPTIONS = 32
const MAX_PERMISSION_OPTION_ID = 160
const MAX_PERMISSION_OPTION_NAME = 300
const MAX_PERMISSION_DIFFS = 8
const MAX_PERMISSION_PATH = 2_048
const MAX_PERMISSION_DIFF_TEXT = 40_000

function cleanString(value, { fallback = '', max, mark } = {}) {
  if (typeof value !== 'string') return fallback
  if (value.length <= max) return value
  mark?.('truncated')
  return value.slice(0, max)
}

function deepFreeze(value) {
  if (!value || typeof value !== 'object' || Object.isFrozen(value)) return value
  for (const child of Object.values(value)) deepFreeze(child)
  return Object.freeze(value)
}

function cloneReceipt(receipt) {
  return receipt ? { ...receipt } : receipt
}

function cloneJson(value, fallback) {
  if (value == null) return value
  try { return JSON.parse(JSON.stringify(value)) } catch { return fallback }
}

function createAcpActorCapability({ id, surface, projectId, ownerId, capabilities } = {}) {
  if (typeof id !== 'string' || !id || id.length > 500) throw new Error('ACP actor id is invalid.')
  if (surface !== 'desktop' && surface !== 'companion') throw new Error('ACP actor surface is invalid.')
  if (typeof projectId !== 'string' || projectId.length > 240 || (surface === 'companion' && !projectId)) {
    throw new Error('ACP actor project capability is invalid.')
  }
  const list = Array.isArray(capabilities) ? capabilities : capabilities instanceof Set ? [...capabilities] : []
  const unique = new Set(list)
  if (!unique.size || unique.size !== list.length || [...unique].some((capability) => !ACTOR_CAPABILITIES.has(capability))) {
    throw new Error('ACP actor capabilities are invalid.')
  }
  if (surface === 'desktop' && (typeof ownerId !== 'string' || !ownerId || ownerId.length > 240)) {
    throw new Error('ACP desktop owner capability is invalid.')
  }
  if (surface === 'companion' && ownerId != null) throw new Error('ACP companion actors cannot name a renderer owner.')
  return Object.freeze({
    [ACTOR_CAPABILITY]: true,
    id,
    surface,
    projectId,
    ...(surface === 'desktop' ? { ownerId } : {}),
    capabilities: Object.freeze([...unique]),
  })
}

function hasActiveTurn(entry) {
  // `channel` keeps older state/probe fixtures readable while live service turns
  // use only renderer-neutral actor + turn ids.
  return !!(entry?.current?.turnId || entry?.current?.channel)
}

function identityFor(entry) {
  const meta = entry?.meta || {}
  const targetId = typeof meta.key === 'string' && meta.key
    ? meta.key
    : typeof meta.presetId === 'string' ? meta.presetId : ''
  return {
    projectId: typeof meta.scope === 'string' ? meta.scope : '',
    targetId,
    ...(typeof meta.sessionId === 'string' && meta.sessionId ? { sessionId: meta.sessionId } : {}),
    ...(entry?.sender?.id != null ? { ownerId: String(entry.sender.id) } : {}),
  }
}

function targetMatches(identity, targetId) {
  return identity.targetId === targetId || identity.sessionId === targetId
}

function sanitizePermissionEvent({ permId, revision, entry, agent, key, toolCall, options, sensitive }) {
  let completeness = 'complete'
  const mark = (state) => {
    if (COMPLETENESS_RANK[state] > COMPLETENESS_RANK[completeness]) completeness = state
  }
  const identity = identityFor(entry)
  const call = toolCall && typeof toolCall === 'object' && !Array.isArray(toolCall) ? toolCall : null
  if (!call) mark('unavailable')

  const rawKind = call?.kind
  const kind = typeof rawKind === 'string' && rawKind
    ? cleanString(rawKind, { max: MAX_PERMISSION_KIND, mark })
    : undefined
  const rawTitle = typeof call?.title === 'string' && call.title ? call.title : kind
  if (!rawTitle) mark('unavailable')
  const title = cleanString(rawTitle, { fallback: 'Agent action', max: MAX_PERMISSION_TITLE, mark })
  const cleanAgent = cleanString(agent, { fallback: 'Agent', max: MAX_PERMISSION_AGENT, mark })

  const rawOptions = Array.isArray(options) ? options : []
  if (!Array.isArray(options)) mark('unavailable')
  if (rawOptions.length > MAX_PERMISSION_OPTIONS) mark('truncated')
  const cleanOptions = []
  for (const raw of rawOptions.slice(0, MAX_PERMISSION_OPTIONS)) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw) || typeof raw.optionId !== 'string' || !raw.optionId) {
      mark('redacted')
      continue
    }
    // Option ids are provider semantics, not display prose. Never truncate one
    // into a different decision token; omit it and require a fail-closed reject.
    if (raw.optionId.length > MAX_PERMISSION_OPTION_ID) {
      mark('redacted')
      continue
    }
    const optionId = raw.optionId
    const name = cleanString(raw.name, { fallback: optionId, max: MAX_PERMISSION_OPTION_NAME, mark })
    const optionKind = typeof raw.kind === 'string' && raw.kind
      ? cleanString(raw.kind, { max: MAX_PERMISSION_KIND, mark })
      : undefined
    cleanOptions.push({ optionId, name, ...(optionKind ? { kind: optionKind } : {}) })
  }

  const content = Array.isArray(call?.content) ? call.content : []
  if (call?.content != null && !Array.isArray(call.content)) mark('redacted')
  const diffs = []
  for (const block of content) {
    if (!block || typeof block !== 'object' || Array.isArray(block) || block.type !== 'diff') {
      // The desktop card has no faithful renderer for arbitrary provider blocks.
      // Make that loss explicit instead of presenting the remaining fields as full context.
      mark('redacted')
      continue
    }
    if (diffs.length >= MAX_PERMISSION_DIFFS) {
      mark('truncated')
      continue
    }
    if (typeof block.path !== 'string' || !block.path) {
      mark('redacted')
      continue
    }
    const path = cleanString(block.path, { max: MAX_PERMISSION_PATH, mark })
    const oldText = cleanString(block.oldText, { fallback: '', max: MAX_PERMISSION_DIFF_TEXT, mark })
    const newText = cleanString(block.newText, { fallback: '', max: MAX_PERMISSION_DIFF_TEXT, mark })
    diffs.push({ path, oldText, newText })
  }

  return deepFreeze({
    type: 'agent.permission.requested',
    permId,
    revision,
    completeness,
    projectId: identity.projectId,
    targetId: identity.targetId,
    ...(identity.sessionId ? { sessionId: identity.sessionId } : {}),
    key: typeof key === 'string' && key ? key : identity.targetId,
    agent: cleanAgent,
    title,
    ...(kind ? { kind } : {}),
    ...(sensitive === true ? { sensitive: true } : {}),
    options: cleanOptions,
    diffs,
  })
}

function providerDecision(displayPayload, { optionId, decision } = {}) {
  if (typeof optionId === 'string' && optionId) {
    if (!displayPayload.options.some((option) => option.optionId === optionId)) return null
    return { optionId }
  }
  if (decision === 'reject') return 'reject'
  if (decision === 'allow') return 'allow'
  return null
}

class AcpSessionService {
  #connections
  #pendingPermissions
  #resolvedPermissions = new Map()
  #subscribers = new Map()
  #subscriberSeq = 0
  #permissionRevision = 0
  #permissionTimeoutMs
  #cancelGraceMs
  #steerFlushMs
  #resolvedReceiptLimit
  #isMoving
  #readOnlyModeForControls
  #onDesktopEvent
  #hasDesktopSubscriber
  #onCancelTimeout
  #setTimeout
  #clearTimeout
  #idFactory

  constructor({
    connections,
    pendingPermissions = new Map(),
    permissionTimeoutMs = 300_000,
    cancelGraceMs = 8_000,
    steerFlushMs = 2_000,
    resolvedReceiptLimit = 512,
    isMoving = () => false,
    readOnlyModeForControls = () => null,
    onDesktopEvent = () => false,
    hasDesktopSubscriber = (entry) => !!entry?.sender && !entry.sender.isDestroyed?.(),
    onCancelTimeout = () => {},
    setTimeoutFn = setTimeout,
    clearTimeoutFn = clearTimeout,
    idFactory = randomUUID,
  } = {}) {
    if (!(connections instanceof Map) || !(pendingPermissions instanceof Map)) throw new Error('ACP service maps are required.')
    this.#connections = connections
    this.#pendingPermissions = pendingPermissions
    this.#permissionTimeoutMs = Math.max(1, Number(permissionTimeoutMs) || 300_000)
    this.#cancelGraceMs = Math.max(1, Number(cancelGraceMs) || 8_000)
    this.#steerFlushMs = Math.max(1, Number(steerFlushMs) || 2_000)
    this.#resolvedReceiptLimit = Math.max(1, Number(resolvedReceiptLimit) || 512)
    this.#isMoving = isMoving
    this.#readOnlyModeForControls = readOnlyModeForControls
    this.#onDesktopEvent = onDesktopEvent
    this.#hasDesktopSubscriber = hasDesktopSubscriber
    this.#onCancelTimeout = onCancelTimeout
    this.#setTimeout = setTimeoutFn
    this.#clearTimeout = clearTimeoutFn
    this.#idFactory = idFactory
  }

  sessionSummaries(actor) {
    const cleanActor = this.#requireActor(actor, 'observe')
    const summaries = []
    for (const [internalKey, entry] of this.#connections) {
      const identity = identityFor(entry)
      if (identity.projectId !== cleanActor.projectId) continue
      if (cleanActor.surface === 'desktop' && !this.#ownerMatches(entry, internalKey, cleanActor.ownerId)) continue
      summaries.push(deepFreeze({
        projectId: identity.projectId,
        targetId: identity.targetId,
        ...(identity.sessionId ? { sessionId: identity.sessionId } : {}),
        provider: entry.meta?.presetId,
        name: entry.meta?.name,
        connected: !!entry.conn?.alive,
        busy: hasActiveTurn(entry) || (entry.inFlightTurns ?? 0) > 0,
        controls: cloneJson(entry.controls, { modes: null, configOptions: [] }),
        availableCommands: cloneJson(entry.availableCommands || [], []),
        canLoadSession: !!entry.conn?.canLoadSession,
        canResumeSession: !!entry.conn?.canResumeSession,
        promptImages: !!entry.conn?.promptImageOk,
        promptQueue: !!entry.conn?.supportsPromptQueue,
      }))
    }
    return summaries
  }

  pendingPermissionEvents(actor, { targetId } = {}) {
    const cleanActor = this.#requireActor(actor, 'observe')
    if (targetId != null && (typeof targetId !== 'string' || !targetId)) throw new Error('ACP permission target is invalid.')
    const events = []
    for (const record of this.#pendingPermissions.values()) {
      if (!record.displayPayload || record.projectId !== cleanActor.projectId) continue
      if (cleanActor.surface === 'desktop' && record.ownerId !== cleanActor.ownerId) continue
      if (targetId && !targetMatches(record, targetId)) continue
      events.push(record.displayPayload)
    }
    return events
  }

  subscribe(actor, { targetId, onEvent } = {}) {
    const cleanActor = this.#requireActor(actor, 'observe')
    if (typeof onEvent !== 'function') throw new Error('ACP subscriber callback is required.')
    if (targetId != null && (typeof targetId !== 'string' || !targetId || targetId.length > 500)) {
      throw new Error('ACP subscriber target is invalid.')
    }
    if (targetId) {
      const resolved = this.#resolveEntry(cleanActor, { projectId: cleanActor.projectId, targetId })
      if (resolved.error) throw new Error(resolved.error.message)
    }
    const subscriptionId = `acp-sub-${++this.#subscriberSeq}`
    this.#subscribers.set(subscriptionId, { actor: cleanActor, targetId: targetId || null, onEvent })
    let active = true
    return () => {
      if (!active) return false
      active = false
      return this.#subscribers.delete(subscriptionId)
    }
  }

  publishUpdate(entry, update) {
    const turn = entry?.current
    if (!turn?.turnId) return false
    const identity = identityFor(entry)
    this.#emit(entry, deepFreeze({
      type: 'agent.turn.delta',
      projectId: identity.projectId,
      targetId: identity.targetId,
      ...(identity.sessionId ? { sessionId: identity.sessionId } : {}),
      turnId: turn.turnId,
      delta: cloneJson(update, null),
    }))
    return true
  }

  requestPermission(entry, { agent, key, toolCall, options, sensitive } = {}) {
    const identity = identityFor(entry)
    if (!identity.targetId || !this.#hasSubscriberFor(entry, identity)) return Promise.resolve('cancel')
    this.#permissionRevision = this.#permissionRevision >= Number.MAX_SAFE_INTEGER ? 1 : this.#permissionRevision + 1
    const revision = this.#permissionRevision
    const basePermId = `perm-${String(this.#idFactory())}`
    let permId = basePermId
    let collision = 0
    while (this.#pendingPermissions.has(permId) || this.#resolvedPermissions.has(permId)) {
      permId = `${basePermId}-${revision}-${++collision}`
    }
    const displayPayload = sanitizePermissionEvent({ permId, revision, entry, agent, key, toolCall, options, sensitive })

    return new Promise((resolve) => {
      const record = {
        entry,
        resolve,
        timer: null,
        displayPayload,
        revision,
        projectId: identity.projectId,
        targetId: identity.targetId,
        sessionId: identity.sessionId,
        ownerId: identity.ownerId,
      }
      record.timer = this.#setTimeout(() => {
        this.#settlePermission(record, 'cancel', 'timed_out')
      }, this.#permissionTimeoutMs)
      this.#pendingPermissions.set(permId, record)
      this.#emit(entry, displayPayload)
    })
  }

  permissionContext(actor, permId) {
    let cleanActor
    try { cleanActor = this.#requireActor(actor, 'agent-control') } catch { return null }
    const record = this.#pendingPermissions.get(permId) || this.#resolvedPermissions.get(permId)
    if (!record) return null
    if (cleanActor.surface === 'desktop') {
      if (!record.ownerId || record.ownerId !== cleanActor.ownerId) return null
    } else if (record.projectId !== cleanActor.projectId) return null
    return Object.freeze({
      projectId: record.projectId,
      targetId: record.targetId,
      ...(record.sessionId ? { sessionId: record.sessionId } : {}),
      revision: record.revision,
    })
  }

  respondPermission(actor, { projectId, targetId, permId, expectedRevision, optionId, decision } = {}) {
    let cleanActor
    try { cleanActor = this.#requireActor(actor, 'agent-control') } catch (error) {
      return this.#failure('rejected', error.message)
    }
    if (typeof permId !== 'string' || !permId || typeof projectId !== 'string' || typeof targetId !== 'string' || !targetId) {
      return this.#failure('rejected', 'Permission target is invalid.')
    }
    if (projectId !== cleanActor.projectId) return this.#failure('rejected', 'Project capability does not match the permission target.')
    const pending = this.#pendingPermissions.get(permId)
    if (!pending) return this.#latePermissionReceipt(cleanActor, { projectId, targetId, permId, expectedRevision })
    if (pending.projectId !== projectId || !targetMatches(pending, targetId)) {
      return this.#failure('rejected', 'Permission does not belong to this project and session.')
    }
    if (cleanActor.surface === 'desktop' && pending.ownerId !== cleanActor.ownerId) {
      return this.#failure('rejected', 'Permission does not belong to this desktop actor.')
    }
    if (!Number.isSafeInteger(expectedRevision) || expectedRevision !== pending.revision) {
      return this.#staleRevisionReceipt(permId, expectedRevision, pending.revision)
    }
    const answer = providerDecision(pending.displayPayload, { optionId, decision })
    if (answer == null) return this.#failure('rejected', 'Permission response is invalid.')

    const receipt = Object.freeze({
      ok: true,
      status: 'applied',
      permId,
      revision: pending.revision,
      resolution: 'responded',
      message: decision === 'reject' ? 'Permission rejected.' : 'Permission response applied.',
    })
    if (!this.#settlePermission(pending, answer, 'responded', cleanActor.id)) {
      return this.#latePermissionReceipt(cleanActor, { projectId, targetId, permId, expectedRevision })
    }
    return cloneReceipt(receipt)
  }

  async prompt(actor, { projectId, targetId, turnId, text, images, readOnly } = {}) {
    const resolved = this.#controlEntry(actor, { projectId, targetId })
    if (resolved.error) return resolved.error
    const { entry, actor: cleanActor } = resolved
    if (!entry.conn?.alive) return this.#failure('unavailable', 'Agent not connected.')
    if (this.#isMoving(entry)) return { ...this.#failure('unavailable', 'This project is moving to another window. Try again in a moment.'), moving: true }
    if (hasActiveTurn(entry) || (entry.inFlightTurns ?? 0) > 0) {
      return this.#failure('rejected', 'The previous agent turn is still stopping — send again in a moment.')
    }
    if (typeof turnId !== 'string' || !turnId || turnId.length > 500) return this.#failure('rejected', 'Agent turn id is invalid.')

    entry.cancelRequested = false
    const turn = { actorId: cleanActor.id, targetId, turnId }
    entry.current = turn
    entry.turnSeq = (entry.turnSeq ?? 0) + 1
    entry.inFlightTurns = (entry.inFlightTurns ?? 0) + 1
    entry.steerPromises = []
    let signalTurnDone
    entry.turnDone = new Promise((resolve) => { signalTurnDone = resolve })
    const constrainedMode = readOnly === true ? this.#readOnlyModeForControls(entry.controls) : null
    let restoreModeId = null
    let signalled = false
    const flushSteers = async () => {
      entry.turnEnding = true
      if (!signalled) { signalled = true; signalTurnDone() }
      if (entry.steerPromises.length) {
        await Promise.race([
          Promise.allSettled(entry.steerPromises),
          this.#delay(this.#steerFlushMs),
        ])
      }
    }
    try {
      if (readOnly === true) {
        if (!constrainedMode) throw new Error('This agent does not expose a read-only mode required by Mesh Idea mode.')
        if (constrainedMode.previousModeId !== constrainedMode.modeId) {
          await entry.conn.setMode(constrainedMode.modeId)
          restoreModeId = constrainedMode.previousModeId
        }
      }
      const result = await entry.conn.prompt(text, images)
      await flushSteers()
      this.#emitTurnCompleted(entry, turn, { ok: true, stopReason: result?.stopReason })
      return { ok: true, stopReason: result?.stopReason }
    } catch (error) {
      await flushSteers()
      this.#emitTurnCompleted(entry, turn, { ok: false })
      return this.#failure('rejected', String(error?.message || error))
    } finally {
      if (restoreModeId && entry.conn?.alive) {
        try { await entry.conn.setMode(restoreModeId) } catch { /* staying read-only is the fail-closed fallback */ }
      }
      if (entry.current === turn) entry.current = { actorId: null, turnId: null }
      entry.steerPromises = []
      entry.turnEnding = false
      entry.inFlightTurns = 0
      entry.cancelRequested = false
      this.clearCancelWatchdog(entry)
    }
  }

  async steer(actor, { projectId, targetId, text, images } = {}) {
    const resolved = this.#controlEntry(actor, { projectId, targetId })
    if (resolved.error) return resolved.error
    const { entry } = resolved
    if (!entry.conn?.alive) return this.#failure('unavailable', 'Agent not connected.')
    if (!entry.conn.supportsPromptQueue) return { ...this.#failure('unavailable', 'unsupported'), unsupported: true }
    if (!entry.current?.turnId || entry.turnEnding) {
      return { ...this.#failure('rejected', 'No active turn to steer.'), noTurn: true }
    }
    const seq = entry.turnSeq
    const turnDone = entry.turnDone
    entry.inFlightTurns = (entry.inFlightTurns ?? 0) + 1
    const prompt = entry.conn.prompt(text, images)
    ;(entry.steerPromises ??= []).push(prompt.catch(() => {}))
    try {
      const settled = await Promise.race([
        prompt.then((result) => ({ result })).catch((error) => ({ error })),
        turnDone.then(() => this.#delay(this.#steerFlushMs)).then(() => ({ turnEnded: true })),
      ])
      if (settled.turnEnded) return { ok: true, stopReason: 'turn_ended' }
      if (settled.error) return this.#failure('rejected', String(settled.error?.message || settled.error))
      return { ok: true, stopReason: settled.result?.stopReason }
    } finally {
      if (entry.turnSeq === seq) entry.inFlightTurns = Math.max(0, (entry.inFlightTurns ?? 1) - 1)
    }
  }

  async setMode(actor, { projectId, targetId, modeId } = {}) {
    const resolved = this.#controlEntry(actor, { projectId, targetId })
    if (resolved.error) return resolved.error
    const { entry } = resolved
    if (!entry.conn?.alive) return this.#failure('unavailable', 'Agent not connected.')
    if (this.#isMoving(entry)) return { ...this.#failure('unavailable', 'This project is moving to another window.'), moving: true }
    try {
      await entry.conn.setMode(modeId)
      return { ok: true }
    } catch (error) {
      return this.#failure('rejected', String(error?.message || error))
    }
  }

  cancel(actor, { projectId, targetId } = {}) {
    const resolved = this.#controlEntry(actor, { projectId, targetId })
    if (resolved.error) return resolved.error
    const { entry, internalKey } = resolved
    if (!entry.conn?.alive) return this.#failure('unavailable', 'Agent not connected.')
    this.beginEntryCancellation(entry)
    entry.conn.cancel()
    if (hasActiveTurn(entry)) entry.current = { actorId: null, turnId: null }
    if ((entry.inFlightTurns ?? 0) > 0 && !entry.cancelWatchdog) {
      entry.cancelWatchdog = this.#setTimeout(() => {
        entry.cancelWatchdog = null
        if ((entry.inFlightTurns ?? 0) <= 0) return
        this.cancelPendingFor(entry, 'cancel_timeout')
        entry.conn.dispose()
        if (this.#connections.get(internalKey) === entry) this.#connections.delete(internalKey)
        this.#onCancelTimeout({ entry, internalKey, targetId })
      }, this.#cancelGraceMs)
      entry.cancelWatchdog?.unref?.()
    }
    return { ok: true }
  }

  cancelPendingFor(entry, reason = 'cancelled') {
    let cancelled = 0
    for (const pending of [...this.#pendingPermissions.values()]) {
      if (pending.entry !== entry) continue
      if (this.#settlePermission(pending, 'cancel', reason)) cancelled++
    }
    return cancelled
  }

  beginEntryCancellation(entry) {
    if (!entry) return false
    entry.cancelRequested = (entry.inFlightTurns ?? 0) > 0 || hasActiveTurn(entry)
    this.cancelPendingFor(entry, 'cancelled')
    return entry.cancelRequested
  }

  clearCancelWatchdog(entry) {
    if (entry?.cancelWatchdog) this.#clearTimeout(entry.cancelWatchdog)
    if (entry) entry.cancelWatchdog = null
  }

  dispose() {
    for (const pending of [...this.#pendingPermissions.values()]) this.#settlePermission(pending, 'cancel', 'service_disposed')
    this.#subscribers.clear()
    this.#resolvedPermissions.clear()
  }

  #requireActor(actor, capability) {
    if (!actor || actor[ACTOR_CAPABILITY] !== true || !actor.capabilities.includes(capability)) {
      throw new Error(`ACP actor lacks ${capability} capability.`)
    }
    return actor
  }

  #controlEntry(actor, target) {
    let cleanActor
    try { cleanActor = this.#requireActor(actor, 'agent-control') } catch (error) {
      return { error: this.#failure('rejected', error.message) }
    }
    const resolved = this.#resolveEntry(cleanActor, target)
    return resolved.error ? resolved : { ...resolved, actor: cleanActor }
  }

  #resolveEntry(actor, { projectId, targetId } = {}) {
    if (typeof projectId !== 'string' || typeof targetId !== 'string' || !targetId || targetId.length > 500) {
      return { error: this.#failure('rejected', 'ACP project and session target are required.') }
    }
    if (actor.projectId !== projectId) {
      return { error: this.#failure('rejected', 'Project capability does not match the ACP target.') }
    }

    if (actor.surface === 'desktop') {
      const directKey = `${actor.ownerId}|${targetId}`
      const direct = this.#connections.get(directKey)
      if (direct) {
        const identity = identityFor(direct)
        if (identity.projectId !== projectId) {
          return { error: this.#failure('rejected', 'ACP target belongs to another project.') }
        }
        return { entry: direct, internalKey: directKey }
      }
    }

    const matches = []
    let targetInAnotherProject = false
    for (const [internalKey, entry] of this.#connections) {
      const identity = identityFor(entry)
      if (!targetMatches(identity, targetId)) continue
      if (identity.projectId !== projectId) {
        targetInAnotherProject = true
        continue
      }
      if (actor.surface === 'desktop' && !this.#ownerMatches(entry, internalKey, actor.ownerId)) continue
      matches.push({ entry, internalKey })
    }
    if (matches.length === 1) return matches[0]
    if (matches.length > 1) return { error: this.#failure('unavailable', 'ACP target is ambiguous in this project.') }
    if (targetInAnotherProject) return { error: this.#failure('rejected', 'ACP target belongs to another project.') }
    return { error: this.#failure('unavailable', 'Agent not connected.') }
  }

  #ownerMatches(entry, internalKey, ownerId) {
    if (entry?.sender?.id != null) return String(entry.sender.id) === ownerId
    return String(internalKey).startsWith(`${ownerId}|`)
  }

  #hasSubscriberFor(entry, identity) {
    if (this.#hasDesktopSubscriber(entry)) return true
    for (const subscription of this.#subscribers.values()) {
      if (this.#subscriptionMatches(subscription, entry, identity)) return true
    }
    return false
  }

  #subscriptionMatches(subscription, entry, identity) {
    if (subscription.actor.projectId !== identity.projectId) return false
    if (subscription.actor.surface === 'desktop' && identity.ownerId !== subscription.actor.ownerId) return false
    return !subscription.targetId || targetMatches(identity, subscription.targetId)
  }

  #emit(entry, event) {
    const identity = identityFor(entry)
    try { this.#onDesktopEvent(entry, event) } catch { /* one surface cannot break the provider callback */ }
    for (const subscription of this.#subscribers.values()) {
      if (!this.#subscriptionMatches(subscription, entry, identity)) continue
      try { subscription.onEvent(event) } catch { /* isolate subscriber failures */ }
    }
    return event
  }

  #emitTurnCompleted(entry, turn, { ok, stopReason }) {
    const identity = identityFor(entry)
    this.#emit(entry, Object.freeze({
      type: 'agent.turn.completed',
      projectId: identity.projectId,
      targetId: identity.targetId,
      ...(identity.sessionId ? { sessionId: identity.sessionId } : {}),
      turnId: turn.turnId,
      ok,
      ...(stopReason ? { stopReason } : {}),
    }))
  }

  #settlePermission(record, providerAnswer, resolution, actorId) {
    const permId = record.displayPayload?.permId || [...this.#pendingPermissions].find(([, value]) => value === record)?.[0]
    if (!permId || this.#pendingPermissions.get(permId) !== record) return false
    // Delete first: subscriber callbacks and provider continuations can re-enter,
    // but no second path can observe this permission as actionable.
    this.#pendingPermissions.delete(permId)
    if (record.timer) this.#clearTimeout(record.timer)
    const revision = record.revision ?? record.displayPayload?.revision
    const identity = record.displayPayload ? {
      projectId: record.projectId,
      targetId: record.targetId,
      sessionId: record.sessionId,
      ownerId: record.ownerId,
    } : identityFor(record.entry)
    const resolvedEvent = record.displayPayload
      ? deepFreeze({
          type: 'agent.permission.resolved',
          projectId: identity.projectId,
          targetId: identity.targetId,
          ...(identity.sessionId ? { sessionId: identity.sessionId } : {}),
          permId,
          revision,
          resolution,
          ...(actorId ? { actorId } : {}),
        })
      : Object.freeze({ type: 'agent.permission.resolved', permId })
    const lateReceipt = Object.freeze({
      ok: false,
      status: 'stale',
      resolved: true,
      permId,
      ...(revision != null ? { revision } : {}),
      resolution,
      message: 'Permission is already resolved.',
    })
    this.#rememberResolved(permId, {
      projectId: identity.projectId,
      targetId: identity.targetId,
      sessionId: identity.sessionId,
      ownerId: identity.ownerId,
      revision,
      lateReceipt,
    })
    try { record.resolve(providerAnswer) } catch { /* resolver failure cannot resurrect the permission */ }
    this.#emit(record.entry, resolvedEvent)
    return true
  }

  #rememberResolved(permId, record) {
    this.#resolvedPermissions.delete(permId)
    this.#resolvedPermissions.set(permId, record)
    while (this.#resolvedPermissions.size > this.#resolvedReceiptLimit) {
      this.#resolvedPermissions.delete(this.#resolvedPermissions.keys().next().value)
    }
  }

  #latePermissionReceipt(actor, { projectId, targetId, permId, expectedRevision }) {
    const record = this.#resolvedPermissions.get(permId)
    if (!record) return this.#failure('stale', 'Permission is stale or unavailable.')
    if (record.projectId !== projectId || !targetMatches(record, targetId)) {
      return this.#failure('rejected', 'Permission does not belong to this project and session.')
    }
    if (actor.surface === 'desktop' && record.ownerId !== actor.ownerId) {
      return this.#failure('rejected', 'Permission does not belong to this desktop actor.')
    }
    if (!Number.isSafeInteger(expectedRevision) || expectedRevision !== record.revision) {
      return this.#staleRevisionReceipt(permId, expectedRevision, record.revision)
    }
    return cloneReceipt(record.lateReceipt)
  }

  #staleRevisionReceipt(permId, expectedRevision, currentRevision) {
    return {
      ok: false,
      status: 'stale',
      permId,
      expectedRevision,
      currentRevision,
      message: 'Permission revision is stale.',
    }
  }

  #failure(status, message) {
    return { ok: false, status, message }
  }

  #delay(ms) {
    return new Promise((resolve) => { this.#setTimeout(resolve, ms) })
  }
}

module.exports = {
  AcpSessionService,
  createAcpActorCapability,
  hasActiveTurn,
  PERMISSION_COMPLETENESS,
}
