const attentionByRenderer = new Map()
const trackedRenderers = new Set()
const lastNoticeAt = new Map()
const notifiedEventIds = new Map()

function boundedCount(value) {
  const count = Number(value)
  return Number.isFinite(count) ? Math.min(999, Math.max(0, Math.floor(count))) : 0
}

function exactId(value, max) {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= max
    && /^[A-Za-z0-9][A-Za-z0-9._:@-]*$/.test(value)
    ? value
    : undefined
}

function safeNotice(value) {
  if (!value || typeof value !== 'object') return null
  const title = typeof value.title === 'string' ? value.title.trim().slice(0, 100) : ''
  const body = typeof value.body === 'string' ? value.body.trim().slice(0, 300) : ''
  if (!title) return null
  return {
    title,
    body,
    ...(exactId(value.projectId, 160) ? { projectId: value.projectId } : {}),
    ...(exactId(value.sessionId, 160) ? { sessionId: value.sessionId } : {}),
    ...(exactId(value.eventId, 160) ? { eventId: value.eventId } : {}),
    ...(exactId(value.sourceId, 500) ? { sourceId: value.sourceId } : {}),
    ...(['permission', 'question', 'review', 'blocked', 'failed', 'completed'].includes(value.kind) ? { kind: value.kind } : {}),
    ...(Number.isSafeInteger(value.createdAt) && value.createdAt >= 0 ? { createdAt: value.createdAt } : {}),
  }
}

function noticeKind(payload) {
  if (payload.kind) return payload.kind
  if (/permission|needs you/i.test(payload.title)) return 'question'
  if (/fail|stopp|error/i.test(payload.title)) return 'failed'
  return 'completed'
}

function scopedActiveCount(service, projectSets) {
  const projects = new Set()
  for (const ids of projectSets.values()) for (const id of ids) projects.add(id)
  if (service?.activeCount) return boundedCount(service.activeCount(projects))
  if (!service?.activeEvents) return service?.stats ? boundedCount(service.stats().active) : 0
  return service.activeEvents().reduce((count, event) => count + Number(projects.has(event.projectId)), 0)
}

function registerAttentionHandlers(ipcMain, { app, BrowserWindow, Notification, service = null, platform = process.platform }) {
  const surfaceOwners = new Map()
  const surfaceProjects = new Map()
  const surfaceRenderers = new Set()
  const syncBadge = () => {
    if (platform !== 'darwin' || !app.dock?.setBadge) return
    const total = service
      ? scopedActiveCount(service, surfaceProjects)
      : [...attentionByRenderer.values()].reduce((sum, count) => sum + count, 0)
    app.dock.setBadge(total > 0 ? String(Math.min(999, total)) : '')
  }
  const forget = (sender) => {
    attentionByRenderer.delete(sender.id)
    trackedRenderers.delete(sender.id)
    syncBadge()
  }

  const ownerFor = (payload, fallbackSender) => {
    if (payload.windowId) {
      const exact = BrowserWindow.getAllWindows?.().find((win) => win.__kaisolaSavedId === payload.windowId && !win.isDestroyed?.())
      if (exact) return exact
    }
    if (fallbackSender) {
      const fallback = BrowserWindow.fromWebContents(fallbackSender)
      if (fallback && !fallback.isDestroyed?.()) return fallback
    }
    return BrowserWindow.getFocusedWindow?.()
      ?? BrowserWindow.getAllWindows?.().find((win) => !win.__kaisolaPop && !win.isDestroyed?.())
      ?? null
  }

  const showNotice = (payload, fallbackSender) => {
    if (!payload?.eventId || !payload.title || !Notification?.isSupported?.()) return
    const now = Date.now()
    if (notifiedEventIds.has(payload.eventId)) return
    const owner = ownerFor(payload, fallbackSender)
    if (!owner || owner.isDestroyed?.()) return
    notifiedEventIds.set(payload.eventId, now)
    if (notifiedEventIds.size > 512) {
      for (const [id, at] of notifiedEventIds) if (now - at > 7 * 24 * 60 * 60_000) notifiedEventIds.delete(id)
      while (notifiedEventIds.size > 512) notifiedEventIds.delete(notifiedEventIds.keys().next().value)
    }
    const notice = new Notification({ title: payload.title, body: payload.detail || '', silent: true })
    notice.on('click', () => {
      if (owner.isDestroyed() || owner.webContents.isDestroyed()) return
      if (owner.isMinimized()) owner.restore()
      owner.show()
      owner.focus()
      owner.webContents.send('attention:open', {
        eventId: payload.eventId,
        projectId: payload.projectId,
        sessionId: payload.sessionId,
      })
    })
    notice.show()
    if (!BrowserWindow.getFocusedWindow() && platform === 'darwin' && app.dock?.bounce) {
      app.dock.bounce('informational')
    }
  }

  const unsubscribe = service?.subscribe?.((payload) => {
    syncBadge()
    const channel = payload.type === 'attention.raised' ? 'attention:raised' : 'attention:cleared'
    for (const win of BrowserWindow.getAllWindows?.() ?? []) {
      if (win.__kaisolaPop || win.isDestroyed?.() || win.webContents.isDestroyed()) continue
      win.webContents.send(channel, payload)
    }
    if (payload.type === 'attention.raised' && payload.updated !== true) showNotice(payload)
  }) ?? null

  ipcMain.on('attention:count', (event, value) => {
    if (event.sender.isDestroyed()) return
    attentionByRenderer.set(event.sender.id, boundedCount(value))
    if (!trackedRenderers.has(event.sender.id)) {
      trackedRenderers.add(event.sender.id)
      event.sender.once('destroyed', () => forget(event.sender))
    }
    syncBadge()
  })

  ipcMain.on('attention:surface', (event, raw = {}) => {
    if (!service || event.sender.isDestroyed()) return
    const owner = BrowserWindow.fromWebContents(event.sender)
    if (!owner || owner.isDestroyed?.() || owner.__kaisolaPop || !owner.__kaisolaSavedId) return
    const windowId = owner.__kaisolaSavedId
    surfaceOwners.set(windowId, event.sender.id)
    try {
      service.updateSurface({
        windowId,
        focused: raw.documentVisible === true && raw.documentFocused === true && owner.isFocused?.() === true,
        projectId: raw.projectId,
        visibleSessionIds: raw.visibleSessionIds,
        projects: raw.projects,
      })
      const projects = new Set()
      if (exactId(raw.projectId, 240)) projects.add(raw.projectId)
      for (const item of Array.isArray(raw.projects) ? raw.projects.slice(0, 64) : []) {
        if (exactId(item?.projectId, 240)) projects.add(item.projectId)
      }
      surfaceProjects.set(windowId, projects)
      syncBadge()
    } catch { /* malformed renderer projection is ignored */ }
    if (!surfaceRenderers.has(event.sender.id)) {
      surfaceRenderers.add(event.sender.id)
      event.sender.once('destroyed', () => {
        surfaceRenderers.delete(event.sender.id)
        if (surfaceOwners.get(windowId) === event.sender.id) {
          surfaceOwners.delete(windowId)
          surfaceProjects.delete(windowId)
          service.removeSurface(windowId)
        }
        forget(event.sender)
      })
    }
  })

  ipcMain.handle('attention:ack', (event, { projectId, eventId } = {}) => {
    if (!service) return { ok: false, status: 'unavailable', message: 'Attention authority is unavailable.' }
    const owner = BrowserWindow.fromWebContents(event.sender)
    if (!owner || owner.isDestroyed?.() || owner.__kaisolaPop || !owner.__kaisolaSavedId) {
      return { ok: false, status: 'rejected', message: 'This window cannot acknowledge attention.' }
    }
    try {
      const { createAttentionActorCapability } = require('./attentionService.cjs')
      const actor = createAttentionActorCapability({
        id: `desktop-${owner.__kaisolaSavedId}`,
        surface: 'desktop',
        projectId,
        capabilities: ['observe'],
      })
      return service.acknowledge(actor, { projectId, eventId, reason: 'desktop_acknowledged' })
    } catch (error) {
      return { ok: false, status: 'rejected', message: String(error?.message || error) }
    }
  })

  ipcMain.on('attention:notify', (event, raw) => {
    const payload = safeNotice(raw)
    if (!payload || event.sender.isDestroyed()) return
    if (service && payload.projectId) {
      // ACP permission requests already enter through handleAcpEvent with the
      // authoritative permId. A renderer echo must never create a second source.
      if (payload.kind === 'permission') return
      const owner = BrowserWindow.fromWebContents(event.sender)
      const now = Date.now()
      try {
        service.raise({
          projectId: payload.projectId,
          sessionId: payload.sessionId,
          source: 'renderer-notice',
          sourceId: payload.sourceId || payload.eventId || `${payload.sessionId || 'project'}:${Math.floor(now / 15_000)}`,
          kind: noticeKind(payload),
          title: payload.title,
          detail: payload.body,
          createdAt: payload.createdAt,
          windowId: owner?.__kaisolaSavedId,
          coalesceTarget: true,
        })
      } catch { /* malformed legacy notice is ignored */ }
      return
    }
    if (!Notification?.isSupported?.()) return
    const noticeKey = `${event.sender.id}\0${payload.projectId ?? ''}\0${payload.sessionId ?? ''}`
    const now = Date.now()
    if (now - (lastNoticeAt.get(noticeKey) ?? 0) < 12_000) return
    lastNoticeAt.set(noticeKey, now)
    if (lastNoticeAt.size > 512) {
      for (const [key, at] of lastNoticeAt) if (now - at > 60_000) lastNoticeAt.delete(key)
    }
    const owner = BrowserWindow.fromWebContents(event.sender)
    if (!owner || owner.isDestroyed()) return
    const notice = new Notification({ title: payload.title, body: payload.body, silent: true })
    notice.on('click', () => {
      if (owner.isDestroyed() || owner.webContents.isDestroyed()) return
      if (owner.isMinimized()) owner.restore()
      owner.show()
      owner.focus()
      owner.webContents.send('attention:open', {
        projectId: payload.projectId,
        sessionId: payload.sessionId,
      })
    })
    notice.show()
    if (!BrowserWindow.getFocusedWindow() && platform === 'darwin' && app.dock?.bounce) {
      app.dock.bounce('informational')
    }
  })
  syncBadge()
  return () => unsubscribe?.()
}

module.exports = { boundedCount, exactId, noticeKind, safeNotice, scopedActiveCount, registerAttentionHandlers }
