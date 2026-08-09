'use strict'

// The native controller normally has only a handful of operations outstanding.
// These ceilings leave room for UI bursts while preventing one authenticated
// socket, or a collection of them, from retaining unbounded dispatch promises.
const DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT = 16
const DEFAULT_PROCESS_IN_FLIGHT_LIMIT = 128

function positiveInteger(value, name) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new TypeError(`${name} must be a positive integer`)
  return value
}

class BrokerRequestGate {
  constructor({
    perClientLimit = DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT,
    processLimit = DEFAULT_PROCESS_IN_FLIGHT_LIMIT,
  } = {}) {
    this.perClientLimit = positiveInteger(perClientLimit, 'per-client request limit')
    this.processLimit = positiveInteger(processLimit, 'process request limit')
    this.clientInFlight = new WeakMap()
    this.processInFlight = 0
  }

  acquire(client) {
    if ((typeof client !== 'object' && typeof client !== 'function') || client === null) {
      throw new TypeError('broker request client identity must be an object')
    }
    const clientCount = this.clientInFlight.get(client) || 0
    if (clientCount >= this.perClientLimit) {
      return {
        ok: false,
        code: 'broker_overloaded',
        scope: 'client',
        limit: this.perClientLimit,
        message: 'broker request capacity exceeded',
      }
    }
    if (this.processInFlight >= this.processLimit) {
      return {
        ok: false,
        code: 'broker_overloaded',
        scope: 'process',
        limit: this.processLimit,
        message: 'broker request capacity exceeded',
      }
    }

    this.clientInFlight.set(client, clientCount + 1)
    this.processInFlight += 1
    let released = false
    return {
      ok: true,
      release: () => {
        if (released) return false
        released = true
        const current = this.clientInFlight.get(client) || 0
        if (current <= 1) this.clientInFlight.delete(client)
        else this.clientInFlight.set(client, current - 1)
        this.processInFlight = Math.max(0, this.processInFlight - 1)
        return true
      },
    }
  }
}

/** Admit and settle one already-authenticated request. Kept outside the broker
 * executable so overload and release ordering can be tested without sockets or
 * PTYs. Returns false only for a synchronous capacity rejection. */
function dispatchBrokerRequest({
  gate,
  client,
  requestID,
  mutating,
  dispatch,
  beginMutation,
  endMutation,
  respond,
  onSuccess,
}) {
  const admission = gate.acquire(client)
  if (!admission.ok) {
    respond({ type: 'response', id: requestID, ok: false, ...admission })
    return false
  }

  let mutationBegan = false
  let operation
  try {
    if (mutating) {
      beginMutation()
      mutationBegan = true
    }
    // Preserve the broker's existing immediate dispatch ordering. Wrapping a
    // synchronous throw still gives the shared settlement path one Promise.
    operation = Promise.resolve(dispatch())
  } catch (error) {
    operation = Promise.reject(error)
  }

  void operation.finally(() => {
    try {
      if (mutationBegan) endMutation()
    } finally {
      // Accounting must never leak even if a diagnostic mutation hook fails.
      admission.release()
    }
  }).then(
    (result) => {
      respond({ type: 'response', id: requestID, ok: true, result })
      onSuccess?.()
    },
    (error) => respond({
      type: 'response',
      id: requestID,
      ok: false,
      message: String(error?.message || error),
    }),
  )
  return true
}

module.exports = {
  BrokerRequestGate,
  DEFAULT_PER_CLIENT_IN_FLIGHT_LIMIT,
  DEFAULT_PROCESS_IN_FLIGHT_LIMIT,
  dispatchBrokerRequest,
}
