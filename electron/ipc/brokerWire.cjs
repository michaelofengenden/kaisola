// Single source of truth for the detached session-broker wire contract.
// Both endpoints (session-broker.cjs server, sessionBrokerClient.cjs client)
// and the spool require this module, so the framing caps and handshake
// constants can never drift between the two ends of the durability-critical
// socket. The Swift-native port should mirror exactly these values.
const fs = require('node:fs')
const path = require('node:path')

// Protocol 1 shipped without project-scoped terminal ownership. It must never
// be reused by a build which promises project isolation: the legacy broker has
// no trustworthy project label to migrate for already-running PTYs.
const PROTOCOL = 2
const SECURITY_EPOCH = 1
// These versions are deliberately independent from the desktop app version.
// The implementation version describes broker behavior within the protocol-2
// compatibility envelope. The package schema describes the signed helper
// layout used by the native preview. Neither value is permission to replace a
// live broker; clients must adopt a compatible live process and defer helper
// upgrades until its terminal inventory is empty.
const BROKER_IMPLEMENTATION_VERSION = 1
const BROKER_PACKAGE_SCHEMA = 1
const TERMINAL_OBSERVE_FEATURE = 'terminal-observe-v1'
const OBSERVER_ROLE_FEATURE = 'observer-role-v1'
const OBSERVER_ACCESS = 'observer'
const OBSERVER_METHODS = Object.freeze([
  'broker.status',
  'terminal.list',
  'terminal.diagnostics',
  'terminal.subscribe',
  'terminal.unsubscribe',
])

// A terminal snapshot may legally carry 8 MiB of retained output in one
// response frame. JSON escaping of control-dense bytes (ESC, NUL) expands up
// to 6x — e.g. an agent cat-ing a binary — so the envelope must hold
// 8 MiB * 6 plus framing slack. Undersizing this turns a valid snapshot into
// a socket teardown + reconnect loop on the durability-critical reattach path.
const MAX_FRAME = 56 * 1024 * 1024

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 })
  fs.renameSync(tmp, file)
  try { fs.chmodSync(file, 0o600) } catch { /* best effort */ }
}

function observerMethodAllowed(method) {
  return OBSERVER_METHODS.includes(String(method || ''))
}

function brokerMethodAllowedForAccess(access, method) {
  return access !== OBSERVER_ACCESS || observerMethodAllowed(method)
}

function brokerVersionsCompatible({ protocol, securityEpoch, implementationVersion }) {
  if (Number(protocol) !== PROTOCOL || Number(securityEpoch) !== SECURITY_EPOCH) return false
  // Protocol-2 brokers predating this additive field are implementation N.
  const implementation = implementationVersion == null ? BROKER_IMPLEMENTATION_VERSION : Number(implementationVersion)
  return Number.isInteger(implementation)
    && implementation >= BROKER_IMPLEMENTATION_VERSION
    && implementation <= BROKER_IMPLEMENTATION_VERSION + 1
}

module.exports = {
  PROTOCOL,
  SECURITY_EPOCH,
  BROKER_IMPLEMENTATION_VERSION,
  BROKER_PACKAGE_SCHEMA,
  TERMINAL_OBSERVE_FEATURE,
  OBSERVER_ROLE_FEATURE,
  OBSERVER_ACCESS,
  OBSERVER_METHODS,
  MAX_FRAME,
  atomicJson,
  observerMethodAllowed,
  brokerMethodAllowedForAccess,
  brokerVersionsCompatible,
}
