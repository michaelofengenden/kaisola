#!/usr/bin/env node
'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const https = require('node:https')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const repoRoot = path.resolve(__dirname, '..')
const policy = JSON.parse(fs.readFileSync(
  path.join(repoRoot, 'native', 'KaisolaMac', 'BrokerHelper', 'package-policy.json'),
  'utf8',
))
const artifactRoot = path.join(repoRoot, 'native', 'KaisolaMac', '.artifacts')

function fail(message) { throw new Error(message) }

function download(url, destination) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, { headers: { 'User-Agent': 'Kaisola-native-helper-builder/1' } }, (response) => {
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        response.resume()
        download(new URL(response.headers.location, url), destination).then(resolve, reject)
        return
      }
      if (response.statusCode !== 200) {
        response.resume()
        reject(new Error(`download failed with HTTP ${response.statusCode}`))
        return
      }
      const stream = fs.createWriteStream(destination, { mode: 0o600 })
      response.pipe(stream)
      stream.on('finish', () => stream.close(resolve))
      stream.on('error', reject)
    })
    request.on('error', reject)
  })
}

function hash(file) {
  const digest = crypto.createHash('sha256')
  digest.update(fs.readFileSync(file))
  return digest.digest('hex')
}

async function install(architecture) {
  const archive = policy.node.archives[architecture]
  if (!archive) fail(`unsupported architecture ${architecture}`)
  const nodeArchitecture = architecture === 'x86_64' ? 'x64' : architecture
  const destination = path.join(artifactRoot, `node-v${policy.node.version}-darwin-${nodeArchitecture}`)
  const binary = path.join(destination, 'bin', 'node')
  if (fs.existsSync(binary)) {
    console.log(`NATIVE_NODE_RUNTIME=READY architecture=${architecture} path=${binary}`)
    return binary
  }
  fs.mkdirSync(artifactRoot, { recursive: true, mode: 0o700 })
  const temporaryArchive = path.join(artifactRoot, `.${archive.name}.${process.pid}.download`)
  try {
    await download(`https://nodejs.org/download/release/v${policy.node.version}/${archive.name}`, temporaryArchive)
    const actual = hash(temporaryArchive)
    if (actual !== archive.sha256) fail(`checksum mismatch for ${archive.name}: ${actual}`)
    const result = spawnSync('/usr/bin/tar', ['-xJf', temporaryArchive, '-C', artifactRoot], { encoding: 'utf8' })
    if (result.status !== 0) fail(`tar failed: ${String(result.stderr || result.stdout).trim()}`)
    if (!fs.existsSync(binary)) fail(`archive did not produce ${binary}`)
    console.log(`NATIVE_NODE_RUNTIME=DOWNLOADED architecture=${architecture} path=${binary}`)
    return binary
  } finally {
    fs.rmSync(temporaryArchive, { force: true })
  }
}

;(async () => {
  const requested = process.argv.slice(2)
  const architectures = requested.length ? requested : ['arm64', 'x86_64']
  for (const architecture of architectures) await install(architecture)
})().catch((error) => {
  console.error(`NATIVE_NODE_RUNTIME=FAIL ${error.message}`)
  process.exitCode = 1
})
