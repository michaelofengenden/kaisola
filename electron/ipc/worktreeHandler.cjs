// Git worktree isolation for file-mutating (coding) agents. Each coding task
// gets its OWN git worktree + branch, so parallel agents never touch the same
// files. When the agent finishes, the branch diff is surfaced as a Proposal
// (file-patch); approving it merges the branch back — the Proposal gate becomes
// the merge gate. Pure local git via child_process: ZERO model/API cost.
//
// Lifecycle: create → (agent writes in the worktree cwd) → finalize (commit) →
//   diff (→ file-patch Proposal) → merge (on approve) → remove.
//
// Exposes registerWorktreeHandlers(ipcMain) for the app AND the raw async
// functions for the headless smoke harness to drive against a temp repo.
const { execFile } = require('child_process')
const fs = require('node:fs')
const path = require('path')

const WT_DIR = '.pasola-worktrees'
const GIT_OUTPUT_LIMIT = 32 * 1024 * 1024
const TASK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,159}$/
const isTaskId = (value) => {
  if (typeof value !== 'string') return false
  const match = TASK_ID_RE.exec(value)
  return match?.[0] === value
}
const isCommitId = (value) => typeof value === 'string' && /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i.test(value)
// canonicalRepo + taskId → { taskId, repo, path, branch, base, baseBranch }.
// task IDs are only unique inside a repository; keying by taskId alone can send
// an operation to the wrong project when two projects run the same Mesh task.
const worktrees = new Map()

const worktreeKey = (repo, taskId) => `${repo}\0${taskId}`

function git(cwd, args) {
  return new Promise((resolve) => {
    execFile('git', args, { cwd, maxBuffer: GIT_OUTPUT_LIMIT }, (err, stdout, stderr) => {
      const message = err ? String(err.message || err) : ''
      resolve({
        ok: !err,
        code: err ? err.code ?? 1 : 0,
        stdout: stdout ?? '',
        stderr: stderr ?? '',
        message,
        truncated: !!err && (err.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' || /maxBuffer length exceeded/i.test(message)),
      })
    })
  })
}

async function canonicalRepo(repo) {
  if (typeof repo !== 'string' || !repo.trim()) return { ok: false, message: 'invalid base repository' }
  try {
    const input = fs.realpathSync(repo)
    if (!fs.statSync(input).isDirectory()) return { ok: false, message: 'invalid base repository' }
    const top = await git(input, ['rev-parse', '--show-toplevel'])
    if (!top.ok || !top.stdout.trim()) return { ok: false, message: 'invalid base repository' }
    const root = fs.realpathSync(top.stdout.trim())
    if (!fs.statSync(root).isDirectory()) return { ok: false, message: 'invalid base repository' }
    return { ok: true, repo: root }
  } catch {
    return { ok: false, message: 'invalid base repository' }
  }
}

/** Resolve only the real repo's direct .pasola-worktrees/<taskId> child.
 * Refuse symlinked bookkeeping paths: `git worktree remove --force` must never
 * be handed a renderer-controlled path that resolves elsewhere on disk. */
function directWorktreePath(repo, taskId, { createBase = false } = {}) {
  if (!isTaskId(taskId)) return { ok: false, message: 'invalid worktree task id' }
  const base = path.join(repo, WT_DIR)
  try {
    if (createBase && !fs.existsSync(base)) fs.mkdirSync(base)
    if (fs.existsSync(base)) {
      const baseStat = fs.lstatSync(base)
      if (baseStat.isSymbolicLink() || !baseStat.isDirectory() || fs.realpathSync(base) !== base) {
        return { ok: false, message: 'unsafe worktree storage path' }
      }
    }
    const wtPath = path.join(base, taskId)
    if (path.dirname(wtPath) !== base) return { ok: false, message: 'unsafe worktree path' }
    if (!fs.existsSync(wtPath)) return { ok: true, path: wtPath, exists: false }
    const wtStat = fs.lstatSync(wtPath)
    if (wtStat.isSymbolicLink() || !wtStat.isDirectory() || fs.realpathSync(wtPath) !== wtPath) {
      return { ok: false, message: 'unsafe worktree path' }
    }
    return { ok: true, path: wtPath, exists: true }
  } catch {
    return { ok: false, message: 'could not validate the worktree path' }
  }
}

function validateCachedEntry(entry, taskId, repo) {
  if (!entry || entry.taskId !== taskId || entry.repo !== repo) {
    return { ok: false, message: 'invalid cached worktree state' }
  }
  const direct = directWorktreePath(repo, taskId)
  if (!direct.ok) return direct
  if (path.resolve(entry.path) !== direct.path) return { ok: false, message: 'unsafe cached worktree path' }
  return { ok: true, entry }
}

function diffFailure(result, label) {
  if (result.truncated) {
    return {
      ok: false,
      incomplete: true,
      message: `${label} exceeds the ${GIT_OUTPUT_LIMIT / (1024 * 1024)} MiB review limit. The review is incomplete, so this candidate cannot be approved.`,
    }
  }
  return {
    ok: false,
    incomplete: true,
    message: (result.stderr || result.message || result.stdout).trim().slice(0, 300) || `${label} failed; the candidate cannot be reviewed safely.`,
  }
}

async function create(repo, taskId) {
  if (!isTaskId(taskId)) return { ok: false, message: 'invalid worktree task id' }
  const canonical = await canonicalRepo(repo)
  if (!canonical.ok) return canonical
  repo = canonical.repo
  const key = worktreeKey(repo, taskId)
  if (worktrees.has(key)) return { ok: false, message: `worktree ${taskId} already exists` }
  // Every worker must branch from the exact project state the user approved.
  // Reject tracked *and* untracked changes: silently omitting a new source file
  // gives agents a coherent-looking but stale checkout.
  const status = await git(repo, ['status', '--porcelain', '--untracked-files=normal', '--', '.', ':(exclude).pasola-worktrees'])
  if (!status.ok) return { ok: false, message: (status.stderr || status.message).trim().slice(0, 300) || 'could not inspect the base repository' }
  if (status.stdout.trim()) return { ok: false, dirty: true, message: 'base repo has uncommitted or untracked changes — commit or stash them before Mesh execution' }
  const branch = `pz/${taskId}`
  const location = directWorktreePath(repo, taskId, { createBase: true })
  if (!location.ok) return location
  const head = await git(repo, ['rev-parse', 'HEAD'])
  const branchAtCreation = await git(repo, ['rev-parse', '--abbrev-ref', 'HEAD'])
  const base = head.stdout.trim()
  const baseBranch = branchAtCreation.stdout.trim()
  if (!head.ok || !base) return { ok: false, message: 'not a git repository (or it has no commits yet)' }
  if (!branchAtCreation.ok || !baseBranch) return { ok: false, message: 'could not resolve the base branch' }
  const r = await git(repo, ['worktree', 'add', '-b', branch, location.path])
  if (!r.ok) return { ok: false, message: (r.stderr || r.stdout).trim() || 'worktree add failed' }
  const createdLocation = directWorktreePath(repo, taskId)
  if (!createdLocation.ok || !createdLocation.exists) {
    return { ok: false, message: createdLocation.message || 'worktree was created outside its safe storage path' }
  }
  const wtPath = createdLocation.path
  // Branch-local git config is the durable journal for the intended merge
  // target. It survives renderer/main restarts and cannot be reconstructed
  // safely from whichever branch happens to be checked out later.
  const baseSaved = await git(repo, ['config', '--local', `branch.${branch}.kaisolaBase`, base])
  const targetSaved = await git(repo, ['config', '--local', `branch.${branch}.kaisolaBaseBranch`, baseBranch])
  if (!baseSaved.ok || !targetSaved.ok) {
    await git(repo, ['worktree', 'remove', '--force', wtPath])
    await git(repo, ['branch', '-D', branch])
    return { ok: false, message: 'could not persist the Mesh base branch journal' }
  }
  worktrees.set(key, { taskId, repo, path: wtPath, branch, base, baseBranch })
  return { ok: true, path: wtPath, branch, base, baseBranch }
}

// The Map is in-memory but worktrees are DISK state that outlives the app.
// Callers that persisted a taskId pass `repo` along; the entry rebuilds from
// the deterministic layout (repo/.pasola-worktrees/<taskId>, branch pz/<id>).
async function rehydrate(taskId, repo) {
  const key = worktreeKey(repo, taskId)
  const cached = worktrees.get(key)
  if (cached) return { ...validateCachedEntry(cached, taskId, repo), key }
  const location = directWorktreePath(repo, taskId)
  if (!location.ok) return { ...location, key }
  if (!location.exists) return { ok: true, key, entry: undefined }
  const branch = `pz/${taskId}`
  const savedBase = await git(repo, ['config', '--local', '--get', `branch.${branch}.kaisolaBase`])
  const savedBranch = await git(repo, ['config', '--local', '--get', `branch.${branch}.kaisolaBaseBranch`])
  let base = savedBase.stdout.trim()
  if (!base) {
    const fallback = await git(repo, ['merge-base', 'HEAD', branch])
    if (!fallback.ok || !fallback.stdout.trim()) return { ok: false, key, message: 'could not restore the worktree base journal' }
    base = fallback.stdout.trim()
  }
  const baseBranch = savedBranch.stdout.trim()
  const entry = { taskId, repo, path: location.path, branch, base, baseBranch }
  worktrees.set(key, entry)
  return { ok: true, key, entry }
}

async function resolveWorktree(taskId, repo) {
  if (!isTaskId(taskId)) return { ok: false, message: 'invalid worktree task id' }
  if (repo !== undefined && repo !== null) {
    const canonical = await canonicalRepo(repo)
    if (!canonical.ok) return canonical
    const hydrated = await rehydrate(taskId, canonical.repo)
    return { ...hydrated, repo: canonical.repo }
  }

  const matches = [...worktrees.entries()].filter(([, entry]) => entry.taskId === taskId)
  if (matches.length > 1) return { ok: false, message: 'worktree repository is required because this task id exists in multiple projects' }
  if (!matches.length) return { ok: true, entry: undefined }
  const [key, entry] = matches[0]
  const checked = validateCachedEntry(entry, taskId, entry.repo)
  return { ...checked, key, repo: entry.repo }
}

async function finalize(taskId, message, repo) {
  const resolved = await resolveWorktree(taskId, repo)
  if (!resolved.ok) return resolved
  const wt = resolved.entry
  if (!wt) return { ok: false, message: 'unknown worktree' }
  const added = await git(wt.path, ['add', '-A'])
  // a FAILED stage (stale .git/index.lock, disk-full, permissions) must fail
  // loudly too — otherwise `diff --cached` below sees nothing staged and we'd
  // merge the branch WITHOUT the agent's newest edits while toasting success.
  if (!added.ok) return { ok: false, message: (added.stderr || added.stdout).trim().slice(0, 300) || 'git add failed in the worktree' }
  // nothing staged = nothing to commit = fine. But a FAILED commit of real
  // changes must fail loudly — merging the stale branch would drop them.
  const staged = await git(wt.path, ['diff', '--cached', '--quiet'])
  let committed = false
  if (!staged.ok) {
    const c = await git(wt.path, ['commit', '-m', message || `pasola: ${taskId}`])
    if (!c.ok) return { ok: false, message: (c.stderr || c.stdout).trim().slice(0, 300) || 'commit failed in the worktree' }
    committed = true
  }
  const head = await git(wt.path, ['rev-parse', 'HEAD'])
  if (!head.ok || !head.stdout.trim()) return { ok: false, message: 'could not resolve the frozen candidate commit' }
  return { ok: true, committed, sha: head.stdout.trim() }
}

async function diff(taskId, repo, ref) {
  const resolvedWorktree = await resolveWorktree(taskId, repo)
  if (!resolvedWorktree.ok) return resolvedWorktree
  const wt = resolvedWorktree.entry
  if (!wt) return { ok: false, message: 'unknown worktree' }
  if (ref && !isCommitId(ref)) return { ok: false, message: 'review candidate must be an exact commit id' }
  const target = ref || wt.branch
  const resolved = await git(wt.repo, ['rev-parse', '--verify', `${target}^{commit}`])
  if (!resolved.ok) return { ok: false, message: 'review candidate commit no longer exists' }
  const sha = resolved.stdout.trim()
  const patch = await git(wt.repo, ['diff', wt.base, sha])
  if (!patch.ok) return diffFailure(patch, 'Worktree patch')
  const ns = await git(wt.repo, ['diff', '--numstat', wt.base, sha])
  if (!ns.ok) return diffFailure(ns, 'Worktree file summary')
  const files = ns.stdout
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      const [add, del, p] = line.split('\t')
      return { path: p, additions: Number(add) || 0, deletions: Number(del) || 0 }
    })
  return { ok: true, patch: patch.stdout, files, sha }
}

/** Preflight every frozen candidate before the first merge mutates main. This
 * keeps a multi-member integration atomic with respect to the common case of a
 * worker changing after review; merge() repeats the check to close the race. */
async function verify(taskId, repo, ref) {
  const resolvedWorktree = await resolveWorktree(taskId, repo)
  if (!resolvedWorktree.ok) return resolvedWorktree
  const wt = resolvedWorktree.entry
  if (!wt) return { ok: false, message: 'unknown worktree' }
  if (!isCommitId(ref)) return { ok: false, drifted: false, message: 'review candidate must be an exact commit id' }
  const resolved = await git(wt.repo, ['rev-parse', '--verify', `${ref}^{commit}`])
  if (!resolved.ok) return { ok: false, drifted: false, message: 'review candidate commit no longer exists' }
  const head = await git(wt.path, ['rev-parse', 'HEAD'])
  const workerStatus = await git(wt.path, ['status', '--porcelain'])
  if (!head.ok || !workerStatus.ok || head.stdout.trim() !== ref || workerStatus.stdout.trim()) {
    return { ok: false, drifted: true, message: 'candidate changed after review — cross-review it again before integration' }
  }
  return { ok: true, drifted: false, sha: resolved.stdout.trim() }
}

async function merge(taskId, repo, ref) {
  const resolvedWorktree = await resolveWorktree(taskId, repo)
  if (!resolvedWorktree.ok) return resolvedWorktree
  const wt = resolvedWorktree.entry
  if (!wt) return { ok: false, message: 'unknown worktree' }
  if (ref && !isCommitId(ref)) return { ok: false, conflicted: false, message: 'review candidate must be an exact commit id' }
  // refuse to merge into a detached HEAD — the merge commit would advance no
  // branch ref and be lost on the next checkout.
  const sym = await git(wt.repo, ['symbolic-ref', '-q', 'HEAD'])
  if (!sym.ok) return { ok: false, conflicted: false, message: 'base repo is in detached HEAD — check out a branch first' }
  const branchResult = await git(wt.repo, ['rev-parse', '--abbrev-ref', 'HEAD'])
  if (!branchResult.ok) return { ok: false, conflicted: false, message: 'could not inspect the base branch' }
  const currentBranch = branchResult.stdout.trim()
  if (!wt.baseBranch) return { ok: false, conflicted: false, wrongBranch: true, message: 'the original base branch journal is missing — recreate this worktree before merging' }
  if (currentBranch !== wt.baseBranch) {
    return { ok: false, conflicted: false, wrongBranch: true, message: `base repo is on ${currentBranch || 'an unknown branch'}; switch back to ${wt.baseBranch} before merging` }
  }
  // refuse to merge into a dirty working tree — but only TRACKED changes (a merge
  // can't clobber untracked files, and the .pasola-worktrees/ dir itself is
  // untracked, so -uno avoids a false positive).
  const status = await git(wt.repo, ['status', '--porcelain', '--untracked-files=no'])
  if (!status.ok) return { ok: false, conflicted: false, message: 'could not inspect the base repository' }
  if (status.stdout.trim()) return { ok: false, conflicted: false, message: 'base repo has uncommitted changes — commit or stash them first' }
  const target = ref || wt.branch
  if (ref) {
    const frozen = await verify(taskId, repo, ref)
    if (!frozen.ok) return { ...frozen, conflicted: false }
  }
  const m = await git(wt.repo, ['merge', '--no-ff', '-m', `pasola merge ${taskId}`, target])
  if (!m.ok) {
    const conflicted = /conflict/i.test(`${m.stdout}${m.stderr}`)
    // ALWAYS abort on failure (a no-op if no merge is in progress) so the base
    // repo is never left half-merged, regardless of git's message wording/locale.
    await git(wt.repo, ['merge', '--abort'])
    return { ok: false, conflicted, message: (m.stderr || m.stdout).trim() || 'merge failed' }
  }
  return { ok: true, conflicted: false }
}

async function remove(taskId, repo) {
  const resolved = await resolveWorktree(taskId, repo)
  if (!resolved.ok) return resolved
  const wt = resolved.entry
  if (!wt) {
    // the worktree DIR is already gone (rehydrate bailed on !existsSync), but its
    // registration and the pz/<taskId> branch can still linger — prune + delete
    // so nothing leaks. Needs `repo`; without it there is nothing we can reach.
    if (!resolved.repo) return { ok: true }
    await git(resolved.repo, ['worktree', 'prune'])
    const branch = `pz/${taskId}`
    const present = await git(resolved.repo, ['show-ref', '--verify', '--quiet', `refs/heads/${branch}`])
    const br = present.ok ? await git(resolved.repo, ['branch', '-D', branch]) : { ok: true, stdout: '', stderr: '' }
    const remains = await git(resolved.repo, ['show-ref', '--verify', '--quiet', `refs/heads/${branch}`])
    if (!br.ok && remains.ok) return { ok: false, message: (br.stderr || br.stdout).trim().slice(0, 300) || 'worktree branch removal failed' }
    if (resolved.key) worktrees.delete(resolved.key)
    return { ok: true }
  }
  // Each resource is independently retryable. A previous attempt may have
  // removed the directory but failed to delete the branch (or vice versa), so
  // missing already means success instead of wedging forever on a stale Map.
  const location = directWorktreePath(wt.repo, taskId)
  if (!location.ok) return location
  if (location.path !== wt.path) return { ok: false, message: 'unsafe cached worktree path' }
  const rm = location.exists
    ? await git(wt.repo, ['worktree', 'remove', '--force', location.path])
    : { ok: true, stdout: '', stderr: '' }
  const afterRemove = directWorktreePath(wt.repo, taskId)
  if (!afterRemove.ok) return afterRemove
  if (afterRemove.exists) {
    return { ok: false, message: (rm.stderr || rm.stdout).trim().slice(0, 300) || 'worktree remove failed' }
  }
  await git(wt.repo, ['worktree', 'prune'])
  const branchPresent = await git(wt.repo, ['show-ref', '--verify', '--quiet', `refs/heads/${wt.branch}`])
  const br = branchPresent.ok
    ? await git(wt.repo, ['branch', '-D', wt.branch])
    : { ok: true, stdout: '', stderr: '' }
  const branchRemains = (await git(wt.repo, ['show-ref', '--verify', '--quiet', `refs/heads/${wt.branch}`])).ok
  if (branchRemains) {
    // Leave the entry registered so a later retry can finish whichever half
    // remains; successful halves are recognized above and never retried.
    return { ok: false, message: (br.stderr || br.stdout).trim().slice(0, 300) || 'worktree branch removal failed' }
  }
  worktrees.delete(resolved.key)
  return { ok: true }
}

async function list(repo) {
  const canonical = await canonicalRepo(repo)
  if (!canonical.ok) return canonical
  const r = await git(canonical.repo, ['worktree', 'list', '--porcelain'])
  return { ok: r.ok, raw: r.stdout, message: r.ok ? undefined : (r.stderr || r.message).trim().slice(0, 300) }
}

function registerWorktreeHandlers(ipcMain) {
  ipcMain.handle('worktree:create', (_e, { repo, taskId }) => create(repo, taskId))
  ipcMain.handle('worktree:finalize', (_e, { taskId, message, repo }) => finalize(taskId, message, repo))
  ipcMain.handle('worktree:diff', (_e, { taskId, repo, ref }) => diff(taskId, repo, ref))
  ipcMain.handle('worktree:verify', (_e, { taskId, repo, ref }) => verify(taskId, repo, ref))
  ipcMain.handle('worktree:merge', (_e, { taskId, repo, ref }) => merge(taskId, repo, ref))
  ipcMain.handle('worktree:remove', (_e, { taskId, repo }) => remove(taskId, repo))
  ipcMain.handle('worktree:list', (_e, { repo }) => list(repo))
}

module.exports = { registerWorktreeHandlers, create, finalize, diff, verify, merge, remove, list }
