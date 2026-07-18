'use strict'

const { validateIdentifier } = require('./protocol.cjs')

function safeCursor(cursor) {
  if (cursor == null) return null
  if (!cursor || typeof cursor !== 'object' || Array.isArray(cursor)) throw new Error('companion cursor is invalid')
  const epoch = validateIdentifier(cursor.epoch, 'cursor.epoch')
  const afterSeq = cursor.afterSeq
  if (!Number.isSafeInteger(afterSeq) || afterSeq < 0) throw new Error('companion cursor is invalid')
  return { epoch, afterSeq }
}

/** Renderer-neutral snapshot/replay facade. It owns no listener and never
 * reaches into a renderer store; all state comes from main-owned authorities. */
class CompanionStateHub {
  constructor({ desktopState } = {}) {
    if (!desktopState?.snapshot || !desktopState?.replay || !desktopState?.acknowledge) {
      throw new Error('companion desktop state is required')
    }
    this.desktopState = desktopState
  }

  synchronize(cursor) {
    const cleanCursor = safeCursor(cursor)
    const stats = this.desktopState.stats().eventLog
    if (cleanCursor) {
      const replay = this.desktopState.replay(cleanCursor)
      if (replay.kind === 'replay') return replay
      return this.#snapshot(replay.reason)
    }
    return this.#snapshot('initial_connection')
  }

  acknowledge(clientId, seq) {
    validateIdentifier(clientId, 'clientId')
    return this.desktopState.acknowledge(clientId, seq)
  }

  acknowledgeAttention(actor, target) {
    if (!this.desktopState.acknowledgeAttention) {
      return { ok: false, status: 'unavailable', message: 'Attention authority is unavailable.' }
    }
    return this.desktopState.acknowledgeAttention(actor, target)
  }

  projectionPublished(windowId, result) {
    return this.desktopState.projectionPublished?.(windowId, result) ?? null
  }

  projectionRemoved(windowId) {
    return this.desktopState.projectionRemoved?.(windowId) ?? null
  }

  terminalObserverEvent(projectId, event) {
    return this.desktopState.terminalObserverEvent?.(projectId, event) ?? null
  }

  terminalObserverSnapshot(projectId, terminalId, result) {
    return this.desktopState.terminalObserverSnapshot?.(projectId, terminalId, result) ?? null
  }

  acpSessionEvent(event, options) {
    return this.desktopState.acpSessionEvent?.(event, options) ?? null
  }

  terminalAttention(event) {
    return this.desktopState.terminalAttention?.(event) ?? null
  }

  ledgerEvent(event) {
    return this.desktopState.ledgerEvent?.(event) ?? null
  }

  subscribe(listener) {
    if (!this.desktopState.subscribe) return () => false
    return this.desktopState.subscribe(listener)
  }

  disconnect(clientId) {
    validateIdentifier(clientId, 'clientId')
    return this.desktopState.disconnect?.(clientId) ?? false
  }

  stats() {
    return this.desktopState.stats()
  }

  #snapshot(reason) {
    const projection = this.desktopState.snapshot()
    const eventLog = this.desktopState.stats().eventLog
    return {
      kind: 'snapshot',
      reason,
      epoch: eventLog.epoch,
      currentSeq: eventLog.currentSeq,
      revision: projection.revision,
      projection,
    }
  }
}

module.exports = { CompanionStateHub, safeCursor }
