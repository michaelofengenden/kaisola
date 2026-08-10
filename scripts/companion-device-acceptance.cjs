#!/usr/bin/env node
'use strict'

const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const util = require('node:util')
const { spawnSync } = require('node:child_process')

const SCHEMA_VERSION = 1
const OBSERVATION_KIND = 'kaisola-companion-real-device-observations'
const IPHONE_BUILD_KIND = 'kaisola-companion-iphone-build'
const RECEIPT_KIND = 'kaisola-companion-real-device-acceptance'
const MAC_BUNDLE_IDENTIFIER = 'com.kaisola.mac'
const IPHONE_BUNDLE_IDENTIFIER = 'com.kaisola.companion'
const REQUIRED_ARCHITECTURES = Object.freeze(['arm64'])
const MAX_EVIDENCE_FILES = 128
const MAX_TEXT_EVIDENCE_BYTES = 5 * 1024 * 1024
const MAX_IMAGE_EVIDENCE_BYTES = 25 * 1024 * 1024
const MAX_TOTAL_EVIDENCE_BYTES = 250 * 1024 * 1024
const MAX_EVIDENCE_ENTRIES = 512
const MAX_JSON_BYTES = 5 * 1024 * 1024
const HEX_256 = /^[0-9a-f]{64}$/u
const SOURCE_COMMIT = /^[0-9a-f]{40}$/u
const TEAM_IDENTIFIER = /^[A-Z0-9]{10}$/u
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
const VERSION = /^\d+(?:\.\d+){1,2}$/u
const MAC_MODEL_IDENTIFIER = /^(?:Mac(?:Book(?:Air|Pro)?|mini|Pro|Studio)?|iMac(?:Pro)?)\d{1,3},\d{1,3}$/u
const IPHONE_MODEL_IDENTIFIER = /^iPhone\d{1,3},\d{1,3}$/u

const PAIRING_TRANSCRIPT = Object.freeze([
  'pair.start',
  'pair.message2',
  'pair.message3',
  'pair.confirmation',
  'sas-confirm.iphone',
  'sas-confirm.mac',
  'paired',
])

const SCENARIO_SPECS = Object.freeze({
  qr: Object.freeze({ expected: 'paired', positive: true, rendezvous: 'not-used' }),
  manualCode: Object.freeze({ expected: 'paired', positive: true, rendezvous: 'not-used' }),
  accountRendezvous: Object.freeze({
    expected: 'paired',
    positive: true,
    rendezvous: 'same-account-offer-claimed',
  }),
  userCancellation: Object.freeze({ expected: 'cancelled-without-pairing', positive: false }),
  malformedOffer: Object.freeze({ expected: 'rejected-malformed-offer', positive: false }),
  staleOffer: Object.freeze({ expected: 'rejected-expired-offer', positive: false }),
  wrongAccount: Object.freeze({ expected: 'rejected-account-mismatch', positive: false }),
  protocolVersionMismatch: Object.freeze({ expected: 'rejected-protocol-mismatch', positive: false }),
})

const EVIDENCE_KINDS = Object.freeze([
  'mac-log',
  'iphone-log',
  'screenshot',
  'screenshot-ocr',
  'pasteboard-audit',
  'analytics-audit',
  'operator-note',
])

function fail(message) {
  throw new Error(message)
}

function plainObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`)
  return value
}

function exactKeys(value, keys, label) {
  plainObject(value, label)
  const actual = Object.keys(value).sort()
  const expected = [...keys].sort()
  if (!util.isDeepStrictEqual(actual, expected)) {
    fail(`${label} fields must be exactly ${expected.join(', ')}`)
  }
}

function string(value, label, pattern = null) {
  if (typeof value !== 'string' || !value || (pattern && !pattern.test(value))) fail(`${label} is invalid`)
  return value
}

function positiveInteger(value, label) {
  const number = typeof value === 'string' && /^[1-9]\d*$/u.test(value) ? Number(value) : value
  if (!Number.isSafeInteger(number) || number <= 0) fail(`${label} must be a positive integer`)
  return number
}

function canonicalDate(value, label) {
  const date = new Date(value)
  if (typeof value !== 'string' || Number.isNaN(date.valueOf()) || date.toISOString() !== value) {
    fail(`${label} must be canonical ISO-8601 UTC`)
  }
  return value
}

function exactArray(value, expected, label) {
  if (!Array.isArray(value) || !util.isDeepStrictEqual(value, expected)) {
    fail(`${label} must be exactly ${expected.join(', ')}`)
  }
  return [...expected]
}

function requireHex256(value, label) {
  return string(value, label, HEX_256)
}

function parseArguments(argv) {
  const command = argv[0]
  if (command === '--help' || command === '-h') return { help: true }
  if (!['inspect-ios', 'seal', 'verify'].includes(command)) {
    fail('first argument must be inspect-ios, seal, or verify')
  }
  const options = { command }
  const keys = {
    '--app': 'app',
    '--source-commit': 'sourceCommit',
    '--mac-preflight': 'macPreflight',
    '--iphone-build': 'iphoneBuild',
    '--observations': 'observations',
    '--evidence-directory': 'evidenceDirectory',
    '--receipt': 'receipt',
    '--output': 'output',
  }
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      options.help = true
      continue
    }
    const key = keys[argument]
    if (!key) fail(`unknown argument: ${argument}`)
    if (options[key] !== undefined) fail(`duplicate argument: ${argument}`)
    const value = argv[++index]
    if (!value || value.startsWith('--')) fail(`${argument} requires a value`)
    options[key] = key === 'sourceCommit' ? value : path.resolve(value)
  }
  if (options.help) return options
  const allowed = {
    'inspect-ios': new Set(['command', 'app', 'sourceCommit', 'output']),
    seal: new Set([
      'command', 'macPreflight', 'iphoneBuild', 'observations', 'evidenceDirectory', 'output',
    ]),
    verify: new Set([
      'command', 'receipt', 'macPreflight', 'iphoneBuild', 'observations', 'evidenceDirectory',
    ]),
  }[command]
  for (const key of Object.keys(options)) {
    if (!allowed.has(key)) fail(`--${key.replace(/[A-Z]/gu, (letter) => `-${letter.toLowerCase()}`)} is not valid for ${command}`)
  }
  if (options.sourceCommit && !SOURCE_COMMIT.test(options.sourceCommit)) {
    fail('--source-commit must be a lowercase 40-character Git commit')
  }
  const required = command === 'inspect-ios'
    ? ['app', 'sourceCommit', 'output']
    : command === 'seal'
      ? ['macPreflight', 'iphoneBuild', 'observations', 'evidenceDirectory', 'output']
      : ['receipt', 'macPreflight', 'iphoneBuild', 'observations', 'evidenceDirectory']
  for (const key of required) {
    if (!options[key]) fail(`--${key.replace(/[A-Z]/gu, (letter) => `-${letter.toLowerCase()}`)} is required`)
  }
  return options
}

function usage() {
  return `Usage:
  node scripts/companion-device-acceptance.cjs inspect-ios \\
    --app /path/KaisolaCompanion.app --source-commit <40-hex> \\
    --output iphone-build.json

  node scripts/companion-device-acceptance.cjs seal \\
    --mac-preflight mac-preflight.json --iphone-build iphone-build.json \\
    --observations observations.json --evidence-directory evidence \\
    --output companion-device-acceptance.json

  node scripts/companion-device-acceptance.cjs verify \\
    --receipt companion-device-acceptance.json \\
    --mac-preflight mac-preflight.json --iphone-build iphone-build.json \\
    --observations observations.json --evidence-directory evidence

The tool never pairs a Simulator or treats a checklist as physical-device
evidence. It accepts no credential, private-key, device-identifier, or token
argument.`
}

function runCommand(executable, arguments_, options = {}) {
  const result = spawnSync(executable, arguments_, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  })
  if (result.error) throw result.error
  const output = `${result.stdout || ''}${result.stderr || ''}`.trim()
  if (result.status !== 0) {
    fail(`${path.basename(executable)} ${arguments_[0] || ''} failed${output ? `: ${output}` : ''}`)
  }
  return output
}

function readPlist(file, run = runCommand) {
  return JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file]))
}

function parseCodeSignature(output) {
  const authorities = [...String(output).matchAll(/^Authority=(.+)$/gmu)].map((match) => match[1].trim())
  const rawTeam = String(output).match(/^TeamIdentifier=(.+)$/mu)?.[1]?.trim() || null
  return {
    authorities,
    teamIdentifier: rawTeam === 'not set' ? null : rawTeam,
  }
}

function parseEntitlements(output, run = runCommand) {
  const text = String(output).trim()
  try {
    const parsed = JSON.parse(text)
    return plainObject(parsed, 'iPhone entitlements')
  } catch {}
  const start = text.indexOf('<?xml')
  const end = text.lastIndexOf('</plist>')
  if (start < 0 || end < start) fail('codesign returned no readable iPhone entitlements')
  return JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '--', '-'], {
    input: text.slice(start, end + '</plist>'.length),
  }))
}

function sha256Buffer(value) {
  return crypto.createHash('sha256').update(value).digest('hex')
}

function sha256File(file) {
  const hash = crypto.createHash('sha256')
  const descriptor = fs.openSync(file, 'r')
  const buffer = Buffer.allocUnsafe(1024 * 1024)
  try {
    for (;;) {
      const count = fs.readSync(descriptor, buffer, 0, buffer.length, null)
      if (!count) break
      hash.update(buffer.subarray(0, count))
    }
  } finally {
    fs.closeSync(descriptor)
  }
  return hash.digest('hex')
}

function readBoundedRegularFile(file, label, limit) {
  const initial = fs.lstatSync(file)
  if (initial.isSymbolicLink()) fail(`${label} must not be a symbolic link`)
  if (!initial.isFile() || initial.size <= 0) fail(`${label} must be a non-empty regular file`)
  let descriptor
  try {
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW)
  } catch (error) {
    if (error.code === 'ELOOP') fail(`${label} must not be a symbolic link`)
    throw error
  }
  try {
    const before = fs.fstatSync(descriptor)
    if (!before.isFile() || before.size <= 0) fail(`${label} must be a non-empty regular file`)
    if (before.size > limit) fail(`${label} exceeds its ${limit}-byte bound`)
    const buffer = fs.readFileSync(descriptor)
    const after = fs.fstatSync(descriptor)
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || buffer.length !== after.size) {
      fail(`${label} changed while it was being read`)
    }
    return buffer
  } finally {
    fs.closeSync(descriptor)
  }
}

function safeRelativePath(root, candidate, label) {
  const relative = path.relative(root, candidate)
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${label} escapes its declared root`)
  }
  return relative.split(path.sep).join('/')
}

function canonicalFuturePath(value) {
  let current = path.resolve(value)
  const suffix = []
  while (!fs.existsSync(current)) {
    const parent = path.dirname(current)
    if (parent === current) fail(`could not resolve output path: ${value}`)
    suffix.unshift(path.basename(current))
    current = parent
  }
  return path.join(fs.realpathSync(current), ...suffix)
}

function requireOutputOutside(root, output, label) {
  const canonicalRoot = canonicalFuturePath(root)
  const canonicalOutput = canonicalFuturePath(output)
  const relative = path.relative(canonicalRoot, canonicalOutput)
  if (!relative || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))) {
    fail(`receipt output must stay outside ${label}`)
  }
  return true
}

function bundleInventory(root) {
  const rootStat = fs.lstatSync(root)
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) fail('iPhone app must be a real application directory')
  const canonicalRoot = fs.realpathSync(root)
  const pending = [root]
  const entries = []
  while (pending.length) {
    const directory = pending.pop()
    for (const name of fs.readdirSync(directory).sort()) {
      if (/\r|\n|\0/u.test(name)) fail('iPhone app contains a path with control characters')
      const absolute = path.join(directory, name)
      const relative = safeRelativePath(root, absolute, 'iPhone app entry')
      const stat = fs.lstatSync(absolute)
      const mode = (stat.mode & 0o777).toString(8).padStart(3, '0')
      if (stat.isSymbolicLink()) {
        const resolved = fs.realpathSync(absolute)
        safeRelativePath(canonicalRoot, resolved, 'iPhone app symlink')
        entries.push(`L\0${relative}\0${mode}\0${fs.readlinkSync(absolute)}`)
      } else if (stat.isDirectory()) {
        entries.push(`D\0${relative}\0${mode}`)
        pending.push(absolute)
      } else if (stat.isFile()) {
        entries.push(`F\0${relative}\0${mode}\0${stat.size}\0${sha256File(absolute)}`)
      } else {
        fail(`iPhone app contains unsupported entry: ${relative}`)
      }
      if (entries.length > 100_000) fail('iPhone app inventory exceeds 100000 entries')
    }
  }
  entries.sort()
  return { bundleDigest: sha256Buffer(Buffer.from(`${entries.join('\n')}\n`)), fileCount: entries.length }
}

function validateIPhoneInspection(input) {
  const info = plainObject(input.info, 'iPhone Info.plist')
  const signature = plainObject(input.signature, 'iPhone code signature')
  const entitlements = plainObject(input.entitlements, 'iPhone entitlements')
  const sourceCommit = string(input.sourceCommit, 'iPhone source commit', SOURCE_COMMIT)
  if (info.CFBundleIdentifier !== IPHONE_BUNDLE_IDENTIFIER) fail('unexpected iPhone bundle identifier')
  const version = string(info.CFBundleShortVersionString, 'iPhone version', VERSION)
  const build = String(positiveInteger(info.CFBundleVersion, 'iPhone build'))
  const minimumOSVersion = string(info.MinimumOSVersion, 'iPhone minimum OS version', VERSION)
  exactArray(info.CFBundleSupportedPlatforms, ['iPhoneOS'], 'iPhone device platform')
  const architectures = exactArray(input.architectures, REQUIRED_ARCHITECTURES, 'iPhone architectures')
  const teamIdentifier = string(signature.teamIdentifier, 'iPhone signing team', TEAM_IDENTIFIER)
  const authorities = Array.isArray(signature.authorities) ? signature.authorities : []
  const development = authorities.some((authority) => /^Apple Development:/u.test(authority))
  const distribution = authorities.some((authority) => /^Apple Distribution:/u.test(authority))
  if (!development && !distribution) fail('iPhone app requires an Apple development or distribution signature')
  if (entitlements['application-identifier'] !== `${teamIdentifier}.${IPHONE_BUNDLE_IDENTIFIER}`
      || entitlements['com.apple.developer.team-identifier'] !== teamIdentifier) {
    fail('iPhone signing entitlements do not bind the bundle to its signing team')
  }
  const getTaskAllow = entitlements['get-task-allow'] === true
  const executableSHA256 = requireHex256(input.executableSHA256, 'iPhone executable SHA-256')
  const provisioningProfileSHA256 = requireHex256(
    input.provisioningProfileSHA256,
    'iPhone provisioning profile SHA-256',
  )
  const bundleDigest = requireHex256(input.bundleDigest, 'iPhone bundle digest')
  const fileCount = positiveInteger(input.fileCount, 'iPhone bundle file count')
  return {
    schemaVersion: SCHEMA_VERSION,
    kind: IPHONE_BUILD_KIND,
    pass: true,
    sourceCommit,
    bundleIdentifier: IPHONE_BUNDLE_IDENTIFIER,
    version,
    build,
    minimumOSVersion,
    teamIdentifier,
    signatureKind: distribution ? 'apple-distribution' : 'apple-development',
    getTaskAllow,
    architectures,
    executableSHA256,
    provisioningProfileSHA256,
    bundleDigest,
    fileCount,
  }
}

function inspectIPhoneApp(options, dependencies = {}) {
  const run = dependencies.run || runCommand
  const plistReader = dependencies.readPlist || ((file) => readPlist(file, run))
  const app = path.resolve(string(options.app, 'iPhone app path'))
  const appStat = fs.lstatSync(app)
  if (!appStat.isDirectory() || appStat.isSymbolicLink()) fail('iPhone app must be a real application directory')
  const infoFile = path.join(app, 'Info.plist')
  const infoStat = fs.lstatSync(infoFile)
  if (!infoStat.isFile() || infoStat.isSymbolicLink() || infoStat.size <= 0) {
    fail('iPhone Info.plist must be a non-empty regular file')
  }
  const info = plistReader(infoFile)
  const executableName = string(info.CFBundleExecutable, 'iPhone executable name')
  if (path.basename(executableName) !== executableName || /[\\/\r\n\0]/u.test(executableName)
      || executableName === '.' || executableName === '..') {
    fail('iPhone executable name must stay inside the application bundle')
  }
  const executable = path.join(app, executableName)
  const profile = path.join(app, 'embedded.mobileprovision')
  for (const [target, label] of [[executable, 'iPhone executable'], [profile, 'iPhone provisioning profile']]) {
    const stat = fs.lstatSync(target)
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0) fail(`${label} must be a non-empty regular file`)
  }
  if ((fs.statSync(executable).mode & 0o111) === 0) fail('iPhone executable is not executable')
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=4', app])
  const signature = parseCodeSignature(run('/usr/bin/codesign', ['-dv', '--verbose=4', app]))
  const entitlements = parseEntitlements(run('/usr/bin/codesign', ['-d', '--entitlements', ':-', app]), run)
  const architectures = run('/usr/bin/lipo', ['-archs', executable]).split(/\s+/u).filter(Boolean)
  const inventory = bundleInventory(app)
  return validateIPhoneInspection({
    sourceCommit: options.sourceCommit,
    info,
    signature,
    entitlements,
    architectures,
    executableSHA256: sha256File(executable),
    provisioningProfileSHA256: sha256File(profile),
    ...inventory,
  })
}

function safeEvidencePath(value) {
  string(value, 'relative evidence path')
  if (value.includes('\\')
      || value.includes('\0')
      || path.posix.isAbsolute(value)
      || path.posix.normalize(value) !== value
      || value === '.'
      || value.startsWith('../')) {
    fail(`relative evidence path is invalid: ${value}`)
  }
  return value
}

function evidenceTarget(root, relative) {
  let current = root
  const components = relative.split('/')
  for (let index = 0; index < components.length; index += 1) {
    current = path.join(current, components[index])
    const stat = fs.lstatSync(current)
    if (stat.isSymbolicLink()) fail(`evidence path contains a symbolic link: ${relative}`)
    if (index < components.length - 1 && !stat.isDirectory()) {
      fail(`evidence parent is not a directory: ${relative}`)
    }
    if (index === components.length - 1 && !stat.isFile()) {
      fail(`evidence must be a regular file: ${relative}`)
    }
  }
  safeRelativePath(root, current, 'evidence file')
  return current
}

function listEvidenceFiles(root) {
  const pending = [root]
  const files = []
  let entries = 0
  while (pending.length) {
    const directory = pending.pop()
    for (const name of fs.readdirSync(directory).sort()) {
      entries += 1
      if (entries > MAX_EVIDENCE_ENTRIES) {
        fail(`evidence directory exceeds ${MAX_EVIDENCE_ENTRIES} filesystem entries`)
      }
      const absolute = path.join(directory, name)
      const relative = safeEvidencePath(safeRelativePath(root, absolute, 'evidence entry'))
      const stat = fs.lstatSync(absolute)
      if (stat.isSymbolicLink()) fail(`evidence path contains a symbolic link: ${relative}`)
      if (stat.isDirectory()) pending.push(absolute)
      else if (stat.isFile()) files.push(relative)
      else fail(`evidence contains an unsupported filesystem entry: ${relative}`)
    }
  }
  return files.sort()
}

function scanSensitiveText(text, label) {
  const value = String(text)
  if (/-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----/iu.test(value)) {
    fail(`${label} contains a private key`)
  }
  if (/\b(?:authorization\s*:\s*)?bearer\s+[A-Za-z0-9._~+/=-]{16,}/iu.test(value)) {
    fail(`${label} contains a bearer credential`)
  }
  if (/\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/u.test(value)) {
    fail(`${label} contains a JWT`)
  }
  if (/["']?\b[A-Za-z0-9_-]*(?:idToken|refreshToken|accessToken|authToken|bearerToken|access_token|refresh_token|client_secret|apiKey|api_key|privateKey|private_key|identityPublicKey|staticPublicKey|token)\b["']?\s*[=:]\s*["']?[A-Za-z0-9._~+/=-]{8,}/iu.test(value)) {
    fail(`${label} contains a credential field`)
  }
  if (/["']type["']\s*:\s*["']kaisola-companion-pairing["']/iu.test(value)) {
    fail(`${label} contains a raw pairing offer`)
  }
  return true
}

function parseAudit(buffer, expectedKind, label) {
  let audit
  try { audit = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer)) } catch {
    fail(`${label} must contain UTF-8 JSON`)
  }
  plainObject(audit, label)
  if (expectedKind === 'kaisola-companion-pasteboard-audit') {
    exactKeys(audit, [
      'schemaVersion', 'kind', 'longTermKeyObserved', 'privateKeyObserved',
      'bearerCredentialObserved',
      'pairingOfferClearedAfterManualEntry',
    ], label)
    if (audit.schemaVersion !== SCHEMA_VERSION || audit.kind !== expectedKind
        || audit.longTermKeyObserved !== false || audit.privateKeyObserved !== false
        || audit.bearerCredentialObserved !== false
        || audit.pairingOfferClearedAfterManualEntry !== true) {
      fail(`${label} did not prove a cleared, credential-free pasteboard`)
    }
  } else {
    exactKeys(audit, [
      'schemaVersion', 'kind', 'longTermKeyObserved', 'privateKeyObserved',
      'bearerCredentialObserved',
      'rawPairingOfferObserved',
    ], label)
    if (audit.schemaVersion !== SCHEMA_VERSION || audit.kind !== expectedKind
        || audit.longTermKeyObserved !== false || audit.privateKeyObserved !== false
        || audit.bearerCredentialObserved !== false
        || audit.rawPairingOfferObserved !== false) {
      fail(`${label} did not prove credential-free analytics`)
    }
  }
  return true
}

function inventoryEvidence(directory, declarations, contentValidator = null) {
  const root = path.resolve(string(directory, 'evidence directory'))
  const rootStat = fs.lstatSync(root)
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) fail('evidence directory must be a real directory')
  if (!Array.isArray(declarations) || declarations.length === 0
      || declarations.length > MAX_EVIDENCE_FILES) {
    fail(`evidence must contain between 1 and ${MAX_EVIDENCE_FILES} files`)
  }
  const seen = new Set()
  const inventory = []
  let totalBytes = 0
  for (const declaration of declarations) {
    exactKeys(declaration, ['path', 'kind'], 'evidence declaration')
    const relative = safeEvidencePath(declaration.path)
    if (seen.has(relative)) fail(`duplicate evidence path: ${relative}`)
    seen.add(relative)
    const kind = string(declaration.kind, `evidence kind for ${relative}`)
    if (!EVIDENCE_KINDS.includes(kind)) fail(`unsupported evidence kind: ${kind}`)
    const limit = kind === 'screenshot' ? MAX_IMAGE_EVIDENCE_BYTES : MAX_TEXT_EVIDENCE_BYTES
    const target = evidenceTarget(root, relative)
    const buffer = readBoundedRegularFile(target, `evidence ${relative}`, limit)
    totalBytes += buffer.length
    if (totalBytes > MAX_TOTAL_EVIDENCE_BYTES) fail('evidence exceeds the total byte bound')
    if (kind === 'screenshot') {
      const png = buffer.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))
      const jpeg = buffer.length >= 3 && buffer[0] === 0xFF && buffer[1] === 0xD8 && buffer[2] === 0xFF
      if (!png && !jpeg) fail(`screenshot evidence is not PNG or JPEG: ${relative}`)
    } else {
      let text
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(buffer) } catch {
        fail(`text evidence is not UTF-8: ${relative}`)
      }
      scanSensitiveText(text, relative)
      if (kind === 'pasteboard-audit') {
        parseAudit(buffer, 'kaisola-companion-pasteboard-audit', relative)
      } else if (kind === 'analytics-audit') {
        parseAudit(buffer, 'kaisola-companion-analytics-audit', relative)
      }
      if (contentValidator) contentValidator({ path: relative, kind, text })
    }
    inventory.push({ path: relative, kind, size: buffer.length, sha256: sha256Buffer(buffer) })
  }
  const declaredFiles = inventory.map((entry) => entry.path).sort()
  const actualFiles = listEvidenceFiles(root)
  if (!util.isDeepStrictEqual(actualFiles, declaredFiles)) {
    const declared = new Set(declaredFiles)
    const extra = actualFiles.find((entry) => !declared.has(entry))
    fail(extra ? `undeclared evidence file: ${extra}` : 'evidence directory does not match its declarations')
  }
  return inventory.sort((left, right) => left.path.localeCompare(right.path, 'en'))
}

function normalizedEvidenceReferences(value, label, declarations, allowedKinds = null) {
  if (!Array.isArray(value) || value.length === 0) fail(`${label} must name evidence`)
  const references = value.map((entry) => safeEvidencePath(entry))
  if (new Set(references).size !== references.length) fail(`${label} contains duplicate evidence`)
  for (const reference of references) {
    const kind = declarations.get(reference)
    if (!kind) fail(`${label} names undeclared evidence: ${reference}`)
    if (allowedKinds && !allowedKinds.has(kind)) fail(`${label} names the wrong evidence kind: ${reference}`)
  }
  return references.sort()
}

function validateScenario(name, value, spec, run, declarations) {
  const baseKeys = ['result', 'expected', 'observed', 'startedAt', 'completedAt', 'evidence']
  const extraKeys = spec.positive
    ? ['transcript', 'sasConfirmation', 'storedIdentity', 'rendezvous']
    : ['persistedIdentity', 'activeChannel', 'userVisibleResult']
  exactKeys(value, [...baseKeys, ...extraKeys], `${name} scenario`)
  if (value.result !== 'pass' || value.expected !== spec.expected || value.observed !== spec.expected) {
    fail(`${name} scenario did not pass with ${spec.expected}`)
  }
  const startedAt = canonicalDate(value.startedAt, `${name} startedAt`)
  const completedAt = canonicalDate(value.completedAt, `${name} completedAt`)
  if (startedAt < run.startedAt || completedAt > run.completedAt || startedAt >= completedAt) {
    fail(`${name} scenario timestamps fall outside the acceptance run`)
  }
  const evidence = normalizedEvidenceReferences(value.evidence, `${name} evidence`, declarations)
  const kinds = new Set(evidence.map((reference) => declarations.get(reference)))
  if (!kinds.has('mac-log') || !kinds.has('iphone-log')) {
    fail(`${name} scenario requires both Mac and iPhone logs`)
  }
  const normalized = {
    result: 'pass',
    expected: spec.expected,
    observed: spec.expected,
    startedAt,
    completedAt,
    evidence,
  }
  if (spec.positive) {
    normalized.transcript = exactArray(value.transcript, PAIRING_TRANSCRIPT, `${name} Noise XX transcript`)
    if (value.sasConfirmation !== 'matched-on-both') fail(`${name} did not confirm SAS on both devices`)
    if (value.storedIdentity !== 'mac-and-iphone') fail(`${name} did not persist both identities`)
    if (value.rendezvous !== spec.rendezvous) fail(`${name} account rendezvous result is invalid`)
    normalized.sasConfirmation = value.sasConfirmation
    normalized.storedIdentity = value.storedIdentity
    normalized.rendezvous = value.rendezvous
  } else {
    if (value.persistedIdentity !== false) fail(`${name} retained a persisted identity`)
    if (value.activeChannel !== false) fail(`${name} retained an active channel`)
    if (value.userVisibleResult !== true) fail(`${name} had no user-visible result`)
    normalized.persistedIdentity = false
    normalized.activeChannel = false
    normalized.userVisibleResult = true
  }
  return normalized
}

function exactStringSet(actual, expected, label) {
  const normalizedActual = [...actual].sort()
  const normalizedExpected = [...expected].sort()
  if (!util.isDeepStrictEqual(normalizedActual, normalizedExpected)) {
    fail(`${label} must include every scenario log exactly once`)
  }
}

function parseLogFields(text) {
  const fields = new Map()
  for (const line of text.split(/\r?\n/u)) {
    const match = line.match(/^([A-Za-z][A-Za-z0-9]*)=(\S.*)$/u)
    if (!match) continue
    if (match[1] === 'event') continue
    if (fields.has(match[1])) fail(`scenario log repeats ${match[1]}`)
    fields.set(match[1], match[2])
  }
  return fields
}

function validateScenarioLog(name, scenario, kind, text) {
  const side = kind === 'mac-log' ? 'mac' : 'iphone'
  const fields = parseLogFields(text)
  if (fields.get('side') !== side) fail(`${name} ${side} log has the wrong side`)
  if (fields.get('startedAt') !== scenario.startedAt
      || fields.get('completedAt') !== scenario.completedAt) {
    fail(`${name} ${side} log timestamps do not match the observation`)
  }
  if (fields.get('result') !== scenario.observed) {
    fail(`${name} ${side} log does not corroborate ${scenario.observed}`)
  }
  const events = [...text.matchAll(/^event=([a-z0-9.-]+)\r?$/gmu)].map((match) => match[1])
  if (scenario.transcript) {
    if (!util.isDeepStrictEqual(events, PAIRING_TRANSCRIPT)) {
      fail(`${name} ${side} log does not contain the exact Noise XX transcript`)
    }
    if (fields.get('sas') !== scenario.sasConfirmation
        || fields.get('storedIdentity') !== scenario.storedIdentity
        || fields.get('rendezvous') !== scenario.rendezvous) {
      fail(`${name} ${side} log does not corroborate SAS, identity, and rendezvous`)
    }
  } else {
    if (events.length !== 0
        || fields.get('persistedIdentity') !== String(scenario.persistedIdentity)
        || fields.get('activeChannel') !== String(scenario.activeChannel)
        || fields.get('userVisibleResult') !== String(scenario.userVisibleResult)) {
      fail(`${name} ${side} log does not corroborate fail-closed rejection state`)
    }
  }
}

function validateObservations(input) {
  exactKeys(input, [
    'schemaVersion', 'kind', 'sourceCommit', 'run', 'hardware', 'scenarios',
    'privacy', 'evidence',
  ], 'device observations')
  if (input.schemaVersion !== SCHEMA_VERSION || input.kind !== OBSERVATION_KIND) {
    fail('device observation schema or kind is invalid')
  }
  const sourceCommit = string(input.sourceCommit, 'observation source commit', SOURCE_COMMIT)
  exactKeys(input.run, ['id', 'startedAt', 'completedAt'], 'acceptance run')
  const run = {
    id: string(input.run.id, 'acceptance run ID', UUID),
    startedAt: canonicalDate(input.run.startedAt, 'acceptance run startedAt'),
    completedAt: canonicalDate(input.run.completedAt, 'acceptance run completedAt'),
  }
  if (run.startedAt >= run.completedAt) fail('acceptance run must finish after it starts')

  exactKeys(input.hardware, ['mac', 'iphone'], 'acceptance hardware')
  exactKeys(input.hardware.mac, ['modelIdentifier', 'osVersion'], 'Mac hardware')
  exactKeys(input.hardware.iphone, [
    'modelIdentifier', 'osVersion', 'deviceIdentifierHash', 'physicalDevice', 'cleanInstall',
  ], 'iPhone hardware')
  const hardware = {
    mac: {
      modelIdentifier: string(
        input.hardware.mac.modelIdentifier,
        'Mac model identifier',
        MAC_MODEL_IDENTIFIER,
      ),
      osVersion: string(input.hardware.mac.osVersion, 'Mac OS version', VERSION),
    },
    iphone: {
      modelIdentifier: string(
        input.hardware.iphone.modelIdentifier,
        'iPhone model identifier',
        IPHONE_MODEL_IDENTIFIER,
      ),
      osVersion: string(input.hardware.iphone.osVersion, 'iPhone OS version', VERSION),
      deviceIdentifierHash: requireHex256(input.hardware.iphone.deviceIdentifierHash, 'hashed iPhone identifier'),
      physicalDevice: input.hardware.iphone.physicalDevice,
      cleanInstall: input.hardware.iphone.cleanInstall,
    },
  }
  if (hardware.iphone.physicalDevice !== true) fail('acceptance requires a physical device, never a Simulator')
  if (hardware.iphone.cleanInstall !== true) fail('acceptance requires a clean physical iPhone install')

  if (!Array.isArray(input.evidence) || input.evidence.length === 0) fail('device observations require evidence')
  const declarations = new Map()
  const evidence = input.evidence.map((entry) => {
    exactKeys(entry, ['path', 'kind'], 'evidence declaration')
    const relative = safeEvidencePath(entry.path)
    const kind = string(entry.kind, `evidence kind for ${relative}`)
    if (!EVIDENCE_KINDS.includes(kind)) fail(`unsupported evidence kind: ${kind}`)
    if (declarations.has(relative)) fail(`duplicate evidence path: ${relative}`)
    declarations.set(relative, kind)
    return { path: relative, kind }
  }).sort((left, right) => left.path.localeCompare(right.path, 'en'))

  exactKeys(input.scenarios, Object.keys(SCENARIO_SPECS), 'acceptance scenarios')
  const scenarios = {}
  for (const [name, spec] of Object.entries(SCENARIO_SPECS)) {
    scenarios[name] = validateScenario(name, input.scenarios[name], spec, run, declarations)
  }
  let previousCompletedAt = run.startedAt
  const scenarioLogPaths = []
  const uniqueScenarioLogs = new Set()
  for (const [name, scenario] of Object.entries(scenarios)) {
    if (scenario.startedAt < previousCompletedAt) {
      fail('acceptance scenarios must be ordered and non-overlapping')
    }
    previousCompletedAt = scenario.completedAt
    const logKinds = scenario.evidence.map((reference) => declarations.get(reference))
    if (logKinds.filter((kind) => kind === 'mac-log').length !== 1
        || logKinds.filter((kind) => kind === 'iphone-log').length !== 1) {
      fail(`${name} requires exactly one Mac log and one iPhone log`)
    }
    if (logKinds.some((kind) => !['mac-log', 'iphone-log', 'operator-note'].includes(kind))) {
      fail(`${name} evidence may contain only logs and operator notes`)
    }
    for (const reference of scenario.evidence.filter((entry) => declarations.get(entry) !== 'operator-note')) {
      if (uniqueScenarioLogs.has(reference)) fail('every scenario requires unique Mac and iPhone logs')
      uniqueScenarioLogs.add(reference)
      scenarioLogPaths.push(reference)
    }
  }

  exactKeys(input.privacy, ['logs', 'screenshots', 'pasteboard', 'analytics'], 'privacy observations')
  exactKeys(input.privacy.logs, ['result', 'evidence'], 'log privacy')
  exactKeys(input.privacy.screenshots, ['result', 'evidence', 'ocrReviewed'], 'screenshot privacy')
  exactKeys(input.privacy.pasteboard, [
    'result', 'evidence', 'pairingOfferClearedAfterManualEntry',
  ], 'pasteboard privacy')
  exactKeys(input.privacy.analytics, ['result', 'evidence', 'captureReviewed'], 'analytics privacy')
  for (const [name, observation] of Object.entries(input.privacy)) {
    if (observation.result !== 'pass') fail(`${name} privacy review did not pass`)
  }
  if (input.privacy.screenshots.ocrReviewed !== true) fail('screenshot OCR review is required')
  if (input.privacy.pasteboard.pairingOfferClearedAfterManualEntry !== true) {
    fail('pasteboard must be cleared after manual pairing entry')
  }
  if (input.privacy.analytics.captureReviewed !== true) fail('analytics capture review is required')
  const privacy = {
    logs: {
      result: 'pass',
      evidence: normalizedEvidenceReferences(
        input.privacy.logs.evidence,
        'log privacy evidence',
        declarations,
        new Set(['mac-log', 'iphone-log']),
      ),
    },
    screenshots: {
      result: 'pass',
      evidence: normalizedEvidenceReferences(
        input.privacy.screenshots.evidence,
        'screenshot privacy evidence',
        declarations,
        new Set(['screenshot', 'screenshot-ocr']),
      ),
      ocrReviewed: true,
    },
    pasteboard: {
      result: 'pass',
      evidence: normalizedEvidenceReferences(
        input.privacy.pasteboard.evidence,
        'pasteboard privacy evidence',
        declarations,
        new Set(['pasteboard-audit']),
      ),
      pairingOfferClearedAfterManualEntry: true,
    },
    analytics: {
      result: 'pass',
      evidence: normalizedEvidenceReferences(
        input.privacy.analytics.evidence,
        'analytics privacy evidence',
        declarations,
        new Set(['analytics-audit']),
      ),
      captureReviewed: true,
    },
  }
  const screenshotKinds = new Set(privacy.screenshots.evidence.map((entry) => declarations.get(entry)))
  if (!screenshotKinds.has('screenshot') || !screenshotKinds.has('screenshot-ocr')) {
    fail('screenshot privacy requires both an image and screenshot OCR evidence')
  }
  exactStringSet(privacy.logs.evidence, scenarioLogPaths, 'log privacy evidence')
  const referenced = new Set([
    ...Object.values(scenarios).flatMap((scenario) => scenario.evidence),
    ...Object.values(privacy).flatMap((observation) => observation.evidence),
  ])
  for (const declaration of evidence) {
    if (!referenced.has(declaration.path)) fail(`unreferenced evidence declaration: ${declaration.path}`)
  }
  const normalized = {
    schemaVersion: SCHEMA_VERSION,
    kind: OBSERVATION_KIND,
    sourceCommit,
    run,
    hardware,
    scenarios,
    privacy,
    evidence,
  }
  scanSensitiveText(JSON.stringify(normalized), 'device observations')
  return normalized
}

function validateMacPreflight(value) {
  plainObject(value, 'Mac preflight receipt')
  if (value.pass !== true || value.bundleIdentifier !== MAC_BUNDLE_IDENTIFIER
      || value.developerID !== true || value.secureTimestamp !== true || value.launchProbe !== true) {
    fail('Mac build must pass Developer ID, secure timestamp, and launch preflight')
  }
  const architectures = plainObject(value.architectures, 'Mac architectures')
  return {
    sourceCommit: string(value.sourceCommit, 'Mac source commit', SOURCE_COMMIT),
    bundleIdentifier: MAC_BUNDLE_IDENTIFIER,
    version: string(value.version, 'Mac version', VERSION),
    build: String(positiveInteger(value.build, 'Mac build')),
    teamIdentifier: string(value.teamIdentifier, 'Mac signing team', TEAM_IDENTIFIER),
    architectures: {
      app: exactArray(architectures.app, REQUIRED_ARCHITECTURES, 'Mac app architectures'),
      node: exactArray(architectures.node, REQUIRED_ARCHITECTURES, 'Mac Node runtime architectures'),
      bootstrap: exactArray(
        architectures.bootstrap,
        REQUIRED_ARCHITECTURES,
        'Mac broker bootstrap architectures',
      ),
    },
    developerID: true,
    secureTimestamp: true,
    launchProbe: true,
    notarized: value.notarizationRequired === true,
  }
}

function validateIPhoneBuildReceipt(value) {
  exactKeys(value, [
    'schemaVersion', 'kind', 'pass', 'sourceCommit', 'bundleIdentifier', 'version',
    'build', 'minimumOSVersion', 'teamIdentifier', 'signatureKind', 'getTaskAllow',
    'architectures', 'executableSHA256', 'provisioningProfileSHA256', 'bundleDigest',
    'fileCount',
  ], 'iPhone build receipt')
  if (value.schemaVersion !== SCHEMA_VERSION || value.kind !== IPHONE_BUILD_KIND || value.pass !== true
      || value.bundleIdentifier !== IPHONE_BUNDLE_IDENTIFIER) {
    fail('iPhone build receipt schema, kind, pass, or bundle identifier is invalid')
  }
  if (!['apple-development', 'apple-distribution'].includes(value.signatureKind)) {
    fail('iPhone build receipt has no Apple signing identity')
  }
  if (typeof value.getTaskAllow !== 'boolean') fail('iPhone get-task-allow receipt is invalid')
  return {
    schemaVersion: SCHEMA_VERSION,
    kind: IPHONE_BUILD_KIND,
    pass: true,
    sourceCommit: string(value.sourceCommit, 'iPhone source commit', SOURCE_COMMIT),
    bundleIdentifier: IPHONE_BUNDLE_IDENTIFIER,
    version: string(value.version, 'iPhone version', VERSION),
    build: String(positiveInteger(value.build, 'iPhone build')),
    minimumOSVersion: string(value.minimumOSVersion, 'iPhone minimum OS version', VERSION),
    teamIdentifier: string(value.teamIdentifier, 'iPhone signing team', TEAM_IDENTIFIER),
    signatureKind: value.signatureKind,
    getTaskAllow: value.getTaskAllow,
    architectures: exactArray(value.architectures, REQUIRED_ARCHITECTURES, 'iPhone architectures'),
    executableSHA256: requireHex256(value.executableSHA256, 'iPhone executable SHA-256'),
    provisioningProfileSHA256: requireHex256(
      value.provisioningProfileSHA256,
      'iPhone provisioning profile SHA-256',
    ),
    bundleDigest: requireHex256(value.bundleDigest, 'iPhone bundle digest'),
    fileCount: positiveInteger(value.fileCount, 'iPhone bundle file count'),
  }
}

function createAcceptanceReceipt({
  macPreflight,
  iphoneBuild,
  observations,
  evidenceDirectory,
  macPreflightSHA256,
  iphoneBuildSHA256,
}) {
  const mac = validateMacPreflight(macPreflight)
  const iphone = validateIPhoneBuildReceipt(iphoneBuild)
  const observed = validateObservations(observations)
  if (mac.sourceCommit !== iphone.sourceCommit || mac.sourceCommit !== observed.sourceCommit) {
    fail('Mac, iPhone, and observations must bind the same source commit')
  }
  if (mac.teamIdentifier !== iphone.teamIdentifier) {
    fail('Mac and iPhone must use the same signing team')
  }
  const scenarioForEvidence = new Map()
  for (const [name, scenario] of Object.entries(observed.scenarios)) {
    for (const reference of scenario.evidence) scenarioForEvidence.set(reference, { name, scenario })
  }
  const files = inventoryEvidence(evidenceDirectory, observed.evidence, ({ path: evidencePath, kind, text }) => {
    const owner = scenarioForEvidence.get(evidencePath)
    if (owner && (kind === 'mac-log' || kind === 'iphone-log')) {
      validateScenarioLog(owner.name, owner.scenario, kind, text)
    }
  })
  const evidenceDigest = sha256Buffer(Buffer.from(`${JSON.stringify(files)}\n`))
  const receipt = {
    schemaVersion: SCHEMA_VERSION,
    kind: RECEIPT_KIND,
    pass: true,
    sourceCommit: observed.sourceCommit,
    run: observed.run,
    hardware: observed.hardware,
    builds: {
      mac: {
        ...mac,
        receiptSHA256: requireHex256(macPreflightSHA256, 'Mac preflight receipt SHA-256'),
      },
      iphone: {
        ...iphone,
        receiptSHA256: requireHex256(iphoneBuildSHA256, 'iPhone build receipt SHA-256'),
      },
    },
    scenarios: observed.scenarios,
    privacy: observed.privacy,
    evidence: {
      fileCount: files.length,
      totalBytes: files.reduce((sum, file) => sum + file.size, 0),
      digest: evidenceDigest,
      files,
    },
  }
  scanSensitiveText(JSON.stringify(receipt), 'acceptance receipt')
  return receipt
}

function verifyAcceptanceReceipt(receipt, input) {
  const calculated = createAcceptanceReceipt(input)
  if (!util.isDeepStrictEqual(receipt, calculated)) fail('acceptance receipt does not match exact builds and evidence')
  return true
}

function readJSONWithDigest(file, label) {
  const buffer = readBoundedRegularFile(file, label, MAX_JSON_BYTES)
  let text
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(buffer)
  } catch {
    fail(`${label} must contain UTF-8 JSON`)
  }
  let value
  try { value = JSON.parse(text) } catch (error) { fail(`could not parse ${label}: ${error.message}`) }
  return { value: plainObject(value, label), sha256: sha256Buffer(buffer) }
}

function readJSON(file, label) {
  return readJSONWithDigest(file, label).value
}

function writeJSONAtomic(destination, value) {
  const directory = path.dirname(destination)
  fs.mkdirSync(directory, { recursive: true })
  try {
    fs.lstatSync(destination)
    fail('receipt output already exists')
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
  const temporary = path.join(directory, `.${path.basename(destination)}.${process.pid}.tmp`)
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
      encoding: 'utf8',
      flag: 'wx',
      mode: 0o600,
    })
    try {
      fs.linkSync(temporary, destination)
    } catch (error) {
      if (error.code === 'EEXIST') fail('receipt output already exists')
      throw error
    }
  } finally {
    fs.rmSync(temporary, { force: true })
  }
}

function receiptInputs(options) {
  const mac = readJSONWithDigest(options.macPreflight, 'Mac preflight receipt')
  const iphone = readJSONWithDigest(options.iphoneBuild, 'iPhone build receipt')
  const observations = readJSON(options.observations, 'device observations')
  return {
    macPreflight: mac.value,
    iphoneBuild: iphone.value,
    observations,
    evidenceDirectory: options.evidenceDirectory,
    macPreflightSHA256: mac.sha256,
    iphoneBuildSHA256: iphone.sha256,
  }
}

function main(argv) {
  const options = parseArguments(argv)
  if (options.help) {
    process.stdout.write(`${usage()}\n`)
    return
  }
  if (options.command === 'inspect-ios') {
    requireOutputOutside(options.app, options.output, 'iPhone app')
    const receipt = inspectIPhoneApp(options)
    writeJSONAtomic(options.output, receipt)
    process.stdout.write(`COMPANION_DEVICE_BUILD=PASS bundle=${receipt.bundleIdentifier} version=${receipt.version} build=${receipt.build}\n`)
    return
  }
  const input = receiptInputs(options)
  if (options.command === 'seal') {
    requireOutputOutside(options.evidenceDirectory, options.output, 'evidence directory')
    const receipt = createAcceptanceReceipt(input)
    writeJSONAtomic(options.output, receipt)
    process.stdout.write(`COMPANION_DEVICE_ACCEPTANCE=PASS evidence=${receipt.evidence.digest}\n`)
    return
  }
  const receipt = readJSON(options.receipt, 'acceptance receipt')
  verifyAcceptanceReceipt(receipt, input)
  process.stdout.write(`COMPANION_DEVICE_ACCEPTANCE=VERIFIED evidence=${receipt.evidence.digest}\n`)
}

if (require.main === module) {
  try {
    main(process.argv.slice(2))
  } catch (error) {
    process.stderr.write(`COMPANION_DEVICE_ACCEPTANCE=FAIL ${error.message}\n`)
    process.exitCode = 1
  }
}

module.exports = {
  PAIRING_TRANSCRIPT,
  createAcceptanceReceipt,
  inspectIPhoneApp,
  inventoryEvidence,
  parseArguments,
  parseCodeSignature,
  requireOutputOutside,
  scanSensitiveText,
  validateIPhoneInspection,
  validateObservations,
  verifyAcceptanceReceipt,
  writeJSONAtomic,
}
