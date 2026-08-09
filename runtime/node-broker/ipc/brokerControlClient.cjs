'use strict'

const crypto = require('node:crypto')
const net = require('node:net')
const { StringDecoder } = require('node:string_decoder')
const {
  MAX_FRAME,
  encodeBrokerFrame,
  inspectBrokerFrame,
  validateEncodedBrokerFrame,
} = require('./brokerWire.cjs')

const CONNECT_TIMEOUT_MS = 8_000

/**
 * Send one authenticated administrative request without adopting the broker
 * as a live app transport. Native performance gates use this for read-only
 * broker.status snapshots.
 */
function requestBrokerControl(info, {
  protocol,
  appVersion,
  method,
  timeoutMs = CONNECT_TIMEOUT_MS,
  createConnection = net.createConnection,
}) {
  return new Promise((resolve, reject) => {
    let settled = false
    let authenticated = false
    let buffer = ''
    const decoder = new StringDecoder('utf8')
    const requestId = `broker-control:${crypto.randomUUID()}`
    const socket = createConnection(info.socketPath)
    const timer = setTimeout(() => finish(new Error(`session broker ${method} timed out`)), timeoutMs)
    timer.unref?.()

    const finish = (error, value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try { socket.destroy() } catch {}
      if (error) reject(error)
      else resolve(value)
    }
    const send = (frame, frameMethod) => {
      try { socket.write(encodeBrokerFrame(frame, { method: frameMethod })) } catch (error) { finish(error) }
    }

    socket.setNoDelay?.(true)
    socket.once('connect', () => send({
      type: 'hello',
      protocol,
      token: info.token,
      instanceId: crypto.randomUUID(),
      appVersion,
      access: 'observer',
    }))
    socket.on('data', (chunk) => {
      buffer += decoder.write(chunk)
      if (Buffer.byteLength(buffer) > MAX_FRAME) {
        finish(new Error('session broker sent an oversized control frame'))
        return
      }
      let newline
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline)
        buffer = buffer.slice(newline + 1)
        if (!line) continue
        let frame
        try {
          const envelope = inspectBrokerFrame(line)
          validateEncodedBrokerFrame(line, {
            envelope,
            method: envelope.type === 'response' ? method : undefined,
          })
          frame = JSON.parse(line)
        } catch {
          finish(new Error('session broker sent malformed control data'))
          return
        }
        if (!authenticated) {
          if (frame?.type !== 'hello') continue
          if (!frame.ok || frame.protocol !== protocol || frame.access !== 'observer') {
            finish(new Error(frame?.message || 'session broker authentication failed'))
            return
          }
          authenticated = true
          send({
            type: 'request',
            id: requestId,
            method,
            params: { ownerId: '0' },
          }, method)
          continue
        }
        if (frame?.type !== 'response' || frame.id !== requestId) continue
        if (!frame.ok) finish(new Error(frame.message || `session broker ${method} failed`))
        else finish(null, frame.result)
        return
      }
    })
    socket.once('error', (error) => finish(error))
    socket.once('close', () => {
      decoder.end()
      if (!settled) finish(new Error(`session broker closed before ${method} completed`))
    })
  })
}

module.exports = { requestBrokerControl }
