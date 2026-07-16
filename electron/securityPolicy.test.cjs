const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { pathToFileURL } = require('node:url')

const {
  hardenWebviewAttachment,
  installPermissionPolicy,
  isSafeWebUrl,
  isTrustedRendererUrl,
  terminalOwnerAllowed,
  terminalOwnerParts,
} = require('./ipc/securityPolicy.cjs')

const rendererFile = path.resolve('/tmp/kaisola-dist/index.html')
const rendererUrl = pathToFileURL(rendererFile).href

test('privileged renderer trust is exact in production and origin-bound in development', () => {
  assert.equal(isTrustedRendererUrl(`${rendererUrl}?win=2`, { rendererFile }), true)
  assert.equal(isTrustedRendererUrl(pathToFileURL(path.resolve('/tmp/kaisola-dist/other.html')).href, { rendererFile }), false)
  assert.equal(isTrustedRendererUrl('https://example.com/', { rendererFile }), false)

  const dev = { devUrl: 'http://127.0.0.1:5173/', rendererFile }
  assert.equal(isTrustedRendererUrl('http://127.0.0.1:5173/?win=2', dev), true)
  assert.equal(isTrustedRendererUrl('http://127.0.0.1:5174/', dev), false)
  assert.equal(isTrustedRendererUrl('http://127.0.0.1:5173.example.com/', dev), false)
})

test('permission policy denies browser content and only allows trusted main-frame clipboard writes', () => {
  const handlers = {}
  const fakeSession = {
    setPermissionCheckHandler: (handler) => { handlers.check = handler },
    setPermissionRequestHandler: (handler) => { handlers.request = handler },
    setDevicePermissionHandler: (handler) => { handlers.device = handler },
    setDisplayMediaRequestHandler: (handler) => { handlers.display = handler },
  }
  const trusted = { getURL: () => rendererUrl }
  const hostile = { getURL: () => 'https://hostile.example/' }
  installPermissionPolicy(fakeSession, {
    allowTrustedRenderer: true,
    trustedContents: new Set([trusted]),
    rendererFile,
  })

  assert.equal(handlers.check(trusted, 'clipboard-sanitized-write', rendererUrl, { requestingUrl: rendererUrl, isMainFrame: true }), true)
  assert.equal(handlers.check(trusted, 'media', rendererUrl, { requestingUrl: rendererUrl, isMainFrame: true }), false)
  assert.equal(handlers.check(trusted, 'clipboard-sanitized-write', 'https://hostile.example/', { requestingUrl: 'https://hostile.example/', isMainFrame: false }), false)
  assert.equal(handlers.check(hostile, 'clipboard-sanitized-write', rendererUrl, { requestingUrl: rendererUrl, isMainFrame: true }), false)
  assert.equal(handlers.device({}), false)

  let granted = null
  handlers.request(trusted, 'clipboard-sanitized-write', (value) => { granted = value }, { requestingUrl: rendererUrl, isMainFrame: true })
  assert.equal(granted, true)
  handlers.request(trusted, 'notifications', (value) => { granted = value }, { requestingUrl: rendererUrl, isMainFrame: true })
  assert.equal(granted, false)
  handlers.display({}, (streams) => { granted = streams })
  assert.deepEqual(granted, {})
})

test('webview attachment is restricted to http(s), the browser partition, and safe preferences', () => {
  const preferences = { preload: '/tmp/hostile.cjs', nodeIntegration: true, webSecurity: false, plugins: true }
  const params = { src: 'https://example.com/', partition: 'persist:browser', preload: '/tmp/hostile.cjs' }
  assert.equal(hardenWebviewAttachment(preferences, params), true)
  assert.equal('preload' in preferences, false)
  assert.equal('preload' in params, false)
  assert.equal(preferences.nodeIntegration, false)
  assert.equal(preferences.contextIsolation, true)
  assert.equal(preferences.sandbox, true)
  assert.equal(preferences.webSecurity, true)
  assert.equal(preferences.plugins, false)
  assert.equal(preferences.backgroundThrottling, true)

  assert.equal(hardenWebviewAttachment({}, { src: 'file:///etc/passwd', partition: 'persist:browser' }), false)
  assert.equal(hardenWebviewAttachment({}, { src: 'https://example.com/', partition: 'persist:other' }), false)
  assert.equal(isSafeWebUrl('httpx://example.com/'), false)
})

test('terminal broker ownership isolates projects and makes handoff explicit', () => {
  const base = { requestOwner: 'app-a|11|project-one', requestProject: 'project-one' }
  assert.deepEqual(terminalOwnerParts(base.requestOwner), { instanceId: 'app-a', ownerId: '11', projectId: 'project-one' })
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: 'app-a|11|project-one' }), true)

  // A second renderer in the same project cannot inventory or operate a live
  // terminal. Only attach/create may explicitly transfer its capability.
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: 'app-a|12|project-one' }), false)
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: 'app-a|12|project-one', adopt: true }), true)

  // Project scope survives both renderer swaps and a whole Electron-main
  // restart, but can never be crossed by a guessed terminal id.
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: 'app-b|12|project-one', adopt: true }), true)
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: 'app-b|12|project-two', adopt: true }), false)

  // Socket/window loss leaves only lastOwner. It is invisible and inert until
  // an explicit same-project attach/create adopts it.
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: '', recordLastOwner: 'app-b|12|project-one' }), false)
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: '', recordLastOwner: 'app-b|12|project-one', adopt: true }), true)
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: '', recordLastOwner: 'app-b|12|project-two', adopt: true }), false)

  // A caller cannot claim a project that disagrees with its durable owner key.
  assert.equal(terminalOwnerAllowed({ ...base, requestProject: 'project-two', recordOwner: base.requestOwner }), false)
  assert.equal(terminalOwnerAllowed({ ...base, recordOwner: 'app-b|12|project-two', admin: true }), true)
})
