// UI screenshot harness — a headless "computer-using" view of the REAL desktop
// renderer. Boots the app like smoke.cjs (isDesktop = true, so Settings shows
// the desktop variant), drives the store into a matrix of states, and writes a
// PNG per state via webContents.capturePage(). Any agent can then READ the PNGs
// in ./screenshots and actually SEE the UI.
//
//   npm run shoot            → capture the full matrix
//   npm run shoot -- ideas   → capture only states whose name includes "ideas"
const { app, BrowserWindow, ipcMain } = require('electron')
const path = require('node:path')
const os = require('node:os')
const fsx = require('node:fs')
const { registerModelHandlers } = require('./ipc/modelHandler.cjs')
const { registerToolHandlers } = require('./ipc/toolHandler.cjs')
const { registerSettingsHandlers } = require('./ipc/settingsHandler.cjs')
const { registerTerminalHandlers, killAllSessions } = require('./ipc/terminalHandler.cjs')
const { registerAcpHandlers, disposeAcp } = require('./ipc/acpHandler.cjs')
const { registerAuthHandlers } = require('./ipc/authHandler.cjs')
const { registerFsHandlers } = require('./ipc/fsHandler.cjs')
const { registerGrobidHandlers } = require('./ipc/grobidHandler.cjs')
const { registerSandboxHandlers } = require('./ipc/sandboxHandler.cjs')
const { registerDbHandlers } = require('./ipc/dbHandler.cjs')
const { registerCodexHandlers } = require('./ipc/codexHandler.cjs')
const { registerGitHandlers } = require('./ipc/gitHandler.cjs')
const { registerClaudeHooksHandlers } = require('./ipc/claudeHooksHandler.cjs')
const { registerUpdateHandlers } = require('./ipc/updateHandler.cjs')
const { registerMcpHandlers } = require('./ipc/mcpServer.cjs')
const { registerExtensionHandlers } = require('./ipc/extensionHandler.cjs')
const { registerAssistantArchiveHandlers } = require('./ipc/assistantArchive.cjs')
const worktree = require('./ipc/worktreeHandler.cjs')

process.env.KAISOLA_SMOKE = '1'
app.disableHardwareAcceleration()
const filter = (process.argv.find((a) => !a.startsWith('-') && !a.includes('electron') && !a.includes('shoot.cjs')) || '').toLowerCase()
const OUT = path.join(__dirname, '..', 'screenshots')
fsx.mkdirSync(OUT, { recursive: true })
app.setPath('userData', path.join(os.tmpdir(), 'kaisola-shoot-userdata'))
try { fsx.rmSync(app.getPath('userData'), { recursive: true, force: true }) } catch { /* fresh */ }

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

app.whenReady().then(async () => {
  registerModelHandlers(ipcMain); registerToolHandlers(ipcMain); registerSettingsHandlers(ipcMain)
  registerTerminalHandlers(ipcMain); registerAcpHandlers(ipcMain); registerAuthHandlers(ipcMain)
  registerFsHandlers(ipcMain); registerGrobidHandlers(ipcMain); registerSandboxHandlers(ipcMain)
  registerDbHandlers(ipcMain); registerCodexHandlers(ipcMain); worktree.registerWorktreeHandlers(ipcMain)
  registerGitHandlers(ipcMain); registerClaudeHooksHandlers(ipcMain); registerUpdateHandlers(ipcMain)
  registerMcpHandlers(ipcMain); registerExtensionHandlers(ipcMain)
  registerAssistantArchiveHandlers(ipcMain, path.join(app.getPath('userData'), 'assistant-archives'))
  ipcMain.handle('shell:glass', () => ({ supported: false, active: false, enabled: false }))
  ipcMain.handle('shell:window-mode', () => ({ wantSolid: true, liveSolid: true }))
  ipcMain.handle('window:popped', () => ({ ok: true, termIds: [], states: [], closed: [] }))
  ipcMain.handle('window:pop-closed-ack', () => ({ ok: false }))

  const win = new BrowserWindow({
    show: false,
    width: 1440,
    height: 900,
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false },
  })
  await win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  await wait(800)
  await win.webContents.executeJavaScript(`(() => { try { localStorage.removeItem('kaisola-store') } catch (e) {}; window.__kaisola.getState().clearProject() })()`)

  const js = (code) => win.webContents.executeJavaScript(code)
  const shots = []
  const shot = async (name) => {
    if (filter && !name.toLowerCase().includes(filter)) return
    await wait(380)
    const img = await win.webContents.capturePage()
    const file = path.join(OUT, `${name}.png`)
    fsx.writeFileSync(file, img.toPNG())
    const { width, height } = img.getSize()
    shots.push({ name, file, width, height })
    console.log(`SHOT ${name} ${width}x${height}`)
  }
  const setTheme = (t) => js(`(() => { window.__kaisola.getState().setTheme(${JSON.stringify(t)}); document.documentElement.dataset.theme=${JSON.stringify(t)} })()`)
  const setStage = (s) => js(`window.__kaisola.getState().setStage(${JSON.stringify(s)})`)
  const openSettings = async (tab) => {
    await js(`window.__kaisola.getState().setSettingsOpen(true)`)
    await wait(220)
    // Zed-style Settings: click the matching category in the left nav
    if (tab) await js(`(() => { const b=[...document.querySelectorAll('.settings-nav-item')].find(x => (x.textContent||'').toLowerCase().includes(${JSON.stringify(tab)})); if (b) b.click() })()`)
    await wait(120)
  }
  const closeSettings = () => js(`window.__kaisola.getState().setSettingsOpen(false)`)

  try {
    await js(`window.__kaisola.getState().loadDemo()`)
    await wait(400)

    const views = ['corpus', 'claims', 'questions', 'ideas', 'analysis', 'manuscript', 'review', 'files']
    for (const theme of ['light', 'dark']) {
      await setTheme(theme)
      for (const v of views) {
        await setStage(v)
        // nudge ResizeObserver so react-flow (claim graph) runs fitView in offscreen mode
        await js(`window.dispatchEvent(new Event('resize'))`)
        await wait(v === 'claims' ? 650 : 60)
        await shot(`view-${v}-${theme}`)
      }
    }

    // a toast in flight (legibility pass)
    await setTheme('light'); await setStage('ideas')
    await js(`window.__kaisola.getState().pushToast('success','Hypothesis proposed 2 changes')`)
    await js(`window.__kaisola.getState().pushToast('info','Workflow “Literature pass” — 2 steps queued')`)
    await shot('toast-light')

    // Settings — every tab, both themes for the default tab
    await setTheme('light')
    for (const tab of ['general', 'interface', 'agents', 'models']) {
      await openSettings(tab); await shot(`settings-${tab}-light`)
    }
    await js(`(() => {
      const input = document.querySelector('.settings-search input')
      if (!input) return
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
      setter.call(input, 'permissions')
      input.dispatchEvent(new Event('input', { bubbles: true }))
    })()`)
    await shot('settings-search-light')
    await closeSettings()
    await setTheme('dark')
    for (const tab of ['general', 'models']) {
      await openSettings(tab); await shot(`settings-${tab}-dark`)
    }
    await closeSettings()

    // Extensions — the Zed-shaped full-screen catalog, both themes.
    await setTheme('light')
    await js(`window.dispatchEvent(new CustomEvent('kaisola:extensions-open'))`)
    await shot('extensions-light')
    await js(`window.dispatchEvent(new CustomEvent('kaisola:extensions-open:close'))`)
    await setTheme('dark')
    await js(`window.dispatchEvent(new CustomEvent('kaisola:extensions-open'))`)
    await shot('extensions-dark')
    await js(`window.dispatchEvent(new CustomEvent('kaisola:extensions-open:close'))`)

    // Files editor — set a real workspace, open a code file, switch to Edit
    await setTheme('light'); await setStage('files')
    await js(`window.__kaisola.getState().setWorkspace(${JSON.stringify(path.join(__dirname, '..', 'src', 'styles'))})`)
    await wait(600)
    await js(`(() => { const r=[...document.querySelectorAll('.fx-row')].find(x => /\\.(css|ts|tsx|json|md)$/.test(x.textContent||'')); if (r) r.click() })()`)
    await wait(600)
    await js(`(() => { const b=[...document.querySelectorAll('.fx-mode')].find(x => /Edit|Source/.test(x.textContent||'')); if (b) b.click() })()`)
    await wait(800) // CodeMirror mount
    await shot('files-editor-light')

    // Minimal assistant chrome: the prompt timeline is a top-right hover rail,
    // and waiting follow-ups sit quietly above the composer instead of toasting.
    await setStage('corpus')
    await js(`(() => {
      window.__kaisola.getState().requestNewThread('mock')
      const st = window.__kaisola.getState()
      const tid = st.activeThreadId
      window.__kaisola.setState({ dockGrid: [[tid]], dockViews: [tid], dockOpen: true })
      st.updateAssistantRuntime(tid, () => ({ first: false, turns: [
        { kind: 'user', text: 'Summarize the strongest evidence for this hypothesis.', at: Date.now() - 60000 },
        { kind: 'assistant', text: 'The current evidence converges on two reproducible findings, with one unresolved confound.', at: Date.now() - 55000 },
        { kind: 'user', text: 'Turn the unresolved confound into the smallest useful experiment.', at: Date.now() - 30000 },
        { kind: 'assistant', text: 'Use a paired ablation with the same seed and hold every preprocessing choice constant.', at: Date.now() - 25000 },
      ] }))
      st.setThreadBusy(tid, true)
      st.enqueueAssistantPrompt(tid, { text: 'Check whether the control is already in the repo.', attachments: [], mentions: [], speed: 'default' })
      st.enqueueAssistantPrompt(tid, { text: 'Then draft the exact command to run it.', attachments: [], mentions: [], speed: 'fast' })
    })()`)
    await wait(300)
    await shot('assistant-queue-light')

    // An explicit split layout — ordinary opens focus; only the split action
    // adds columns. Keep one terminal stacked under the second agent.
    await setStage('corpus')
    await js(`(() => {
      const st = window.__kaisola.getState()
      const first = st.activeThreadId
      st.requestNewThread('mock')
      const second = window.__kaisola.getState().activeThreadId
      st.requestTerminal()
      const term = window.__kaisola.getState().terminals.at(-1).id
      st.switchSession(first)
      st.addDockSplit(second)
      st.placeDockView(term, second, 'bottom')
      // Keep the hero shot representative of the two-tier navigation: one
      // active project owns the session shelf while background projects show
      // independent activity states in the calmer parent row.
      st.renameProjectTab(st.activeProjectId, 'Kaisola')
      st.setProjectColor(st.activeProjectId, '#6376d9')
      const docs = st.newProject({ path: null, focus: false })
      st.renameProjectTab(docs, 'Docs')
      st.setProjectColor(docs, '#52a96b')
      st.setProjectActivity(docs, 'running')
      const experiments = st.newProject({ path: null, focus: false })
      st.renameProjectTab(experiments, 'Experiments')
      st.setProjectColor(experiments, '#d18a55')
      st.setProjectActivity(experiments, 'completed')
    })()`)
    await wait(400)
    // the toast-pass toasts must not linger into the hero shots
    await js(`(() => { const s = window.__kaisola.getState(); for (const t of s.toasts) s.dismissToast(t.id) })()`)
    await wait(300)
    for (const theme of ['light', 'dark']) {
      await setTheme(theme)
      for (const layout of ['sidebar', 'shelf', 'bare', 'runway', 'flat', 'compact']) {
        await js(`window.__kaisola.getState().setTabLayout(${JSON.stringify(layout)})`)
        await shot(`tab-layout-${layout}-${theme}`)
      }
    }
    await js(`window.__kaisola.getState().setTabLayout('sidebar')`)

    // High-count red team: 30 live sessions stay in the searchable rail while
    // ordinary creation keeps exactly one primary card. Five explicit panes
    // then occupy at most two columns, stacking instead of crushing width.
    await setTheme('light')
    const sessionStress = await js(`(() => {
      let st = window.__kaisola.getState()
      const anchor = st.activeThreadId || st.assistantThreads.find((thread) => !thread.groupParentId)?.id || st.terminals[0]?.id
      if (anchor) window.__kaisola.setState({ dockGrid: [[anchor]], dockViews: [anchor], dockOpen: true })
      for (let i = 0; i < 30; i++) {
        window.__kaisola.getState().requestNewThread('mock')
        st = window.__kaisola.getState()
        const id = st.activeThreadId
        st.renameAssistantThread(id, i === 17 ? 'Needle · exceptionally long duplicated research session title' : 'Research session ' + String(i + 1).padStart(2, '0'))
        if (i % 7 === 0) st.setThreadBusy(id, true)
        if (i % 9 === 0) st.markNeedsYou(id)
        if (i < 2) st.togglePinSession(id)
      }
      st = window.__kaisola.getState()
      return { total: st.assistantThreads.filter((thread) => !thread.groupParentId).length, cards: st.dockViews.length, columns: st.dockGrid.length }
    })()`)
    await wait(450)
    await shot('sessions-stress-30-light')
    await js(`(() => {
      const input = document.querySelector('.session-filter input')
      if (!input) return
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
      setter.call(input, 'Needle')
      input.dispatchEvent(new Event('input', { bubbles: true }))
    })()`)
    await shot('sessions-filter-light')
    await js(`(() => {
      const clear = document.querySelector('.session-filter button')
      if (clear) clear.click()
      const st = window.__kaisola.getState()
      const hidden = st.assistantThreads.filter((thread) => !thread.groupParentId && !st.dockViews.includes(thread.id)).slice(-4)
      for (const thread of hidden) st.addDockSplit(thread.id)
    })()`)
    await wait(300)
    const splitStress = await js(`(() => {
      const st = window.__kaisola.getState()
      return { cards: st.dockViews.length, columns: st.dockGrid.length, stackDepths: st.dockGrid.map((column) => column.length) }
    })()`)
    console.log('SESSION_STRESS=' + JSON.stringify({ default: sessionStress, explicit: splitStress }))
    if (sessionStress.cards !== 1 || splitStress.columns > 2) throw new Error('Session focus/split stress invariant failed')
    await shot('sessions-split-stress-light')

    // Mesh red team: the supported six-participant ceiling, deliberately long
    // labels, model names, mission, and responses must remain a one-column
    // conversation with compact presence instead of widening into a dashboard.
    const meshStress = await js(`(() => {
      const state = window.__kaisola.getState()
      state.requestNewGroup()
      let group = window.__kaisola.getState().assistantThreads.findLast((thread) => thread.group)
      if (!group) return { configured: false }
      for (const [agentKey, label] of [
        ['codex', 'Implementation verifier with a long name'],
        ['claude-code', 'Research synthesis and evidence owner'],
        ['codex', 'Cross-platform interaction reviewer'],
        ['claude-code', 'Release and regression coordinator'],
      ]) window.__kaisola.getState().addGroupMember(group.id, agentKey, label)
      const next = window.__kaisola.getState()
      group = next.assistantThreads.find((thread) => thread.id === group.id)
      if (!group?.group) return { configured: false }
      const members = group.group.members.map((member, index) => ({
        ...member,
        label: index < 2 ? member.label : member.label,
        modelLabel: 'Frontier reasoning model · extended-context profile ' + (index + 1),
      }))
      const answers = Object.fromEntries(members.map((member, index) => [member.threadId,
        'Participant ' + (index + 1) + ' proposes a bounded ownership lane, names the exact acceptance evidence, and identifies a concrete integration risk. '.repeat(4),
      ]))
      next.setGroupSession(group.id, {
        flow: 'guided',
        phase: 'ready',
        task: 'Red-team a very long multi-agent mission while preserving readable hierarchy, explicit repository boundaries, and calm status feedback. '.repeat(7),
        members,
        answers,
        memberStatuses: Object.fromEntries(members.map((member) => [member.threadId, 'done'])),
      })
      window.__kaisola.setState({ dockGrid: [[group.id]], dockViews: [group.id], dockOpen: true, canvasOpen: false })
      return { configured: true, members: members.length }
    })()`)
    await wait(650)
    const meshGeometry = await js(`(() => {
      const root = document.querySelector('.group-assistant')
      const stream = root?.querySelector('.group-stream')
      const messages = [...root?.querySelectorAll('.group-message') ?? []]
      const streamRect = stream?.getBoundingClientRect()
      return {
        rootFits: !!root && root.scrollWidth <= root.clientWidth + 1,
        streamFits: !!stream && stream.scrollWidth <= stream.clientWidth + 1,
        messagesFit: !!streamRect && messages.length === 6 && messages.every((message) => {
          const rect = message.getBoundingClientRect()
          return rect.left >= streamRect.left - 1 && rect.right <= streamRect.right + 1
        }),
        presenceCompacts: root?.querySelector('.group-presence-more')?.textContent === '+2',
      }
    })()`)
    console.log('MESH_STRESS=' + JSON.stringify({ ...meshStress, ...meshGeometry }))
    if (!meshStress.configured || meshStress.members !== 6 || Object.values(meshGeometry).some((value) => !value)) throw new Error('Mesh six-participant stress invariant failed')
    await shot('mesh-stress-6-light')
  } catch (e) {
    console.log('SHOOT_ERROR ' + (e && e.message || e))
  }

  console.log(`SHOOT_DONE ${shots.length} → ${OUT}`)
  await disposeAcp()
  killAllSessions()
  await wait(250)
  app.exit(0)
}).catch(async (error) => {
  console.error(error)
  await disposeAcp()
  killAllSessions()
  await wait(250)
  app.exit(1)
})
