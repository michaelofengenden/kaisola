// Real-renderer Markdown image lifecycle probe: caret access, selection,
// keyboard resize, block movement, deletion, undo/redo, save, and reopen.
const { app, BrowserWindow, ipcMain } = require('electron')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { killAllSessions } = require('./ipc/terminalHandler.cjs')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
const userData = path.join(os.tmpdir(), `kaisola-markdown-image-${process.pid}`)
const workspace = path.join(userData, 'workspace')
const markdownPath = path.join(workspace, 'image-edit.md')
const imagePath = path.join(workspace, 'image one.png')
fs.rmSync(userData, { recursive: true, force: true })
fs.mkdirSync(workspace, { recursive: true })
fs.writeFileSync(imagePath, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAF/gL+Xl2hAAAAAElFTkSuQmCC', 'base64'))
fs.writeFileSync(markdownPath, [
  '# Stable heading',
  '',
  'Before block.',
  '',
  '![First](image%20one.png#kaisola-width=48 "first title")',
  '',
  'Middle block.',
  '',
  '![Trailing](image%20one.png#kaisola-width=36 "tail title")',
  '',
  '<script>window.__unsafe = true</script>',
  '',
  '![Unsafe](javascript:alert(1))',
  '',
].join('\n'))
app.setPath('userData', userData)

const registrations = [
  ['./ipc/modelHandler.cjs', 'registerModelHandlers'],
  ['./ipc/toolHandler.cjs', 'registerToolHandlers'],
  ['./ipc/settingsHandler.cjs', 'registerSettingsHandlers'],
  ['./ipc/terminalHandler.cjs', 'registerTerminalHandlers'],
  ['./ipc/fsHandler.cjs', 'registerFsHandlers'],
  ['./ipc/dbHandler.cjs', 'registerDbHandlers'],
  ['./ipc/gitHandler.cjs', 'registerGitHandlers'],
  ['./ipc/mcpServer.cjs', 'registerMcpHandlers'],
  ['./ipc/extensionHandler.cjs', 'registerExtensionHandlers'],
  ['./ipc/claudeHooksHandler.cjs', 'registerClaudeHooksHandlers'],
  ['./ipc/updateHandler.cjs', 'registerUpdateHandlers'],
]
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

app.whenReady().then(async () => {
  for (const [modulePath, name] of registrations) require(modulePath)[name](ipcMain)
  require('./ipc/assistantArchive.cjs').registerAssistantArchiveHandlers(ipcMain, path.join(userData, 'assistant-archives'))
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: true, liveSolid: true }))
  ipcMain.handle('window:list-saved', () => ({ ok: true, windows: [] }))
  ipcMain.handle('window:reopen-saved', () => ({ ok: false, missing: true }))
  ipcMain.handle('window:delete-saved', () => ({ ok: false, missing: true }))
  ipcMain.handle('window:popped', () => ({ ok: true, termIds: [], states: [], closed: [] }))
  ipcMain.handle('window:pop-closed-ack', () => ({ ok: false }))
  ipcMain.on('window:terminal-state', () => {})
  ipcMain.handle('app-auth:status', () => ({ ok: true, configured: true, serverVerified: true, profile: { uid: 'markdown-probe', name: 'Markdown Probe' } }))
  ipcMain.handle('app-auth:sign-out', () => ({ ok: true, configured: true }))
  ipcMain.handle('acp:presets', () => [{ id: 'codex', name: 'Codex' }, { id: 'claude-code', name: 'Claude' }])
  ipcMain.handle('acp:status', () => ({ ok: true, agents: [] }))
  ipcMain.handle('acp:diagnostics', () => ({}))
  ipcMain.handle('acp:connect', () => ({ ok: false, message: 'Markdown probe does not start agents.' }))
  ipcMain.handle('acp:lease', () => ({ ok: true }))

  const errors = []
  const win = new BrowserWindow({
    show: true,
    width: 1320,
    height: 860,
    frame: false,
    transparent: false,
    backgroundColor: '#ffffff',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: false },
  })
  win.webContents.on('console-message', (_event, level, message) => { if (level >= 3) errors.push(message) })
  const js = (code) => win.webContents.executeJavaScript(code, true)
  const waitFor = async (expression, timeoutMs = 5_000) => {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      if (await js(`Boolean(${expression})`)) return true
      await wait(50)
    }
    return false
  }

  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'), { query: { solidwin: '1' } })
  await wait(700)
  await js(`(() => {
    const state = window.__kaisola.getState()
    state.setWorkspace(${JSON.stringify(workspace)})
    state.requestFile(${JSON.stringify(markdownPath)}, 'edit', { pinned: true })
  })()`)
  const mounted = await waitFor(`document.querySelector('.fx-doc-markdown[data-editing] [data-markdown-image-shell]')`)
  await wait(300)

  const initial = mounted ? await js(`(() => {
    const surface = document.querySelector('.fx-doc-markdown[data-editing] .fx-doc-page')
    const shells = [...surface.querySelectorAll('[data-markdown-image-shell]')]
    const trailing = shells.at(-1)
    const block = trailing?.closest('p')
    return {
      imageCount: shells.filter((shell) => shell.querySelector('img')?.dataset.markdownSrc).length,
      selectable: shells.every((shell) => shell.tabIndex === 0 && shell.draggable),
      actions: shells.every((shell) => shell.querySelectorAll('[data-markdown-image-action]').length === 3),
      beforeCaret: block?.previousElementSibling?.matches('[data-markdown-image-caret]') ?? false,
      afterCaret: block?.nextElementSibling?.matches('[data-markdown-image-caret]') ?? false,
      unsafeScript: !!surface.querySelector('script') || window.__unsafe === true,
      unsafeImage: [...surface.querySelectorAll('img')].some((image) => String(image.getAttribute('src') || image.dataset.markdownSrc || '').startsWith('javascript:')),
      firstSrc: shells[0]?.querySelector('img')?.dataset.markdownSrc,
      firstTitle: shells[0]?.querySelector('img')?.getAttribute('title'),
    }
  })()`) : null

  const interactions = mounted ? await js(`(async () => {
    const surface = document.querySelector('.fx-doc-markdown[data-editing] .fx-doc-page')
    const validImageCount = () => [...surface.querySelectorAll('[data-markdown-image-shell]')].filter((shell) => shell.querySelector('img')?.dataset.markdownSrc).length
    const first = surface.querySelector('[data-markdown-image-shell]')
    const middle = [...surface.children].find((node) => node.textContent?.includes('Middle block.'))
    const transfer = new DataTransfer()
    const middleRect = middle.getBoundingClientRect()
    first.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: transfer }))
    surface.dispatchEvent(new DragEvent('dragover', {
      bubbles: true,
      cancelable: true,
      dataTransfer: transfer,
      clientX: middleRect.left + Math.min(20, middleRect.width / 2),
      clientY: middleRect.bottom - 1,
    }))
    const dragMarker = !!surface.querySelector('[data-markdown-image-drop]')
    surface.dispatchEvent(new DragEvent('drop', {
      bubbles: true,
      cancelable: true,
      dataTransfer: transfer,
      clientX: middleRect.left + Math.min(20, middleRect.width / 2),
      clientY: middleRect.bottom - 1,
    }))
    const firstBlockAfterDrop = first.closest('p')
    const childrenAfterDrop = [...surface.children]
    const dragged = childrenAfterDrop.indexOf(middle) < childrenAfterDrop.indexOf(firstBlockAfterDrop) &&
      !surface.querySelector('[data-markdown-image-drop]')
    first.click()
    const selected = first.dataset.selected === 'true'
    const resize = first.querySelector('[data-markdown-image-resize]')
    resize.focus()
    resize.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true }))
    const resized = resize.getAttribute('aria-valuenow') === '43' && first.querySelector('img').dataset.markdownSrc.includes('kaisola-width=43')
    first.querySelector('[data-markdown-image-action="down"]').click()
    const textOrder = [...surface.children].map((node) => node.textContent || node.querySelector?.('img')?.alt || '')
    const moved = textOrder.findIndex((text) => text.includes('Middle block.')) < [...surface.children].findIndex((node) => node.querySelector?.('img')?.alt === 'First')
    const trailing = [...surface.querySelectorAll('[data-markdown-image-shell]')].find((shell) => shell.querySelector('img')?.alt === 'Trailing')
    trailing.querySelector('[data-markdown-image-action="delete"]').click()
    const deleted = validImageCount() === 1
    const useFormatting = async (label) => {
      surface.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 180, clientY: 180 }))
      await new Promise(requestAnimationFrame)
      const button = document.querySelector('.fx-md-toolbar [aria-label="' + label + '"]')
      if (!button) throw new Error('Formatting action did not open: ' + label)
      button.click()
      await new Promise(requestAnimationFrame)
    }
    await useFormatting('Undo')
    const undone = validImageCount() === 2
    await useFormatting('Redo')
    const redone = validImageCount() === 1
    await useFormatting('Undo')
    const restored = [...surface.querySelectorAll('[data-markdown-image-shell]')].find((shell) => shell.querySelector('img')?.alt === 'Trailing')
    restored.focus()
    restored.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
    document.execCommand('insertText', false, 'Text below image.')
    surface.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'Text below image.' }))
    restored.focus()
    restored.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, bubbles: true, cancelable: true }))
    document.execCommand('insertText', false, 'Text before image.')
    surface.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'Text before image.' }))
    restored.querySelector('[data-markdown-image-action="delete"]').click()
    return { dragMarker, dragged, selected, resized, moved, deleted, undone, redone, textBelow: surface.textContent.includes('Text below image.'), textBefore: surface.textContent.includes('Text before image.'), finalImageCount: validImageCount() }
  })()`) : null

  await wait(100)
  await js(`window.dispatchEvent(new KeyboardEvent('keydown', { key: 's', metaKey: true, bubbles: true, cancelable: true }))`)
  await wait(700)
  const saved = fs.readFileSync(markdownPath, 'utf8')
  await js(`document.querySelector('.fx-mode[title="Preview"]')?.click()`)
  await waitFor(`!document.querySelector('.fx-doc-markdown[data-editing]')`)
  await js(`document.querySelector('.fx-mode[title="Edit"]')?.click()`)
  const reopened = await waitFor(`document.querySelector('.fx-doc-markdown[data-editing] [data-markdown-image-shell]')`)
  await wait(250)
  const reopenState = reopened ? await js(`(() => {
    const surface = document.querySelector('.fx-doc-markdown[data-editing] .fx-doc-page')
    const image = surface.querySelector('[data-markdown-image-shell] img')
    return {
      imageCount: surface.querySelectorAll('[data-markdown-image-shell]').length,
      src: image?.dataset.markdownSrc,
      title: image?.getAttribute('title'),
      heading: surface.querySelector('h1')?.textContent,
      text: surface.textContent,
      unsafeScript: !!surface.querySelector('script') || window.__unsafe === true,
    }
  })()`) : null

  const checks = {
    mounted,
    twoSafeImages: initial?.imageCount === 2,
    selectionControls: initial?.selectable === true && initial?.actions === true && interactions?.selected === true,
    trailingCaret: initial?.beforeCaret === true && initial?.afterCaret === true,
    cursorDrag: interactions?.dragMarker === true && interactions?.dragged === true,
    resized: interactions?.resized === true,
    moved: interactions?.moved === true,
    deleteUndoRedo: interactions?.deleted === true && interactions?.undone === true && interactions?.redone === true,
    writeAround: interactions?.textBelow === true && interactions?.textBefore === true,
    referenceOnlyDelete: interactions?.finalImageCount === 1 && fs.existsSync(imagePath),
    sanitizerStable: initial?.unsafeScript === false && initial?.unsafeImage === false && reopenState?.unsafeScript === false,
    savedMetadata: saved.includes('![First](image%20one.png#kaisola-width=43 "first title")'),
    savedDeletion: !saved.includes('![Trailing]'),
    savedSurroundingText: saved.includes('# Stable heading') && saved.includes('Before block.') && saved.includes('Middle block.') && saved.includes('Text before image.') && saved.includes('Text below image.'),
    reopened: reopenState?.imageCount === 1 && reopenState?.src === 'image%20one.png#kaisola-width=43' && reopenState?.title === 'first title' && reopenState?.heading === 'Stable heading',
    noConsoleErrors: errors.length === 0,
  }
  const pass = Object.values(checks).every(Boolean)
  console.log('MARKDOWN_IMAGE=' + (pass ? 'PASS' : 'FAIL') + ' ' + JSON.stringify({ checks, initial, interactions, reopenState, saved, errors }))
  killAllSessions()
  app.exit(pass ? 0 : 1)
}).catch((error) => {
  console.error('MARKDOWN_IMAGE=FAIL', error)
  killAllSessions()
  app.exit(1)
})
