const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const Module = require('node:module')
const { execFileSync } = require('node:child_process')

const { registerGitHandlers } = require('./ipc/gitHandler.cjs')

const git = (cwd, args) => execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()

function repoFixture() {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-checkpoint-ref-'))
  git(repo, ['init'])
  git(repo, ['config', 'user.name', 'Kaisola Test'])
  git(repo, ['config', 'user.email', 'test@kaisola.local'])
  fs.writeFileSync(path.join(repo, 'base.txt'), 'base\n')
  git(repo, ['add', 'base.txt'])
  git(repo, ['commit', '-m', 'base'])
  return repo
}

function captureHandlers() {
  const handlers = new Map()
  registerGitHandlers({
    handle(channel, handler) {
      handlers.set(channel, handler)
    },
  })
  return (channel, payload) => handlers.get(channel)({}, payload)
}

test('checkpoint IPC rejects option-like refs before Git or Trash can mutate files', async (t) => {
  const repo = repoFixture()
  const checkpointDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-checkpoint-store-'))
  const output = path.join(os.tmpdir(), `kaisola-git-option-output-${process.pid}-${Date.now().toString(36)}`)
  const priorCheckpointDir = process.env.PASOLA_CKPT_DIR
  process.env.PASOLA_CKPT_DIR = checkpointDir
  fs.rmSync(output, { force: true })
  t.after(() => {
    if (priorCheckpointDir === undefined) delete process.env.PASOLA_CKPT_DIR
    else process.env.PASOLA_CKPT_DIR = priorCheckpointDir
    fs.rmSync(output, { force: true })
    fs.rmSync(checkpointDir, { recursive: true, force: true })
    fs.rmSync(repo, { recursive: true, force: true })
  })

  const untracked = path.join(repo, 'keep-untracked.txt')
  fs.writeFileSync(untracked, 'must survive\n')
  const invoke = captureHandlers()
  const maliciousOutputRef = `--output=${output}`
  const trashCalls = []
  const originalLoad = Module._load
  Module._load = function loadWithFakeElectron(request, parent, isMain) {
    if (request === 'electron') return { shell: { trashItem: async (file) => { trashCalls.push(file) } } }
    return originalLoad.call(this, request, parent, isMain)
  }
  let invalidRestore
  try {
    // Without the validator, `--cached` makes the legacy fallback classify
    // every current untracked path as absent from the checkpoint and Trash it.
    invalidRestore = await invoke('git:restore', { cwd: repo, sha: '--cached' })
  } finally {
    Module._load = originalLoad
  }

  for (const result of [
    await invoke('git:changes', { cwd: repo, sha: maliciousOutputRef }),
    await invoke('git:show', { cwd: repo, sha: maliciousOutputRef, file: 'base.txt' }),
    invalidRestore,
  ]) {
    assert.equal(result.ok, false)
    assert.equal(result.invalidCheckpoint, true)
    assert.match(result.message, /exact commit id/)
  }
  assert.deepEqual(trashCalls, [])
  assert.equal(fs.existsSync(output), false)
  assert.equal(fs.readFileSync(untracked, 'utf8'), 'must survive\n')

  // Immutable checkpoint IDs remain functional, as do the Git panel's two
  // fixed non-option views (HEAD and the stage-0 index).
  const sha = git(repo, ['rev-parse', 'HEAD'])
  const changed = await invoke('git:changes', { cwd: repo, sha })
  assert.equal(changed.ok, true)
  assert.deepEqual(changed.files, [{ status: 'A', path: 'keep-untracked.txt' }])
  assert.equal((await invoke('git:show', { cwd: repo, sha, file: 'base.txt' })).content, 'base\n')
  assert.equal((await invoke('git:show', { cwd: repo, sha: 'HEAD', file: 'base.txt' })).content, 'base\n')
  fs.writeFileSync(path.join(repo, 'base.txt'), 'staged\n')
  git(repo, ['add', 'base.txt'])
  assert.equal((await invoke('git:show', { cwd: repo, sha: ':0', file: 'base.txt' })).content, 'staged\n')
})
