#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const SPARKLE_NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
const DEFAULT_MINIMUM_SYSTEM_VERSION = '14.0'

function fail(message) {
  throw new Error(message)
}

function requireValue(argv, index, argument) {
  const value = argv[index + 1]
  if (value == null || value.startsWith('--')) fail(`${argument} requires a value`)
  return value
}

function parseArguments(argv) {
  const options = { minimumSystemVersion: DEFAULT_MINIMUM_SYSTEM_VERSION }
  const seen = new Set()
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      options.help = true
      continue
    }
    const keys = {
      '--zip': 'zip',
      '--version': 'version',
      '--build': 'build',
      '--url': 'url',
      '--sign-update': 'signUpdate',
      '--ed-signature': 'edSignature',
      '--archive-length': 'archiveLength',
      '--output': 'output',
      '--existing': 'existing',
      '--min-system': 'minimumSystemVersion',
      '--ed-key-file': 'edKeyFile',
    }
    const key = keys[argument]
    if (!key) fail(`unknown argument: ${argument}`)
    if (seen.has(key)) fail(`duplicate argument: ${argument}`)
    seen.add(key)
    const value = requireValue(argv, index, argument)
    index += 1
    options[key] = ['zip', 'signUpdate', 'output', 'existing', 'edKeyFile'].includes(key)
      ? path.resolve(value)
      : value
  }
  if (options.help) return options
  for (const key of ['zip', 'version', 'build', 'url', 'output']) {
    if (!options[key]) fail(`--${key} is required`)
  }
  const hasSigner = Boolean(options.signUpdate)
  const hasPreparedSignature = Boolean(options.edSignature || options.archiveLength)
  if (hasSigner === hasPreparedSignature) {
    fail('provide exactly one signing mode: --sign-update, or --ed-signature with --archive-length')
  }
  if (hasPreparedSignature && (!options.edSignature || !options.archiveLength)) {
    fail('--ed-signature and --archive-length must be provided together')
  }
  if (!hasSigner && options.edKeyFile) {
    fail('--ed-key-file requires --sign-update')
  }
  if (!/^\d+(?:\.\d+){0,2}$/.test(options.minimumSystemVersion)) {
    fail('--min-system must be a numeric macOS version such as 14.0')
  }
  return options
}

function usage() {
  return `Usage:
  node scripts/native-appcast.cjs --zip <path> --version <marketingVersion> \\
    --build <bundleVersion> --url <https enclosure url> \\
    (--sign-update <Sparkle sign_update> | \\
      --ed-signature <prepared signature> --archive-length <bytes>) \\
    --output <appcast.xml> \\
    [--existing <appcast.xml>] [--min-system 14.0] [--ed-key-file <file>]`
}

function validateEnclosureURL(value) {
  if (value !== value.trim()) fail('enclosure URL must not contain surrounding whitespace')
  if (value.includes('#')) fail('enclosure URL must not contain a fragment')
  let url
  try {
    url = new URL(value)
  } catch {
    fail('enclosure URL is not a valid URL')
  }
  if (url.protocol !== 'https:' || !url.hostname) fail('enclosure URL must use HTTPS')
  if (url.username || url.password || /^https:\/\/[^/?#]*@/i.test(value)) {
    fail('enclosure URL must not contain credentials')
  }
  return value
}

function parseSignatureOutput(output) {
  const line = String(output).split(/\r?\n/).find((candidate) => candidate.includes('sparkle:edSignature='))
  const signature = line?.match(/(?:^|\s)sparkle:edSignature="([^"]+)"(?:\s|$)/)?.[1]
  const rawLength = line?.match(/(?:^|\s)length="([^"]+)"(?:\s|$)/)?.[1]
  if (!signature || !rawLength) {
    fail('sign_update did not return sparkle:edSignature and length attributes')
  }
  return validatePreparedSignature(signature, rawLength)
}

function validatePreparedSignature(signature, archiveLength) {
  if (typeof signature !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(signature)) {
    fail('Sparkle Ed25519 signature must be canonical base64')
  }
  const decoded = Buffer.from(signature, 'base64')
  if (decoded.length !== 64 || decoded.toString('base64') !== signature) {
    fail('Sparkle Ed25519 signature must canonically encode exactly 64 bytes')
  }
  const rawLength = String(archiveLength)
  const length = Number(rawLength)
  if (!/^\d+$/.test(rawLength) || !Number.isSafeInteger(length) || length <= 0) {
    fail('prepared archive length must be a positive safe integer')
  }
  return { signature, length }
}

function signArchive(options) {
  if (!options.signUpdate) {
    return validatePreparedSignature(options.edSignature, options.archiveLength)
  }
  const args = []
  if (options.edKeyFile) args.push('--ed-key-file', options.edKeyFile)
  args.push(options.zip)
  const result = spawnSync(options.signUpdate, args, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  })
  if (result.error) fail(`sign_update failed: ${result.error.message}`)
  const output = `${result.stdout || ''}${result.stderr || ''}`.trim()
  if (result.status !== 0) {
    fail(`sign_update failed with exit code ${result.status}${output ? `: ${output}` : ''}`)
  }
  return parseSignatureOutput(output)
}

function decodeXML(value, offset) {
  let result = ''
  let cursor = 0
  const entity = /&(#x[0-9A-Fa-f]+|#[0-9]+|amp|lt|gt|quot|apos);/g
  for (let match = entity.exec(value); match; match = entity.exec(value)) {
    if (value.slice(cursor, match.index).includes('&')) fail(`malformed XML entity near byte ${offset + cursor}`)
    result += value.slice(cursor, match.index)
    const name = match[1]
    if (name === 'amp') result += '&'
    else if (name === 'lt') result += '<'
    else if (name === 'gt') result += '>'
    else if (name === 'quot') result += '"'
    else if (name === 'apos') result += "'"
    else {
      const codePoint = Number.parseInt(name.startsWith('#x') ? name.slice(2) : name.slice(1), name.startsWith('#x') ? 16 : 10)
      if (!Number.isInteger(codePoint) || codePoint <= 0 || codePoint > 0x10FFFF
          || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
        fail(`invalid XML character entity near byte ${offset + match.index}`)
      }
      result += String.fromCodePoint(codePoint)
    }
    cursor = match.index + match[0].length
  }
  if (value.slice(cursor).includes('&')) fail(`malformed XML entity near byte ${offset + cursor}`)
  return result + value.slice(cursor)
}

function parseXML(source) {
  const document = String(source).replace(/^\uFEFF/, '')
  const roots = []
  const stack = []
  const namePattern = /^[A-Za-z_][A-Za-z0-9_.:-]*/
  let index = 0

  const addText = (text, rawOffset) => {
    const decoded = decodeXML(text, rawOffset)
    if (stack.length > 0) stack.at(-1).children.push({ type: 'text', text: decoded })
    else if (decoded.trim()) fail(`text is not allowed outside the root element near byte ${rawOffset}`)
  }
  const readName = () => {
    const match = namePattern.exec(document.slice(index))
    if (!match) fail(`expected an XML name near byte ${index}`)
    index += match[0].length
    return match[0]
  }
  const skipWhitespace = () => {
    while (/\s/.test(document[index] || '')) index += 1
  }

  while (index < document.length) {
    if (document[index] !== '<') {
      const next = document.indexOf('<', index)
      const end = next < 0 ? document.length : next
      addText(document.slice(index, end), index)
      index = end
      continue
    }
    if (document.startsWith('<!--', index)) {
      const end = document.indexOf('-->', index + 4)
      if (end < 0) fail(`unterminated XML comment near byte ${index}`)
      if (document.slice(index + 4, end).includes('--')) fail(`invalid XML comment near byte ${index}`)
      index = end + 3
      continue
    }
    if (document.startsWith('<![CDATA[', index)) {
      if (stack.length === 0) fail(`CDATA is not allowed outside the root element near byte ${index}`)
      const end = document.indexOf(']]>', index + 9)
      if (end < 0) fail(`unterminated CDATA section near byte ${index}`)
      stack.at(-1).children.push({ type: 'text', text: document.slice(index + 9, end) })
      index = end + 3
      continue
    }
    if (document.startsWith('<?', index)) {
      const end = document.indexOf('?>', index + 2)
      if (end < 0) fail(`unterminated XML processing instruction near byte ${index}`)
      index = end + 2
      continue
    }
    if (document.startsWith('<!', index)) fail(`unsupported XML declaration near byte ${index}`)
    if (document.startsWith('</', index)) {
      const tagStart = index
      index += 2
      const name = readName()
      skipWhitespace()
      if (document[index] !== '>') fail(`malformed closing tag near byte ${tagStart}`)
      index += 1
      const node = stack.pop()
      if (!node || node.name !== name) fail(`mismatched closing tag </${name}> near byte ${tagStart}`)
      node.innerEnd = tagStart
      node.end = index
      continue
    }

    const tagStart = index
    index += 1
    const name = readName()
    const attributes = new Map()
    let selfClosing = false
    while (index < document.length) {
      skipWhitespace()
      if (document.startsWith('/>', index)) {
        selfClosing = true
        index += 2
        break
      }
      if (document[index] === '>') {
        index += 1
        break
      }
      const attributeStart = index
      const attributeName = readName()
      if (attributes.has(attributeName)) fail(`duplicate XML attribute ${attributeName} near byte ${attributeStart}`)
      skipWhitespace()
      if (document[index] !== '=') fail(`XML attribute ${attributeName} is missing '=' near byte ${attributeStart}`)
      index += 1
      skipWhitespace()
      const quote = document[index]
      if (quote !== '"' && quote !== "'") fail(`XML attribute ${attributeName} must be quoted near byte ${attributeStart}`)
      index += 1
      const valueStart = index
      const valueEnd = document.indexOf(quote, valueStart)
      if (valueEnd < 0) fail(`unterminated XML attribute ${attributeName} near byte ${attributeStart}`)
      const rawValue = document.slice(valueStart, valueEnd)
      if (rawValue.includes('<')) fail(`XML attribute ${attributeName} contains '<' near byte ${attributeStart}`)
      attributes.set(attributeName, decodeXML(rawValue, valueStart))
      index = valueEnd + 1
    }
    if (index > document.length || (!selfClosing && document[index - 1] !== '>')) {
      fail(`unterminated opening tag <${name}> near byte ${tagStart}`)
    }
    const node = {
      type: 'element',
      name,
      attributes,
      children: [],
      start: tagStart,
      innerStart: index,
      innerEnd: selfClosing ? index - 2 : null,
      end: selfClosing ? index : null,
    }
    if (stack.length > 0) stack.at(-1).children.push(node)
    else roots.push(node)
    if (!selfClosing) stack.push(node)
  }
  if (stack.length > 0) fail(`unclosed XML element <${stack.at(-1).name}>`)
  if (roots.length !== 1) fail(`expected one XML root element; found ${roots.length}`)
  return { document, root: roots[0] }
}

function childElements(node, name) {
  return node.children.filter((child) => child.type === 'element' && (!name || child.name === name))
}

function textContent(node) {
  return node.children.map((child) => child.type === 'text' ? child.text : textContent(child)).join('')
}

function parseExistingAppcast(source) {
  try {
    const parsed = parseXML(source)
    const { root } = parsed
    if (root.name !== 'rss') fail('root element must be <rss>')
    const channels = childElements(root, 'channel')
    if (channels.length !== 1) fail('RSS appcast must contain exactly one <channel>')
    const channel = channels[0]
    const namespace = channel.attributes.get('xmlns:sparkle') || root.attributes.get('xmlns:sparkle')
    if (namespace !== SPARKLE_NAMESPACE) fail('RSS appcast has a missing or invalid Sparkle namespace')

    const namespaces = new Map([['xmlns:sparkle', SPARKLE_NAMESPACE]])
    for (const element of [root, channel]) {
      for (const [name, value] of element.attributes) {
        if (name.startsWith('xmlns:') && name !== 'xmlns:sparkle') namespaces.set(name, value)
      }
    }
    const items = childElements(channel, 'item').map((item) => {
      const versions = childElements(item, 'sparkle:version')
      if (versions.length !== 1) fail('each appcast item must contain exactly one <sparkle:version>')
      const build = textContent(versions[0]).trim()
      if (!build) fail('appcast item has an empty <sparkle:version>')
      const enclosure = childElements(item, 'enclosure').find((candidate) => candidate.attributes.has('sparkle:edSignature'))
      return {
        build,
        signature: enclosure?.attributes.get('sparkle:edSignature') || null,
        xml: parsed.document.slice(item.start, item.end),
      }
    })
    return { items, namespaces }
  } catch (error) {
    fail(`could not parse existing appcast: ${error.message}`)
  }
}

function tokenizeBuild(build) {
  return String(build).match(/\d+|\D+/g) || []
}

function compareBuildVersions(left, right) {
  const a = tokenizeBuild(left)
  const b = tokenizeBuild(right)
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    if (a[index] == null) return -1
    if (b[index] == null) return 1
    const aNumeric = /^\d+$/.test(a[index])
    const bNumeric = /^\d+$/.test(b[index])
    if (aNumeric && bNumeric) {
      const difference = BigInt(a[index]) - BigInt(b[index])
      if (difference !== 0n) return difference < 0n ? -1 : 1
    } else if (a[index] !== b[index]) {
      return a[index] < b[index] ? -1 : 1
    }
  }
  return 0
}

function escapeXML(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
}

function renderItem(options, signed, publicationDate) {
  return `<item>
  <title>${escapeXML(`Kaisola ${options.version}`)}</title>
  <pubDate>${escapeXML(publicationDate.toUTCString())}</pubDate>
  <sparkle:version>${escapeXML(options.build)}</sparkle:version>
  <sparkle:shortVersionString>${escapeXML(options.version)}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>${escapeXML(options.minimumSystemVersion)}</sparkle:minimumSystemVersion>
  <enclosure url="${escapeXML(options.url)}" length="${signed.length}" type="application/octet-stream" sparkle:edSignature="${escapeXML(signed.signature)}"/>
</item>`
}

function mergeItems(existingItems, current) {
  const seen = new Set()
  for (const item of existingItems) {
    if (seen.has(item.build)) {
      fail(`existing appcast already contains build ${item.build} more than once`)
    }
    seen.add(item.build)
    if (item.build === current.build && item.signature !== current.signature) {
      fail(`refusing to replace build ${current.build} with a different Sparkle signature`)
    }
    if (compareBuildVersions(current.build, item.build) < 0) {
      fail(`refusing to publish non-monotonic build ${current.build} after build ${item.build}`)
    }
  }
  return [...existingItems.filter((item) => item.build !== current.build), current]
    .sort((left, right) => compareBuildVersions(right.build, left.build))
}

function indentXML(value, spaces) {
  const prefix = ' '.repeat(spaces)
  return value.trim().split(/\r?\n/).map((line) => `${prefix}${line}`).join('\n')
}

function renderAppcast(items, namespaces) {
  const namespaceAttributes = [...namespaces]
    .map(([name, value]) => `${name}="${escapeXML(value)}"`)
    .join(' ')
  const itemXML = items.map((item) => indentXML(item.xml, 4)).join('\n')
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" ${namespaceAttributes}>
  <channel>
    <title>Kaisola Updates</title>
    <link>https://github.com/michaelofengenden/kaisola/releases</link>
    <description>Signed updates for the Kaisola native macOS preview.</description>
${itemXML}
  </channel>
</rss>
`
}

function writeFileAtomic(destination, contents) {
  const temporary = path.join(path.dirname(destination), `.${path.basename(destination)}.${process.pid}.tmp`)
  try {
    fs.writeFileSync(temporary, contents, { encoding: 'utf8', flag: 'wx', mode: 0o644 })
    fs.renameSync(temporary, destination)
  } finally {
    fs.rmSync(temporary, { force: true })
  }
}

function canonicalPath(candidate) {
  try {
    return fs.realpathSync(candidate)
  } catch {
    return path.resolve(candidate)
  }
}

function rejectOutputAliases(options) {
  const output = canonicalPath(options.output)
  const protectedInputs = [
    ['--zip', options.zip],
    ['--sign-update', options.signUpdate],
    ['--ed-key-file', options.edKeyFile],
  ]
  for (const [flag, value] of protectedInputs) {
    if (value && canonicalPath(value) === output) {
      fail(`--output must not overwrite the ${flag} input`)
    }
  }
}

function generateAppcast(options, publicationDate = new Date()) {
  validateEnclosureURL(options.url)
  rejectOutputAliases(options)
  if (!(publicationDate instanceof Date) || Number.isNaN(publicationDate.valueOf())) fail('publication date is invalid')
  let zipStat
  try {
    zipStat = fs.statSync(options.zip)
  } catch (error) {
    fail(`could not read zip: ${error.message}`)
  }
  if (!zipStat.isFile() || zipStat.size <= 0) fail('--zip must point to a non-empty file')
  if (options.edKeyFile && !fs.statSync(options.edKeyFile).isFile()) fail('--ed-key-file must point to a file')

  let existing = { items: [], namespaces: new Map([['xmlns:sparkle', SPARKLE_NAMESPACE]]) }
  if (options.existing) {
    let source
    try {
      source = fs.readFileSync(options.existing, 'utf8')
    } catch (error) {
      fail(`could not read existing appcast: ${error.message}`)
    }
    existing = parseExistingAppcast(source)
  }
  const signed = signArchive(options)
  if (signed.length !== zipStat.size) {
    fail(`signed archive length ${signed.length} does not match zip size ${zipStat.size}`)
  }
  const current = {
    build: options.build,
    signature: signed.signature,
    xml: renderItem(options, signed, publicationDate),
  }
  const items = mergeItems(existing.items, current)
  const xml = renderAppcast(items, existing.namespaces)
  writeFileAtomic(options.output, xml)
  return { output: options.output, build: options.build, itemCount: items.length, length: signed.length }
}

if (require.main === module) {
  try {
    const options = parseArguments(process.argv.slice(2))
    if (options.help) console.log(usage())
    else console.log(`NATIVE_APPCAST=${JSON.stringify(generateAppcast(options))}`)
  } catch (error) {
    console.error(`NATIVE_APPCAST=FAIL ${error.message}`)
    process.exitCode = 1
  }
}

module.exports = {
  DEFAULT_MINIMUM_SYSTEM_VERSION,
  SPARKLE_NAMESPACE,
  compareBuildVersions,
  generateAppcast,
  mergeItems,
  parseArguments,
  parseExistingAppcast,
  parseSignatureOutput,
  validatePreparedSignature,
  validateEnclosureURL,
}
