'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { StringDecoder } = require('node:string_decoder')

const {
  PROTOCOL,
  TERMINAL_EXIT_STATUS_FEATURE,
  CONTROLLER_ACCESS,
  OBSERVER_ACCESS,
  ADMINISTRATOR_ACCESS,
  OBSERVER_METHODS,
  ADMINISTRATOR_METHODS,
  MAX_FRAME,
  maximumEncodedFrameBytes,
  brokerMethodAllowedForAccess,
  eventPayloadForFeatures,
} = require('../../runtime/node-broker/ipc/brokerWire.cjs')

const repoRoot = path.resolve(__dirname, '..', '..')
const fixturePath = path.join(repoRoot, 'protocol', 'broker', 'protocol-2-golden-v1.json')

function loadCorpus() {
  return JSON.parse(fs.readFileSync(fixturePath, 'utf8'))
}

function currentDispatchMethods() {
  const source = fs.readFileSync(path.join(repoRoot, 'runtime', 'node-broker', 'session-broker.cjs'), 'utf8')
  const start = source.indexOf('async function dispatch(')
  const end = source.indexOf('\nfunction handleLine(', start)
  assert.notEqual(start, -1, 'dispatch implementation exists')
  assert.notEqual(end, -1, 'dispatch implementation has a bounded source section')
  return [...source.slice(start, end).matchAll(/^\s*case '([^']+)':/gmu)]
    .map((match) => match[1])
    .sort()
}

function sourceSignalWrite() {
  const source = fs.readFileSync(path.join(repoRoot, 'runtime', 'node-broker', 'session-broker.cjs'), 'utf8')
  const match = source.match(/case 'terminal\.signal': \{([\s\S]*?)\n\s*\}/u)
  assert.ok(match, 'terminal.signal dispatch block exists')
  return match[1].includes("return mgr.write(id, '\\x03')") ? '03' : null
}

function decodeUTF8(chunksHex) {
  const decoder = new StringDecoder('utf8')
  let text = ''
  for (const chunk of chunksHex) text += decoder.write(Buffer.from(chunk, 'hex'))
  text += decoder.end()
  return {
    text,
    replacementCount: [...text].filter((character) => character === '\uFFFD').length,
  }
}

function maximumForPurpose(purpose) {
  return purpose.type === 'transport'
    ? MAX_FRAME
    : maximumEncodedFrameBytes(purpose)
}

// These entries freeze initial normalization examples; they are not a
// complete black-box protocol suite.
function assertScenario(scenario) {
  switch (scenario.id) {
    case 'exit.legacy':
    case 'exit.structured': {
      assert.equal(scenario.kind, 'exit-payload', scenario.id)
      const actual = eventPayloadForFeatures(
        'terminal:exit:golden',
        scenario.input,
        new Set(scenario.negotiatedFeatures),
      )
      const expected = scenario.expected.signal == null
        ? scenario.expected.exitCode
        : { exitCode: scenario.expected.exitCode, signal: scenario.expected.signal }
      assert.deepEqual(actual, expected, scenario.id)
      return
    }
    case 'terminal-signal.etx':
      assert.equal(scenario.kind, 'terminal-signal-write', scenario.id)
      assert.equal(scenario.input.method, 'terminal.signal')
      assert.equal(sourceSignalWrite(), scenario.expected.writeHex)
      return
    case 'utf8.split-scalar':
    case 'utf8.invalid-sequence':
      assert.equal(scenario.kind, 'utf8-stream-normalization', scenario.id)
      assert.deepEqual(decodeUTF8(scenario.input.chunksHex), scenario.expected, scenario.id)
      return
    case 'observer.snapshot-before-live':
      assert.equal(scenario.kind, 'observer-ordering', scenario.id)
      assert.equal(scenario.input.snapshotEndOffset, scenario.input.liveStartOffset)
      assert.deepEqual(scenario.expected, { order: ['snapshot', 'live'], duplicateBytes: 0 })
      return
    default:
      assert.fail(`unsupported golden scenario: ${scenario.id}`)
  }
}

function assertCorpus(corpus) {
  assert.equal(corpus.schemaVersion, 1)
  assert.equal(corpus.protocolVersion, PROTOCOL)
  assert.deepEqual(corpus.identifierConstraints, {
    pattern: '^[a-z0-9]+(?:[.-][a-z0-9]+)*$',
    maximumUtf8Bytes: 80,
  })

  const identifierPattern = new RegExp(corpus.identifierConstraints.pattern, 'u')
  const identifiers = []
  const assertIdentifier = (identifier) => {
    assert.equal(identifierPattern.test(identifier), true, identifier)
    assert.ok(Buffer.byteLength(identifier, 'utf8') <= corpus.identifierConstraints.maximumUtf8Bytes, identifier)
    identifiers.push(identifier)
  }

  const methodNames = corpus.methods.map(({ method }) => method)
  assert.equal(new Set(methodNames).size, methodNames.length, 'methods appear exactly once')
  assert.deepEqual(methodNames, [...methodNames].sort(), 'methods have deterministic order')
  assert.deepEqual(methodNames, currentDispatchMethods(), 'corpus covers the current dispatch table')

  for (const entry of corpus.methods) {
    assert.ok([CONTROLLER_ACCESS, OBSERVER_ACCESS, ADMINISTRATOR_ACCESS].includes(entry.requiredAccess))
    assertIdentifier(entry.requestScenario)
    assertIdentifier(entry.responseScenario)
    assert.ok(entry.requestScenario.startsWith('request.'))
    assert.ok(entry.responseScenario.startsWith('response.'))

    if (entry.requiredAccess === OBSERVER_ACCESS) {
      assert.equal(OBSERVER_METHODS.includes(entry.method), true, entry.method)
      assert.equal(brokerMethodAllowedForAccess(OBSERVER_ACCESS, entry.method), true, entry.method)
    } else if (entry.requiredAccess === ADMINISTRATOR_ACCESS) {
      assert.equal(ADMINISTRATOR_METHODS.includes(entry.method), true, entry.method)
      assert.equal(brokerMethodAllowedForAccess(CONTROLLER_ACCESS, entry.method), false, entry.method)
      assert.equal(brokerMethodAllowedForAccess(OBSERVER_ACCESS, entry.method), false, entry.method)
      assert.equal(brokerMethodAllowedForAccess(ADMINISTRATOR_ACCESS, entry.method), true, entry.method)
    } else {
      assert.equal(OBSERVER_METHODS.includes(entry.method), false, entry.method)
      assert.equal(ADMINISTRATOR_METHODS.includes(entry.method), false, entry.method)
      assert.equal(brokerMethodAllowedForAccess(CONTROLLER_ACCESS, entry.method), true, entry.method)
      assert.equal(brokerMethodAllowedForAccess(OBSERVER_ACCESS, entry.method), false, entry.method)
    }
  }
  assert.equal(new Set(identifiers).size, identifiers.length, 'request/response scenario identifiers are unique')

  assert.deepEqual(
    corpus.methods.filter(({ requiredAccess }) => requiredAccess === OBSERVER_ACCESS).map(({ method }) => method).sort(),
    [...OBSERVER_METHODS].sort(),
  )
  assert.deepEqual(
    corpus.methods.filter(({ requiredAccess }) => requiredAccess === ADMINISTRATOR_ACCESS).map(({ method }) => method).sort(),
    [...ADMINISTRATOR_METHODS].sort(),
  )

  const scenarioIDs = corpus.semanticScenarios.map(({ id }) => id)
  assert.deepEqual(scenarioIDs, [
    'exit.legacy',
    'exit.structured',
    'observer.snapshot-before-live',
    'terminal-signal.etx',
    'utf8.invalid-sequence',
    'utf8.split-scalar',
  ])
  for (const scenario of corpus.semanticScenarios) {
    assertIdentifier(scenario.id)
    assertScenario(scenario)
  }

  for (const frameCase of corpus.frameCases) {
    assertIdentifier(frameCase.id)
    const maximum = maximumForPurpose(frameCase.purpose)
    assert.equal(frameCase.encodedBytes, frameCase.expected === 'accept' ? maximum : maximum + 1, frameCase.id)
    assert.equal(frameCase.encodedBytes <= maximum, frameCase.expected === 'accept', frameCase.id)
  }
  assert.equal(new Set(corpus.frameCases.map(({ id }) => id)).size, corpus.frameCases.length)
}

test('Node validates the initial protocol-2 contract inventory against shipping tables', () => {
  assertCorpus(loadCorpus())
})

test('Node inventory consumer rejects a mutated structured-exit expectation', () => {
  const drifted = structuredClone(loadCorpus())
  const scenario = drifted.semanticScenarios.find(({ id }) => id === 'exit.structured')
  assert.ok(scenario)
  scenario.expected.signal = 9

  assert.throws(() => assertCorpus(drifted), { code: 'ERR_ASSERTION' })
})
