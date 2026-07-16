const path = require('node:path')
const { fileURLToPath } = require('node:url')

// The desktop renderer only needs sanitized clipboard writes. Everything else
// (notifications, file access, terminals, external URLs) already crosses an
// explicit main-process bridge and must not be granted by Chromium implicitly.
const TRUSTED_RENDERER_PERMISSIONS = new Set(['clipboard-sanitized-write'])

function parsedUrl(value) {
  try { return new URL(String(value || '')) } catch { return null }
}

function isSafeWebUrl(value) {
  const url = parsedUrl(value)
  return !!url && (url.protocol === 'http:' || url.protocol === 'https:')
}

function isTrustedRendererUrl(value, { devUrl, rendererFile } = {}) {
  const url = parsedUrl(value)
  if (!url) return false
  if (devUrl) {
    const dev = parsedUrl(devUrl)
    return !!dev && url.origin === dev.origin && (url.protocol === 'http:' || url.protocol === 'https:')
  }
  if (url.protocol !== 'file:' || !rendererFile) return false
  try { return path.resolve(fileURLToPath(url)) === path.resolve(rendererFile) } catch { return false }
}

function rendererPermissionAllowed({
  allowTrustedRenderer,
  trustedContents,
  webContents,
  permission,
  requestingUrl,
  isMainFrame,
  devUrl,
  rendererFile,
}) {
  if (!allowTrustedRenderer || !webContents || !trustedContents?.has(webContents)) return false
  if (isMainFrame !== true || !TRUSTED_RENDERER_PERMISSIONS.has(permission)) return false
  let currentUrl = ''
  try { currentUrl = webContents.getURL() } catch { return false }
  return isTrustedRendererUrl(currentUrl, { devUrl, rendererFile }) &&
    isTrustedRendererUrl(requestingUrl, { devUrl, rendererFile })
}

function installPermissionPolicy(ses, options = {}) {
  const decide = (webContents, permission, requestingUrl, isMainFrame) => rendererPermissionAllowed({
    ...options,
    webContents,
    permission,
    requestingUrl,
    isMainFrame,
  })

  ses.setPermissionCheckHandler((webContents, permission, requestingOrigin, details = {}) => decide(
    webContents,
    permission,
    details.requestingUrl || details.securityOrigin || requestingOrigin,
    details.isMainFrame,
  ))
  ses.setPermissionRequestHandler((webContents, permission, callback, details = {}) => {
    callback(decide(webContents, permission, details.requestingUrl, details.isMainFrame))
  })
  // Device-selection and display-capture have additional grant paths outside
  // the generic permission handlers. Keep those fail-closed too.
  ses.setDevicePermissionHandler?.(() => false)
  ses.setDisplayMediaRequestHandler?.((_request, callback) => callback({}))
}

function hardenWebviewAttachment(webPreferences, params) {
  delete webPreferences.preload
  delete params.preload
  webPreferences.nodeIntegration = false
  webPreferences.nodeIntegrationInWorker = false
  webPreferences.nodeIntegrationInSubFrames = false
  webPreferences.contextIsolation = true
  webPreferences.sandbox = true
  webPreferences.webSecurity = true
  webPreferences.allowRunningInsecureContent = false
  webPreferences.webviewTag = false
  webPreferences.plugins = false
  // A hidden guest should stop timers/painting while React tears it down.
  // Explicit guest release in main remains the authoritative lifecycle gate.
  webPreferences.backgroundThrottling = true
  if (params.partition !== 'persist:browser' || !isSafeWebUrl(params.src)) return false
  params.partition = 'persist:browser'
  return true
}

/** Decode the durable broker owner key. New keys carry
 * `<app instance>|<webContents>|<project>`; two-part keys are old, unscoped
 * records retained only for upgrade compatibility. Project ids are validated
 * before an owner key is made, so `|` is never ambiguous here. */
function terminalOwnerParts(owner) {
  const text = String(owner || '')
  const first = text.indexOf('|')
  if (first <= 0) return null
  const second = text.indexOf('|', first + 1)
  if (second < 0) {
    return {
      instanceId: text.slice(0, first),
      ownerId: text.slice(first + 1),
      projectId: 'legacy',
    }
  }
  const instanceId = text.slice(0, first)
  const ownerId = text.slice(first + 1, second)
  const projectId = text.slice(second + 1)
  return instanceId && ownerId && projectId ? { instanceId, ownerId, projectId } : null
}

/** Terminal ids remain unguessable capabilities, but a live renderer may use
 * only its exact owner key. A renderer swap/pop-out must perform the explicit
 * attach/create handoff and may do so only inside the same project. Once an app
 * socket/window dies the active owner is blank; its last project can likewise
 * be adopted only by attach/create. Ordinary operations and inventory never
 * adopt detached terminals implicitly. */
function terminalOwnerAllowed({
  recordOwner,
  recordLastOwner,
  requestOwner,
  requestProject,
  adopt = false,
  admin = false,
}) {
  if (admin) return true
  if (!requestOwner || !requestProject) return false
  const requester = terminalOwnerParts(requestOwner)
  // The broker constructs this tuple, but keep the policy independently
  // fail-closed: a mismatched claimed project must never widen an owner key.
  if (!requester || requester.projectId !== requestProject) return false
  if (recordOwner === requestOwner) return true
  if (!adopt) return false
  const prior = terminalOwnerParts(recordOwner || recordLastOwner)
  return !!prior && prior.projectId === requestProject
}

module.exports = {
  hardenWebviewAttachment,
  installPermissionPolicy,
  isSafeWebUrl,
  isTrustedRendererUrl,
  rendererPermissionAllowed,
  terminalOwnerAllowed,
  terminalOwnerParts,
}
