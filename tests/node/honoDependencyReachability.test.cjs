const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')

const repoRoot = path.resolve(__dirname, '../..')
const packageJSON = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))
const packageLock = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package-lock.json'), 'utf8'))
const honoPackage = packageLock.packages['node_modules/hono']
const installedHonoPackage = JSON.parse(
  fs.readFileSync(path.join(repoRoot, 'node_modules/hono/package.json'), 'utf8')
)
const minimumPatchedVersion = '4.12.34'
const mcpSDKPackageName = ['@modelcontextprotocol', 'sdk'].join('/')

function numericVersion(version) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version)
  assert.ok(match, `expected an exact stable semantic version, found ${version}`)
  return match.slice(1).map(Number)
}

function versionIsAtLeast(version, minimum) {
  const actual = numericVersion(version)
  const required = numericVersion(minimum)
  for (let index = 0; index < Math.max(actual.length, required.length); index += 1) {
    const delta = (actual[index] ?? 0) - (required[index] ?? 0)
    if (delta !== 0) return delta > 0
  }
  return true
}

function productionJavaScriptFiles(root) {
  const files = []
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const filePath = path.join(root, entry.name)
    if (entry.isDirectory()) {
      files.push(...productionJavaScriptFiles(filePath))
    } else if (/\.(?:cjs|mjs|js|ts|tsx)$/.test(entry.name)) {
      files.push(filePath)
    }
  }
  return files
}

const patchedHonoIsInstalled =
  honoPackage != null
  && installedHonoPackage.version === honoPackage.version
  && versionIsAtLeast(installedHonoPackage.version, minimumPatchedVersion)

test('the production lock resolves Hono at or above the four-advisory fix', () => {
  assert.ok(honoPackage, 'the MCP SDK dependency path must stay visible in package-lock.json')
  assert.ok(
    versionIsAtLeast(honoPackage.version, minimumPatchedVersion),
    `expected Hono >= ${minimumPatchedVersion}, found ${honoPackage.version}`
  )
})

test('the installed Hono artifact is the exact locked patched version', () => {
  assert.equal(installedHonoPackage.version, honoPackage.version)
  assert.ok(versionIsAtLeast(installedHonoPackage.version, minimumPatchedVersion))
})

test('Hono remains a transitive MCP SDK package with no first-party server import', () => {
  assert.equal(packageJSON.dependencies?.hono, undefined)
  assert.equal(packageJSON.devDependencies?.hono, undefined)
  assert.equal(packageJSON.dependencies?.['@hono/node-server'], undefined)
  assert.equal(packageJSON.devDependencies?.['@hono/node-server'], undefined)

  const claudeSDK = packageLock.packages['node_modules/@anthropic-ai/claude-agent-sdk']
  const mcpSDK = packageLock.packages[`node_modules/${mcpSDKPackageName}`]
  const honoServer = packageLock.packages['node_modules/@hono/node-server']
  assert.match(claudeSDK.peerDependencies[mcpSDKPackageName], /^\^1\./)
  assert.match(mcpSDK.dependencies.hono, /^\^4\./)
  assert.match(mcpSDK.dependencies['@hono/node-server'], /\^2\./)
  assert.match(honoServer.peerDependencies.hono, /^\^4$/)

  const importPattern =
    /(?:require\s*\(\s*|from\s+|import\s+|import\s*\(\s*)['"](?:hono|@hono\/node-server)(?:\/[^'"]*)?['"]/
  const importedBy = ['runtime', 'scripts']
    .flatMap((directory) => productionJavaScriptFiles(path.join(repoRoot, directory)))
    .filter((filePath) => importPattern.test(fs.readFileSync(filePath, 'utf8')))
    .map((filePath) => path.relative(repoRoot, filePath))
  assert.deepEqual(
    importedBy,
    [],
    `first-party production code unexpectedly made Hono reachable: ${importedBy.join(', ')}`
  )

  const helperPackager = fs.readFileSync(
    path.join(repoRoot, 'scripts/native-broker-package.cjs'),
    'utf8'
  )
  assert.doesNotMatch(helperPackager, /node_modules['"],\s*['"]hono|@hono\/node-server/)
})

test('the security inventory names every advisory and bundled Hono surface', () => {
  const inventory = fs.readFileSync(
    path.join(repoRoot, 'docs/security/hono-reachability.md'),
    'utf8'
  )
  for (const advisory of [
    'GHSA-8j4g-w8fx-2239',
    'GHSA-f23p-vx2j-j53r',
    'GHSA-79qm-7rj5-m7r9',
    'GHSA-54fx-42gc-7vw4',
  ]) {
    assert.match(inventory, new RegExp(advisory))
  }
  for (const surface of [
    'hono',
    '@hono/node-server',
    'hono/cors',
    'hono/jsx',
    'hono/proxy',
    'hono/language',
  ]) {
    assert.ok(inventory.includes(`\`${surface}\``), `inventory omitted ${surface}`)
  }
  assert.match(inventory, /does not instantiate Hono or open a Hono listener/)
})

test(
  'patched CORS parsing handles an adversarial preflight header without a regex backtrack',
  { skip: !patchedHonoIsInstalled },
  async () => {
    const { Hono } = await import('hono')
    const { cors } = await import('hono/cors')
    const app = new Hono()
    app.use('/api/*', cors())
    app.get('/api/abc', (context) => context.text('ok'))

    const request = new Request('https://localhost/api/abc', { method: 'OPTIONS' })
    request.headers.set('Access-Control-Request-Headers', `x${' '.repeat(200_000)}x`)
    const response = await app.request(request)
    assert.equal(response.status, 204)
  }
)

test(
  'patched JSX memo output is isolated between render requests',
  { skip: !patchedHonoIsInstalled },
  async () => {
    const { memo } = await import('hono/jsx')
    let requestIdentity = 'alice'
    const identityPanel = memo(() => `<p>${requestIdentity}</p>`)

    assert.equal(String(identityPanel({})), '<p>alice</p>')
    requestIdentity = 'bob'
    assert.equal(String(identityPanel({})), '<p>bob</p>')
  }
)

test(
  'patched proxy filtering strips connection-scoped response headers',
  { skip: !patchedHonoIsInstalled },
  async () => {
    const { proxy } = await import('hono/proxy')
    const response = await proxy('https://example.test/connection-listed', {
      customFetch: async () =>
        new Response('ok', {
          headers: {
            Connection: 'x-connection-scoped, bad name',
            'X-Connection-Scoped': 'must not escape the upstream hop',
            'X-Normal': 'kept',
          },
        }),
    })

    assert.equal(response.headers.get('connection'), null)
    assert.equal(response.headers.get('x-connection-scoped'), null)
    assert.equal(response.headers.get('x-normal'), 'kept')
  }
)

test(
  'patched language lookup handles adversarial tags and chooses the longest prefix',
  { skip: !patchedHonoIsInstalled },
  async () => {
    const { Hono } = await import('hono')
    const { languageDetector } = await import('hono/language')
    const app = new Hono()
    app.use(
      '*',
      languageDetector({
        supportedLanguages: ['en', 'zh', 'zh-Hant'],
        fallbackLanguage: 'en',
        order: ['header'],
      })
    )
    app.get('*', (context) => context.text(context.get('language')))

    const longestMatch = await app.request('/', {
      headers: { 'accept-language': 'zh-Hant-CN' },
    })
    assert.equal(await longestMatch.text(), 'zh-Hant')

    const adversarialTag = 'x-'.repeat(30_000).slice(0, -1)
    const fallback = await app.request('/', {
      headers: { 'accept-language': adversarialTag },
    })
    assert.equal(await fallback.text(), 'en')
  }
)
