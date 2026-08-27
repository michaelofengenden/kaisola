#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')

const maximumReceiptBytes = 64 * 1024
const packagePolicy = require(path.join(
  __dirname,
  '../native/KaisolaMac/BrokerHelper/package-policy.json'
))
const expectedNodeVersion = packagePolicy.node.version
const booleanEvidence = Object.freeze([
  'adaptersStoppedAfterSuspend',
  'adaptersStoppedAfterDestroy',
  'worktreesPreservedAfterSuspend',
  'unconfirmedDestroyRefused',
  'restoredWithoutDuplicateWorktrees',
  'meshWorktreesRemoved',
  'meshBranchesRemoved',
  'unrelatedProcessPreserved',
  'unrelatedWorktreePreserved',
])
const expectedKeys = Object.freeze([
  'adapterProcessesAfterRestore',
  'adapterProcessesAtStart',
  ...booleanEvidence,
  'columns',
  'descriptorColumnsAfterSuspend',
  'minimumAdapterFileDescriptorsAtStart',
  'nodeVersion',
  'recoverableColumnCount',
  'restoredColumns',
  'schemaVersion',
].sort())

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  if (argv.length !== 2 || argv[0] !== '--receipt' || !argv[1]) {
    fail('Usage: native-mesh-lifecycle-receipt.cjs --receipt PATH')
  }
  return { receiptPath: argv[1] }
}

function exactPositiveInteger(value, label, { minimum = 1, maximum = 10_000 } = {}) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    fail(`${label} must be an integer from ${minimum} through ${maximum}`)
  }
  return value
}

function validateReceipt(receipt) {
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt)) {
    fail('receipt must be one JSON object')
  }
  const actualKeys = Object.keys(receipt).sort()
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    fail('receipt keys do not match the lifecycle evidence schema')
  }
  if (receipt.schemaVersion !== 1) fail('unsupported lifecycle receipt schema')
  if (receipt.nodeVersion !== expectedNodeVersion) {
    fail(`nodeVersion must be exactly ${expectedNodeVersion}`)
  }

  const columns = exactPositiveInteger(receipt.columns, 'columns', { minimum: 2, maximum: 32 })
  const startProcesses = exactPositiveInteger(
    receipt.adapterProcessesAtStart,
    'adapterProcessesAtStart',
    { minimum: 2, maximum: 32 }
  )
  const restoredProcesses = exactPositiveInteger(
    receipt.adapterProcessesAfterRestore,
    'adapterProcessesAfterRestore',
    { minimum: 2, maximum: 32 }
  )
  if (startProcesses !== columns || restoredProcesses !== columns) {
    fail('every Mesh column must own exactly one adapter before suspend and after restore')
  }
  if (exactPositiveInteger(
    receipt.descriptorColumnsAfterSuspend,
    'descriptorColumnsAfterSuspend',
    { minimum: 2, maximum: 32 }
  ) !== columns) {
    fail('the suspended descriptor must retain every column')
  }
  if (exactPositiveInteger(
    receipt.restoredColumns,
    'restoredColumns',
    { minimum: 2, maximum: 32 }
  ) !== columns) {
    fail('restoration must recover every column')
  }
  exactPositiveInteger(
    receipt.minimumAdapterFileDescriptorsAtStart,
    'minimumAdapterFileDescriptorsAtStart',
    { minimum: 3, maximum: 10_000 }
  )
  const recoverable = exactPositiveInteger(
    receipt.recoverableColumnCount,
    'recoverableColumnCount',
    { maximum: columns }
  )
  for (const key of booleanEvidence) {
    if (receipt[key] !== true) fail(`${key} must be true`)
  }

  return {
    ok: true,
    schemaVersion: 1,
    nodeVersion: receipt.nodeVersion,
    columns,
    recoverableColumnCount: recoverable,
  }
}

function readReceipt(receiptPath) {
  const stat = fs.lstatSync(receiptPath)
  if (!stat.isFile() || stat.isSymbolicLink()) fail('receipt must be a regular non-symlink file')
  if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
    fail('receipt must be owned by the current user')
  }
  if (stat.size <= 0 || stat.size > maximumReceiptBytes) {
    fail(`receipt must contain 1 through ${maximumReceiptBytes} bytes`)
  }
  if ((stat.mode & 0o777) !== 0o600) fail('receipt mode must be exactly 0600')
  return JSON.parse(fs.readFileSync(receiptPath, 'utf8'))
}

function main(argv = process.argv.slice(2)) {
  const { receiptPath } = parseArguments(argv)
  const result = validateReceipt(readReceipt(receiptPath))
  process.stdout.write(`${JSON.stringify(result)}\n`)
}

if (require.main === module) {
  try {
    main()
  } catch (error) {
    process.stderr.write(`native Mesh lifecycle receipt rejected: ${error.message}\n`)
    process.exitCode = 1
  }
}

module.exports = { expectedNodeVersion, main, parseArguments, readReceipt, validateReceipt }
