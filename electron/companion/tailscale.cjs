'use strict'

const os = require('node:os')

// Tailscale assigns IPv4 addresses from the shared 100.64.0.0/10 range. On
// macOS its system extension exposes that address through a utun interface.
// Requiring both properties avoids mistaking ordinary carrier-grade NAT for a
// usable private route.
function isTailscaleIpv4(address) {
  const octets = String(address).split('.').map(Number)
  return octets.length === 4
    && octets.every((value) => Number.isInteger(value) && value >= 0 && value <= 255)
    && octets[0] === 100
    && octets[1] >= 64
    && octets[1] <= 127
}

function isTailscaleInterface(name) {
  return /^(?:utun\d+|tailscale\d*)$/i.test(String(name))
}

function tailscaleIpv4Address(networkInterfaces = os.networkInterfaces()) {
  const candidates = []
  for (const [name, entries] of Object.entries(networkInterfaces ?? {})) {
    if (!isTailscaleInterface(name)) continue
    for (const entry of entries ?? []) {
      if (entry?.family !== 'IPv4' || entry.internal || !isTailscaleIpv4(entry.address)) continue
      candidates.push(entry.address)
    }
  }
  candidates.sort((left, right) => left.localeCompare(right, 'en', { numeric: true }))
  return candidates[0] ?? null
}

module.exports = {
  isTailscaleInterface,
  isTailscaleIpv4,
  tailscaleIpv4Address,
}
