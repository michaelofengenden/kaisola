// Native model CLIs cannot execute from inside Electron's app.asar archive.
// Resolve the pinned platform payload from development node_modules or the
// matching app.asar.unpacked directory used by electron-builder.
const fs = require('node:fs')
const path = require('node:path')

function packageRoots(packageName) {
  const roots = []
  if (process.resourcesPath) roots.push(path.join(process.resourcesPath, 'app.asar.unpacked', 'node_modules', ...packageName.split('/')))
  const development = path.join(__dirname, '..', '..', 'node_modules', ...packageName.split('/'))
  // Electron's patched fs can stat files inside app.asar, but the OS spawn
  // syscall cannot traverse that virtual archive (ENOTDIR). Never return it as
  // an executable merely because stat succeeded.
  if (!development.split(path.sep).some((segment) => segment.endsWith('.asar'))) roots.push(development)
  return roots
}

function firstFile(candidates) {
  for (const candidate of candidates) {
    try {
      const real = fs.realpathSync(candidate)
      if (fs.statSync(real).isFile()) return real
    } catch { /* next candidate */ }
  }
  return null
}

function resolveBundledCodexExecutable() {
  const triples = {
    'darwin-arm64': 'aarch64-apple-darwin', 'darwin-x64': 'x86_64-apple-darwin',
    'linux-arm64': 'aarch64-unknown-linux-musl', 'linux-x64': 'x86_64-unknown-linux-musl',
    'win32-arm64': 'aarch64-pc-windows-msvc', 'win32-x64': 'x86_64-pc-windows-msvc',
  }
  const triple = triples[`${process.platform}-${process.arch}`]
  if (!triple) return null
  const packageName = `@openai/codex-${process.platform}-${process.arch}`
  const exe = process.platform === 'win32' ? 'codex.exe' : 'codex'
  return firstFile(packageRoots(packageName).map((root) => path.join(root, 'vendor', triple, 'bin', exe)))
}

function resolveBundledClaudeExecutable() {
  const packageName = `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}`
  const exe = process.platform === 'win32' ? 'claude.exe' : 'claude'
  return firstFile(packageRoots(packageName).map((root) => path.join(root, exe)))
}

module.exports = { resolveBundledCodexExecutable, resolveBundledClaudeExecutable }
