// Execution-module tools the renderer reaches through the preload bridge.
// Phase 0: filesystem reads/writes are sandboxed to a per-project workspace dir
// and experiment execution is a stub. Phase 3 wires runExperiment to a real
// sandbox (Docker / Modal / RunPod / Slurm) and streams the lab notebook back.
const { app, shell, dialog, BrowserWindow } = require('electron')
const path = require('node:path')
const fs = require('node:fs/promises')
const { isSafeWebUrl } = require('./securityPolicy.cjs')

function workspaceRoot() {
  return path.join(app.getPath('userData'), 'workspaces')
}

/** Keep file IO inside the workspace — never let the renderer escape it. */
function safeResolve(relPath, root = workspaceRoot()) {
  const resolved = path.resolve(root, relPath)
  const relative = path.relative(root, resolved)
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('Path escapes the workspace')
  }
  return resolved
}

function pathContains(parent, child) {
  const relative = path.relative(parent, child)
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))
}

function registerToolHandlers(ipcMain) {
  // Pick a workspace folder — the directory agents work in (session cwd).
  ipcMain.handle('kaisola:pickFolder', async () => {
    const win = BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0]
    const res = await dialog.showOpenDialog(win, {
      title: 'Choose a workspace folder',
      properties: ['openDirectory', 'createDirectory'],
    })
    if (res.canceled || !res.filePaths[0]) return { ok: false }
    const chosen = path.resolve(res.filePaths[0])
    // never let the agent work in (or above) Kaisola itself — it could modify the app
    const appRoot = path.resolve(app.getAppPath())
    if (pathContains(appRoot, chosen) || pathContains(chosen, appRoot)) {
      return { ok: false, message: 'That folder contains Kaisola itself — pick a different project folder so the agent can’t modify the app.' }
    }
    return { ok: true, path: chosen }
  })

  // Pick files to attach to the agent's prompt as context.
  ipcMain.handle('kaisola:pickFiles', async () => {
    const win = BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0]
    const res = await dialog.showOpenDialog(win, {
      title: 'Attach files for the agent',
      properties: ['openFile', 'multiSelections'],
    })
    if (res.canceled || !res.filePaths.length) return { ok: false }
    return { ok: true, paths: res.filePaths }
  })

  ipcMain.handle('kaisola:runExperiment', async (_e, spec) => {
    // Stub: pretend to queue a run. The real implementation provisions a
    // sandbox, runs the plan, and streams NotebookEntry objects back.
    return {
      ok: true,
      stub: true,
      runId: `run_${Date.now().toString(36)}`,
      message: `Queued (stub): ${spec?.title ?? 'experiment'}. Execution sandbox lands in Phase 3.`,
    }
  })

  ipcMain.handle('kaisola:readFile', async (_e, relPath) => {
    try {
      return { ok: true, contents: await fs.readFile(safeResolve(relPath), 'utf8') }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('kaisola:writeFile', async (_e, { relPath, contents }) => {
    try {
      const full = safeResolve(relPath)
      await fs.mkdir(path.dirname(full), { recursive: true })
      await fs.writeFile(full, contents, 'utf8')
      return { ok: true }
    } catch (err) {
      return { ok: false, message: String((err && err.message) || err) }
    }
  })

  ipcMain.handle('kaisola:openExternal', async (_e, url) => {
    if (!isSafeWebUrl(url)) return { ok: false, message: 'Only http and https links can be opened.' }
    await shell.openExternal(url)
    return { ok: true }
  })
}

module.exports = { registerToolHandlers, __test: { pathContains, safeResolve } }
