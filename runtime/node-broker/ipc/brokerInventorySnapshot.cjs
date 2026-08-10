'use strict'

function positiveEpoch(value) {
  return Number.isSafeInteger(value) && value > 0 ? value : null
}

function activityChanged(activityEpoch) {
  return {
    ok: false,
    state: 'activity_changed',
    activityEpoch: positiveEpoch(activityEpoch),
  }
}

/**
 * Collect the three inventory surfaces synchronously under one broker-wide
 * activity epoch. A mutation that is already in flight, begins during a test
 * collector, or changes the epoch causes the whole payload to be discarded.
 * No partial status or terminal records escape on the rejection path.
 */
function collectBrokerInventorySnapshot({
  activityEpoch,
  inFlightMutations,
  status,
  diagnostics,
  live,
}) {
  for (const [name, value] of Object.entries({
    activityEpoch,
    inFlightMutations,
    status,
    diagnostics,
    live,
  })) {
    if (typeof value !== 'function') throw new TypeError(`${name} collector must be a function`)
  }

  const startedEpoch = positiveEpoch(activityEpoch())
  if (startedEpoch == null || inFlightMutations() !== 0) {
    return activityChanged(activityEpoch())
  }

  const capturedStatus = status()
  const capturedDiagnostics = diagnostics()
  const capturedLive = live()
  const completedEpoch = positiveEpoch(activityEpoch())
  const statusEpoch = positiveEpoch(capturedStatus?.activityEpoch)

  if (completedEpoch == null
      || completedEpoch !== startedEpoch
      || statusEpoch !== startedEpoch
      || inFlightMutations() !== 0) {
    return activityChanged(completedEpoch)
  }

  return {
    ok: true,
    state: 'stable',
    activityEpoch: startedEpoch,
    status: capturedStatus,
    diagnostics: capturedDiagnostics,
    live: capturedLive,
  }
}

module.exports = { collectBrokerInventorySnapshot }
