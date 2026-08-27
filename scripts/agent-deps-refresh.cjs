#!/usr/bin/env node
'use strict'
// Keeps the agent integration current. Three pinned surfaces live in this
// repo; the ACP adapters deliberately do not (AcpAdapterResolver spawns
// `npx -y @agentclientprotocol/…@latest`, so every chat launch already runs
// the newest published adapter):
//
//   1. `@anthropic-ai/claude-agent-sdk` in package.json — the sealed usage
//      helper rides it, and its version is sealed into the helper manifest
//      through package-policy.json.
//   2. The pinned Node runtime the sealed helper ships (version + archive
//      SHAs in package-policy.json), tracked to the newest same-major release.
//   3. `node-pty` — the helper's PTY module, sealed the same way.
//
// Modes:
//   --check   report staleness, write nothing; exit 3 when anything is stale
//   (default) apply every bump: npm install --save-exact + rewrite the policy
//
// After an apply, run `npm run test:node` and the Swift BrokerHelperPackage
// suite before landing; the weekly refresh automation does exactly that.

const { execFileSync } = require('node:child_process')
const fs = require('node:fs')
const https = require('node:https')
const path = require('node:path')

const repoRoot = path.join(__dirname, '..')
const policyPath = path.join(repoRoot, 'native/KaisolaMac/BrokerHelper/package-policy.json')
const packagePath = path.join(repoRoot, 'package.json')

const checkOnly = process.argv.includes('--check')

function npmView(spec) {
  return execFileSync('npm', ['view', spec, 'version'], { encoding: 'utf8' }).trim()
}

function fetchText(url) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'user-agent': 'kaisola-agent-deps-refresh' } }, (response) => {
      if (response.statusCode !== 200) {
        response.resume()
        reject(new Error(`${url} -> HTTP ${response.statusCode}`))
        return
      }
      let body = ''
      response.setEncoding('utf8')
      response.on('data', (chunk) => { body += chunk })
      response.on('end', () => resolve(body))
    }).on('error', reject)
  })
}

/// Newest release of the sealed runtime's own major line. Staying inside the
/// major keeps the ABI story boring; moving majors is a deliberate decision,
/// not a refresh.
async function latestNodeOfSameMajor(currentVersion) {
  const major = currentVersion.split('.')[0]
  const index = JSON.parse(await fetchText('https://nodejs.org/dist/index.json'))
  const entry = index.find((release) => release.version.startsWith(`v${major}.`))
  if (!entry) throw new Error(`no v${major}.x release found in the dist index`)
  return { version: entry.version.slice(1), abi: String(entry.modules) }
}

async function nodeArchiveShas(version) {
  const sums = await fetchText(`https://nodejs.org/dist/v${version}/SHASUMS256.txt`)
  const wanted = {
    arm64: `node-v${version}-darwin-arm64.tar.xz`,
    x86_64: `node-v${version}-darwin-x64.tar.xz`,
  }
  const archives = {}
  for (const [architecture, name] of Object.entries(wanted)) {
    const line = sums.split('\n').find((candidate) => candidate.trim().endsWith(`  ${name}`)
      || candidate.trim().endsWith(` ${name}`))
    if (!line) throw new Error(`${name} missing from SHASUMS256.txt`)
    archives[architecture] = { name, sha256: line.trim().split(/\s+/)[0] }
  }
  return archives
}

function bumpMinor(version) {
  const [major, minor] = version.split('.').map(Number)
  return `${major}.${minor + 1}.0`
}

async function main() {
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'))
  const manifest = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
  const stale = []
  const applied = []

  const sdkCurrent = manifest.dependencies['@anthropic-ai/claude-agent-sdk']
  const sdkLatest = npmView('@anthropic-ai/claude-agent-sdk')
  if (sdkCurrent !== sdkLatest) stale.push(`claude-agent-sdk ${sdkCurrent} -> ${sdkLatest}`)

  const ptyCurrent = manifest.dependencies['node-pty']
  const ptyLatest = npmView('node-pty')
  if (ptyCurrent !== ptyLatest) stale.push(`node-pty ${ptyCurrent} -> ${ptyLatest}`)

  const node = await latestNodeOfSameMajor(policy.node.version)
  if (policy.node.version !== node.version) {
    stale.push(`sealed node ${policy.node.version} -> ${node.version}`)
  }

  // Informational only: the adapters are resolved at spawn, not pinned here.
  for (const adapter of ['@agentclientprotocol/claude-agent-acp', '@agentclientprotocol/codex-acp']) {
    console.log(`adapter ${adapter}@latest currently publishes ${npmView(adapter)} (resolved at every chat launch)`)
  }

  if (stale.length === 0) {
    console.log('agent deps are current')
    return
  }
  for (const line of stale) console.log(`stale: ${line}`)
  if (checkOnly) process.exitCode = 3
  if (checkOnly) return

  if (sdkCurrent !== sdkLatest) {
    execFileSync('npm', [
      'install', '--save-exact', `@anthropic-ai/claude-agent-sdk@${sdkLatest}`,
    ], { cwd: repoRoot, stdio: 'inherit' })
    policy.claudeAgentSDKVersion = sdkLatest
    applied.push('sdk')
  }
  if (ptyCurrent !== ptyLatest) {
    execFileSync('npm', ['install', '--save-exact', `node-pty@${ptyLatest}`], {
      cwd: repoRoot, stdio: 'inherit',
    })
    policy.nodePtyVersion = ptyLatest
    applied.push('node-pty')
  }
  if (policy.node.version !== node.version) {
    policy.node = {
      version: node.version,
      abi: node.abi,
      archives: await nodeArchiveShas(node.version),
    }
    applied.push('node runtime')
  }

  // The sealed package's contents changed, so its declared version moves.
  policy.packageVersion = bumpMinor(policy.packageVersion)
  fs.writeFileSync(policyPath, `${JSON.stringify(policy, null, 2)}\n`)
  console.log(`applied: ${applied.join(', ')}; helper package now ${policy.packageVersion}`)
}

main().catch((error) => {
  console.error(error.message || error)
  process.exitCode = 1
})
