'use strict'

function registerCompanionProjectionHandlers(ipcMain, { BrowserWindow, store, onPublished }) {
  if (!ipcMain?.on || !BrowserWindow?.fromWebContents || !store) throw new Error('companion projection handler dependencies are invalid')
  ipcMain.on('companion:publish-projection', (event, projection) => {
    let result = { ok: false, message: 'Companion projection was rejected.' }
    try {
      const win = BrowserWindow.fromWebContents(event.sender)
      if (!win || win.isDestroyed?.() || win.__kaisolaPop || win.__kaisolaDeleteBoot || win.__kaisolaDeleting) {
        result = { ok: false, message: 'This window cannot publish companion state.' }
      } else if (!win.__kaisolaSavedId || !Number.isSafeInteger(win.__kaisolaCompanionGeneration)) {
        result = { ok: false, message: 'This window has no companion identity.' }
      } else {
        result = store.publish({
          windowId: win.__kaisolaSavedId,
          publisherGeneration: win.__kaisolaCompanionGeneration,
          projection,
        })
        if (result?.projection && typeof onPublished === 'function') onPublished(win.__kaisolaSavedId, result)
      }
    } catch (error) {
      result = { ok: false, message: String(error?.message || error) }
    }
    event.returnValue = result
  })
}

module.exports = { registerCompanionProjectionHandlers }
