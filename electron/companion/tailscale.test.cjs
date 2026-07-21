'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  isTailscaleInterface,
  isTailscaleIpv4,
  tailscaleIpv4Address,
} = require('./tailscale.cjs')

test('Tailscale detection requires its macOS tunnel interface and 100.64/10 address', () => {
  assert.equal(isTailscaleInterface('utun7'), true)
  assert.equal(isTailscaleInterface('en0'), false)
  assert.equal(isTailscaleIpv4('100.64.0.1'), true)
  assert.equal(isTailscaleIpv4('100.127.255.254'), true)
  assert.equal(isTailscaleIpv4('100.128.0.1'), false)
  assert.equal(isTailscaleIpv4('192.168.1.10'), false)

  assert.equal(tailscaleIpv4Address({
    en0: [{ family: 'IPv4', internal: false, address: '192.168.1.23' }],
    utun4: [{ family: 'IPv4', internal: false, address: '100.90.1.14' }],
  }), '100.90.1.14')
  assert.equal(tailscaleIpv4Address({
    en0: [{ family: 'IPv4', internal: false, address: '100.90.1.14' }],
    utun4: [{ family: 'IPv4', internal: false, address: '10.0.0.4' }],
  }), null)
})
