'use strict'

const { CompanionCommandCache, fingerprintCommand } = require('./commandCache.cjs')
const { requiredCapability, validateEnvelope, validateIdentifier } = require('./protocol.cjs')

function receipt(commandId, status, message) {
  return { type: 'command.receipt', commandId, status, message }
}

class CompanionCommandRouter {
  constructor({ commandCache = new CompanionCommandCache(), enabledCapabilities = [], handlers = {} } = {}) {
    this.commandCache = commandCache
    this.enabledCapabilities = new Set(enabledCapabilities)
    this.handlers = { ...handlers }
  }

  async route({ frame, device }) {
    const clean = validateEnvelope(frame)
    if (clean.kind !== 'command') throw new Error('companion command frame is required')
    validateIdentifier(device?.deviceId, 'device.deviceId')
    const granted = new Set(Array.isArray(device.capabilities) ? device.capabilities : [])
    const required = requiredCapability(clean.body.type)
    const descriptor = {
      commandId: clean.body.commandId,
      fingerprint: fingerprintCommand(clean.body),
    }
    return this.commandCache.execute(descriptor, async () => {
      if (!required || !granted.has(required)) {
        return receipt(clean.body.commandId, 'rejected', `${required ?? 'requested'} capability is not granted to this device.`)
      }
      if (!this.enabledCapabilities.has(required)) {
        return receipt(clean.body.commandId, 'unavailable', `${required} is disabled in this companion build.`)
      }
      const handler = this.handlers[clean.body.type]
      if (typeof handler !== 'function') {
        return receipt(clean.body.commandId, 'unavailable', `${clean.body.type} is not available.`)
      }
      const result = await handler({ device, command: clean.body })
      if (!result || typeof result !== 'object') return receipt(clean.body.commandId, 'applied', 'Command applied.')
      return receipt(
        clean.body.commandId,
        result.status ?? (result.ok === false ? 'rejected' : 'applied'),
        String(result.message ?? (result.ok === false ? 'Command rejected.' : 'Command applied.')).slice(0, 800),
      )
    })
  }

  stats() {
    return {
      enabledCapabilities: [...this.enabledCapabilities].sort(),
      handlers: Object.keys(this.handlers).sort(),
      cache: this.commandCache.stats(),
    }
  }
}

module.exports = { CompanionCommandRouter, receipt }
