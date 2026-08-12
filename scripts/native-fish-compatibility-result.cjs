#!/usr/bin/env node
'use strict'

const fs = require('node:fs')

const maximumResultsBytes = 1024 * 1024
const maximumNodes = 10_000
const maximumDepth = 32
const expectedIdentifier =
  'NativeTerminalInteractionTests/testGeneratedFishIntegrationExecutesWhenFishRuntimeIsAvailable()'

function fail(message) {
  throw new Error(message)
}

function parseArguments(argv) {
  if (argv.length !== 2 || argv[0] !== '--results' || !argv[1]) {
    fail('Usage: native-fish-compatibility-result.cjs --results PATH')
  }
  return { resultsPath: argv[1] }
}

function readResults(resultsPath) {
  const stat = fs.lstatSync(resultsPath)
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail('Fish test results must be a regular non-symlink file')
  }
  if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
    fail('Fish test results must be owned by the current user')
  }
  if (stat.size <= 0 || stat.size > maximumResultsBytes) {
    fail(`Fish test results must contain 1 through ${maximumResultsBytes} bytes`)
  }
  return JSON.parse(fs.readFileSync(resultsPath, 'utf8'))
}

function validateTestResults(root) {
  if (!root || typeof root !== 'object' || Array.isArray(root)) {
    fail('Fish test results must be one JSON object')
  }
  if (!Array.isArray(root.testNodes)) fail('Fish test results are missing testNodes')

  const nodes = []
  const visit = (node, depth) => {
    if (!node || typeof node !== 'object' || Array.isArray(node)) {
      fail('Fish test result nodes must be objects')
    }
    if (depth > maximumDepth) fail('Fish test result nesting exceeds the bounded depth')
    nodes.push(node)
    if (nodes.length > maximumNodes) fail('Fish test result node count exceeds the bound')
    if (node.children !== undefined && !Array.isArray(node.children)) {
      fail('Fish test result children must be an array')
    }
    for (const child of node.children ?? []) visit(child, depth + 1)
  }
  for (const node of root.testNodes) visit(node, 0)

  const skipped = nodes.filter((node) => node.nodeType === 'Test Case' && node.result === 'Skipped')
  if (skipped.length > 0) fail('required Fish compatibility test skipped')
  const testCases = nodes.filter((node) => node.nodeType === 'Test Case')
  if (testCases.length !== 1) fail('Fish results must contain exactly one test case')
  const expected = testCases.filter((node) => node.nodeIdentifier === expectedIdentifier)
  if (expected.length !== 1 || expected[0].nodeType !== 'Test Case' || expected[0].result !== 'Passed') {
    fail('required Fish result is not one unambiguous pass')
  }

  return {
    ok: true,
    fishVersion: '4.8.1',
    test: expectedIdentifier,
    result: 'Passed',
  }
}

function main(argv = process.argv.slice(2)) {
  const { resultsPath } = parseArguments(argv)
  process.stdout.write(`${JSON.stringify(validateTestResults(readResults(resultsPath)))}\n`)
}

if (require.main === module) {
  try {
    main()
  } catch (error) {
    process.stderr.write(`required Fish compatibility result rejected: ${error.message}\n`)
    process.exitCode = 1
  }
}

module.exports = {
  expectedIdentifier,
  main,
  parseArguments,
  readResults,
  validateTestResults,
}
