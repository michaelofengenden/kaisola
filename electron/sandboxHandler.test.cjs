const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const { _sandboxTest } = require('./ipc/sandboxHandler.cjs')

test('sandbox preserves the campaign shell command for in-container execution only', () => {
  const command = 'python prep.py && python eval.py > result.txt; echo success_rate=0.49'
  assert.deepEqual(_sandboxTest.shellCommand(command), { ok: true, command })
  assert.equal(_sandboxTest.shellCommand('bad\0command').ok, false)
})

test('Docker sandbox is isolated and runs the persisted command in a writable copy', () => {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-sandbox-'))
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-sandbox-output-'))
  try {
    const command = 'python prep.py && python eval.py > result.txt; echo success_rate=0.49'
    const result = _sandboxTest.dockerRunArgs({
      cwd,
      outputDir,
      command,
      env: { SAFE_FLAG: 'yes' },
    }, 'kaisola-sandbox-test')
    assert.equal(result.ok, true)
    assert.deepEqual(result.args.slice(0, 4), ['run', '--rm', '--name', 'kaisola-sandbox-test'])
    for (const required of [
      '--network=none', '--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges',
      '--pids-limit=128', '--memory=2g', '--cpus=2',
    ]) assert.equal(result.args.includes(required), true, required)
    const volumes = result.args.flatMap((value, index) => result.args[index - 1] === '--volume' ? [value] : [])
    assert.deepEqual(volumes, [`${fs.realpathSync(cwd)}:/input:ro`, `${fs.realpathSync(outputDir)}:/work:rw`])
    assert.equal(result.args.includes('/bin/sh'), true)
    assert.equal(result.args[result.args.length - 1], command)
    assert.equal(result.args.filter((value) => value === command).length, 1)
    assert.equal(result.args.includes('--network=none'), true)
  } finally {
    fs.rmSync(cwd, { recursive: true, force: true })
    fs.rmSync(outputDir, { recursive: true, force: true })
  }
})

test('Docker sandbox rejects unsafe image, environment, and workspace inputs', () => {
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'kaisola-sandbox-output-'))
  try {
    assert.equal(_sandboxTest.dockerRunArgs({ command: 'python x.py', outputDir, image: '--privileged' }).ok, false)
    assert.equal(_sandboxTest.dockerRunArgs({ command: 'python x.py', outputDir, env: { 'BAD-KEY': 'x' } }).ok, false)
    assert.equal(_sandboxTest.dockerRunArgs({ command: 'python x.py', outputDir, cwd: '/definitely/not/here' }).ok, false)
  } finally {
    fs.rmSync(outputDir, { recursive: true, force: true })
  }
})
