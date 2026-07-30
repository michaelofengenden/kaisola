'use strict'

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const test = require('node:test')

const script = path.join(__dirname, '..', '..', 'scripts', 'native-appcast.cjs')
const signUpdate = path.join(__dirname, '..', 'fixtures', 'native-sign-update.sh')
const signature = 'paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpQ=='
const otherSignature = Buffer.alloc(64, 0x5A).toString('base64')

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-native-appcast-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const zip = path.join(root, 'Kaisola.zip')
  const output = path.join(root, 'appcast.xml')
  const key = path.join(root, 'sparkle-private-key')
  fs.writeFileSync(zip, 'native-zip-fixture\n')
  fs.writeFileSync(key, 'fixture key\n', { mode: 0o600 })
  return { root, zip, output, key }
}

function args(paths, overrides = {}) {
  const values = {
    version: '1.2.3',
    build: '42',
    url: 'https://github.com/michaelofengenden/kaisola/releases/download/v1.2.3/Kaisola-1.2.3.zip',
    ...overrides,
  }
  return [
    '--zip', paths.zip,
    '--version', values.version,
    '--build', values.build,
    '--url', values.url,
    '--sign-update', signUpdate,
    '--output', paths.output,
    ...(values.existing ? ['--existing', values.existing] : []),
    ...(values.minimumSystemVersion ? ['--min-system', values.minimumSystemVersion] : []),
    ...(values.edKeyFile ? ['--ed-key-file', values.edKeyFile] : []),
  ]
}

function run(arguments_, environment = {}) {
  return spawnSync(process.execPath, [script, ...arguments_], {
    encoding: 'utf8',
    env: { ...process.env, ...environment },
  })
}

function existingAppcast(items) {
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Existing updates</title>
${items.join('\n')}
  </channel>
</rss>
`
}

function existingItem({ build, itemSignature, title = `Old ${build}`, url = `https://example.com/${build}.zip`, marker = '' }) {
  return `    <item>
      <title>${title}</title>
      <pubDate>Tue, 21 Jul 2026 12:00:00 GMT</pubDate>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>1.0.${build}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      ${marker}
      <enclosure url="${url}" length="17" type="application/octet-stream" sparkle:edSignature="${itemSignature}"/>
    </item>`
}

test('native appcast generates a fresh signed RSS feed and passes through an Ed25519 key file', (t) => {
  const paths = fixture(t)
  const result = run(args(paths, { edKeyFile: paths.key }), { EXPECTED_ED_KEY_FILE: paths.key })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /NATIVE_APPCAST=.*"itemCount":1/)

  const xml = fs.readFileSync(paths.output, 'utf8')
  assert.match(xml, /<rss version="2\.0" xmlns:sparkle="http:\/\/www\.andymatuschak\.org\/xml-namespaces\/sparkle">/)
  assert.match(xml, /<title>Kaisola 1\.2\.3<\/title>/)
  const pubDate = xml.match(/<pubDate>([^<]+)<\/pubDate>/)?.[1]
  assert.ok(pubDate)
  assert.ok(Number.isFinite(Date.parse(pubDate)))
  assert.match(xml, /<sparkle:version>42<\/sparkle:version>/)
  assert.match(xml, /<sparkle:shortVersionString>1\.2\.3<\/sparkle:shortVersionString>/)
  assert.match(xml, /<sparkle:minimumSystemVersion>14\.0<\/sparkle:minimumSystemVersion>/)
  assert.match(xml, new RegExp(`<enclosure url="https://github\\.com/[^\"]+" length="19" type="application/octet-stream" sparkle:edSignature="${signature}"/>`))
})

test('native appcast merge preserves older items and sorts newest build first', (t) => {
  const paths = fixture(t)
  const existing = path.join(paths.root, 'existing.xml')
  fs.writeFileSync(existing, existingAppcast([
    existingItem({ build: '7', itemSignature: otherSignature, marker: '<description>preserve this item</description>' }),
  ]))

  const result = run(args(paths, { build: '42', existing }))
  assert.equal(result.status, 0, result.stderr)
  const xml = fs.readFileSync(paths.output, 'utf8')
  assert.match(xml, /<description>preserve this item<\/description>/)
  assert.ok(xml.indexOf('<sparkle:version>42</sparkle:version>') < xml.indexOf('<sparkle:version>7</sparkle:version>'))
})

test('native appcast replaces the same build when its signature is unchanged', (t) => {
  const paths = fixture(t)
  const existing = path.join(paths.root, 'existing.xml')
  fs.writeFileSync(existing, existingAppcast([
    existingItem({
      build: '42',
      itemSignature: signature,
      title: 'obsolete title',
      url: 'https://example.com/obsolete.zip',
    }),
  ]))

  const result = run(args(paths, { existing, minimumSystemVersion: '14.2' }))
  assert.equal(result.status, 0, result.stderr)
  const xml = fs.readFileSync(paths.output, 'utf8')
  assert.equal(xml.match(/<sparkle:version>42<\/sparkle:version>/g)?.length, 1)
  assert.doesNotMatch(xml, /obsolete title|obsolete\.zip/)
  assert.match(xml, /<sparkle:minimumSystemVersion>14\.2<\/sparkle:minimumSystemVersion>/)
})

test('native appcast rejects missing signature output', (t) => {
  const paths = fixture(t)
  const result = run(args(paths), { NATIVE_SIGN_UPDATE_STUB_MODE: 'missing' })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /did not return sparkle:edSignature and length/)
  assert.equal(fs.existsSync(paths.output), false)
})

test('native appcast rejects a failed sign_update process', (t) => {
  const paths = fixture(t)
  const result = run(args(paths), { NATIVE_SIGN_UPDATE_STUB_MODE: 'fail' })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /sign_update failed with exit code 9: fixture sign_update failure/)
  assert.equal(fs.existsSync(paths.output), false)
})

test('native appcast rejects non-HTTPS enclosure URLs', (t) => {
  const paths = fixture(t)
  const result = run(args(paths, { url: 'http://example.com/Kaisola.zip' }))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /enclosure URL must use HTTPS/)
})

test('native appcast rejects enclosure URLs with credentials', (t) => {
  const paths = fixture(t)
  const result = run(args(paths, { url: 'https://user:secret@example.com/Kaisola.zip' }))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /enclosure URL must not contain credentials/)
})

test('native appcast rejects enclosure URLs with fragments', (t) => {
  const paths = fixture(t)
  const result = run(args(paths, { url: 'https://example.com/Kaisola.zip#replacement' }))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /enclosure URL must not contain a fragment/)
})

test('native appcast rejects a duplicate build with a different signature', (t) => {
  const paths = fixture(t)
  const existing = path.join(paths.root, 'existing.xml')
  fs.writeFileSync(existing, existingAppcast([
    existingItem({ build: '42', itemSignature: otherSignature }),
  ]))

  const result = run(args(paths, { existing }))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /refusing to replace build 42 with a different Sparkle signature/)
  assert.equal(fs.existsSync(paths.output), false)
})

test('native appcast rejects an unparseable existing appcast', (t) => {
  const paths = fixture(t)
  const existing = path.join(paths.root, 'broken.xml')
  fs.writeFileSync(existing, '<rss><channel><item></channel></rss>')

  const result = run(args(paths, { existing }))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /could not parse existing appcast: mismatched closing tag/)
  assert.equal(fs.existsSync(paths.output), false)
})

test('native appcast refuses an output path that aliases the zip', (t) => {
  const paths = fixture(t)
  const result = run([
    '--zip', paths.zip,
    '--version', '1.2.3',
    '--build', '42',
    '--url', 'https://example.com/Kaisola.zip',
    '--sign-update', signUpdate,
    '--output', paths.zip,
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /--output must not overwrite the --zip input/)
  assert.notEqual(fs.readFileSync(paths.zip, 'utf8').length, 0)
})

test('native appcast rejects an existing feed carrying duplicate builds', (t) => {
  const paths = fixture(t)
  const existing = path.join(paths.root, 'existing.xml')
  fs.writeFileSync(existing, existingAppcast([
    existingItem({ build: '7' }),
    existingItem({ build: '7' }),
  ]))

  const result = run(args(paths, { existing }))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /already contains build 7 more than once/)
  assert.equal(fs.existsSync(paths.output), false)
})
