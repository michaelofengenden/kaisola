// Secrets, stored the right way. The Anthropic API key is encrypted with the OS
// keychain via Electron's built-in safeStorage (no native deps) and written to
// userData. It never reaches the renderer — the renderer can set it, ask whether
// one exists, and clear it, but only the main process reads it to call Claude.
const { app, safeStorage } = require('electron')
const path = require('node:path')
const fs = require('node:fs')
const { writePrivateFile } = require('./privateWrite.cjs')

// A named secret: env var wins (dev/CI), then the keychain-encrypted file. The
// renderer can set / probe / clear it, but only the main process reads it.
const SECRETS = {
  anthropic: { file: 'pasola-anthropic.key', env: 'ANTHROPIC_API_KEY' },
  openai: { file: 'pasola-openai.key', env: 'OPENAI_API_KEY' },
}

function keyPath(name) {
  return path.join(app.getPath('userData'), SECRETS[name].file)
}

function getKey(name) {
  const envName = SECRETS[name].env
  if (process.env[envName]) return process.env[envName]
  try {
    const p = keyPath(name)
    if (!fs.existsSync(p)) return null
    if (!safeStorage.isEncryptionAvailable()) return null
    return safeStorage.decryptString(fs.readFileSync(p))
  } catch {
    return null
  }
}

// the Anthropic key keeps its original accessor name (modelHandler imports it)
const getApiKey = () => getKey('anthropic')
const getOpenaiKey = () => getKey('openai')

function registerSettingsHandlers(ipcMain) {
  const setHandler = (name) => (_e, key) => {
    try {
      if (!key || typeof key !== 'string') return { ok: false, message: 'Empty key' }
      if (!safeStorage.isEncryptionAvailable()) {
        return { ok: false, message: 'OS keychain encryption unavailable on this machine.' }
      }
      // Atomic + 0o600 like every other credential file: a crash mid-write
      // must not truncate the saved key, and it should not be group-readable.
      writePrivateFile(keyPath(name), safeStorage.encryptString(key.trim()))
      return { ok: true }
    } catch (err) {
      return { ok: false, message: String(err.message || err) }
    }
  }
  const clearHandler = (name) => () => {
    try {
      const p = keyPath(name)
      if (fs.existsSync(p)) fs.unlinkSync(p)
      return { ok: true }
    } catch (err) {
      return { ok: false, message: String(err.message || err) }
    }
  }

  ipcMain.handle('settings:setApiKey', setHandler('anthropic'))
  ipcMain.handle('settings:hasApiKey', () => ({ ok: true, present: !!getKey('anthropic'), fromEnv: !!process.env.ANTHROPIC_API_KEY }))
  ipcMain.handle('settings:clearApiKey', clearHandler('anthropic'))

  ipcMain.handle('settings:setOpenaiKey', setHandler('openai'))
  ipcMain.handle('settings:hasOpenaiKey', () => ({ ok: true, present: !!getKey('openai'), fromEnv: !!process.env.OPENAI_API_KEY }))
  ipcMain.handle('settings:clearOpenaiKey', clearHandler('openai'))

  // where settings.json / keymap.json live (Zed-style user config files)
  ipcMain.handle('settings:paths', () => {
    const dir = app.getPath('userData')
    return { dir, settings: path.join(dir, 'settings.json'), keymap: path.join(dir, 'keymap.json') }
  })
}

module.exports = { registerSettingsHandlers, getApiKey, getOpenaiKey, getKey }
