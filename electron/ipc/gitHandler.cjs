// Git plumbing for the workspace: status tinting for the tree, and Zed-style
// checkpoints — a snapshot of the ENTIRE working tree (incl. untracked) taken
// before each agent turn, restorable at any time.
//
// Checkpoints live in a SHADOW GIT_DIR under userData (OpenCode's isolation
// pattern): a bare repo per workspace pointed at the real working tree via
// GIT_WORK_TREE. Nothing is ever written into the user's own `.git`, so
// `git gc`, ref-namespace tools, and worktree pruning can never eat a
// checkpoint — and the user's index/staging area stays untouched.
//
// Older checkpoints (pre-shadow) were commits on hidden refs inside the real
// repo; every read path falls back there when a sha isn't in the shadow.
const { execFile } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const MAX_BUFFER = 32 * 1024 * 1024
const COMMIT_ID_RE = /^[0-9a-f]{40}(?:[0-9a-f]{24})?$/i
const isCommitId = (value) => {
  if (typeof value !== 'string') return false
  const match = COMMIT_ID_RE.exec(value)
  return match?.[0] === value
}
const invalidCheckpoint = () => ({
  ok: false,
  invalidCheckpoint: true,
  message: 'Checkpoint must be an exact commit id.',
})

function git(cwd, args, env) {
  return new Promise((resolve) => {
    execFile('git', args, { cwd, maxBuffer: MAX_BUFFER, env: env ? { ...process.env, ...env } : process.env }, (err, stdout, stderr) => {
      resolve({ ok: !err, code: err ? err.code ?? 1 : 0, stdout: stdout ?? '', stderr: stderr ?? '' })
    })
  })
}

// repoRoot is asked on EVERY git IPC call, and the rail / git panel / files
// view all refresh inside the same debounce window after a change — that was
// a `git rev-parse` spawn per caller. A short TTL keeps a mid-session
// `git init` discoverable while collapsing the storm to one spawn.
const ROOT_TTL_MS = 15_000
const ROOT_CACHE_LIMIT = 256
const rootCache = new Map() // cwd → { at, root } (root may be null: not a repo)
async function repoRoot(cwd) {
  const hit = rootCache.get(cwd)
  if (hit && Date.now() - hit.at < ROOT_TTL_MS) return hit.root
  const r = await git(cwd, ['rev-parse', '--show-toplevel'])
  const root = r.ok ? r.stdout.trim() : null
  rootCache.delete(cwd)
  rootCache.set(cwd, { at: Date.now(), root })
  if (rootCache.size > ROOT_CACHE_LIMIT) rootCache.delete(rootCache.keys().next().value)
  return root
}

// ── the shadow repo ──────────────────────────────────────────────────────────

function checkpointBaseDir() {
  if (process.env.PASOLA_CKPT_DIR) return process.env.PASOLA_CKPT_DIR // tests
  // lazy: gitHandler loads in harnesses before app is ready
  const { app } = require('electron')
  return path.join(app.getPath('userData'), 'checkpoints')
}

const shadowReady = new Set()
/** id → which snapshot tree the shadow's index currently mirrors */
const shadowIndexAt = new Map()

function shadowDirFor(root) {
  const id = crypto.createHash('sha1').update(root).digest('hex').slice(0, 12)
  return path.join(checkpointBaseDir(), id)
}

/** git against the shadow dir, operating on the REAL working tree. */
function sgit(root, args, extraEnv) {
  return git(root, args, {
    GIT_DIR: shadowDirFor(root),
    GIT_WORK_TREE: root,
    ...(extraEnv || {}),
  })
}

async function ensureShadow(root) {
  const dir = shadowDirFor(root)
  if (shadowReady.has(dir)) return dir
  if (!fs.existsSync(path.join(dir, 'HEAD'))) {
    fs.mkdirSync(dir, { recursive: true })
    const r = await git(root, ['init', '--bare', dir])
    if (!r.ok) return null
  }
  shadowReady.add(dir)
  return dir
}

/** Does the shadow have this object? Legacy checkpoints live in the real repo. */
async function inShadow(root, sha) {
  if (!isCommitId(sha)) return false
  const r = await sgit(root, ['cat-file', '-e', `${sha}^{commit}`])
  return r.ok
}

/** Point the shadow's MAIN index at a snapshot tree (status diffs against it). */
async function ensureIndexAt(root, sha) {
  if (!isCommitId(sha)) return false
  const dir = shadowDirFor(root)
  if (shadowIndexAt.get(dir) === sha) return true
  const r = await sgit(root, ['read-tree', sha])
  if (r.ok) shadowIndexAt.set(dir, sha)
  return r.ok
}

// The shadow repo has ONE index ($GIT_DIR/index) shared by every op on a root.
// read-tree/status/checkout each read-then-write it across await boundaries, so
// two overlapping ops would diff/restore against the wrong tree (or collide on
// index.lock). Chain each root's index ops so they run strictly one at a time —
// the tail promise IS the lock, and it releases even on error (the next op
// chains on a swallowed settle).
const indexLocks = new Map() // shadow dir → tail Promise of the last queued op
function withIndexLock(root, fn) {
  const key = shadowDirFor(root)
  const prev = indexLocks.get(key) || Promise.resolve()
  const run = prev.then(() => fn(), () => fn())
  const tail = run.then(() => {}, () => {})
  indexLocks.set(key, tail)
  tail.then(() => { if (indexLocks.get(key) === tail) indexLocks.delete(key) })
  return run
}

/** Working-tree snapshot: temp index → add -A → write-tree → commit-tree. */
async function snapshot(root, label) {
  if (!(await ensureShadow(root))) return { ok: false, message: 'could not create checkpoint store' }
  const tmpIndex = path.join(os.tmpdir(), `pasola-index-${Date.now()}-${Math.random().toString(36).slice(2)}`)
  const env = { GIT_INDEX_FILE: tmpIndex }
  try {
    const add = await sgit(root, ['add', '-A', '.'], env)
    if (!add.ok) return { ok: false, message: add.stderr.trim() || 'git add failed' }
    const tree = await sgit(root, ['write-tree'], env)
    if (!tree.ok) return { ok: false, message: tree.stderr.trim() || 'git write-tree failed' }
    const commit = await sgit(root, [
      '-c', 'user.name=Kaisola', '-c', 'user.email=checkpoint@kaisola.local',
      'commit-tree', tree.stdout.trim(), '-m', label || 'Kaisola checkpoint',
    ])
    if (!commit.ok) return { ok: false, message: commit.stderr.trim() || 'git commit-tree failed' }
    const sha = commit.stdout.trim()
    // a ref inside the SHADOW keeps its own gc honest; the real repo never sees it
    await sgit(root, ['update-ref', `refs/ckpt/${Date.now()}`, sha])
    // aim the shadow index at the new snapshot so the next status diff is warm
    await withIndexLock(root, () => ensureIndexAt(root, sha))
    return { ok: true, sha }
  } finally {
    fs.promises.unlink(tmpIndex).catch(() => {})
  }
}

/** name-status list of what changed since a SHADOW snapshot (status-based:
 *  stat-cache fast after the first pass, and untracked files just work). */
async function shadowChanges(root, sha) {
  if (!isCommitId(sha)) return invalidCheckpoint()
  return withIndexLock(root, async () => {
    if (!(await ensureIndexAt(root, sha))) return { ok: false, message: 'checkpoint not found' }
    const st = await sgit(root, ['status', '--porcelain=v1', '-z', '--untracked-files=all'])
    if (!st.ok) return { ok: false, message: st.stderr.trim() }
    const files = []
    for (const rec of st.stdout.split('\0')) {
      if (!rec || rec.length < 4) continue
      const x = rec[0]
      const y = rec[1]
      const p = rec.slice(3)
      // the shadow has no HEAD branch, so the X (vs-HEAD) column is pure noise —
      // identity lives in Y (snapshot index vs worktree) and '??' (new files)
      if (x === '?') files.push({ status: 'A', path: p })
      else if (y !== ' ') files.push({ status: y, path: p })
    }
    return { ok: true, files }
  })
}

// ── legacy (pre-shadow) checkpoints: commits on hidden refs in the REAL repo ──

async function legacyChanges(root, sha) {
  if (!isCommitId(sha)) return invalidCheckpoint()
  const seen = new Set()
  const files = []
  const st = await git(root, ['status', '--porcelain=v1', '-z', '--untracked-files=all'])
  if (!st.ok) return { ok: false, message: st.stderr.trim() }
  const untrackedPaths = []
  const untrackedSet = new Set()
  for (const rec of st.stdout.split('\0')) {
    if (!rec || rec.length < 4) continue
    if (rec[0] === '?') {
      untrackedPaths.push(rec.slice(3))
      untrackedSet.add(rec.slice(3))
    }
  }
  const diff = await git(root, ['diff', '--name-status', '--no-renames', sha])
  if (!diff.ok) return { ok: false, message: diff.stderr.trim() }
  for (const l of diff.stdout.split('\n')) {
    const line = l.trim()
    if (!line) continue
    const [status, ...rest] = line.split('\t')
    const p = rest.join('\t')
    if (untrackedSet.has(p)) continue // classified by the hash pass below
    if (!seen.has(p)) {
      seen.add(p)
      files.push({ status: status.trim()[0], path: p })
    }
  }
  if (untrackedPaths.length) {
    const tree = await git(root, ['ls-tree', '-r', '-z', sha])
    const atSnapshot = new Map()
    if (tree.ok) {
      for (const rec of tree.stdout.split('\0')) {
        const m = rec.match(/^\d+ blob ([0-9a-f]+)\t(.*)$/)
        if (m) atSnapshot.set(m[2], m[1])
      }
    }
    const hashes = await new Promise((resolve) => {
      const child = execFile('git', ['hash-object', '--stdin-paths'], { cwd: root, maxBuffer: MAX_BUFFER }, (err, stdout) => {
        resolve(err ? [] : stdout.trim().split('\n'))
      })
      child.stdin.end(untrackedPaths.join('\n'))
    })
    untrackedPaths.forEach((p, i) => {
      if (seen.has(p)) return
      const snap = atSnapshot.get(p)
      if (!snap) files.push({ status: 'A', path: p })
      else if (hashes[i] && hashes[i] !== snap) files.push({ status: 'M', path: p })
      seen.add(p)
    })
  }
  return { ok: true, files }
}

async function changesFor(root, sha) {
  if (!isCommitId(sha)) return invalidCheckpoint()
  return (await inShadow(root, sha)) ? shadowChanges(root, sha) : legacyChanges(root, sha)
}

// ── IPC surface ──────────────────────────────────────────────────────────────

function registerGitHandlers(ipcMain) {
  // branch + porcelain status of the REAL repo — the tree's git tinting
  ipcMain.handle('git:status', async (_e, { cwd } = {}) => {
    const root = cwd && (await repoRoot(cwd))
    if (!root) return { ok: false, notRepo: true }
    const [branch, status] = await Promise.all([
      git(root, ['rev-parse', '--abbrev-ref', 'HEAD']),
      // --no-renames: in -z mode a rename is TWO records (new\0old\0) — without it
      // the old path parses as a phantom entry (stageStatus below does the same)
      git(root, ['status', '--porcelain=v1', '-z', '--no-renames', '--untracked-files=all']),
    ])
    const entries = []
    if (status.ok) {
      for (const rec of status.stdout.split('\0')) {
        if (!rec || rec.length < 4) continue
        const x = rec[0]
        const y = rec[1]
        const rel = rec.slice(3)
        const code = x === '?' ? '?' : y !== ' ' ? y : x
        entries.push({ path: path.join(root, rel), code })
      }
    }
    return { ok: true, root, branch: branch.ok ? branch.stdout.trim() : null, entries }
  })

  ipcMain.handle('git:snapshot', async (_e, { cwd, label } = {}) => {
    const root = cwd && (await repoRoot(cwd))
    if (!root) return { ok: false, notRepo: true }
    const r = await snapshot(root, label)
    return r.ok ? { ...r, root } : r
  })

  ipcMain.handle('git:changes', async (_e, { cwd, sha } = {}) => {
    if (sha !== undefined && sha !== null && !isCommitId(sha)) return invalidCheckpoint()
    const root = cwd && (await repoRoot(cwd))
    if (!root) return { ok: false, notRepo: true }
    if (sha !== undefined && sha !== null) return changesFor(root, sha)
    // no checkpoint yet → uncommitted changes vs the REAL repo's HEAD
    // (--no-renames: keep -z output one record per file — see git:status)
    const st = await git(root, ['status', '--porcelain=v1', '-z', '--no-renames', '--untracked-files=all'])
    if (!st.ok) return { ok: false, message: st.stderr.trim() }
    const files = st.stdout
      .split('\0')
      .filter((rec) => rec && rec.length >= 4)
      .map((rec) => ({ status: rec[0] === '?' ? 'A' : (rec[1] !== ' ' ? rec[1] : rec[0]), path: rec.slice(3) }))
    return { ok: true, files }
  })

  // a file's content at a snapshot — the base buffer for the merge view
  ipcMain.handle('git:show', async (_e, { cwd, sha, file } = {}) => {
    // The checkpoint/turn-blame path accepts only immutable commit IDs. The
    // Git panel additionally needs these two fixed, non-option sentinels for
    // its HEAD and index sides; no renderer-provided arbitrary rev syntax.
    if (!isCommitId(sha) && sha !== 'HEAD' && sha !== ':0') return invalidCheckpoint()
    const root = cwd && (await repoRoot(cwd))
    if (!root) return { ok: false, notRepo: true }
    const rel = path.isAbsolute(file) ? path.relative(root, file) : file
    const shadow = await inShadow(root, sha)
    const r = shadow
      ? await sgit(root, ['show', `${sha}:${rel}`])
      : await git(root, ['show', `${sha}:${rel}`])
    // absent at the snapshot (file created since) → empty base is the honest diff
    return r.ok ? { ok: true, content: r.stdout } : { ok: true, content: '', missing: true }
  })

  // ── the commit panel: stage / unstage / commit against the REAL repo ──
  // (The only surface that touches the user's actual index — checkpoints never do.)

  // porcelain v1, split by column: X = index (staged), Y = worktree (unstaged)
  ipcMain.handle('git:stageStatus', async (_e, { cwd } = {}) => {
    const root = cwd && (await repoRoot(cwd))
    if (!root) return { ok: false, notRepo: true }
    const [branch, st, head] = await Promise.all([
      git(root, ['rev-parse', '--abbrev-ref', 'HEAD']),
      git(root, ['status', '--porcelain=v1', '-z', '--no-renames', '--untracked-files=all']),
      git(root, ['rev-parse', '--verify', '-q', 'HEAD']),
    ])
    if (!st.ok) return { ok: false, message: st.stderr.trim() }
    const staged = []
    const unstaged = []
    for (const rec of st.stdout.split('\0')) {
      if (!rec || rec.length < 4) continue
      const x = rec[0]
      const y = rec[1]
      const p = rec.slice(3)
      if (x === '?') unstaged.push({ path: p, status: 'A', untracked: true })
      // merge conflicts (UU/AA/DD/…U) are neither stageable nor committable —
      // surface them as a conflict row, never as "ready to commit"
      else if (x === 'U' || y === 'U' || (x === 'A' && y === 'A') || (x === 'D' && y === 'D')) {
        unstaged.push({ path: p, status: 'U', conflicted: true })
      } else {
        if (x !== ' ') staged.push({ path: p, status: x })
        if (y !== ' ') unstaged.push({ path: p, status: y })
      }
    }
    return { ok: true, root, branch: branch.ok ? branch.stdout.trim() : null, hasHead: head.ok, staged, unstaged }
  })

  // Paths from porcelain output are LITERAL names — pathspec magic stops git
  // from glob-expanding `test[1].py` / `a*.txt` onto unrelated files.
  const literal = (paths) => paths.map((p) => `:(literal)${p}`)

  ipcMain.handle('git:stage', async (_e, { cwd, paths } = {}) => {
    const root = cwd && (await repoRoot(cwd))
    if (!root || !Array.isArray(paths) || !paths.length) return { ok: false }
    for (let i = 0; i < paths.length; i += 200) {
      // --ignore-errors: the panel's list can be ~400ms stale and agents delete
      // temp files constantly — stage the survivors instead of failing the batch
      const r = await git(root, ['add', '--ignore-errors', '--', ...literal(paths.slice(i, i + 200))])
      if (!r.ok && !/did not match any files/.test(r.stderr)) {
        return { ok: false, message: r.stderr.trim() || 'git add failed' }
      }
    }
    return { ok: true }
  })

  ipcMain.handle('git:unstage', async (_e, { cwd, paths } = {}) => {
    const root = cwd && (await repoRoot(cwd))
    if (!root || !Array.isArray(paths) || !paths.length) return { ok: false }
    // `restore --staged` needs a HEAD. The rm --cached fallback is ONLY for a
    // brand-new repo (no commits): on any other failure (e.g. a transient
    // index.lock) rm --cached would stage a DELETION of a committed file.
    const hasHead = (await git(root, ['rev-parse', '--verify', '-q', 'HEAD'])).ok
    for (let i = 0; i < paths.length; i += 200) {
      const batch = literal(paths.slice(i, i + 200))
      // -f: without it rm --cached refuses when the worktree drifted from the
      // staged blob; --cached never touches the worktree, so force is safe
      const r = hasHead
        ? await git(root, ['restore', '--staged', '--', ...batch])
        : await git(root, ['rm', '--cached', '-r', '-q', '-f', '--', ...batch])
      if (!r.ok) return { ok: false, message: r.stderr.trim() || 'git unstage failed' }
    }
    return { ok: true }
  })

  ipcMain.handle('git:commit', async (_e, { cwd, message } = {}) => {
    const root = cwd && (await repoRoot(cwd))
    if (!root) return { ok: false, notRepo: true }
    if (!message || !String(message).trim()) return { ok: false, message: 'Commit message is empty.' }
    const r = await git(root, ['commit', '-m', String(message)])
    if (!r.ok) return { ok: false, message: (r.stderr.trim() || r.stdout.trim() || 'git commit failed').slice(0, 400) }
    const sha = await git(root, ['rev-parse', '--short', 'HEAD'])
    return { ok: true, sha: sha.ok ? sha.stdout.trim() : undefined, summary: r.stdout.trim().split('\n')[0] }
  })

  ipcMain.handle('git:log', async (_e, { cwd, n } = {}) => {
    const root = cwd && (await repoRoot(cwd))
    if (!root) return { ok: false, notRepo: true }
    const r = await git(root, ['log', `-${Math.min(50, Math.max(1, n || 20))}`, '--pretty=format:%h%x00%s%x00%cr%x00%an'])
    if (!r.ok) return { ok: true, commits: [] } // fresh repo: no HEAD yet
    const commits = r.stdout.split('\n').filter(Boolean).map((line) => {
      const [sha, subject, when, author] = line.split('\0')
      return { sha, subject, when, author }
    })
    return { ok: true, commits }
  })

  // Restore the working tree to a snapshot. Files present-now-but-absent-then
  // go to the Trash (recoverable), never rm. The user's index is untouched.
  ipcMain.handle('git:restore', async (_e, { cwd, sha } = {}) => {
    // Validate before loading Electron, resolving a repo, invoking Git, or
    // touching Trash. Option-like/corrupt persisted refs are inert.
    if (!isCommitId(sha)) return invalidCheckpoint()
    const { shell } = require('electron')
    const root = cwd && (await repoRoot(cwd))
    if (!root) return { ok: false, notRepo: true }
    const shadow = await inShadow(root, sha)
    const ch = await changesFor(root, sha)
    if (!ch.ok) return ch
    let restored = 0
    let trashed = 0
    const paths = ch.files.filter((f) => f.status !== 'A').map((f) => `:(literal)${f.path}`)
    const restore = await withIndexLock(root, async () => {
      try {
        for (let i = 0; i < paths.length; i += 200) {
          const batch = paths.slice(i, i + 200)
          // legacy (real-repo) snapshots: `git restore --worktree` — `checkout <sha> --`
          // would also stage every restored file into the user's real index
          const co = shadow
            ? await sgit(root, ['checkout', sha, '--', ...batch])
            : await git(root, ['restore', '--source', sha, '--worktree', '--', ...batch])
          if (!co.ok) {
            return {
              ok: false,
              message: (co.stderr.trim() || 'Git could not restore every checkpoint file.').slice(0, 500),
              failedPaths: batch.map((literalPath) => literalPath.replace(/^:\(literal\)/, '')),
            }
          }
          restored += batch.length
        }
        return { ok: true }
      } finally {
        // checkout mutates the shadow index. Force the next status/restore to
        // re-read the checkpoint even when a later batch failed.
        if (shadow) shadowIndexAt.delete(shadowDirFor(root))
      }
    })
    if (!restore.ok) return { ...restore, restored, trashed: 0 }
    // Only remove files that did not exist in the checkpoint after every
    // tracked file was restored successfully. A checkout/index failure can no
    // longer trash user files and then falsely report success.
    for (const f of ch.files) {
      if (f.status !== 'A') continue
      try {
        await shell.trashItem(path.join(root, f.path))
        trashed += 1
      } catch (error) {
        return { ok: false, restored, trashed, message: `Checkpoint files were restored, but ${f.path} could not be moved to Trash: ${String(error?.message ?? error)}` }
      }
    }
    return { ok: true, restored, trashed }
  })
}

module.exports = { registerGitHandlers }
