'use strict'

// GHSA-7p8r-x3mc-p8w7: fast-uri below 3.1.5 reads a backslash authority
// introducer as an ordinary path, so `https://good.test\@evil.test` parses to
// host `evil.test` while WHATWG (`new URL`) reads host `good.test`. Two parsers
// disagreeing about the host of the same string is the whole bug. This file
// pins the dependency, replays the adversarial spellings at each URI boundary
// Kaisola actually owns, and records why the vulnerable helper was never
// reachable from Kaisola code in the first place.

const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const uri = require('fast-uri')
const { readConfig, validateServer } = require('../../scripts/native-mcp-registry.cjs')

const repoRoot = path.join(__dirname, '..', '..')
const lock = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package-lock.json'), 'utf8'))
const manifest = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))
const FIXED_FAST_URI = [3, 1, 5]

/** A host-confusion spelling: every parser that reads it must refuse, because
 * no two of them agree on which host it names. `whatwgHost` records what
 * Node's `new URL` makes of it, which is the reading an attacker is fishing
 * for. */
const ADVERSARIAL = [
  { uri: 'https:\\\\evil.test/mcp', whatwgHost: 'evil.test', note: 'backslash authority introducer' },
  { uri: 'https:/\\evil.test/mcp', whatwgHost: 'evil.test', note: 'mixed separator, slash then backslash' },
  { uri: 'https:\\/evil.test/mcp', whatwgHost: 'evil.test', note: 'mixed separator, backslash then slash' },
  { uri: 'https://good.test\\@evil.test/mcp', whatwgHost: 'good.test', note: 'backslash before userinfo' },
  { uri: 'https://good.test\\.evil.test/mcp', whatwgHost: 'good.test', note: 'backslash inside the authority' },
  { uri: 'https:/\t/evil.test/mcp', whatwgHost: 'evil.test', note: 'tab-smuggled authority introducer' },
  { uri: 'https:/\tevil.test/mcp', whatwgHost: 'evil.test', note: 'tab standing in for the second slash' },
  { uri: 'https://good.test%09.evil.test/mcp', whatwgHost: null, note: 'percent-encoded tab inside the host' },
]

/** Everyday remote MCP endpoints, including the private-CA shape an enterprise
 * deployment uses: an internal name on a non-default port. Nothing here may be
 * caught by the guards above. */
const ORDINARY = [
  { uri: 'https://api.example.test/v1', host: 'api.example.test' },
  { uri: 'https://localhost:8443/mcp', host: 'localhost' },
  { uri: 'https://127.0.0.1:8443/mcp', host: '127.0.0.1' },
  { uri: 'https://[::1]:8443/mcp', host: '::1' },
  { uri: 'https://mcp.internal.corp.test:8443/mcp', host: 'mcp.internal.corp.test' },
  { uri: 'https://good.test/a%5Cb', host: 'good.test' },
]

function versionTuple(value) {
  return String(value).split('.').map((part) => Number.parseInt(part, 10))
}

function atLeast(actual, floor) {
  for (let index = 0; index < floor.length; index += 1) {
    if (actual[index] > floor[index]) return true
    if (actual[index] < floor[index]) return false
  }
  return true
}

function sourceFiles(directory, accumulator = []) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name)
    if (entry.isDirectory()) sourceFiles(full, accumulator)
    else if (/\.(?:cjs|mjs|js)$/u.test(entry.name)) accumulator.push(full)
  }
  return accumulator
}

function installedDependents(packageName) {
  const modules = path.join(repoRoot, 'node_modules')
  const roots = []
  for (const entry of fs.readdirSync(modules, { withFileTypes: true })) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue
    if (entry.name.startsWith('@')) {
      for (const scoped of fs.readdirSync(path.join(modules, entry.name), { withFileTypes: true })) {
        roots.push(`${entry.name}/${scoped.name}`)
      }
    } else if (!entry.name.startsWith('.')) {
      roots.push(entry.name)
    }
  }
  return roots.filter((name) => {
    let installed
    try {
      installed = JSON.parse(fs.readFileSync(path.join(modules, name, 'package.json'), 'utf8'))
    } catch {
      return false
    }
    return ['dependencies', 'peerDependencies', 'optionalDependencies']
      .some((field) => installed[field] && Object.hasOwn(installed[field], packageName))
  }).sort()
}

test('the lockfile resolves fast-uri past the advisory without a forced override', () => {
  const entry = lock.packages['node_modules/fast-uri']
  assert.ok(entry, 'fast-uri is expected in the production tree via ajv')
  assert.ok(
    atLeast(versionTuple(entry.version), FIXED_FAST_URI),
    `fast-uri ${entry.version} is inside GHSA-7p8r-x3mc-p8w7 (>=3.0.0 <3.1.5)`
  )
  assert.equal(entry.resolved, `https://registry.npmjs.org/fast-uri/-/fast-uri-${entry.version}.tgz`)
  assert.match(entry.integrity, /^sha512-/u)

  // ajv already admits the fixed line, so nothing has to be pinned over its
  // head. An override here would mean a transitive range was overruled without
  // review, which is what the advisory response was asked to avoid.
  assert.equal(lock.packages['node_modules/ajv'].dependencies['fast-uri'], '^3.0.1')
  assert.equal(manifest.overrides, undefined)
  assert.equal(lock.packages[''].overrides, undefined)
})

test('the installed fast-uri is the one the lockfile promises', () => {
  const installed = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'node_modules', 'fast-uri', 'package.json'), 'utf8')
  )
  assert.equal(installed.version, lock.packages['node_modules/fast-uri'].version)
  assert.ok(atLeast(versionTuple(installed.version), FIXED_FAST_URI))
})

test('fast-uri refuses every backslash and mixed-separator authority', () => {
  for (const fixture of ADVERSARIAL) {
    const parsed = uri.parse(fixture.uri)
    assert.ok(parsed.error, `${fixture.note}: ${JSON.stringify(fixture.uri)} parsed without an error`)
  }
})

test('fast-uri refuses to resolve against an ambiguous authority instead of guessing', () => {
  // 3.1.4 returned the ambiguous string from resolve() with no signal at all,
  // which is how a $ref could reach a host the schema author never named.
  for (const fixture of ADVERSARIAL.slice(0, 6)) {
    assert.throws(
      () => uri.resolve('https://good.test/schema/', fixture.uri),
      /malformed|backslash|whitespace/iu,
      `${fixture.note}: resolve() accepted ${JSON.stringify(fixture.uri)}`
    )
  }
})

test('fast-uri keeps ordinary HTTPS, localhost, IPv6, and internal-CA hosts working', () => {
  for (const fixture of ORDINARY) {
    const parsed = uri.parse(fixture.uri)
    assert.equal(parsed.error, undefined, `${fixture.uri} was rejected`)
    assert.equal(parsed.host, fixture.host)
    assert.equal(uri.resolve('https://good.test/schema/', fixture.uri), fixture.uri)
  }
})

test('the MCP server registry refuses the same spellings before they reach new URL', () => {
  for (const fixture of ADVERSARIAL) {
    assert.throws(
      () => validateServer({ id: 'probe', name: 'probe', transport: 'http', url: fixture.uri }),
      /url is (?:ambiguous|invalid)/u,
      `${fixture.note}: registry accepted ${JSON.stringify(fixture.uri)}`
    )
  }
})

test('the MCP registry and WHATWG never disagree about a stored host', () => {
  // The divergence is the payload: whatever `new URL` would have resolved to,
  // the registry must not have stored a server pointing there.
  for (const fixture of ADVERSARIAL) {
    if (!fixture.whatwgHost) continue
    assert.equal(new URL(fixture.uri).hostname, fixture.whatwgHost)
  }
})

test('the MCP registry keeps ordinary remote servers addable', () => {
  for (const fixture of ORDINARY) {
    const server = validateServer({ id: 'probe', name: 'probe', transport: 'http', url: fixture.uri })
    assert.equal(new URL(server.url).hostname, new URL(fixture.uri).hostname)
  }
})

test('a persisted config carrying an ambiguous URL degrades to no server, not a redirected one', (t) => {
  const root = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'kaisola-uri-boundary-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const configPath = path.join(root, 'mcp.json')
  fs.writeFileSync(configPath, JSON.stringify({
    schemaVersion: 1,
    workspace: root,
    servers: [
      { id: 'trap', name: 'trap', transport: 'http', url: 'https://good.test\\@evil.test/mcp' },
      { id: 'real', name: 'real', transport: 'http', url: 'https://mcp.internal.corp.test:8443/mcp' },
    ],
  }))
  const config = readConfig({ configPath })
  assert.deepEqual(config.servers.map((server) => server.id), ['real'])
})

test('the vulnerable parser was never reachable from Kaisola code', () => {
  // 1. Nothing but ajv pulls fast-uri into the tree.
  assert.deepEqual(installedDependents('fast-uri'), ['ajv'])

  // 2. ajv itself arrives only as an MCP SDK peer, and the SDK loads it from
  //    its opt-in validation provider rather than any default code path.
  assert.deepEqual(installedDependents('ajv'), ['@modelcontextprotocol/sdk', 'ajv-formats'])
  const sdkRoot = path.join(repoRoot, 'node_modules', '@modelcontextprotocol', 'sdk', 'dist')
  const sdkLoaders = sourceFiles(sdkRoot)
    .filter((file) => /(?:require\(["']ajv["']\)|from ["']ajv["'])/u.test(fs.readFileSync(file, 'utf8')))
    .map((file) => path.relative(sdkRoot, file))
  assert.ok(sdkLoaders.length > 0, 'expected to find where the MCP SDK loads ajv')
  for (const loader of sdkLoaders) {
    assert.match(loader, /(?:^|\/)(?:validation|examples)\//u, `${loader} loads ajv outside the opt-in provider`)
  }

  // 3. No Kaisola-owned source reaches either one, so the provider is never
  //    constructed and fast-uri is never required at runtime.
  const owned = [
    ...sourceFiles(path.join(repoRoot, 'runtime')),
    ...sourceFiles(path.join(repoRoot, 'scripts')),
    ...sourceFiles(path.join(repoRoot, 'tests')),
  ].filter((file) => file !== __filename)
  for (const file of owned) {
    const text = fs.readFileSync(file, 'utf8')
    assert.doesNotMatch(text, /(?:require|from)\s*\(?\s*["']ajv(?:-formats)?["']/u, `${file} loads ajv`)
    assert.doesNotMatch(text, /["']@modelcontextprotocol\/sdk/u, `${file} loads the MCP SDK`)
  }

  // 4. The signed helper package copies only node-pty and the Claude Agent SDK
  //    into lib/node_modules, and neither tree carries a nested copy, so the
  //    shipped app never had the file on disk to begin with.
  for (const staged of ['node-pty', path.join('@anthropic-ai', 'claude-agent-sdk')]) {
    const root = path.join(repoRoot, 'node_modules', staged)
    assert.ok(!fs.existsSync(path.join(root, 'node_modules')), `${staged} nests its own dependencies`)
    for (const file of sourceFiles(root)) {
      assert.doesNotMatch(fs.readFileSync(file, 'utf8'), /["'](?:fast-uri|ajv)["']/u, `${staged}/${file} loads it`)
    }
  }
})
