// Real LAN pairing harness for the native Kaisola Companion client.
// Run with: npm run companion:pair-harness [-- --print-qr-only]
'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { app, safeStorage } = require('electron')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-companion-pair-harness-'))
app.setPath('userData', userData)

const { BonjourCompanionTransport, serviceNames } = require('./companion/bonjourTransport.cjs')
const { CompanionDesktopState } = require('./companion/desktopState.cjs')
const { CompanionDeviceStore } = require('./companion/deviceStore.cjs')
const { CompanionGateway } = require('./companion/gateway.cjs')
const { CompanionPairingManager } = require('./companion/pairing.cjs')
const { CompanionProjectionStore } = require('./companion/projectionStore.cjs')
const { sanitizeProjection } = require('./companion/redaction.cjs')
const { CompanionStateHub } = require('./companion/stateHub.cjs')
const { makeBoundedSnapshot } = require('./companion/terminalCursor.cjs')
const fixtureProjection = require('./companion/fixtures/snapshot-board.json').body.projection

const PRINT_QR_ONLY = process.argv.includes('--print-qr-only')
const EPOCH = `desktop-epoch-harness-${crypto.randomUUID()}`
const PROJECT_ID = 'project-kaisola'
const TERMINAL_ID = 'terminal-pair-harness'
const TERMINAL_STREAM_EPOCH = `terminal-epoch-harness-${crypto.randomUUID()}`
const TERMINAL_SNAPSHOT_BYTES = 128 * 1024
const TERMINAL_INTERVAL_MS = 3_000

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function harnessEvent(type, fields = {}) {
  console.log(`HARNESS_EVENT=${JSON.stringify({ type, at: Date.now(), ...fields })}`)
}

function demoProjection() {
  const now = Date.now()
  return sanitizeProjection({
    ...fixtureProjection,
    revision: 1,
    generatedAt: now,
    freshness: 'live',
    projects: [
      {
        id: PROJECT_ID,
        name: 'Kaisola',
        repo: 'Kaisola',
        branch: 'main',
        connection: 'live',
        lastContactAt: now,
      },
      {
        id: 'project-companion-ios',
        name: 'Companion iOS',
        repo: 'KaisolaCompanion',
        branch: 'pairing-harness',
        connection: 'live',
        lastContactAt: now - 700,
      },
      {
        id: 'project-research-notes',
        name: 'Research Notes',
        repo: 'Research',
        branch: 'main',
        connection: 'live',
        lastContactAt: now - 2_000,
      },
    ],
    sessions: [
      {
        id: 'session-companion-agent',
        projectId: PROJECT_ID,
        kind: 'agent',
        title: 'Build the companion pairing harness',
        status: 'running',
        needsYou: false,
        unread: false,
        updatedAt: now - 400,
        provider: 'Codex',
        model: 'GPT-5',
        summary: 'Serving a real encrypted desktop session over Bonjour.',
        startedAt: now - 90_000,
        turns: [
          { kind: 'user', text: 'Pair the simulator against a real listener.', at: now - 80_000 },
          { kind: 'thought', text: 'Constructing the production gateway and Noise transport.', at: now - 70_000 },
          { kind: 'tool', text: 'Bonjour listener bound on the LAN interface.', status: 'completed', at: now - 15_000 },
          { kind: 'assistant', text: 'The demo snapshot is live; terminal output will continue streaming.', at: now - 1_000 },
        ],
      },
      {
        id: 'session-needs-you',
        projectId: 'project-companion-ios',
        kind: 'agent',
        title: 'Confirm the four-word phrase',
        status: 'waiting',
        needsYou: true,
        unread: true,
        updatedAt: now - 8_000,
        provider: 'Claude',
        summary: 'Compare the SAS on the phone with DESKTOP_SAS in this terminal.',
      },
      {
        id: 'session-demo-done',
        projectId: 'project-research-notes',
        kind: 'agent',
        title: 'Prepare demo projection',
        status: 'done',
        needsYou: false,
        unread: false,
        updatedAt: now - 32_000,
        provider: 'Codex',
        summary: 'Projects, board lanes, and transcript are ready.',
      },
      {
        id: TERMINAL_ID,
        projectId: PROJECT_ID,
        kind: 'terminal',
        title: 'Live pairing harness',
        status: 'running',
        needsYou: false,
        unread: false,
        updatedAt: now,
        summary: 'A demo line arrives about every three seconds while subscribed.',
      },
    ],
    attention: [
      {
        id: 'attention-confirm-sas',
        projectId: 'project-companion-ios',
        sessionId: 'session-needs-you',
        kind: 'question',
        title: 'Does the authentication phrase match?',
        detail: 'Confirm it on the phone after checking DESKTOP_SAS.',
        createdAt: now - 8_000,
        severity: 'info',
      },
    ],
    permissions: [],
  })
}

function memoryProjectionStore() {
  const records = new Map()
  return new CompanionProjectionStore({
    epoch: EPOCH,
    get: (key) => records.get(key) ?? null,
    set: (key, value) => records.set(key, value),
    del: (key) => records.delete(key),
    keys: () => [...records.keys()],
  })
}

function demoTerminal() {
  const listeners = new Set()
  let tick = 0
  const initialOutput = [
    '$ npm run companion:pair-harness',
    'Kaisola Companion demo terminal is ready.',
    'Waiting for live output...',
    '',
  ].join('\r\n')
  let snapshot = makeBoundedSnapshot({
    streamEpoch: TERMINAL_STREAM_EPOCH,
    output: initialOutput,
    endOffset: Buffer.byteLength(initialOutput, 'utf8'),
    maxBytes: TERMINAL_SNAPSHOT_BYTES,
    exited: false,
  })

  return {
    observe: async ({ id, projectId, onEvent }) => {
      if (id !== TERMINAL_ID || projectId !== PROJECT_ID || typeof onEvent !== 'function') {
        return { ok: false, unavailable: true, message: 'Demo terminal is unavailable.' }
      }
      listeners.add(onEvent)
      let subscribed = true
      return {
        ok: true,
        mode: 'snapshot',
        snapshot: clone(snapshot),
        unsubscribe: async () => {
          if (!subscribed) return false
          subscribed = false
          return listeners.delete(onEvent)
        },
      }
    },
    push() {
      tick++
      const data = `[${new Date().toISOString()}] demo stream ${tick}: encrypted companion session active\r\n`
      const startOffset = snapshot.endOffset
      const endOffset = startOffset + Buffer.byteLength(data, 'utf8')
      snapshot = makeBoundedSnapshot({
        streamEpoch: TERMINAL_STREAM_EPOCH,
        output: snapshot.output + data,
        endOffset,
        maxBytes: TERMINAL_SNAPSHOT_BYTES,
        truncated: snapshot.truncated,
        exited: false,
      })
      const event = {
        channel: 'terminal:observer-output',
        payload: {
          id: TERMINAL_ID,
          streamEpoch: TERMINAL_STREAM_EPOCH,
          startOffset,
          endOffset,
          data,
        },
      }
      for (const listener of listeners) {
        try { listener(event) } catch (error) {
          harnessEvent('terminal.listener_error', { message: String(error?.message || error).slice(0, 300) })
        }
      }
      return { tick, subscribers: listeners.size, startOffset, endOffset }
    },
  }
}

function listenForHarnessEvents({ deviceStore, transport }) {
  transport.on('enabled', (status) => harnessEvent('listener.enabled', status))
  transport.on('disabled', () => harnessEvent('listener.disabled'))
  transport.on('pairingFailed', (event) => harnessEvent('pairing.failed', event))
  transport.on('authenticated', (event) => harnessEvent('connection.authenticated', event))
  deviceStore.on('paired', ({ deviceId, displayName, capabilities }) => {
    harnessEvent('device.paired', { deviceId, displayName, capabilities })
  })
  deviceStore.on('connected', (event) => harnessEvent('device.connected', event))
  deviceStore.on('disconnected', (event) => harnessEvent('device.disconnected', event))
  transport.on('pairingPhrase', (event) => {
    const phrase = typeof event?.sas === 'string' ? event.sas : event?.sas?.phrase
    console.log(`DESKTOP_SAS=${phrase ?? 'unavailable'}`)
    const confirmed = transport.confirmPairing(event.pairingId)
    harnessEvent('pairing.desktop_auto_confirmed', { pairingId: event.pairingId, confirmed })
  })
}

async function main() {
  let gateway = null
  let transport = null
  let terminalTimer = null
  try {
    const projectionStore = memoryProjectionStore()
    const desktopState = new CompanionDesktopState({ epoch: EPOCH, projectionStore })
    const stateHub = new CompanionStateHub({ desktopState })
    const deviceStore = new CompanionDeviceStore({
      filePath: path.join(app.getPath('userData'), 'companion', 'devices.json'),
      safeStorage,
    })
    const terminal = demoTerminal()
    gateway = new CompanionGateway({
      desktopId: deviceStore.desktopIdentity().id,
      epoch: EPOCH,
      stateHub,
      terminalObserver: terminal.observe,
      enabledCapabilities: ['observe'],
    })
    const pairingManager = new CompanionPairingManager({ deviceStore })
    transport = new BonjourCompanionTransport({
      gateway,
      pairingManager,
      deviceStore,
      host: '0.0.0.0',
      port: 0,
      logger: {
        warn: (message) => harnessEvent('listener.warning', { message: String(message).slice(0, 300) }),
      },
    })
    listenForHarnessEvents({ deviceStore, transport })

    const published = projectionStore.publish({
      windowId: 'pair-harness-demo',
      publisherGeneration: 1,
      projection: demoProjection(),
    })
    gateway.projectionPublished('pair-harness-demo', published)

    const status = await transport.enable()
    const qrPayload = pairingManager.createOffer({
      requestedCapabilities: ['observe'],
      transportHint: transport.pairingTransportHint(),
    })
    const names = serviceNames(deviceStore.desktopIdentity().id)

    console.log('PAIR_HARNESS_OUTPUT_BEGIN')
    console.log(`QR_PAYLOAD=${JSON.stringify(qrPayload)}`)
    console.log(`LISTENING_HOST_PORT=${status.host}:${status.port}`)
    console.log(`BONJOUR_INSTANCE=${names.instance}`)
    console.log('PAIR_HARNESS_OUTPUT_END')

    if (PRINT_QR_ONLY) return

    terminalTimer = setInterval(() => {
      const pushed = terminal.push()
      harnessEvent('terminal.tick', pushed)
    }, TERMINAL_INTERVAL_MS)

    const signal = await new Promise((resolve) => {
      process.once('SIGINT', () => resolve('SIGINT'))
      process.once('SIGTERM', () => resolve('SIGTERM'))
    })
    harnessEvent('shutdown.requested', { signal })
  } finally {
    if (terminalTimer) clearInterval(terminalTimer)
    try { await transport?.disable() } catch (error) {
      harnessEvent('shutdown.transport_error', { message: String(error?.message || error).slice(0, 300) })
    }
    try { await gateway?.dispose() } catch (error) {
      harnessEvent('shutdown.gateway_error', { message: String(error?.message || error).slice(0, 300) })
    }
    try { fs.rmSync(userData, { recursive: true, force: true }) } catch (error) {
      harnessEvent('shutdown.user_data_error', { message: String(error?.message || error).slice(0, 300) })
    }
  }
}

// app.exit() can discard piped output unless both streams have drained first.
function exitFlushed(code) {
  process.stderr.write('', () => {
    process.stdout.write('', () => app.exit(code))
  })
}

app.whenReady().then(main).then(
  () => exitFlushed(0),
  (error) => {
    console.error(`HARNESS_FATAL=${error?.stack || error}`)
    exitFlushed(1)
  },
)
