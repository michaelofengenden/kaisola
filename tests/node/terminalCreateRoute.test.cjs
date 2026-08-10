'use strict'

const { after, test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const realManager = require('../../runtime/node-broker/ipc/terminalManager.cjs')
const { TerminalSpool } = require('../../runtime/node-broker/ipc/terminalSpool.cjs')
const {
  TERMINAL_CREATE_LIMITS,
  TERMINAL_GEOMETRY_LIMITS,
} = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')

const {
  argumentCount: MAX_ARGUMENT_COUNT,
  argumentBytes: MAX_ARGUMENT_BYTES,
  argumentsBytes: MAX_ARGUMENTS_BYTES,
  environmentEntries: MAX_ENVIRONMENT_ENTRIES,
  environmentKeyBytes: MAX_ENVIRONMENT_KEY_BYTES,
  environmentValueBytes: MAX_ENVIRONMENT_VALUE_BYTES,
  environmentBytes: MAX_ENVIRONMENT_BYTES,
} = TERMINAL_CREATE_LIMITS

const {
  maxCols: MAX_TERMINAL_COLS,
  maxRows: MAX_TERMINAL_ROWS,
} = TERMINAL_GEOMETRY_LIMITS

const managerSpoolDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-terminal-create-route-'))
realManager.configureStorage(managerSpoolDir, { asyncWrites: false })
realManager.setEventSink(() => true)
after(() => {
  realManager.killAll()
  realManager.setEventSink(null)
  fs.rmSync(managerSpoolDir, { recursive: true, force: true })
})

function fakeManager({ live = false, recovered = null } = {}) {
  const calls = []
  return {
    calls,
    available: () => true,
    has: () => !live,
    isLive: () => live,
    spawn: (options) => {
      calls.push(options)
      return { pty: { pid: 4242 }, recovered }
    },
    setSender: () => null,
    snapshot: () => ({
      output: 'new-session-output',
      streamEpoch: 'new-stream-epoch',
      startOffset: 0,
      endOffset: 18,
      truncated: false,
      exited: false,
      exitStatus: null,
    }),
  }
}

test('terminal create route awaits asynchronous replacement and snapshot work', async () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager({
    recovered: { text: 'retained-before-restart', truncated: true },
  })
  const spawn = manager.spawn
  const snapshot = manager.snapshot
  manager.spawn = async (options) => spawn(options)
  manager.snapshot = async (...args) => {
    manager.snapshotArgs = args
    return snapshot()
  }
  const authorized = []

  const response = await terminalCreateRoute({
    manager,
    params: {
      id: 'caller-supplied-terminal-id',
      command: '/bin/zsh',
      args: ['-l'],
      cwd: '/tmp/restored-cwd',
      restore: true,
      cols: 132,
      rows: 44,
    },
    owner: 'instance|owner|project',
    clientInstanceId: 'new-instance',
    requireAllowed: (id, adopt) => authorized.push([id, adopt]),
    brokerPid: 5151,
    now: () => 1234,
  })

  assert.deepEqual(authorized, [['caller-supplied-terminal-id', true]])
  assert.equal(manager.calls.length, 1)
  assert.equal(manager.calls[0].id, 'caller-supplied-terminal-id')
  assert.equal(manager.calls[0].restore, true)
  assert.deepEqual(manager.snapshotArgs, [
    'caller-supplied-terminal-id',
    { responseBarrier: true },
  ])
  assert.equal(response.recovered, null)
  assert.equal(response.output, 'new-session-output')
})

test('terminal create route always returns recovered null for a plain spawn', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager({
    recovered: { text: 'must-not-leak', truncated: false },
  })

  const response = terminalCreateRoute({
    manager,
    params: { id: 'fresh-terminal', cwd: '/tmp/fresh' },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })

  assert.equal(manager.calls[0].restore, false)
  assert.equal(response.recovered, null)
})

test('terminal create route returns only a typed bounded capacity rejection', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => false
  manager.spawn = () => {
    const error = new Error('sensitive process inventory must not cross the wire')
    error.code = 'TERMINAL_CAPACITY_EXCEEDED'
    error.liveTerminalCount = 64
    error.maximumLiveTerminals = 64
    error.rawTerminalIDs = ['secret-terminal']
    throw error
  }

  assert.deepEqual(terminalCreateRoute({
    manager,
    params: { id: 'capacity-rejected-terminal' },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  }), {
    ok: false,
    code: 'terminal_capacity_exceeded',
    message: 'broker terminal capacity reached',
    maximumLiveTerminals: 64,
  })
})

test('terminal create route preserves the typed capacity rejection after an async spool close', async () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => false
  manager.spawn = async () => {
    const error = new Error('sensitive process inventory must not cross the wire')
    error.code = 'TERMINAL_CAPACITY_EXCEEDED'
    error.liveTerminalCount = 64
    error.maximumLiveTerminals = 64
    error.rawTerminalIDs = ['secret-terminal']
    throw error
  }

  assert.deepEqual(await terminalCreateRoute({
    manager,
    params: { id: 'async-capacity-rejected-terminal' },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  }), {
    ok: false,
    code: 'terminal_capacity_exceeded',
    message: 'broker terminal capacity reached',
    maximumLiveTerminals: 64,
  })
})

test('terminal create route preserves safe multibyte arguments and environment', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  const args = ['--title', 'Café 🧪', '日本語']
  const env = { LANG: '日本語.UTF-8', EMPTY: '' }

  const response = terminalCreateRoute({
    manager,
    params: { id: 'safe-multibyte-payload', args, env },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })

  assert.equal(response.ok, true)
  assert.deepEqual(manager.calls[0].args, args)
  assert.deepEqual(manager.calls[0].env, env)
})

test('terminal create route defaults only omitted geometry before spawn', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => false

  const response = terminalCreateRoute({
    manager,
    params: { id: 'default-terminal-geometry' },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => assert.fail('a new terminal must not require adoption'),
  })

  assert.equal(response.ok, true)
  assert.equal(manager.calls.length, 1)
  assert.equal(manager.calls[0].cols, 80)
  assert.equal(manager.calls[0].rows, 24)
})

test('terminal create route rejects malformed geometry before ownership lookup or spawn', async (t) => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const fixtures = [
    { name: 'numeric-string columns', params: { cols: '120', rows: 40 }, field: 'cols' },
    { name: 'fractional columns', params: { cols: 80.5, rows: 24 }, field: 'cols' },
    { name: 'fractional rows', params: { cols: 80, rows: 24.5 }, field: 'rows' },
    { name: 'zero columns', params: { cols: 0, rows: 24 }, field: 'cols' },
    { name: 'negative rows', params: { cols: 80, rows: -1 }, field: 'rows' },
    { name: 'infinite columns', params: { cols: Number.POSITIVE_INFINITY, rows: 24 }, field: 'cols' },
    { name: 'NaN rows', params: { cols: 80, rows: Number.NaN }, field: 'rows' },
    { name: 'null columns', params: { cols: null, rows: 24 }, field: 'cols' },
  ]

  for (const fixture of fixtures) {
    await t.test(fixture.name, () => {
      const manager = fakeManager()
      manager.has = () => assert.fail('invalid geometry must fail before ownership lookup')
      manager.isLive = () => assert.fail('invalid geometry must fail before liveness lookup')
      const response = terminalCreateRoute({
        manager,
        params: { id: `invalid-geometry-${fixture.name}`, ...fixture.params },
        owner: 'instance|owner|project',
        clientInstanceId: 'instance',
        requireAllowed: () => assert.fail('invalid geometry must not authorize'),
      })

      assert.deepEqual(response, {
        ok: false,
        code: 'terminal_geometry_invalid',
        message: `terminal ${fixture.field} must be a finite positive integer`,
        field: fixture.field,
        expected: 'finite positive integer',
      })
      assert.equal(manager.calls.length, 0)
    })
  }
})

test('terminal create route clamps extreme integers and preserves documented boundaries', async (t) => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const fixtures = [
    {
      name: 'minimum boundary',
      params: { cols: 1, rows: 1 },
      expected: { cols: 1, rows: 1 },
    },
    {
      name: 'maximum boundary',
      params: { cols: MAX_TERMINAL_COLS, rows: MAX_TERMINAL_ROWS },
      expected: { cols: MAX_TERMINAL_COLS, rows: MAX_TERMINAL_ROWS },
    },
    {
      name: 'extreme positive integers',
      params: { cols: Number.MAX_SAFE_INTEGER, rows: Number.MAX_SAFE_INTEGER },
      expected: { cols: MAX_TERMINAL_COLS, rows: MAX_TERMINAL_ROWS },
    },
    {
      name: 'one above each maximum',
      params: { cols: MAX_TERMINAL_COLS + 1, rows: MAX_TERMINAL_ROWS + 1 },
      expected: { cols: MAX_TERMINAL_COLS, rows: MAX_TERMINAL_ROWS },
    },
    {
      name: 'one omitted dimension',
      params: { cols: 132 },
      expected: { cols: 132, rows: 24 },
    },
  ]

  for (const fixture of fixtures) {
    await t.test(fixture.name, () => {
      const manager = fakeManager()
      manager.has = () => false
      const response = terminalCreateRoute({
        manager,
        params: { id: `bounded-geometry-${fixture.name}`, ...fixture.params },
        owner: 'instance|owner|project',
        clientInstanceId: 'instance',
        requireAllowed: () => assert.fail('a new terminal must not require adoption'),
      })

      assert.equal(response.ok, true)
      assert.equal(manager.calls.length, 1)
      assert.equal(manager.calls[0].cols, fixture.expected.cols)
      assert.equal(manager.calls[0].rows, fixture.expected.rows)
    })
  }
})

test('terminal create route rejects invalid argument shapes before spawn', async (t) => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const fixtures = [
    {
      name: 'arguments must be an array',
      args: '--flag',
      expected: {
        ok: false,
        code: 'terminal_create_payload_type',
        message: 'terminal arguments must be an array',
        scope: 'arguments',
        expected: 'array',
      },
    },
    {
      name: 'each argument must be a string',
      args: ['--flag', 42],
      expected: {
        ok: false,
        code: 'terminal_create_payload_type',
        message: 'terminal argument 1 must be a string',
        scope: 'arguments',
        expected: 'string',
        index: 1,
      },
    },
  ]

  for (const fixture of fixtures) {
    await t.test(fixture.name, () => {
      const manager = fakeManager()
      manager.has = () => false
      const response = terminalCreateRoute({
        manager,
        params: { id: `invalid-${fixture.name}`, args: fixture.args },
        owner: 'instance|owner|project',
        clientInstanceId: 'instance',
        requireAllowed: () => assert.fail('invalid payload must not authorize'),
      })

      assert.deepEqual(response, fixture.expected)
      assert.equal(manager.calls.length, 0)
    })
  }
})

test('terminal create route rejects argument count above the documented maximum', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => false
  const args = Array.from({ length: MAX_ARGUMENT_COUNT + 1 }, (_, index) => `arg-${index}`)

  const response = terminalCreateRoute({
    manager,
    params: { id: 'too-many-arguments', args },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => assert.fail('oversized payload must not authorize'),
  })

  assert.deepEqual(response, {
    ok: false,
    code: 'terminal_create_payload_limit',
    message: 'terminal arguments exceed 200 entries',
    scope: 'arguments',
    limit: 'entryCount',
    maxCount: MAX_ARGUMENT_COUNT,
    actualCount: MAX_ARGUMENT_COUNT + 1,
  })
  assert.equal(manager.calls.length, 0)
})

test('terminal create route measures each argument in UTF-8 bytes', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const boundaryManager = fakeManager()
  const boundary = 'é'.repeat(MAX_ARGUMENT_BYTES / 2)
  const accepted = terminalCreateRoute({
    manager: boundaryManager,
    params: { id: 'argument-byte-boundary', args: [boundary] },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })
  assert.equal(accepted.ok, true)
  assert.equal(Buffer.byteLength(boundary), MAX_ARGUMENT_BYTES)

  const rejectedManager = fakeManager()
  rejectedManager.has = () => false
  const oversized = `${boundary}é`
  const rejected = terminalCreateRoute({
    manager: rejectedManager,
    params: { id: 'argument-byte-overflow', args: [oversized] },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => assert.fail('oversized payload must not authorize'),
  })
  assert.deepEqual(rejected, {
    ok: false,
    code: 'terminal_create_payload_limit',
    message: 'terminal argument 0 exceeds 16384 UTF-8 bytes',
    scope: 'arguments',
    limit: 'itemBytes',
    index: 0,
    maxBytes: MAX_ARGUMENT_BYTES,
    actualBytes: MAX_ARGUMENT_BYTES + 2,
  })
  assert.equal(rejectedManager.calls.length, 0)
})

test('terminal create route bounds aggregate argument bytes', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const boundaryManager = fakeManager()
  const boundaryArgs = Array.from({ length: 16 }, () => 'a'.repeat(MAX_ARGUMENT_BYTES))
  assert.equal(
    boundaryArgs.reduce((total, argument) => total + Buffer.byteLength(argument), 0),
    MAX_ARGUMENTS_BYTES,
  )
  const accepted = terminalCreateRoute({
    manager: boundaryManager,
    params: { id: 'aggregate-argument-boundary', args: boundaryArgs },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })
  assert.equal(accepted.ok, true)

  const manager = fakeManager()
  manager.has = () => false
  const args = Array.from({ length: 17 }, () => 'a'.repeat(MAX_ARGUMENT_BYTES))
  const actualBytes = args.reduce((total, argument) => total + Buffer.byteLength(argument), 0)
  assert.ok(actualBytes > MAX_ARGUMENTS_BYTES)

  const response = terminalCreateRoute({
    manager,
    params: { id: 'aggregate-argument-overflow', args },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => assert.fail('oversized payload must not authorize'),
  })

  assert.deepEqual(response, {
    ok: false,
    code: 'terminal_create_payload_limit',
    message: 'terminal arguments exceed 262144 total UTF-8 bytes',
    scope: 'arguments',
    limit: 'totalBytes',
    maxBytes: MAX_ARGUMENTS_BYTES,
    actualBytes,
  })
  assert.equal(manager.calls.length, 0)
})

test('terminal create route rejects invalid environment shapes before spawn', async (t) => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const fixtures = [
    {
      name: 'environment must be an object',
      env: [],
      expected: {
        ok: false,
        code: 'terminal_create_payload_type',
        message: 'terminal environment must be an object of string values',
        scope: 'environment',
        expected: 'object',
      },
    },
    {
      name: 'environment values must be strings',
      env: { SAFE: 'yes', TOKEN: 42 },
      expected: {
        ok: false,
        code: 'terminal_create_payload_type',
        message: 'terminal environment value 1 must be a string',
        scope: 'environment',
        expected: 'string',
        index: 1,
      },
    },
  ]

  for (const fixture of fixtures) {
    await t.test(fixture.name, () => {
      const manager = fakeManager()
      manager.has = () => false
      const response = terminalCreateRoute({
        manager,
        params: { id: `invalid-${fixture.name}`, env: fixture.env },
        owner: 'instance|owner|project',
        clientInstanceId: 'instance',
        requireAllowed: () => assert.fail('invalid payload must not authorize'),
      })

      assert.deepEqual(response, fixture.expected)
      assert.equal(manager.calls.length, 0)
    })
  }
})

test('terminal create route bounds environment entry count', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => false
  const env = Object.fromEntries(
    Array.from({ length: MAX_ENVIRONMENT_ENTRIES + 1 }, (_, index) => [`KEY_${index}`, 'value']),
  )

  const response = terminalCreateRoute({
    manager,
    params: { id: 'environment-entry-overflow', env },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => assert.fail('oversized payload must not authorize'),
  })

  assert.deepEqual(response, {
    ok: false,
    code: 'terminal_create_payload_limit',
    message: 'terminal environment exceeds 256 entries',
    scope: 'environment',
    limit: 'entryCount',
    maxCount: MAX_ENVIRONMENT_ENTRIES,
    actualCount: MAX_ENVIRONMENT_ENTRIES + 1,
  })
  assert.equal(manager.calls.length, 0)
})

test('terminal create route measures environment keys and values in UTF-8 bytes', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const safeKey = '界'.repeat(341)
  const safeValue = '🙂'.repeat(MAX_ENVIRONMENT_VALUE_BYTES / 4)
  assert.ok(Buffer.byteLength(safeKey) <= MAX_ENVIRONMENT_KEY_BYTES)
  assert.equal(Buffer.byteLength(safeValue), MAX_ENVIRONMENT_VALUE_BYTES)

  const boundaryManager = fakeManager()
  const accepted = terminalCreateRoute({
    manager: boundaryManager,
    params: { id: 'environment-byte-boundary', env: { [safeKey]: safeValue } },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })
  assert.equal(accepted.ok, true)

  const keyManager = fakeManager()
  keyManager.has = () => false
  const oversizedKey = `${safeKey}界`
  const rejectedKey = terminalCreateRoute({
    manager: keyManager,
    params: { id: 'environment-key-overflow', env: { [oversizedKey]: 'value' } },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => assert.fail('oversized payload must not authorize'),
  })
  assert.deepEqual(rejectedKey, {
    ok: false,
    code: 'terminal_create_payload_limit',
    message: 'terminal environment key 0 exceeds 1024 UTF-8 bytes',
    scope: 'environment',
    limit: 'keyBytes',
    index: 0,
    maxBytes: MAX_ENVIRONMENT_KEY_BYTES,
    actualBytes: Buffer.byteLength(oversizedKey),
  })

  const valueManager = fakeManager()
  valueManager.has = () => false
  const oversizedValue = `${safeValue}🙂`
  const rejectedValue = terminalCreateRoute({
    manager: valueManager,
    params: { id: 'environment-value-overflow', env: { KEY: oversizedValue } },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => assert.fail('oversized payload must not authorize'),
  })
  assert.deepEqual(rejectedValue, {
    ok: false,
    code: 'terminal_create_payload_limit',
    message: 'terminal environment value 0 exceeds 65536 UTF-8 bytes',
    scope: 'environment',
    limit: 'valueBytes',
    index: 0,
    maxBytes: MAX_ENVIRONMENT_VALUE_BYTES,
    actualBytes: MAX_ENVIRONMENT_VALUE_BYTES + 4,
  })
  assert.equal(keyManager.calls.length, 0)
  assert.equal(valueManager.calls.length, 0)
})

test('terminal create route bounds aggregate environment bytes', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const boundaryManager = fakeManager()
  const boundaryEnv = {
    K0: 'v'.repeat(MAX_ENVIRONMENT_VALUE_BYTES),
    K1: 'v'.repeat(MAX_ENVIRONMENT_VALUE_BYTES),
    K2: 'v'.repeat(MAX_ENVIRONMENT_VALUE_BYTES),
    K3: 'v'.repeat(MAX_ENVIRONMENT_VALUE_BYTES - 8),
  }
  const boundaryBytes = Object.entries(boundaryEnv).reduce(
    (total, [key, value]) => total + Buffer.byteLength(key) + Buffer.byteLength(value),
    0,
  )
  assert.equal(boundaryBytes, MAX_ENVIRONMENT_BYTES)
  const accepted = terminalCreateRoute({
    manager: boundaryManager,
    params: { id: 'aggregate-environment-boundary', env: boundaryEnv },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })
  assert.equal(accepted.ok, true)

  const manager = fakeManager()
  manager.has = () => false
  const env = Object.fromEntries(
    Array.from({ length: 5 }, (_, index) => [`K${index}`, 'v'.repeat(60 * 1024)]),
  )
  const actualBytes = Object.entries(env).reduce(
    (total, [key, value]) => total + Buffer.byteLength(key) + Buffer.byteLength(value),
    0,
  )
  assert.ok(actualBytes > MAX_ENVIRONMENT_BYTES)

  const response = terminalCreateRoute({
    manager,
    params: { id: 'aggregate-environment-overflow', env },
    owner: 'instance|owner|project',
    clientInstanceId: 'instance',
    requireAllowed: () => assert.fail('oversized payload must not authorize'),
  })

  assert.deepEqual(response, {
    ok: false,
    code: 'terminal_create_payload_limit',
    message: 'terminal environment exceeds 262144 total UTF-8 bytes',
    scope: 'environment',
    limit: 'totalBytes',
    maxBytes: MAX_ENVIRONMENT_BYTES,
    actualBytes,
  })
  assert.equal(manager.calls.length, 0)
})

test('terminal create route preserves an id at the 240-character boundary', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  const id = 't'.repeat(240)

  const response = terminalCreateRoute({
    manager,
    params: { id, projectId: 'project-boundary' },
    owner: 'instance|owner|project-boundary',
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })

  assert.equal(response.ok, true)
  assert.equal(manager.calls.length, 1)
  assert.equal(manager.calls[0].id, id)
})

test('terminal create route rejects an overlong id before authorization or spawn', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => assert.fail('an overlong id must not reach terminal lookup')
  const authorized = []

  const response = terminalCreateRoute({
    manager,
    params: { id: 't'.repeat(241), projectId: 'project-a' },
    owner: 'instance-a|owner-a|project-a',
    clientInstanceId: 'instance-a',
    requireAllowed: (...args) => authorized.push(args),
  })

  assert.deepEqual(response, {
    ok: false,
    code: 'terminal_id_too_long',
    message: 'terminal id exceeds 240 characters',
    maxLength: 240,
    actualLength: 241,
  })
  assert.deepEqual(authorized, [])
  assert.equal(manager.calls.length, 0)
})

test('terminal create route never aliases overlong ids with a shared 240-character prefix', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager()
  manager.has = () => assert.fail('colliding overlong ids must not reach terminal lookup')
  const prefix = 't'.repeat(240)
  const authorized = []

  const first = terminalCreateRoute({
    manager,
    params: { id: `${prefix}a`, projectId: 'project-a' },
    owner: 'instance-a|owner-a|project-a',
    clientInstanceId: 'instance-a',
    requireAllowed: (...args) => authorized.push(args),
  })
  const second = terminalCreateRoute({
    manager,
    params: { id: `${prefix}b`, projectId: 'project-b' },
    owner: 'instance-b|owner-b|project-b',
    clientInstanceId: 'instance-b',
    requireAllowed: (...args) => authorized.push(args),
  })

  assert.equal(first.code, 'terminal_id_too_long')
  assert.equal(second.code, 'terminal_id_too_long')
  assert.deepEqual(authorized, [])
  assert.equal(manager.calls.length, 0)
})

test('restore for an id unknown to this broker requires the id-embedded project to match', () => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const manager = fakeManager({ recovered: { text: 'secret-project-a-output', truncated: false } })
  manager.has = () => false // fresh broker process: nothing in memory to check ownership against

  const denied = terminalCreateRoute({
    manager,
    params: {
      id: 'term-nproj_project-a-11112222',
      projectId: 'nproj_project-b',
      restore: true,
    },
    owner: 'instance|owner|nproj_project-b',
    clientInstanceId: 'new-instance',
    requireAllowed: () => { throw new Error('nothing to check against post-restart') },
  })
  assert.equal(denied.ok, false)
  assert.match(denied.message, /project mismatch/)
  assert.equal(manager.calls.length, 0, 'a denied restore must never reach spawn')

  const allowed = terminalCreateRoute({
    manager,
    params: {
      id: 'term-nproj_project-a-11112222',
      projectId: 'nproj_project-a',
      restore: true,
    },
    owner: 'instance|owner|nproj_project-a',
    clientInstanceId: 'new-instance',
    requireAllowed: () => {},
  })
  assert.equal(allowed.ok, true)
  assert.equal(allowed.recovered, null)
})

test('restore of naturally ended spool registers a history-serving cold record', (t) => {
  const { terminalCreateRoute } = require('../../runtime/node-broker/ipc/terminalCreateRoute.cjs')
  const projectId = 'nproj_cold-history'
  const id = `term-${projectId}-deadbeef`
  const oldOutput = 'first byte through final byte\n'
  const exitStatus = { exitCode: 23, signal: null }
  const spool = new TerminalSpool({ dir: managerSpoolDir, id, fresh: true })
  spool.push(oldOutput)
  spool.markExited(exitStatus)
  spool.close()
  const liveID = 'capacity-live-while-restoring-cold-history'
  realManager.configureCapacity(1)
  assert.ok(realManager.spawn({
    id: liveID,
    command: '/bin/cat',
    args: [],
    cwd: managerSpoolDir,
  }))
  t.after(() => {
    realManager.release(id)
    realManager.release(liveID)
    realManager.configureCapacity(realManager.DEFAULT_MAX_LIVE_TERMINALS)
  })

  const response = terminalCreateRoute({
    manager: realManager,
    params: {
      id,
      projectId,
      command: '/bin/cat',
      cwd: managerSpoolDir,
      restore: true,
    },
    owner: `instance|owner|${projectId}`,
    clientInstanceId: 'instance',
    requireAllowed: () => {},
  })

  const oldBytes = Buffer.byteLength(oldOutput)
  assert.equal(response.ok, true)
  assert.equal(response.existed, false)
  assert.equal(response.pid, null)
  assert.equal(response.exited, true)
  assert.deepEqual(response.exitStatus, exitStatus)
  assert.equal(response.recovered, null)
  assert.equal(response.output, '')
  assert.equal(response.startOffset, oldBytes)
  assert.equal(response.endOffset, oldBytes)
  assert.deepEqual(realManager.capacity(), {
    liveTerminalCount: 1,
    maximumLiveTerminals: 1,
    availableTerminalSlots: 0,
  })

  assert.deepEqual(realManager.history(id, {
    streamEpoch: response.streamEpoch,
    beforeOffset: response.endOffset,
    maxBytes: 1024 * 1024,
  }), {
    ok: true,
    streamEpoch: response.streamEpoch,
    output: oldOutput,
    startOffset: 0,
    endOffset: oldBytes,
    hasMore: false,
    truncated: false,
  })
  assert.deepEqual(realManager.write(id, 'must not reach a pty'), {
    ok: false,
    message: 'terminal already ended',
  })
  assert.deepEqual(realManager.resize(id, 100, 40), {
    ok: false,
    message: 'terminal already ended',
  })
})
