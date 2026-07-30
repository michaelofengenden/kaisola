'use strict'

// Bounded Git operations for the native app. Every public operation requires
// an explicit repository root and invokes Git with that directory as its cwd.

const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const DEFAULT_TIMEOUT_MS = 10_000
const DEFAULT_MAX_BUFFER_BYTES = 8 * 1024 * 1024
const DIFF_MAX_BYTES = 1024 * 1024
const MAX_LOG_LIMIT = 200
const DIFF_TRUNCATION_MARKER = `\n[diff truncated at ${DIFF_MAX_BYTES} bytes]\n`

function failure(reason) {
  return { ok: false, reason: String(reason || 'git operation failed') }
}

function timeout(options = {}) {
  const value = Number(options.timeoutMs ?? DEFAULT_TIMEOUT_MS)
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : DEFAULT_TIMEOUT_MS
}

function boundedReason(value, fallback) {
  const clean = String(value || '').trim()
  if (!clean) return fallback
  return clean.length > 4_096 ? `${clean.slice(0, 4_096)}...` : clean
}

function buffer(value) {
  if (Buffer.isBuffer(value)) return value
  return Buffer.from(value == null ? '' : String(value))
}

function decodePrefix(value, maximumBytes) {
  const bytes = buffer(value)
  if (bytes.length <= maximumBytes) return bytes.toString('utf8')
  let end = maximumBytes
  while (end > 0 && (bytes[end] & 0xC0) === 0x80) end -= 1
  return bytes.subarray(0, end).toString('utf8')
}

function executeGit(context, arguments_, options = {}) {
  const timeoutMs = timeout(options)
  const maxBuffer = options.maxBuffer ?? DEFAULT_MAX_BUFFER_BYTES
  const environment = {
    ...process.env,
    GIT_OPTIONAL_LOCKS: options.readOnly === false ? '1' : '0',
    GIT_PAGER: 'cat',
    GIT_TERMINAL_PROMPT: '0',
    LANG: 'C',
    LC_ALL: 'C',
    PAGER: 'cat',
  }
  const result = spawnSync('git', [
    '-c', 'color.ui=false',
    '-c', 'core.fsmonitor=false',
    '--literal-pathspecs',
    ...arguments_,
  ], {
    cwd: context.root,
    encoding: null,
    env: environment,
    killSignal: 'SIGKILL',
    maxBuffer,
    timeout: timeoutMs,
  })

  const stdout = buffer(result.stdout)
  const stderr = buffer(result.stderr)
  if (result.error) {
    if (result.error.code === 'ENOBUFS' && options.truncateOutput) {
      return { ok: true, status: result.status, stdout, stderr, truncated: true }
    }
    if (result.error.code === 'ETIMEDOUT') return failure(`git command timed out after ${timeoutMs} ms`)
    if (result.error.code === 'ENOBUFS') return failure('git output exceeded the service limit')
    if (result.error.code === 'ENOENT') return failure('git executable was not found')
    return failure(boundedReason(result.error.message, 'could not run git'))
  }

  const allowedStatuses = options.allowedStatuses || [0]
  if (!allowedStatuses.includes(result.status)) {
    return failure(boundedReason(stderr.toString('utf8') || stdout.toString('utf8'), `git exited with status ${result.status}`))
  }
  return { ok: true, status: result.status, stdout, stderr, truncated: false }
}

function repositoryContext(repoRoot, options = {}) {
  if (typeof repoRoot !== 'string' || !repoRoot.trim()) return failure('repository root is required')
  if (repoRoot.includes('\0')) return failure('repository root is invalid')

  let root
  try {
    root = fs.realpathSync.native(path.resolve(repoRoot))
    if (!fs.statSync(root).isDirectory()) return failure('repository root is not a directory')
  } catch {
    return failure('repository root does not exist')
  }

  const probe = executeGit({ root }, ['rev-parse', '--show-toplevel'], { ...options, readOnly: true })
  if (!probe.ok) return failure(`not a git repository: ${probe.reason}`)

  let topLevel
  try {
    topLevel = fs.realpathSync.native(probe.stdout.toString('utf8').trim())
  } catch {
    return failure('git returned an invalid repository root')
  }
  if (topLevel !== root) return failure('repository path must be the repository root')
  return { ok: true, root }
}

function isInside(root, candidate) {
  const relative = path.relative(root, candidate)
  return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith(`..${path.sep}`))
}

function nearestExistingDirectory(candidate) {
  let current = candidate
  while (true) {
    try {
      const stat = fs.statSync(current)
      if (stat.isDirectory()) return fs.realpathSync.native(current)
      current = path.dirname(current)
    } catch {
      const parent = path.dirname(current)
      if (parent === current) throw new Error('no existing path ancestor')
      current = parent
    }
  }
}

function resolvePathspec(context, input) {
  if (typeof input !== 'string' || !input || input.includes('\0')) return failure('file path is required')
  const absolute = path.resolve(context.root, input)
  if (!isInside(context.root, absolute)) return failure('file path escapes the repository root')

  const relative = path.relative(context.root, absolute)
  if (!relative) return failure('file path must identify one file inside the repository root')
  try {
    if (fs.lstatSync(absolute).isDirectory()) return failure('file path must not be a directory')
  } catch (error) {
    if (error.code !== 'ENOENT') return failure('file path is not accessible')
  }
  try {
    const parent = nearestExistingDirectory(path.dirname(absolute))
    if (!isInside(context.root, parent)) return failure('file path escapes the repository root through a symbolic link')
  } catch {
    return failure('file path has no accessible parent directory')
  }
  return { ok: true, path: relative }
}

function parseFixedRecord(record, fieldCount) {
  const fields = []
  let cursor = 0
  for (let index = 0; index < fieldCount; index += 1) {
    const separator = record.indexOf(' ', cursor)
    if (separator < 0) throw new Error(`malformed porcelain v2 record: ${record.slice(0, 80)}`)
    fields.push(record.slice(cursor, separator))
    cursor = separator + 1
  }
  const pathname = record.slice(cursor)
  if (!pathname) throw new Error('porcelain v2 record has no path')
  return { fields, pathname }
}

function compareStatusEntries(left, right) {
  if (left.path < right.path) return -1
  if (left.path > right.path) return 1
  if (left.status < right.status) return -1
  if (left.status > right.status) return 1
  return 0
}

function parseStatusV2(output) {
  let branch = null
  let ahead = 0
  let behind = 0
  const staged = []
  const unstaged = []
  const untracked = []
  const records = String(output).split('\0')

  for (let index = 0; index < records.length; index += 1) {
    const record = records[index]
    if (!record) continue
    if (record.startsWith('# branch.head ')) {
      const value = record.slice('# branch.head '.length)
      branch = value === '(detached)' ? null : value
      continue
    }
    if (record.startsWith('# branch.ab ')) {
      const match = record.match(/^# branch\.ab \+(\d+) -(\d+)$/)
      if (!match) throw new Error(`malformed branch.ab header: ${record}`)
      ahead = Number(match[1])
      behind = Number(match[2])
      continue
    }
    if (record.startsWith('# ')) continue
    if (record.startsWith('? ')) {
      untracked.push(record.slice(2))
      continue
    }
    if (record.startsWith('! ')) continue

    let parsed
    if (record.startsWith('1 ')) parsed = parseFixedRecord(record, 8)
    else if (record.startsWith('2 ')) {
      parsed = parseFixedRecord(record, 9)
      index += 1
      if (!records[index]) throw new Error('porcelain v2 rename record has no original path')
    } else if (record.startsWith('u ')) parsed = parseFixedRecord(record, 10)
    else throw new Error(`unknown porcelain v2 record: ${record.slice(0, 80)}`)

    const xy = parsed.fields[1]
    if (!xy || xy.length !== 2) throw new Error(`malformed porcelain v2 status code: ${String(xy)}`)
    if (xy[0] !== '.') staged.push({ path: parsed.pathname, status: xy[0] })
    if (xy[1] !== '.') unstaged.push({ path: parsed.pathname, status: xy[1] })
  }

  staged.sort(compareStatusEntries)
  unstaged.sort(compareStatusEntries)
  untracked.sort()
  return { ok: true, branch, ahead, behind, staged, unstaged, untracked }
}

function status(repoRoot, options = {}) {
  const context = repositoryContext(repoRoot, options)
  if (!context.ok) return context
  const result = executeGit(context, [
    'status', '--porcelain=v2', '--branch', '-z', '--untracked-files=all', '--find-renames=50%',
  ], { ...options, readOnly: true })
  if (!result.ok) return result
  try {
    return parseStatusV2(result.stdout.toString('utf8'))
  } catch (error) {
    return failure(`could not parse git status: ${error.message}`)
  }
}

function diff(repoRoot, file, options = {}) {
  const context = repositoryContext(repoRoot, options)
  if (!context.ok) return context
  const target = resolvePathspec(context, file)
  if (!target.ok) return target
  const arguments_ = ['diff', '--no-ext-diff', '--no-textconv', '--no-color', '--unified=3']
  if (options.staged) arguments_.push('--cached')
  arguments_.push('--', target.path)
  const result = executeGit(context, arguments_, {
    ...options,
    maxBuffer: DIFF_MAX_BYTES,
    readOnly: true,
    truncateOutput: true,
  })
  if (!result.ok) return result

  const wasTruncated = result.truncated || result.stdout.length > DIFF_MAX_BYTES
  if (!wasTruncated) return { ok: true, diff: result.stdout.toString('utf8'), truncated: false }
  const contentLimit = DIFF_MAX_BYTES - Buffer.byteLength(DIFF_TRUNCATION_MARKER)
  return {
    ok: true,
    diff: `${decodePrefix(result.stdout, contentLimit)}${DIFF_TRUNCATION_MARKER}`,
    truncated: true,
  }
}

function normalizeLogLimit(value) {
  if (value == null) return { ok: true, limit: 20 }
  const limit = Number(value)
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_LOG_LIMIT) {
    return failure(`log limit must be an integer from 1 to ${MAX_LOG_LIMIT}`)
  }
  return { ok: true, limit }
}

function log(repoRoot, options = {}) {
  const context = repositoryContext(repoRoot, options)
  if (!context.ok) return context
  const normalized = normalizeLogLimit(options.limit)
  if (!normalized.ok) return normalized
  const result = executeGit(context, [
    'log', '-z', '--no-show-signature', `--max-count=${normalized.limit}`,
    '--format=%H%x00%h%x00%an%x00%aI%x00%s',
  ], { ...options, readOnly: true })
  if (!result.ok) {
    if (/does not have any commits yet|bad default revision 'HEAD'/i.test(result.reason)) return []
    return result
  }

  const fields = result.stdout.toString('utf8').split('\0')
  if (fields.at(-1) === '') fields.pop()
  if (fields.length % 5 !== 0) return failure('could not parse git log output')
  const entries = []
  for (let index = 0; index < fields.length; index += 5) {
    entries.push({
      hash: fields[index],
      shortHash: fields[index + 1],
      author: fields[index + 2],
      date: fields[index + 3],
      subject: fields[index + 4],
    })
  }
  return entries
}

function stage(repoRoot, file, options = {}) {
  const context = repositoryContext(repoRoot, options)
  if (!context.ok) return context
  const target = resolvePathspec(context, file)
  if (!target.ok) return target
  const result = executeGit(context, ['add', '--', target.path], { ...options, readOnly: false })
  return result.ok ? { ok: true } : result
}

function unstage(repoRoot, file, options = {}) {
  const context = repositoryContext(repoRoot, options)
  if (!context.ok) return context
  const target = resolvePathspec(context, file)
  if (!target.ok) return target
  const result = executeGit(context, ['restore', '--staged', '--', target.path], { ...options, readOnly: false })
  return result.ok ? { ok: true } : result
}

function commit(repoRoot, message, options = {}) {
  const context = repositoryContext(repoRoot, options)
  if (!context.ok) return context
  if (typeof message !== 'string' || !message.trim()) return failure('commit message is required')
  if (message.includes('\0') || Buffer.byteLength(message) > 64 * 1024) return failure('commit message is invalid')

  const staged = executeGit(context, ['diff', '--cached', '--quiet', '--exit-code'], {
    ...options,
    allowedStatuses: [0, 1],
    readOnly: true,
  })
  if (!staged.ok) return staged
  if (staged.status === 0) return failure('nothing staged to commit')

  const committed = executeGit(context, ['commit', '-m', message], { ...options, readOnly: false })
  if (!committed.ok) return committed
  const revision = executeGit(context, ['rev-parse', 'HEAD'], { ...options, readOnly: true })
  if (!revision.ok) return revision
  const hash = revision.stdout.toString('utf8').trim()
  if (!/^[0-9a-f]{40,64}$/.test(hash)) return failure('git commit returned an invalid hash')
  return { ok: true, hash }
}

function usage() {
  return `Usage:
  node scripts/native-git-service.cjs status --repo <path> [--json]
  node scripts/native-git-service.cjs diff --repo <path> --path <file> [--staged] [--json]
  node scripts/native-git-service.cjs log --repo <path> [--limit N] [--json]
  node scripts/native-git-service.cjs stage --repo <path> <file> [--json]
  node scripts/native-git-service.cjs unstage --repo <path> <file> [--json]
  node scripts/native-git-service.cjs commit --repo <path> --message <message> [--json]

The repository root is always explicit; the service never uses the process cwd as a repository.
`
}

function parseCliArguments(argv) {
  const [command, ...rest] = argv
  if (!command || command === '--help' || command === '-h') return { help: true }
  const parsed = { command, positionals: [] }
  for (let index = 0; index < rest.length; index += 1) {
    const argument = rest[index]
    const take = () => {
      if (index + 1 >= rest.length) throw new Error(`${argument} requires a value`)
      index += 1
      return rest[index]
    }
    if (argument === '--repo') parsed.repoRoot = take()
    else if (argument === '--path') parsed.file = take()
    else if (argument === '--message') parsed.message = take()
    else if (argument === '--limit') parsed.limit = take()
    else if (argument === '--staged') parsed.staged = true
    else if (argument === '--json') parsed.json = true
    else if (argument.startsWith('--')) throw new Error(`unknown option: ${argument}`)
    else parsed.positionals.push(argument)
  }
  return parsed
}

function operationFromCli(options) {
  if (!options.repoRoot) return failure('--repo <path> is required')
  if (options.command === 'status') return status(options.repoRoot)
  if (options.command === 'diff') {
    if (!options.file) return failure('diff requires --path <file>')
    return diff(options.repoRoot, options.file, { staged: options.staged })
  }
  if (options.command === 'log') return log(options.repoRoot, { limit: options.limit })
  if (options.command === 'stage' || options.command === 'unstage') {
    if (options.positionals.length !== 1) return failure(`${options.command} requires exactly one file path`)
    return options.command === 'stage'
      ? stage(options.repoRoot, options.positionals[0])
      : unstage(options.repoRoot, options.positionals[0])
  }
  if (options.command === 'commit') {
    if (options.message == null) return failure('commit requires --message <message>')
    return commit(options.repoRoot, options.message)
  }
  return failure(`unknown command: ${options.command}`)
}

function main(argv = process.argv.slice(2)) {
  let options
  try {
    options = parseCliArguments(argv)
  } catch (error) {
    const result = failure(error.message)
    process.stdout.write(`${JSON.stringify(result)}\n`)
    process.exitCode = 1
    return result
  }
  if (options.help) {
    process.stdout.write(usage())
    return { ok: true }
  }

  const result = operationFromCli(options)
  if (options.command === 'diff' && !options.json && result.ok) process.stdout.write(result.diff)
  else process.stdout.write(`${JSON.stringify(result, null, options.json ? 2 : 0)}\n`)
  if (result && !Array.isArray(result) && result.ok === false) process.exitCode = 1
  return result
}

if (require.main === module) main()

module.exports = {
  DEFAULT_TIMEOUT_MS,
  DIFF_MAX_BYTES,
  MAX_LOG_LIMIT,
  commit,
  diff,
  getDiff: diff,
  getLog: log,
  getStatus: status,
  log,
  main,
  parseStatusV2,
  stage,
  stageFile: stage,
  status,
  unstage,
  unstageFile: unstage,
}
