// Single source of truth for the detached session-broker wire contract.
// Both endpoints (the detached broker and authenticated native control clients)
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
const BROKER_IMPLEMENTATION_VERSION = 2
const BROKER_PACKAGE_SCHEMA = 1
const TERMINAL_OBSERVE_FEATURE = 'terminal-observe-v1'
const TERMINAL_HISTORY_FEATURE = 'terminal-history-v1'
const TERMINAL_HISTORY_CONTINUOUS_FEATURE = 'terminal-history-continuous-v1'
const OBSERVER_ROLE_FEATURE = 'observer-role-v1'
const BROKER_UPDATE_FEATURE = 'broker-update-v1'
const BROKER_ROLLING_UPDATE_FEATURE = 'broker-rolling-update-v1'
const BROKER_MUTATION_IDEMPOTENCY_FEATURE = 'broker-mutation-idempotency-v1'
const BROKER_INVENTORY_FEATURE = 'broker-inventory-v1'
const BROKER_ADMINISTRATION_FEATURE = 'broker-administration-v1'
const DEFAULT_MAX_LIVE_TERMINALS = 64
const MAX_CONFIGURABLE_LIVE_TERMINALS = 512
// terminal:exit:<id> shipped as a bare exit code, so a signal-killed session
// arrived as an ordinary numeric exit and the cause was lost. Clients that
// declare this feature receive the same { exitCode, signal } record the
// observer channel already carries.
const TERMINAL_EXIT_STATUS_FEATURE = 'terminal-exit-status-v1'
// A controller that reads terminal output through its observer connection has
// no use for terminal:data:<id>, and the broker was serialising, size-scanning
// and writing that second copy for a client which discards it. Declaring this
// feature says "I read output through observers"; the broker then stops
// producing the primary copy for terminals that client owns.
//
// It has to be negotiated rather than assumed. A client that never declares it
// still needs terminal:data:<id>, and silently suppressing the channel would
// give an older app a permanently blank terminal. Ownership and detach
// accounting are untouched either way: this decides what is sent, not who owns
// the terminal or whether a renderer is attached.
const TERMINAL_OBSERVER_ONLY_OUTPUT_FEATURE = 'terminal-observer-only-output-v1'
// terminal.attach answers { id, ok } rather than a bare snapshot, so a caller
// can tell "I adopted this terminal" from "the broker replied". Declaring it
// tells the client the acknowledgement is available to check; a broker without
// it cannot answer the question, and a client must not read that silence as a
// refusal — doing so is what left every terminal read-only when v0.1.114 met a
// retained v0.1.113 broker.
const TERMINAL_ATTACH_ACK_FEATURE = 'terminal-attach-ack-v1'
// Observer output is batched on a frame window here rather than broadcast per
// pty chunk. A client that knows this stops running a second window of its own:
// two stacked windows cost up to two frames of latency to merge what one
// already merged. A client talking to a broker without this must keep its own,
// or it gets raw per-chunk output straight onto its main thread.
const TERMINAL_OBSERVER_COALESCING_FEATURE = 'terminal-observer-coalescing-v1'
const FEATURES = Object.freeze([
  TERMINAL_OBSERVE_FEATURE,
  TERMINAL_HISTORY_FEATURE,
  TERMINAL_HISTORY_CONTINUOUS_FEATURE,
  OBSERVER_ROLE_FEATURE,
  BROKER_UPDATE_FEATURE,
  BROKER_ROLLING_UPDATE_FEATURE,
  BROKER_MUTATION_IDEMPOTENCY_FEATURE,
  BROKER_INVENTORY_FEATURE,
  BROKER_ADMINISTRATION_FEATURE,
  TERMINAL_EXIT_STATUS_FEATURE,
  TERMINAL_OBSERVER_ONLY_OUTPUT_FEATURE,
  TERMINAL_ATTACH_ACK_FEATURE,
  TERMINAL_OBSERVER_COALESCING_FEATURE,
])
const TERMINAL_EXIT_CHANNEL_PREFIX = 'terminal:exit:'
const CONTROLLER_ACCESS = 'controller'
const OBSERVER_ACCESS = 'observer'
const ADMINISTRATOR_ACCESS = 'administrator'
const OBSERVER_METHODS = Object.freeze([
  'broker.status',
  'broker.inventory',
  'terminal.list',
  'terminal.diagnostics',
  'terminal.history',
  'terminal.subscribe',
  'terminal.unsubscribe',
])
const ADMINISTRATOR_METHODS = Object.freeze([
  'broker.shutdown',
  'broker.shutdownForUpdate',
  'broker.prepareRollingUpdate',
  'broker.cancelRollingUpdate',
  'broker.retireDraining',
])

// A terminal snapshot may legally carry 8 MiB of retained output in one
// response frame. JSON escaping of control-dense bytes (ESC, NUL) expands up
// to 6x — e.g. an agent cat-ing a binary — so the envelope must hold
// 8 MiB * 6 plus framing slack. Undersizing this turns a valid snapshot into
// a socket teardown + reconnect loop on the durability-critical reattach path.
const MAX_FRAME = 56 * 1024 * 1024
const TERMINAL_HISTORY_PAGE_BYTES = 4 * 1024 * 1024
const TERMINAL_WRITE_PAYLOAD_BYTES = 64 * 1024
const BROKER_INVENTORY_RESPONSE_BYTES = 12 * 1024 * 1024
const HELLO_FRAME_BYTES = 64 * 1024
const DEFAULT_REQUEST_FRAME_BYTES = 64 * 1024
const DEFAULT_RESPONSE_FRAME_BYTES = 256 * 1024
const DEFAULT_EVENT_FRAME_BYTES = 64 * 1024

function requestFrameBytes(method) {
  switch (method) {
    case 'terminal.write': return 1 * 1024 * 1024
    case 'terminal.create': return 256 * 1024
    default: return DEFAULT_REQUEST_FRAME_BYTES
  }
}

function responseFrameBytes(method) {
  switch (method) {
    case 'terminal.create':
    case 'terminal.attach':
    case 'terminal.snapshot':
    case 'terminal.output':
      return 50 * 1024 * 1024
    case 'terminal.history':
    case 'terminal.subscribe':
      return 26 * 1024 * 1024
    case 'broker.status':
    case 'terminal.list':
    case 'terminal.diagnostics':
      return 4 * 1024 * 1024
    case 'broker.inventory':
      return BROKER_INVENTORY_RESPONSE_BYTES
    default:
      return DEFAULT_RESPONSE_FRAME_BYTES
  }
}

function eventFrameBytes(channel) {
  return channel === 'terminal:observer-output' ? 512 * 1024 : DEFAULT_EVENT_FRAME_BYTES
}

function maximumEncodedFrameBytes({ type, method, channel } = {}) {
  switch (type) {
    case 'hello': return HELLO_FRAME_BYTES
    case 'request': return requestFrameBytes(method)
    case 'response': return responseFrameBytes(method)
    case 'event': return eventFrameBytes(channel)
    default: return DEFAULT_REQUEST_FRAME_BYTES
  }
}

// Scan only the top-level routing strings. Large params/results/payload values
// are skipped without JSON.parse, so their method cap is enforced before a
// synchronous object graph allocation. Full JSON validation remains at the
// existing dispatch boundary after this preflight succeeds.
function inspectBrokerFrame(value) {
  const input = String(value ?? '')
  let cursor = 0
  const envelope = { type: null, id: null, method: null, channel: null }

  const whitespace = () => {
    while (cursor < input.length && /[\x20\t\r\n]/.test(input[cursor])) cursor++
  }
  const scanString = () => {
    if (input[cursor] !== '"') throw new Error('invalid broker envelope')
    const start = cursor++
    let escaped = false
    while (cursor < input.length) {
      const character = input[cursor++]
      if (escaped) escaped = false
      else if (character === '\\') escaped = true
      else if (character === '"') return input.slice(start, cursor)
    }
    throw new Error('invalid broker envelope')
  }
  const decodedString = (token, maximumCharacters) => {
    if (token.length > maximumCharacters) return null
    const result = JSON.parse(token)
    if (typeof result !== 'string') throw new Error('invalid broker envelope')
    return result
  }
  const skipValue = () => {
    if (input[cursor] === '"') {
      scanString()
      return
    }
    if (input[cursor] === '{' || input[cursor] === '[') {
      let depth = 0
      while (cursor < input.length) {
        const character = input[cursor]
        if (character === '"') {
          scanString()
          continue
        }
        cursor++
        if (character === '{' || character === '[') depth++
        else if (character === '}' || character === ']') {
          depth--
          if (depth === 0) return
        }
      }
      throw new Error('invalid broker envelope')
    }
    const start = cursor
    while (cursor < input.length && input[cursor] !== ',' && input[cursor] !== '}') cursor++
    if (cursor === start) throw new Error('invalid broker envelope')
  }

  whitespace()
  if (input[cursor++] !== '{') throw new Error('invalid broker envelope')
  let first = true
  while (true) {
    whitespace()
    if (input[cursor] === '}') {
      cursor++
      break
    }
    if (first) first = false
    else {
      if (input[cursor++] !== ',') throw new Error('invalid broker envelope')
      whitespace()
    }
    const key = decodedString(scanString(), 96)
    whitespace()
    if (input[cursor++] !== ':') throw new Error('invalid broker envelope')
    whitespace()
    if ((key === 'type' || key === 'id' || key === 'method' || key === 'channel') && input[cursor] === '"') {
      envelope[key] = decodedString(scanString(), 512)
    } else {
      skipValue()
    }
  }
  whitespace()
  if (cursor !== input.length) throw new Error('invalid broker envelope')
  return envelope
}

function validateEncodedBrokerFrame(encoded, { method, envelope: suppliedEnvelope } = {}) {
  const envelope = suppliedEnvelope || inspectBrokerFrame(encoded)
  const maximumBytes = maximumEncodedFrameBytes({
    type: envelope.type,
    method: envelope.type === 'response' ? method : envelope.method,
    channel: envelope.channel,
  })
  const encodedBytes = Buffer.byteLength(encoded, 'utf8')
  if (encodedBytes > maximumBytes) {
    const error = new RangeError(`broker ${envelope.type || 'unknown'} frame exceeds ${maximumBytes} bytes`)
    error.code = 'BROKER_FRAME_TOO_LARGE'
    error.maximumBytes = maximumBytes
    error.encodedBytes = encodedBytes
    throw error
  }
  return { envelope, maximumBytes, encodedBytes }
}

function encodeBrokerFrame(frame, context = {}) {
  const encoded = JSON.stringify(frame)
  validateEncodedBrokerFrame(encoded, context)
  return `${encoded}\n`
}

// The scratch path is as guessable as the destination, so a symlink planted at
// either would take the write to another file. O_NOFOLLOW fails the open on a
// linked scratch path instead, and the rename replaces a linked destination
// rather than writing through it — the chmod that follows lands on the regular
// file this call just created.
const ATOMIC_JSON_FLAGS = fs.constants.O_WRONLY
  | fs.constants.O_CREAT
  | fs.constants.O_TRUNC
  | fs.constants.O_NOFOLLOW

// Queue one newline-delimited frame on a client socket. `maxQueueBytes` drops
// deltas a slow consumer has not drained; `force` bypasses that cap for the
// recovery marker a paused subscriber must still receive.
//
// A forced frame reports delivery from whether the socket ACCEPTED it, not
// from write()'s return value: Node returns false once the buffer passes the
// high water mark, and a saturated buffer is exactly the state a recovery
// marker is sent in. Reading that flow-control hint as loss would retire every
// slow consumer whose marker is merely still queued. Only a socket that can no
// longer carry bytes — destroyed, already ended, or throwing — loses one.
function writeFrame(socket, frame, { maxQueueBytes, force = false, method } = {}) {
  if (!socket || socket.destroyed || socket.writableEnded) return false
  try {
    const encoded = encodeBrokerFrame(frame, { method })
    const frameBytes = Buffer.byteLength(encoded, 'utf8')
    if (!force && Number.isFinite(maxQueueBytes) && socket.writableLength + frameBytes > maxQueueBytes) return false
    const flushed = socket.write(encoded)
    return force ? true : flushed
  } catch {
    return false // reconnect replays snapshots
  }
}

function atomicJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 })
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600, flag: ATOMIC_JSON_FLAGS })
  fs.renameSync(tmp, file)
  try { fs.chmodSync(file, 0o600) } catch { /* best effort */ }
}

function observerMethodAllowed(method) {
  return OBSERVER_METHODS.includes(String(method || ''))
}

function administratorMethod(method) {
  return ADMINISTRATOR_METHODS.includes(String(method || ''))
}

function brokerAccessSupported(access) {
  return access === CONTROLLER_ACCESS
    || access === OBSERVER_ACCESS
    || access === ADMINISTRATOR_ACCESS
}

function brokerMethodAllowedForAccess(access, method) {
  if (access === OBSERVER_ACCESS) return observerMethodAllowed(method)
  if (access === CONTROLLER_ACCESS) return !administratorMethod(method)
  return access === ADMINISTRATOR_ACCESS
}

function brokerAccessGrantsAdministration(access) {
  return access === ADMINISTRATOR_ACCESS
}

function brokerAccessGrantsGlobalObservation(access) {
  return access === OBSERVER_ACCESS || access === ADMINISTRATOR_ACCESS
}

function normalizeBrokerOwnerID(value) {
  const id = String(value ?? '0').replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 80)
  return id || '0'
}

function brokerOwnerIDAllowedForAccess(access, value) {
  return access !== CONTROLLER_ACCESS
    || (value != null && normalizeBrokerOwnerID(value) !== '0')
}

/** A client names optional wire capabilities in its `hello` frame. Only
 * capabilities this broker actually implements survive; the authentication
 * boundary applies access-specific grants after this intersection. A client
 * that names nothing keeps every legacy event shape. */
function negotiateFeatures(requested) {
  const negotiated = new Set()
  if (!Array.isArray(requested)) return negotiated
  for (const value of requested) {
    const name = String(value ?? '')
    if (FEATURES.includes(name)) negotiated.add(name)
  }
  return negotiated
}

/** Downgrade one outbound event to what this client negotiated. The manager
 * always emits the structured exit status; a client predating
 * terminal-exit-status-v1 still receives the bare code it parses. */
function eventPayloadForFeatures(channel, payload, features) {
  if (!String(channel ?? '').startsWith(TERMINAL_EXIT_CHANNEL_PREFIX)) return payload
  if (features?.has(TERMINAL_EXIT_STATUS_FEATURE)) return payload
  if (payload && typeof payload === 'object') return payload.exitCode ?? 0
  return payload
}

function brokerVersionsCompatible({ protocol, securityEpoch, implementationVersion }) {
  if (Number(protocol) !== PROTOCOL || Number(securityEpoch) !== SECURITY_EPOCH) return false
  // Protocol-2 brokers predating this additive field are implementation N.
  const implementation = implementationVersion == null ? 1 : Number(implementationVersion)
  return Number.isInteger(implementation)
    && implementation >= 1
    && implementation <= BROKER_IMPLEMENTATION_VERSION
}

module.exports = {
  PROTOCOL,
  SECURITY_EPOCH,
  BROKER_IMPLEMENTATION_VERSION,
  BROKER_PACKAGE_SCHEMA,
  TERMINAL_OBSERVE_FEATURE,
  TERMINAL_HISTORY_FEATURE,
  TERMINAL_HISTORY_CONTINUOUS_FEATURE,
  OBSERVER_ROLE_FEATURE,
  BROKER_UPDATE_FEATURE,
  BROKER_ROLLING_UPDATE_FEATURE,
  BROKER_MUTATION_IDEMPOTENCY_FEATURE,
  BROKER_INVENTORY_FEATURE,
  BROKER_ADMINISTRATION_FEATURE,
  DEFAULT_MAX_LIVE_TERMINALS,
  MAX_CONFIGURABLE_LIVE_TERMINALS,
  TERMINAL_EXIT_STATUS_FEATURE,
  TERMINAL_OBSERVER_ONLY_OUTPUT_FEATURE,
  TERMINAL_ATTACH_ACK_FEATURE,
  TERMINAL_OBSERVER_COALESCING_FEATURE,
  TERMINAL_EXIT_CHANNEL_PREFIX,
  FEATURES,
  CONTROLLER_ACCESS,
  OBSERVER_ACCESS,
  ADMINISTRATOR_ACCESS,
  OBSERVER_METHODS,
  ADMINISTRATOR_METHODS,
  MAX_FRAME,
  TERMINAL_HISTORY_PAGE_BYTES,
  TERMINAL_WRITE_PAYLOAD_BYTES,
  BROKER_INVENTORY_RESPONSE_BYTES,
  HELLO_FRAME_BYTES,
  DEFAULT_REQUEST_FRAME_BYTES,
  DEFAULT_RESPONSE_FRAME_BYTES,
  DEFAULT_EVENT_FRAME_BYTES,
  maximumEncodedFrameBytes,
  inspectBrokerFrame,
  validateEncodedBrokerFrame,
  encodeBrokerFrame,
  atomicJson,
  observerMethodAllowed,
  administratorMethod,
  brokerAccessSupported,
  brokerMethodAllowedForAccess,
  brokerAccessGrantsAdministration,
  brokerAccessGrantsGlobalObservation,
  normalizeBrokerOwnerID,
  brokerOwnerIDAllowedForAccess,
  brokerVersionsCompatible,
  negotiateFeatures,
  eventPayloadForFeatures,
  writeFrame,
}
