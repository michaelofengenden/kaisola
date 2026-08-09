'use strict'

// Observation remains available after an invariant failure so a controller can
// display and recover live PTYs without trusting the broker with another state
// transition. Everything else is treated as a mutation and fails closed.
const DEGRADED_OBSERVATION_METHODS = new Set([
  'broker.status',
  'broker.inventory',
  'terminal.available',
  'terminal.subscribe',
  'terminal.unsubscribe',
  'terminal.snapshot',
  'terminal.history',
  'terminal.waitForExit',
  'terminal.list',
  'terminal.diagnostics',
])

class BrokerBackgroundRejection extends Error {
  constructor(operation) {
    super('classified broker background rejection')
    this.name = 'BrokerBackgroundRejection'
    this.operation = /^[a-z0-9._:-]{1,80}$/i.test(String(operation || ''))
      ? String(operation)
      : 'background-operation'
  }
}

/** Mark a known best-effort background failure before it reaches the process
 * rejection boundary. The original cause is intentionally not retained: it
 * may contain provider credentials, paths, or request data. */
function backgroundRejection(operation) {
  return new BrokerBackgroundRejection(operation)
}

function createBrokerRejectionSupervisor({ log = () => {} } = {}) {
  const report = typeof log === 'function' ? log : () => {}
  let degraded = false
  let backgroundRejectionCount = 0
  let invariantFailureCount = 0
  let lastBackgroundOperation = null

  function handle(reason) {
    if (reason instanceof BrokerBackgroundRejection) {
      backgroundRejectionCount++
      lastBackgroundOperation = reason.operation
      report(`background rejection operation=${reason.operation}`)
      return { kind: 'background', operation: reason.operation }
    }

    invariantFailureCount++
    degraded = true
    // Never interpolate an unclassified rejection. It can contain secrets or
    // terminal control bytes, and classification is the only useful operator
    // signal after the mutation fence has latched.
    report('fatal rejection classification=unhandled mutations=fenced')
    return { kind: 'invariant' }
  }

  function allows(method) {
    return !degraded || DEGRADED_OBSERVATION_METHODS.has(String(method || ''))
  }

  function status() {
    return {
      state: degraded ? 'degraded' : 'healthy',
      mutationFence: degraded,
      backgroundRejectionCount,
      invariantFailureCount,
      lastBackgroundOperation,
    }
  }

  return { allows, handle, status }
}

module.exports = { backgroundRejection, createBrokerRejectionSupervisor }
