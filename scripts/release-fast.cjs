// Cut a release with the least possible waiting.
//
//   npm run release:fast -- <version> [title words...] [flags]
//
// The expensive work (universal build, notarization) happens in
// release-candidate.yml on every push to main, and release.yml only promotes
// an existing green candidate for the exact tagged commit. So the fastest
// release is one whose commit already has a green candidate. This script
// arranges that permanently:
//
// - FAST PATH: when package.json already carries <version> (the normal state,
//   because every release ends by pre-bumping to the next version), HEAD is
//   simply tagged once its candidate is green. If the candidate finished
//   earlier in the day, the release is live in about a minute.
// - SLOW PATH: when <version> differs, the classic bump commit is created and
//   landed first, then the script waits for that commit's candidate before
//   tagging. One-time cost per adoption or renumbering.
//
// Either way the script ends by pre-bumping package.json to the next patch
// version ("Start vX.Y.Z+1"), so the next release takes the fast path.
// The tag is only ever pushed after the candidate is green, so release.yml
// never fires before its input exists.
//
// Commits reach main through a pull request, not a push. `main` is protected
// ("Changes must be made through a pull request", plus a required `landing`
// check), so the old `git push origin HEAD:refs/heads/main` was rejected with
// GH013 and left the release commit stranded locally. `landOnMain` opens the
// pull request, merges it as soon as the required checks go green, and adopts
// the merge commit — which is the sha that gets tagged, since that is the one
// the candidate builds. Tags are not covered by the branch rule, so the tag
// itself is still pushed directly and release.yml fires as designed.
// Nothing here needs to know *which* checks are required: GitHub's own
// mergeStateStatus answers that, so the repo stays the source of truth.
//
// Flags: --no-wait (fail instead of polling for the candidate),
//        --no-next-bump (skip the trailing pre-bump commit),
//        --allow-version-reset (deliberate renumbering below current).
const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

const root = path.join(__dirname, '..')

function command(program, args, { capture = false, allowFailure = false } = {}) {
  const result = spawnSync(program, args, {
    cwd: root,
    encoding: capture ? 'utf8' : undefined,
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
  })
  if (result.error) throw result.error
  if (!allowFailure && result.status !== 0) {
    // In capture mode the child's stderr went to a pipe; surfacing it is the
    // difference between a diagnosable failure and the silent exits that made
    // three releases in a row look finished while the bump PR sat unarmed.
    if (capture && result.stderr) process.stderr.write(result.stderr)
    console.error(`release-fast: ${program} ${args.join(' ')} exited ${result.status}`)
    process.exit(result.status ?? 1)
  }
  return result
}

function output(program, args) {
  return command(program, args, { capture: true }).stdout.trim()
}

function fail(message) {
  console.error(`release-fast: ${message}`)
  process.exit(1)
}

function sleep(seconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, seconds * 1000)
}

const flags = new Set(process.argv.slice(2).filter((word) => word.startsWith('--')))
const positional = process.argv.slice(2).filter((word) => !word.startsWith('--'))

const requested = positional[0]?.replace(/^v/, '')
if (!requested || !/^\d+\.\d+\.\d+$/.test(requested)) {
  fail('usage: npm run release:fast -- <version> [title words...] [--no-wait] [--no-next-bump]')
}

const tag = `v${requested}`
const message = positional.slice(1).join(' ') || `Release ${tag}`

if (output('git', ['branch', '--show-current']) !== 'main') fail('releases must be cut from main')
command('git', ['fetch', '--quiet', '--tags', 'origin'])
if (command('git', ['show-ref', '--verify', '--quiet', `refs/tags/${tag}`], { allowFailure: true }).status === 0) {
  fail(`tag ${tag} already exists`)
}
if (Number(output('git', ['rev-list', '--count', 'HEAD..origin/main'])) > 0) {
  fail('local main is behind origin/main; update it before releasing')
}

const packagePath = path.join(root, 'package.json')
const current = JSON.parse(fs.readFileSync(packagePath, 'utf8')).version

let releaseSha
if (current === requested) {
  // Fast path: HEAD already carries this version; its candidate is the
  // release. The tree must match the candidate's bytes exactly.
  if (command('git', ['diff', '--quiet'], { allowFailure: true }).status !== 0
    || command('git', ['diff', '--cached', '--quiet'], { allowFailure: true }).status !== 0) {
    fail('the tree has tracked changes; commit and push them first so the candidate matches HEAD')
  }
  if (Number(output('git', ['rev-list', '--count', 'origin/main..HEAD'])) > 0) {
    fail('HEAD is ahead of origin/main; push first so a candidate exists for it')
  }
  releaseSha = output('git', ['rev-parse', 'HEAD'])
  console.log(`release-fast: fast path: tagging existing commit ${releaseSha.slice(0, 10)} as ${tag}`)
} else {
  // Slow path: classic bump commit. Existing tracked edits must already be
  // staged; unrelated untracked files are never swept into the commit.
  if (command('git', ['diff', '--quiet'], { allowFailure: true }).status !== 0) {
    fail('stage the intended tracked changes before releasing')
  }
  const requestedParts = requested.split('.').map(Number)
  const currentParts = current.split('.').map(Number)
  const isNewer = requestedParts.some((part, index) => (
    part > currentParts[index] && requestedParts.slice(0, index).every((value, prior) => value === currentParts[prior])
  ))
  // Going backwards is allowed only when asked for by name: a version that
  // goes down is almost always a typo, and a published release cannot be
  // taken back. Safe for installed copies because Sparkle compares
  // CFBundleVersion, which the candidate derives from a monotonic build
  // counter and never from this string.
  if (!isNewer && !flags.has('--allow-version-reset')) {
    fail(`${requested} must be newer than package version ${current} (pass --allow-version-reset to renumber deliberately)`)
  }
  command('npm', ['version', requested, '--no-git-tag-version', '--ignore-scripts'])
  command('git', ['add', 'package.json', 'package-lock.json'])
  if (command('git', ['diff', '--cached', '--quiet'], { allowFailure: true }).status === 0) {
    fail('there is nothing staged to release')
  }
  command('git', ['commit', '-m', message])
  releaseSha = landOnMain(
    `chore/release-${requested}`,
    message,
    `Version bump to ${requested} so the work already on main can be tagged and promoted.\n\n`
      + '`release.yml` requires the tag to equal `package.json` at the tagged commit, so the bump '
      + 'has to land before the tag exists. Opened by `npm run release:fast`, which merges this '
      + 'itself once the required checks are green and then tags the merge commit.'
  )
  console.log(`release-fast: slow path: release commit landed as ${releaseSha.slice(0, 10)}; its candidate must build before the tag`)
}

// Land a commit on main through a pull request, and return the sha main
// actually ends up at.
//
// `main` is protected: "Changes must be made through a pull request", plus a
// required `landing` check. A direct `git push origin HEAD:refs/heads/main`
// is rejected with GH013, which is where this script used to stop dead with the
// release commit already made locally.
//
// The returned sha matters as much as the landing. A merged PR puts a *merge
// commit* on main whose sha is not the local commit's, and the candidate builds
// for that merge commit — so the tag has to name it. Tagging the local commit
// would tag something that was never on main and has no candidate.
//
// Tags themselves are not covered by the branch rule, so the tag lane below
// still pushes directly and `release.yml` fires exactly as designed.
function landOnMain(branch, title, body) {
  if (command('gh', ['--version'], { capture: true, allowFailure: true }).status !== 0) {
    fail('the GitHub CLI (gh) is required to land a release commit through a pull request')
  }
  const head = output('git', ['rev-parse', 'HEAD'])
  command('git', ['push', '--force-with-lease', 'origin', `HEAD:refs/heads/${branch}`])
  const existing = output('gh', ['pr', 'list', '--head', branch, '--state', 'open',
    '--json', 'number', '--jq', '.[0].number // empty'])
  if (!existing) {
    command('gh', ['pr', 'create', '--base', 'main', '--head', branch,
      '--title', title, '--body', body])
  }
  const number = existing || output('gh', ['pr', 'list', '--head', branch, '--state', 'open',
    '--json', 'number', '--jq', '.[0].number // empty'])
  if (!number) fail(`could not find or open a pull request for ${branch}`)
  console.log(`release-fast: landing ${head.slice(0, 10)} through pull request #${number}`)

  // Poll until GitHub says the PR can merge. `mergeStateStatus` folds the
  // required checks and the branch rules into one answer, so this does not have
  // to know which checks are required — the repo decides that.
  const deadline = Date.now() + 45 * 60 * 1000
  for (;;) {
    // A view moments after `gh pr create` can fail transiently (read-replica
    // lag, a network blip); that is a reason to poll again, not to die. The
    // deadline below still bounds how long transient can claim to be.
    const view = command('gh', ['pr', 'view', number, '--json', 'mergeStateStatus,state'],
      { capture: true, allowFailure: true })
    if (view.status !== 0) {
      if (Date.now() > deadline) {
        fail(`could not read pull request #${number}: ${(view.stderr || '').trim()}`)
      }
      console.log(`release-fast: pull request #${number} read failed transiently, retrying…`)
      sleep(20)
      continue
    }
    const { mergeStateStatus: state, state: prState } = JSON.parse(view.stdout)
    if (prState === 'MERGED') break
    if (state === 'CLEAN' || state === 'UNSTABLE' || state === 'HAS_HOOKS') {
      // UNSTABLE means a non-required check is failing or still running. The
      // required set is green, so the merge is allowed and waiting for the
      // optional ones is exactly the waiting this script exists to remove.
      command('gh', ['pr', 'merge', number, '--merge', '--delete-branch'])
      break
    }
    if (state === 'DIRTY') fail(`pull request #${number} has conflicts with main; resolve them and re-run`)
    if (state === 'BLOCKED') {
      // BLOCKED is not only "a check is still red". This repo also requires
      // review threads to be resolved, and an automated reviewer comments on
      // most pull requests, so the usual cause is a thread nobody has answered
      // — which no amount of waiting will clear. Say which it is rather than
      // spending forty-five minutes finding out. A transient failure of this
      // probe reads as zero threads and the loop simply polls again — the
      // 0.1.144 run died here on the same read-replica lag the main view
      // already tolerates.
      const threads = command('gh', ['pr', 'view', number, '--json', 'reviewThreads',
        '--jq', '[.reviewThreads[]? | select(.isResolved == false)] | length'],
        { capture: true, allowFailure: true })
      const unresolved = threads.status === 0 ? Number(threads.stdout.trim() || '0') : 0
      if (unresolved > 0) {
        fail(`pull request #${number} has ${unresolved} unresolved review thread(s); `
          + 'address them and re-run — the release resumes from here')
      }
    }
    if (Date.now() > deadline) {
      fail(`gave up waiting for pull request #${number} after 45 minutes (${state}); `
        + 'check its required checks, then re-run — the release resumes from here')
    }
    console.log(`release-fast: pull request #${number} is ${state}, waiting…`)
    sleep(20)
  }

  // Adopt whatever main became. The local commit is a parent of the merge, so
  // this is always a fast-forward; anything else means main moved underneath us
  // and the release should stop rather than guess.
  command('git', ['fetch', '--quiet', 'origin', 'main'])
  if (command('git', ['merge', '--ff-only', 'origin/main'], { allowFailure: true }).status !== 0) {
    fail('local main could not fast-forward to origin/main after the merge; reconcile it and re-run')
  }
  const landed = output('git', ['rev-parse', 'HEAD'])
  console.log(`release-fast: landed on main as ${landed.slice(0, 10)}`)
  return landed
}

// The tag is pushed only after the candidate for releaseSha is green, so the
// promotion workflow always finds its input on the first attempt.
function candidateRun(sha) {
  const raw = output('gh', ['api', '-X', 'GET',
    'repos/{owner}/{repo}/actions/workflows/release-candidate.yml/runs',
    '-f', `head_sha=${sha}`, '-f', 'per_page=100'])
  const runs = (JSON.parse(raw).workflow_runs || [])
    .filter((run) => run.head_sha === sha && run.head_branch === 'main'
      && (run.event === 'push' || run.event === 'workflow_dispatch'))
    .sort((a, b) => (a.run_number - b.run_number) || (a.run_attempt - b.run_attempt))
  return runs[runs.length - 1] || null
}

const startedAt = Date.now()
const pollLimitMinutes = 45
for (;;) {
  const run = candidateRun(releaseSha)
  const elapsed = Math.round((Date.now() - startedAt) / 60000)
  if (run && run.conclusion === 'success') {
    console.log(`release-fast: candidate is green (run ${run.id})`)
    break
  }
  if (run && run.conclusion) {
    fail(`the candidate for ${releaseSha.slice(0, 10)} finished ${run.conclusion}: ${run.html_url}`)
  }
  if (flags.has('--no-wait')) {
    fail(run
      ? `the candidate for ${releaseSha.slice(0, 10)} is still ${run.status}: ${run.html_url}`
      : `no candidate run exists yet for ${releaseSha.slice(0, 10)}; it starts on push within a minute`)
  }
  if (elapsed >= pollLimitMinutes) {
    fail(`gave up after ${pollLimitMinutes} minutes; check the candidate workflow and re-run (the fast path will resume here)`)
  }
  console.log(run
    ? `release-fast: candidate ${run.status} (${elapsed}m elapsed), waiting…`
    : `release-fast: waiting for the candidate run to appear (${elapsed}m elapsed)…`)
  sleep(30)
}

command('git', ['tag', '-a', tag, '-m', `Kaisola ${tag}: ${message}`, releaseSha])
command('git', ['push', 'origin', `refs/tags/${tag}`])
console.log(`Release ${tag} promoting: https://github.com/michaelofengenden/kaisola/actions/workflows/release.yml`)

if (!flags.has('--no-next-bump')) {
  // Pre-bump so every future commit carries the next version and the next
  // release takes the fast path (tag an existing green candidate, ~1 minute).
  const next = requested.split('.').map(Number)
  next[2] += 1
  const nextVersion = next.join('.')
  command('npm', ['version', nextVersion, '--no-git-tag-version', '--ignore-scripts'])
  command('git', ['add', 'package.json', 'package-lock.json'])
  command('git', ['commit', '-m', `Start v${nextVersion}`])
  landOnMain(
    `chore/start-v${nextVersion}`,
    `Start v${nextVersion}`,
    `Pre-bump so every commit after ${tag} carries the next version and the next release is a `
      + 'tag-only, roughly one-minute affair. Opened and merged by `npm run release:fast`.'
  )
  console.log(`Pre-bumped to ${nextVersion}; the next release of it will promote in about a minute.`)
}
