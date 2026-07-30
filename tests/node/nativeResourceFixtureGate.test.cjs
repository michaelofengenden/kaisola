'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const {
  EXPECTED_BYTES,
  EXPECTED_MUTABLE_TAIL_BYTES,
  EXPECTED_PAGES,
  EXPECTED_PAGE_BYTES,
  EXPECTED_SCROLLBACK_LINES,
  FIXTURE_LAUNCH_ARGUMENTS,
  RECEIPT_PREFIX,
  createBoundedCapture,
  fixtureEnvironment,
  parseArguments,
  parseReceiptLine,
  validateReceipt,
  validateReadinessOutput,
} = require('../../scripts/native-resource-fixture-gate.cjs')

const exactReceipt = () => ({
  schemaVersion: 1,
  ok: true,
  expectedBytes: EXPECTED_BYTES,
  actualBytes: EXPECTED_BYTES,
  pages: EXPECTED_PAGES,
  pageLimitBytes: EXPECTED_PAGE_BYTES,
  mutableTailLimitBytes: EXPECTED_MUTABLE_TAIL_BYTES,
  scrollbackLines: EXPECTED_SCROLLBACK_LINES,
  renderedEndOffset: EXPECTED_BYTES,
})

test('resource fixture receipt requires exact bytes, pages, renderer depth, and cursor', () => {
  const receipt = exactReceipt()
  assert.equal(EXPECTED_PAGE_BYTES, 1024 * 1024)
  assert.equal(EXPECTED_PAGES, 64)
  assert.equal(EXPECTED_MUTABLE_TAIL_BYTES, 16 * 1024)
  assert.deepEqual(validateReceipt(receipt), receipt)
  assert.deepEqual(parseReceiptLine(`${RECEIPT_PREFIX}${JSON.stringify(receipt)}`), receipt)
  for (const [key, value] of [
    ['ok', false],
    ['actualBytes', EXPECTED_BYTES - 1],
    ['pages', EXPECTED_PAGES - 1],
    ['pageLimitBytes', EXPECTED_PAGE_BYTES * 2],
    ['mutableTailLimitBytes', EXPECTED_MUTABLE_TAIL_BYTES * 2],
    ['scrollbackLines', 5_000],
    ['renderedEndOffset', EXPECTED_BYTES - 1],
  ]) {
    assert.throws(() => validateReceipt({ ...receipt, [key]: value }), new RegExp(key))
  }
})

test('resource fixture runner rejects malformed receipts and unsafe arguments', () => {
  assert.throws(() => parseReceiptLine('READY={}'), /prefix/)
  assert.throws(() => parseReceiptLine(`${RECEIPT_PREFIX}{`), /JSON/)
  assert.throws(() => parseArguments(['--samples', '0']), /positive integer/)
  assert.throws(() => parseArguments(['--samples', '6']), /at least 7/)
  assert.throws(() => parseArguments(['--warm-ms', '14999']), /at least 15000/)
  assert.throws(() => parseArguments(['--token', 'secret']), /unknown argument/)
  assert.deepEqual(parseArguments(['--app', '/tmp/Kaisola.app', '--warm-ms', '15000']), {
    app: '/tmp/Kaisola.app',
    samples: 7,
    intervalMs: 750,
    warmMs: 15000,
  })
})

test('resource fixture runner pins the maximum renderer depth independently of user defaults', () => {
  const environment = fixtureEnvironment()
  assert.equal(environment.KAISOLA_NATIVE_RESOURCE_SCROLLBACK_BYTES, String(EXPECTED_BYTES))
  assert.equal(environment.KAISOLA_NATIVE_RESOURCE_SCROLLBACK_LINES, String(EXPECTED_SCROLLBACK_LINES))
  assert.equal(environment.KAISOLA_NATIVE_RESOURCE_RECEIPT, '1')
  assert.deepEqual(FIXTURE_LAUNCH_ARGUMENTS, ['-ApplePersistenceIgnoreState', 'YES'])
})

test('resource fixture runner rejects every byte outside its single readiness receipt', () => {
  const line = `${RECEIPT_PREFIX}${JSON.stringify(exactReceipt())}`
  assert.deepEqual(validateReadinessOutput({ stdout: `${line}\n`, stderr: '', receipt: exactReceipt() }).receipt, exactReceipt())
  const persistenceNotice = '2026-07-30 02:27:41.409 Kaisola[57115:20001286] ApplePersistenceIgnoreState: Existing state will not be touched. New state will be written to /private/tmp/com.kaisola.mac.savedState\n'
  assert.deepEqual(
    validateReadinessOutput({ stdout: `${line}\n`, stderr: persistenceNotice, receipt: exactReceipt() }).receipt,
    exactReceipt(),
  )
  assert.throws(
    () => validateReadinessOutput({ stdout: `diagnostic\n${line}\n`, stderr: '', receipt: exactReceipt() }),
    /exactly one receipt line/,
  )
  assert.throws(
    () => validateReadinessOutput({ stdout: `${line}\n`, stderr: '\n', receipt: exactReceipt() }),
    /stderr before readiness/,
  )
  assert.throws(
    () => validateReadinessOutput({ stdout: `${line}\n`, stderr: `${persistenceNotice}extra\n`, receipt: exactReceipt() }),
    /stderr before readiness/,
  )

  const stdout = createBoundedCapture('stdout', 4)
  stdout.append('late')
  assert.throws(() => stdout.assertEmpty('after readiness'), /stdout after readiness/)

  const stderr = createBoundedCapture('stderr', 4)
  stderr.append('12345')
  assert.throws(() => stderr.assertEmpty('after readiness'), /exceeded 4 bytes/)
})
