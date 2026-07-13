const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const worktree = require('./ipc/worktreeHandler.cjs')

const git = (cwd, args) => execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()

function repoFixture() {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-reviewed-sha-'))
  git(repo, ['init'])
  git(repo, ['config', 'user.name', 'Kaisola Test'])
  git(repo, ['config', 'user.email', 'test@kaisola.local'])
  fs.writeFileSync(path.join(repo, 'base.txt'), 'base\n')
  git(repo, ['add', 'base.txt'])
  git(repo, ['commit', '-m', 'base'])
  return repo
}

test('Mesh merges the exact reviewed commit and rejects post-review drift', async () => {
  const repo = repoFixture()
  const taskId = `reviewed-${Date.now().toString(36)}`
  try {
    const created = await worktree.create(repo, taskId)
    assert.equal(created.ok, true)
    fs.writeFileSync(path.join(created.path, 'candidate.txt'), 'reviewed\n')
    const frozen = await worktree.finalize(taskId, 'candidate', repo)
    assert.equal(frozen.ok, true)
    assert.match(frozen.sha, /^[0-9a-f]{40}$/)
    const reviewed = await worktree.diff(taskId, repo, frozen.sha)
    assert.equal(reviewed.ok, true)
    assert.equal(reviewed.sha, frozen.sha)
    assert.match(reviewed.patch, /candidate\.txt/)
    const verified = await worktree.verify(taskId, repo, frozen.sha)
    assert.deepEqual(verified, { ok: true, drifted: false, sha: frozen.sha })
    const invalidRef = await worktree.diff(taskId, repo, '--help')
    assert.equal(invalidRef.ok, false)
    assert.match(invalidRef.message, /exact commit id/)
    const invalidVerify = await worktree.verify(taskId, repo, '--help')
    assert.equal(invalidVerify.ok, false)
    assert.match(invalidVerify.message, /exact commit id/)

    fs.writeFileSync(path.join(created.path, 'after-review.txt'), 'not reviewed\n')
    const driftedPreflight = await worktree.verify(taskId, repo, frozen.sha)
    assert.equal(driftedPreflight.ok, false)
    assert.equal(driftedPreflight.drifted, true)
    const drifted = await worktree.merge(taskId, repo, frozen.sha)
    assert.equal(drifted.ok, false)
    assert.equal(drifted.drifted, true)
    assert.match(drifted.message, /changed after review/)
    assert.equal(fs.existsSync(path.join(repo, 'candidate.txt')), false)
  } finally {
    await worktree.remove(taskId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('Mesh accepts an unchanged reviewed commit', async () => {
  const repo = repoFixture()
  const taskId = `unchanged-${Date.now().toString(36)}`
  try {
    const created = await worktree.create(repo, taskId)
    fs.writeFileSync(path.join(created.path, 'candidate.txt'), 'reviewed\n')
    const frozen = await worktree.finalize(taskId, 'candidate', repo)
    const merged = await worktree.merge(taskId, repo, frozen.sha)
    assert.equal(merged.ok, true)
    assert.equal(fs.readFileSync(path.join(repo, 'candidate.txt'), 'utf8'), 'reviewed\n')
  } finally {
    await worktree.remove(taskId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('Mesh never merges a reviewed commit into a different checked-out branch', async () => {
  const repo = repoFixture()
  const taskId = `wrong-branch-${Date.now().toString(36)}`
  try {
    const created = await worktree.create(repo, taskId)
    assert.equal(created.ok, true)
    fs.writeFileSync(path.join(created.path, 'candidate.txt'), 'reviewed\n')
    const frozen = await worktree.finalize(taskId, 'candidate', repo)
    git(repo, ['switch', '-c', 'other-target'])
    const rejected = await worktree.merge(taskId, repo, frozen.sha)
    assert.equal(rejected.ok, false)
    assert.equal(rejected.wrongBranch, true)
    assert.match(rejected.message, new RegExp(created.baseBranch))
    assert.equal(fs.existsSync(path.join(repo, 'candidate.txt')), false)
  } finally {
    await worktree.remove(taskId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('Mesh refuses to branch from tracked or untracked base changes', async () => {
  const repo = repoFixture()
  try {
    fs.writeFileSync(path.join(repo, 'untracked.txt'), 'not in HEAD\n')
    const untracked = await worktree.create(repo, `dirty-untracked-${Date.now().toString(36)}`)
    assert.equal(untracked.ok, false)
    assert.equal(untracked.dirty, true)
    assert.match(untracked.message, /commit or stash/)

    fs.rmSync(path.join(repo, 'untracked.txt'))
    fs.writeFileSync(path.join(repo, 'base.txt'), 'modified\n')
    const tracked = await worktree.create(repo, `dirty-tracked-${Date.now().toString(36)}`)
    assert.equal(tracked.ok, false)
    assert.equal(tracked.dirty, true)
  } finally {
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('Kaisola worktree bookkeeping does not make the base look dirty', async () => {
  const repo = repoFixture()
  const firstId = `parallel-a-${Date.now().toString(36)}`
  const secondId = `parallel-b-${Date.now().toString(36)}`
  try {
    const first = await worktree.create(repo, firstId)
    const second = await worktree.create(repo, secondId)
    assert.equal(first.ok, true)
    assert.equal(second.ok, true)
  } finally {
    await worktree.remove(firstId, repo)
    await worktree.remove(secondId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('worktree cleanup retries a stale entry after the directory was already removed', async () => {
  const repo = repoFixture()
  const taskId = `cleanup-${Date.now().toString(36)}`
  try {
    const created = await worktree.create(repo, taskId)
    assert.equal(created.ok, true)
    // Simulate a prior partial cleanup: git removed/unregistered the worktree,
    // but the process failed before deleting its branch or in-memory entry.
    git(repo, ['worktree', 'remove', '--force', created.path])
    assert.equal(fs.existsSync(created.path), false)
    assert.equal(git(repo, ['show-ref', '--verify', `refs/heads/${created.branch}`]).length > 0, true)

    const removed = await worktree.remove(taskId, repo)
    assert.equal(removed.ok, true)
    assert.equal(git(repo, ['branch', '--list', created.branch]), '')
  } finally {
    await worktree.remove(taskId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('worktree operations reject traversal and cannot delete a sibling registered worktree', async () => {
  const repo = repoFixture()
  const victim = path.join(os.tmpdir(), `kaisola-worktree-victim-${process.pid}-${Date.now().toString(36)}`)
  const victimBranch = `victim-${Date.now().toString(36)}`
  fs.rmSync(victim, { recursive: true, force: true })
  try {
    git(repo, ['worktree', 'add', '-b', victimBranch, victim])
    const traversal = path.relative(path.join(repo, '.pasola-worktrees'), victim)
    assert.match(traversal, /\.\.[/\\]/)

    const rejected = [
      await worktree.create(repo, traversal),
      await worktree.finalize(traversal, 'must not run', repo),
      await worktree.diff(traversal, repo),
      await worktree.verify(traversal, repo, '0'.repeat(40)),
      await worktree.merge(traversal, repo, '0'.repeat(40)),
      await worktree.remove(traversal, repo),
    ]
    for (const result of rejected) {
      assert.equal(result.ok, false)
      assert.match(result.message, /invalid worktree task id/)
    }
    assert.equal(fs.existsSync(victim), true)
    assert.match(git(repo, ['worktree', 'list', '--porcelain']), new RegExp(victim.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  } finally {
    try { git(repo, ['worktree', 'remove', '--force', victim]) } catch {}
    try { git(repo, ['branch', '-D', victimBranch]) } catch {}
    fs.rmSync(victim, { recursive: true, force: true })
    fs.rmSync(repo, { recursive: true, force: true })
  }
})

test('worktree cache isolates identical task ids across canonical repositories', async () => {
  const firstRepo = repoFixture()
  const secondRepo = repoFixture()
  const taskId = `shared-${Date.now().toString(36)}`
  try {
    const first = await worktree.create(firstRepo, taskId)
    const second = await worktree.create(secondRepo, taskId)
    assert.equal(first.ok, true)
    assert.equal(second.ok, true)
    assert.notEqual(first.path, second.path)

    const ambiguous = await worktree.diff(taskId)
    assert.equal(ambiguous.ok, false)
    assert.match(ambiguous.message, /repository is required/)
    assert.equal((await worktree.diff(taskId, firstRepo)).ok, true)
    assert.equal((await worktree.diff(taskId, secondRepo)).ok, true)
  } finally {
    await worktree.remove(taskId, firstRepo)
    await worktree.remove(taskId, secondRepo)
    fs.rmSync(firstRepo, { recursive: true, force: true })
    fs.rmSync(secondRepo, { recursive: true, force: true })
  }
})

test('worktree review fails closed instead of returning a truncated oversized patch', async () => {
  const repo = repoFixture()
  const taskId = `oversized-${Date.now().toString(36)}`
  try {
    const created = await worktree.create(repo, taskId)
    assert.equal(created.ok, true)
    // One long line makes Git emit a patch larger than execFile's review cap.
    fs.writeFileSync(path.join(created.path, 'oversized.txt'), 'A'.repeat(34 * 1024 * 1024))
    const frozen = await worktree.finalize(taskId, 'oversized candidate', repo)
    assert.equal(frozen.ok, true)

    const reviewed = await worktree.diff(taskId, repo, frozen.sha)
    assert.equal(reviewed.ok, false)
    assert.equal(reviewed.incomplete, true)
    assert.match(reviewed.message, /review (?:is )?incomplete|cannot be reviewed safely/i)
    assert.equal(Object.hasOwn(reviewed, 'patch'), false)
  } finally {
    await worktree.remove(taskId, repo)
    fs.rmSync(repo, { recursive: true, force: true })
  }
})
