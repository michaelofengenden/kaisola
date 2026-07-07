import { useEffect, useState } from 'react'
import { useKaisola, type ThemeMode, type CustomAgent } from '../store/store'
import { bridge, isDesktop, type AcpAgent } from '../lib/bridge'
import type { AutonomyLevel } from '../domain/types'
import { useAgentRegistry, openAgentSession, type RegistryAgent } from '../lib/registry'
import { openConfigFile } from '../lib/userConfig'
import { useUpdateState } from '../lib/updates'
import { Icon } from './Icon'
import { Dropdown } from './Dropdown'

// Current Claude models (for the direct API path).
const CLAUDE_MODELS = [
  { value: 'claude-fable-5', name: 'Fable 5' },
  { value: 'claude-opus-4-8', name: 'Opus 4.8' },
  { value: 'claude-opus-4-7', name: 'Opus 4.7' },
  { value: 'claude-sonnet-4-6', name: 'Sonnet 4.6' },
  { value: 'claude-haiku-4-5', name: 'Haiku 4.5' },
]

/** The Zed-style settings nav — one entry per pane. */
const SECTIONS = [
  { id: 'general', name: 'General', icon: 'SlidersHorizontal' },
  { id: 'terminal', name: 'Terminal', icon: 'SquareTerminal' },
  { id: 'agents', name: 'Agents', icon: 'Bot' },
  { id: 'guardrails', name: 'Guardrails', icon: 'ShieldCheck' },
  { id: 'models', name: 'Models & API keys', icon: 'KeyRound' },
  { id: 'literature', name: 'Literature', icon: 'BookOpen' },
] as const
type SectionId = (typeof SECTIONS)[number]['id']

/** One quiet line under each pane title — sparse panes read as designed, not empty. */
const SECTION_DESC: Record<SectionId, string> = {
  general: 'How the shell looks — theme and the native glass material — and software updates.',
  terminal: 'Every terminal card — font size, weight, typeface, and cursor color.',
  agents: 'The CLIs in your + menu. Each runs with your existing install and login — Kaisola never proxies a model.',
  guardrails: 'What agents may do without you: autonomy, saved permission rules, and protected files.',
  models: 'Where AI features think, and the API keys they use — keys live in the OS keychain.',
  literature: 'Sources for the research corpus: PDF ingestion and citation lookups.',
}

const slug = (s: string) =>
  s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || 'agent'

/** Cursor color chips: the olive is the pre-0.1.7 accent look. */
const CURSOR_COLORS = ['#95a456', '#5aa9e6', '#d8a44a', '#e16a6a', '#5ec5c0']

/**
 * Settings — Zed-style: a category nav on the left, one pane at a time on the
 * right. The Agents pane IS the registry: what's in your + menu, what you can
 * add (Zed's agent_servers pattern), and your own custom entries.
 */
export function Settings() {
  const open = useKaisola((s) => s.settingsOpen)
  const setOpen = useKaisola((s) => s.setSettingsOpen)
  const pushToast = useKaisola((s) => s.pushToast)
  const themeMode = useKaisola((s) => s.themeMode)
  const setThemeMode = useKaisola((s) => s.setThemeMode)
  const ecoMode = useKaisola((s) => s.ecoMode)
  const setEcoMode = useKaisola((s) => s.setEcoMode)
  const autonomy = useKaisola((s) => s.autonomy)
  const setAutonomy = useKaisola((s) => s.setAutonomy)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const termFontSize = useKaisola((s) => s.termFontSize)
  const setTermFontSize = useKaisola((s) => s.setTermFontSize)
  const termFontFamily = useKaisola((s) => s.termFontFamily)
  const setTermFontFamily = useKaisola((s) => s.setTermFontFamily)
  const termFontWeight = useKaisola((s) => s.termFontWeight)
  const setTermFontWeight = useKaisola((s) => s.setTermFontWeight)
  const termCursorColor = useKaisola((s) => s.termCursorColor)
  const setTermCursorColor = useKaisola((s) => s.setTermCursorColor)
  const permissionRules = useKaisola((s) => s.permissionRules)
  const removePermissionRule = useKaisola((s) => s.removePermissionRule)
  const sensitiveGlobs = useKaisola((s) => s.sensitiveGlobs)
  const setSensitiveGlobs = useKaisola((s) => s.setSensitiveGlobs)
  const toggleAgentEnabled = useKaisola((s) => s.toggleAgentEnabled)
  const addCustomAgent = useKaisola((s) => s.addCustomAgent)
  const removeCustomAgent = useKaisola((s) => s.removeCustomAgent)
  const claudeModel = useKaisola((s) => s.claudeModel)
  const setClaudeModel = useKaisola((s) => s.setClaudeModel)
  const reasoningProvider = useKaisola((s) => s.reasoningProvider)
  const setReasoningProvider = useKaisola((s) => s.setReasoningProvider)
  const localBaseUrl = useKaisola((s) => s.localBaseUrl)
  const setLocalBaseUrl = useKaisola((s) => s.setLocalBaseUrl)
  const localModel = useKaisola((s) => s.localModel)
  const setLocalModel = useKaisola((s) => s.setLocalModel)
  const openaiModel = useKaisola((s) => s.openaiModel)
  const setOpenaiModel = useKaisola((s) => s.setOpenaiModel)
  const openaiBaseUrl = useKaisola((s) => s.openaiBaseUrl)
  const setOpenaiBaseUrl = useKaisola((s) => s.setOpenaiBaseUrl)
  const grobidEndpoint = useKaisola((s) => s.grobidEndpoint)
  const setGrobidEndpoint = useKaisola((s) => s.setGrobidEndpoint)
  const openAlexMailto = useKaisola((s) => s.openAlexMailto)
  const setOpenAlexMailto = useKaisola((s) => s.setOpenAlexMailto)
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const openSignIn = useKaisola((s) => s.openSignIn)

  const { all: registry, menu } = useAgentRegistry()
  const [agents, setAgents] = useState<AcpAgent[]>([])
  const [connecting, setConnecting] = useState<string | null>(null)
  const [agentMsg, setAgentMsg] = useState<{ id: string; text: string } | null>(null)
  const [glass, setGlass] = useState<{ supported: boolean; active: boolean; enabled: boolean } | null>(null)
  const [section, setSection] = useState<SectionId>('general')

  // custom-agent form (hidden until "Custom…")
  const [adding, setAdding] = useState(false)
  const [newName, setNewName] = useState('')
  const [newCmd, setNewCmd] = useState('')
  const [newKind, setNewKind] = useState<'terminal' | 'acp'>('terminal')
  const [newGlob, setNewGlob] = useState('')

  // Claude API key (folded under Models)
  const [key, setKey] = useState('')
  const [present, setPresent] = useState(false)
  const [fromEnv, setFromEnv] = useState(false)
  const [keyMsg, setKeyMsg] = useState<string | null>(null)
  const [oaKey, setOaKey] = useState('')
  const [oaPresent, setOaPresent] = useState(false)
  const [oaMsg, setOaMsg] = useState<string | null>(null)

  const refresh = () => bridge.acp.status().then((s) => setAgents(s.agents))

  useEffect(() => {
    if (!open) return
    setAgentMsg(null); setKeyMsg(null); setKey(''); setOaMsg(null); setOaKey(''); setAdding(false)
    const pane = useKaisola.getState().settingsPane
    setSection(SECTIONS.some((s) => s.id === pane) ? (pane as SectionId) : 'general')
    void refresh()
    void bridge.settings.hasApiKey().then((s) => { setPresent(s.present); setFromEnv(!!s.fromEnv) })
    void bridge.settings.hasOpenaiKey().then((s) => setOaPresent(s.present))
    if (isDesktop) void bridge.glass().then(setGlass)
    const onCtrl = bridge.acp.onControls(() => void refresh())
    return () => { onCtrl() }
  }, [open])

  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [open, setOpen])

  if (!open) return null

  const isConnected = (id: string) => agents.some((a) => a.key === id && a.connected)
  const runInTerminal = (cmd?: string, name?: string) => {
    if (!cmd) return
    requestTerminal(cmd, { cwd: workspacePath ?? undefined, name })
    setOpen(false)
  }
  const signIn = (a: RegistryAgent) => {
    if (a.deviceLogin) { openSignIn({ key: a.id, name: a.name, command: a.deviceLogin.command, args: a.deviceLogin.args }); setOpen(false) }
    else if (a.login) runInTerminal(a.login, `${a.name} Login`)
  }
  const openAgent = (a: RegistryAgent) => {
    if (a.kind === 'terminal') { openAgentSession(a); setOpen(false); return }
    void (async () => {
      setConnecting(a.id); setAgentMsg(null)
      const r = await bridge.acp.connect(
        a.custom
          ? { presetId: a.id, name: a.name, command: a.command, args: a.args, autonomy, cwd: workspacePath ?? undefined }
          : { presetId: a.id, autonomy, cwd: workspacePath ?? undefined },
      )
      setConnecting(null)
      if (r.ok) void refresh()
      else setAgentMsg({ id: a.id, text: r.message ?? 'Could not connect.' })
    })()
  }
  const addCustom = () => {
    const parts = newCmd.trim().split(/\s+/)
    if (!newName.trim() || !parts[0]) return
    // ids must be unique across customs AND built-ins: 'Aider (local)' and
    // 'Aider Local' slug identically, and silently upserting would destroy
    // the first agent's config — suffix instead
    const taken = new Set(registry.map((a) => a.id))
    const base = `custom-${slug(newName)}`
    let id = base
    for (let n = 2; taken.has(id); n++) id = `${base}-${n}`
    const agent: CustomAgent = {
      id,
      name: newName.trim(),
      kind: newKind,
      command: parts[0],
      args: parts.slice(1),
    }
    addCustomAgent(agent)
    setAdding(false); setNewName(''); setNewCmd('')
  }
  const saveKey = async () => {
    if (!key.trim()) return
    const r = await bridge.settings.setApiKey(key.trim())
    if (r.ok) { setKey(''); setKeyMsg('Saved to the OS keychain.'); void bridge.settings.hasApiKey().then((s) => { setPresent(s.present); setFromEnv(!!s.fromEnv) }) }
    else setKeyMsg(r.message || 'Could not save.')
  }
  const saveOaKey = async () => {
    if (!oaKey.trim()) return
    const r = await bridge.settings.setOpenaiKey(oaKey.trim())
    if (r.ok) { setOaKey(''); setOaMsg('Saved to the OS keychain.'); void bridge.settings.hasOpenaiKey().then((s) => setOaPresent(s.present)) }
    else setOaMsg(r.message || 'Could not save.')
  }
  const clearKey = async () => {
    await bridge.settings.clearApiKey()
    setKeyMsg('Key removed from the keychain.')
    void bridge.settings.hasApiKey().then((s) => { setPresent(s.present); setFromEnv(!!s.fromEnv) })
  }
  const clearOaKey = async () => {
    await bridge.settings.clearOpenaiKey()
    setOaMsg('Key removed from the keychain.')
    void bridge.settings.hasOpenaiKey().then((s) => setOaPresent(s.present))
  }

  const inMenu = new Set(menu.map((a) => a.id))
  const available = registry.filter((a) => !a.custom && !inMenu.has(a.id))
  const rules = permissionRules.filter((r) => r.workspace === workspacePath)

  const agentRow = (a: RegistryAgent) => {
    const on = a.kind === 'acp' && isConnected(a.id)
    // one contextual PRIMARY action per row (the Zed/Claude pattern); install,
    // sign-in, docs, and removal live in the overflow menu
    const overflow = [
      ...(a.installCmd ? [{ value: 'install', name: 'Install CLI', description: a.installCmd }] : []),
      ...(a.login || a.deviceLogin ? [{ value: 'signin', name: 'Sign in', description: a.deviceLogin ? 'Device-code login' : a.login }] : []),
      ...(a.docs ? [{ value: 'docs', name: 'Docs' }] : []),
      { value: 'remove', name: a.custom ? 'Remove agent' : 'Remove from + menu', description: on ? 'Disconnects it first' : undefined },
    ]
    const onOverflow = (value: string) => {
      if (value === 'install') runInTerminal(a.installCmd, `${a.name} Install`)
      else if (value === 'signin') signIn(a)
      else if (value === 'docs') void bridge.openExternal(a.docs!)
      else if (value === 'remove') {
        // never orphan a live connection behind a removed row
        if (on) void bridge.acp.disconnect(a.id).then(() => void refresh())
        if (a.custom) removeCustomAgent(a.id)
        else toggleAgentEnabled(a.id)
      }
    }
    return (
      <div key={a.id}>
        <div className="agent-conn-row">
          <span className={`acp-dot ${on ? 'on' : 'off'}`} />
          <span className="grow agent-preset-name">
            {a.name}
            {a.custom && <span className="faint" style={{ fontWeight: 400 }}> · {[a.command, ...(a.args ?? [])].join(' ')}</span>}
          </span>
          <span className="agent-kind">{a.kind === 'acp' ? 'ACP · stdio' : 'Terminal'}</span>
          {a.kind === 'terminal' ? (
            <button className="btn btn-primary btn-sm" onClick={() => openAgent(a)}><Icon name="SquareTerminal" size={12} /> Open</button>
          ) : on ? (
            <button className="btn btn-sm" onClick={() => { void bridge.acp.disconnect(a.id).then(() => void refresh()) }}><Icon name="Unplug" size={12} /> Disconnect</button>
          ) : (
            <button className="btn btn-primary btn-sm" onClick={() => openAgent(a)} disabled={connecting === a.id}>
              {connecting === a.id ? <Icon name="LoaderCircle" size={12} className="spin" /> : <Icon name="Plug" size={12} />} Connect
            </button>
          )}
          <Dropdown icon="Ellipsis" value="" placeholder="" options={overflow} onSelect={onOverflow} align="right" title="More" />
        </div>
        {agentMsg?.id === a.id && <div className="settings-msg">{agentMsg.text}</div>}
      </div>
    )
  }

  return (
    <div className="focus-scrim" onMouseDown={() => setOpen(false)}>
      <div className="settings-panel-v2 settings-panel-v3" onMouseDown={(e) => e.stopPropagation()}>
        <header className="settings-head">
          <Icon name="Settings" size={14} className="muted" />
          <span className="grow">Settings</span>
          <button className="btn-icon btn-sm" onClick={() => setOpen(false)} aria-label="Close"><Icon name="X" size={14} /></button>
        </header>
        <div className="settings-body-v3">
          {/* Zed-style: categories on the left, one pane at a time on the right */}
          <nav className="settings-nav">
            {SECTIONS.map((s) => (
              <button key={s.id} className="settings-nav-item" data-active={section === s.id} onClick={() => setSection(s.id)}>
                <Icon name={s.icon} size={14} />
                <span className="truncate">{s.name}</span>
              </button>
            ))}
          </nav>
          <div className="settings-pane">
            <div className="settings-pane-head">
              <div className="settings-pane-title">{SECTIONS.find((s) => s.id === section)?.name}</div>
              <p className="settings-pane-desc">{SECTION_DESC[section]}</p>
            </div>

            {section === 'general' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">Theme</span>
                  <div className="settings-row-control">
                    <Dropdown value={themeMode} options={[{ value: 'system', name: 'System' }, { value: 'light', name: 'Light' }, { value: 'dark', name: 'Dark' }]} onSelect={(v) => setThemeMode(v as ThemeMode)} align="right" title="System follows macOS appearance, including scheduled switches" />
                  </div>
                </div>
                {glass?.supported && (
                  <div className="settings-row">
                    <span className="settings-row-label">Liquid Glass <span className="faint" style={{ fontWeight: 400 }}>· relaunch to apply</span></span>
                    <div className="settings-row-control">
                      <Dropdown
                        value={glass.enabled ? 'on' : 'off'}
                        options={[{ value: 'on', name: 'On' }, { value: 'off', name: 'Off' }]}
                        onSelect={(v) => {
                          void bridge.glass({ enabled: v === 'on' }).then(setGlass)
                          pushToast('info', 'Liquid Glass applies on the next launch.')
                        }}
                        align="right"
                        title="Apple's glass material behind the shell"
                      />
                    </div>
                  </div>
                )}
                <div className="settings-row">
                  <span className="settings-row-label">Energy saver <span className="faint" style={{ fontWeight: 400 }}>· solid surfaces, still indicators</span></span>
                  <div className="settings-row-control">
                    <Dropdown
                      value={ecoMode ? 'on' : 'off'}
                      options={[{ value: 'off', name: 'Off' }, { value: 'on', name: 'On' }]}
                      onSelect={(v) => setEcoMode(v === 'on')}
                      align="right"
                      title="Trades the glass look for noticeably lower GPU and battery use"
                    />
                  </div>
                </div>
                {isDesktop && <UpdatesRow />}
              </>
            )}

            {section === 'terminal' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">Font</span>
                  <div className="settings-row-control">
                    <Dropdown
                      value={String(termFontSize)}
                      options={[10, 11, 12, 13, 14, 15, 16].map((n) => ({ value: String(n), name: `${n} px` }))}
                      onSelect={(v) => setTermFontSize(Number(v))}
                      align="right"
                      title="Size — ⌘+ / ⌘− anywhere"
                    />
                    <Dropdown
                      value={String(termFontWeight)}
                      options={[{ value: '400', name: 'Regular' }, { value: '500', name: 'Medium' }, { value: '700', name: 'Bold' }]}
                      onSelect={(v) => setTermFontWeight(Number(v))}
                      align="right"
                      title="Weight"
                    />
                    <Dropdown
                      value={termFontFamily}
                      options={[
                        { value: 'JetBrains Mono', name: 'JetBrains Mono' },
                        { value: 'Fira Code', name: 'Fira Code' },
                        { value: 'IBM Plex Mono', name: 'IBM Plex Mono' },
                        { value: 'ui-monospace', name: 'SF Mono (system)' },
                        { value: 'Menlo', name: 'Menlo' },
                        { value: 'Monaco', name: 'Monaco' },
                      ]}
                      onSelect={setTermFontFamily}
                      align="right"
                      title="Typeface"
                    />
                  </div>
                </div>
                <div className="settings-row">
                  <span className="settings-row-label">Cursor color</span>
                  <div className="settings-row-control" style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <button
                      title="Match text color (default)"
                      onClick={() => setTermCursorColor('auto')}
                      style={{
                        width: 14, height: 14, borderRadius: '50%', cursor: 'pointer', padding: 0,
                        background: 'var(--text-1)',
                        border: '1px solid var(--border-strong)',
                        outline: termCursorColor === 'auto' ? '2px solid var(--text-1)' : 'none',
                        outlineOffset: 2,
                      }}
                    />
                    {CURSOR_COLORS.map((c) => (
                      <button
                        key={c}
                        title={c}
                        onClick={() => setTermCursorColor(c)}
                        style={{
                          width: 14, height: 14, borderRadius: '50%', background: c, border: 'none',
                          cursor: 'pointer', padding: 0,
                          outline: termCursorColor === c ? '2px solid var(--text-1)' : 'none',
                          outlineOffset: 2,
                        }}
                      />
                    ))}
                    <input
                      type="color"
                      title="Custom color"
                      value={termCursorColor.startsWith('#') ? termCursorColor : '#d6dae2'}
                      onChange={(e) => setTermCursorColor(e.target.value)}
                      style={{ width: 22, height: 18, padding: 0, border: 'none', background: 'transparent', cursor: 'pointer', marginLeft: 4 }}
                    />
                  </div>
                </div>
              </>
            )}

            {section === 'agents' && (!isDesktop ? (
              <p className="settings-note">Agents run in the desktop app (npm run electron:dev).</p>
            ) : (
              <>
                {/* agents work in the ACTIVE project tab's folder — the tab strip
                    and launcher own workspace selection, not Settings */}
                <div className="agent-rows">{menu.map(agentRow)}</div>
                {/* the canonical two-track add flow: registry install beside a
                    custom entry, with the JSON escape hatch alongside */}
                <div className="agent-add-row">
                  <Dropdown
                    icon="Plus"
                    value=""
                    placeholder="Add agent"
                    options={[
                      ...available.map((a) => ({ value: `builtin:${a.id}`, name: a.name, description: 'From the built-in registry' })),
                      { value: 'custom', name: 'Custom agent…', description: 'Any CLI — ACP over stdio or a terminal command' },
                    ]}
                    onSelect={(v) => {
                      if (v === 'custom') setAdding(true)
                      else toggleAgentEnabled(v.slice('builtin:'.length))
                    }}
                    align="left"
                    title="Install from the registry, or add any CLI as a custom agent"
                  />
                  <span className="grow" />
                  <button className="btn btn-ghost btn-sm" onClick={() => void openConfigFile('settings')} title="customAgents / enabledAgents in settings.json — the automatable escape hatch">
                    <Icon name="Braces" size={12} /> Edit in settings.json
                  </button>
                </div>
                {adding && (
                  <>
                    <div className="settings-customform">
                      <input className="input" value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Name" spellCheck={false} autoFocus />
                      <input
                        className="input settings-input-full"
                        value={newCmd}
                        onChange={(e) => setNewCmd(e.target.value)}
                        placeholder={newKind === 'acp' ? 'command --acp   (speaks ACP on stdio)' : 'command to run in a terminal'}
                        spellCheck={false}
                        onKeyDown={(e) => { if (e.key === 'Enter') addCustom() }}
                      />
                      <Dropdown
                        value={newKind}
                        options={[{ value: 'terminal', name: 'Terminal' }, { value: 'acp', name: 'ACP chat' }]}
                        onSelect={(v) => setNewKind(v as 'terminal' | 'acp')}
                        align="right"
                        title="How this agent runs"
                      />
                      <button className="btn btn-primary btn-sm" disabled={!newName.trim() || !newCmd.trim()} onClick={addCustom}>
                        <Icon name="Check" size={12} /> Add
                      </button>
                      <button className="btn-icon btn-sm" onClick={() => setAdding(false)} title="Cancel"><Icon name="X" size={13} /></button>
                    </div>
                    <p className="settings-note">Runs this command on your machine with your login — only add agents you trust.</p>
                  </>
                )}
              </>
            ))}

            {section === 'guardrails' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">Agent autonomy <span className="faint" style={{ fontWeight: 400 }}>· what agents may do without you</span></span>
                  <div className="settings-row-control">
                    <Dropdown value={autonomy} options={[{ value: 'observe', name: 'Observe' }, { value: 'propose', name: 'Propose' }, { value: 'execute', name: 'Execute' }, { value: 'sprint', name: 'Sprint' }]} onSelect={(v) => setAutonomy(v as AutonomyLevel)} align="right" title="Observe auto-rejects; Propose/Execute ask; Sprint auto-allows" />
                  </div>
                </div>
                <p className="settings-note">
                  “Always allow” on a permission card saves a rule here. Files matching the globs are blocked on the
                  agents' file channel and never auto-allowed.
                </p>
                {rules.map((r) => (
                  <div key={r.id} className="settings-row">
                    <Icon name="ShieldCheck" size={14} className="muted" />
                    <span className="settings-row-label">
                      <span className="mono">{r.resource === '*' ? `all ${r.action}` : r.resource}</span>
                      <span className="faint" style={{ fontWeight: 400 }}> · {r.action}</span>
                    </span>
                    <div className="settings-row-control">
                      <button className="btn-icon btn-sm" onClick={() => removePermissionRule(r.id)} title="Delete rule — ask again">
                        <Icon name="Trash2" size={13} />
                      </button>
                    </div>
                  </div>
                ))}
                {sensitiveGlobs.map((g) => (
                  <div key={g} className="settings-row">
                    <Icon name="ShieldAlert" size={14} className="muted" />
                    <span className="settings-row-label"><span className="mono">{g}</span></span>
                    <div className="settings-row-control">
                      <button className="btn-icon btn-sm" onClick={() => setSensitiveGlobs(sensitiveGlobs.filter((x) => x !== g))} title="Remove glob">
                        <Icon name="Trash2" size={13} />
                      </button>
                    </div>
                  </div>
                ))}
                <div className="settings-keyrow">
                  <input
                    className="input settings-input-full"
                    value={newGlob}
                    onChange={(e) => setNewGlob(e.target.value)}
                    placeholder="**/credentials*.json"
                    spellCheck={false}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' && newGlob.trim()) { setSensitiveGlobs([...sensitiveGlobs, newGlob.trim()]); setNewGlob('') }
                    }}
                  />
                  <button className="btn btn-sm" disabled={!newGlob.trim()} onClick={() => { setSensitiveGlobs([...sensitiveGlobs, newGlob.trim()]); setNewGlob('') }}>
                    <Icon name="Plus" size={12} /> Add
                  </button>
                </div>
              </>
            )}

            {section === 'models' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">Reasoning provider</span>
                  <div className="settings-row-control">
                    <Dropdown
                      value={reasoningProvider}
                      options={[
                        { value: 'codex', name: 'Codex (subscription)' },
                        { value: 'openai', name: 'OpenAI API' },
                        { value: 'local', name: 'Local model' },
                        { value: 'agent', name: 'Terminal agent' },
                        { value: 'anthropic', name: 'Anthropic API' },
                      ]}
                      onSelect={(v) => setReasoningProvider(v as 'codex' | 'openai' | 'local' | 'agent' | 'anthropic')}
                      align="right"
                      title="Where the AI features think"
                    />
                  </div>
                </div>
                {reasoningProvider === 'codex' && (
                  <p className="settings-note">Runs <span className="mono">codex exec</span> on your ChatGPT login — no per-token billing. Read-only.</p>
                )}
                {reasoningProvider === 'openai' && (
                  <>
                    <div className="settings-row">
                      <span className="settings-row-label">Model</span>
                      <div className="settings-row-control">
                        <input className="input settings-input-md" value={openaiModel} onChange={(e) => setOpenaiModel(e.target.value)} placeholder="gpt-4o-mini" spellCheck={false} />
                      </div>
                    </div>
                    <div className="settings-row">
                      <span className="settings-row-label">Endpoint</span>
                      <div className="settings-row-control">
                        <input className="input settings-input-md" value={openaiBaseUrl} onChange={(e) => setOpenaiBaseUrl(e.target.value)} placeholder="https://api.openai.com/v1" spellCheck={false} />
                      </div>
                    </div>
                    {isDesktop && (
                      <div className="settings-keyrow">
                        <input className="input settings-input-full" type="password" value={oaKey} onChange={(e) => setOaKey(e.target.value)} placeholder={oaPresent ? 'OpenAI key saved — replace…' : 'sk-…'} spellCheck={false} />
                        <button className="btn btn-primary btn-sm" onClick={() => void saveOaKey()} disabled={!oaKey.trim()}><Icon name="Check" size={13} /> Save</button>
                        {oaPresent && (
                          <button className="btn btn-ghost btn-sm" onClick={() => void clearOaKey()} title="Remove the stored OpenAI key"><Icon name="Trash2" size={13} /> Remove</button>
                        )}
                      </div>
                    )}
                    {oaMsg && <div className="settings-msg">{oaMsg}</div>}
                  </>
                )}
                {reasoningProvider === 'local' && (
                  <>
                    <div className="settings-row">
                      <span className="settings-row-label">Endpoint</span>
                      <div className="settings-row-control">
                        <input className="input settings-input-md" value={localBaseUrl} onChange={(e) => setLocalBaseUrl(e.target.value)} placeholder="http://localhost:11434/v1" spellCheck={false} />
                      </div>
                    </div>
                    <div className="settings-row">
                      <span className="settings-row-label">Model</span>
                      <div className="settings-row-control">
                        <input className="input settings-input-md" value={localModel} onChange={(e) => setLocalModel(e.target.value)} placeholder="llama3.1" spellCheck={false} />
                      </div>
                    </div>
                    <p className="settings-note">Ollama, LM Studio, llama.cpp — any OpenAI-compatible endpoint. Nothing leaves your machine.</p>
                  </>
                )}
                {reasoningProvider === 'agent' && (
                  <p className="settings-note">Routes through your connected ACP agent — free with its subscription; structured output is best-effort.</p>
                )}
                <div className="settings-row">
                  <span className="settings-row-label">Claude model <span className="faint" style={{ fontWeight: 400 }}>· direct API</span></span>
                  <div className="settings-row-control">
                    <Dropdown value={claudeModel} options={CLAUDE_MODELS} onSelect={setClaudeModel} align="right" title="Claude model" />
                  </div>
                </div>
                <div className={`settings-status ${present ? 'on' : 'off'}`}>
                  <Icon name={present ? 'CircleCheck' : 'CircleDashed'} size={14} />
                  {present ? (fromEnv ? 'Anthropic key via ANTHROPIC_API_KEY' : 'Anthropic key in keychain') : 'No Anthropic key — only needed for the direct API'}
                </div>
                {isDesktop && (
                  <div className="settings-keyrow">
                    <input className="input settings-input-full" type="password" value={key} onChange={(e) => setKey(e.target.value)} placeholder="sk-ant-…" spellCheck={false} />
                    <button className="btn btn-primary btn-sm" onClick={() => void saveKey()} disabled={!key.trim()}><Icon name="Check" size={13} /> Save</button>
                    {present && !fromEnv && (
                      <button className="btn btn-ghost btn-sm" onClick={() => void clearKey()} title="Remove the stored Anthropic key"><Icon name="Trash2" size={13} /> Remove</button>
                    )}
                  </div>
                )}
                {keyMsg && <div className="settings-msg">{keyMsg}</div>}
              </>
            )}

            {section === 'literature' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">GROBID endpoint</span>
                  <div className="settings-row-control">
                    <input className="input settings-input-md" value={grobidEndpoint} onChange={(e) => setGrobidEndpoint(e.target.value)} placeholder="http://localhost:8070" spellCheck={false} />
                  </div>
                </div>
                <p className="settings-note">Empty turns PDF ingestion off — “Ingest PDFs (GROBID)” needs an endpoint here.</p>
                <div className="settings-row">
                  <span className="settings-row-label">OpenAlex email <span className="faint" style={{ fontWeight: 400 }}>· polite pool</span></span>
                  <div className="settings-row-control">
                    <input className="input settings-input-md" value={openAlexMailto} onChange={(e) => setOpenAlexMailto(e.target.value)} placeholder="you@lab.edu" spellCheck={false} />
                  </div>
                </div>
                <p className="settings-note">A contact email joins OpenAlex's polite pool, raising your rate limits.</p>
              </>
            )}

          </div>
        </div>
      </div>
    </div>
  )
}

/**
 * Software updates — the running version, a manual check, and the live status
 * of the background flow (checks on launch + every 4h, downloads silently,
 * the tab-strip pill appears when a restart applies it).
 */
function UpdatesRow() {
  const u = useUpdateState()
  const status =
    u.type === 'checking' ? 'Checking…'
    : u.type === 'downloading' ? `Downloading ${u.version ?? 'update'}… ${u.percent ?? 0}%`
    : u.type === 'ready' ? `${u.version} downloaded`
    : u.type === 'error' ? 'Could not check for updates'
    : 'Up to date'
  return (
    <>
      <div className="settings-row">
        <span className="settings-row-label">
          Updates {u.appVersion && <span className="faint" style={{ fontWeight: 400 }}>· v{u.appVersion}</span>}
        </span>
        <div className="settings-row-control">
          <span className="faint" title={u.type === 'error' ? u.message ?? undefined : undefined}>{status}</span>
          {u.type === 'ready' ? (
            <button className="btn btn-primary btn-sm" onClick={() => void bridge.update?.install()}>
              <Icon name="ArrowDownToLine" size={12} /> Restart to update
            </button>
          ) : (
            <button
              className="btn btn-sm"
              disabled={u.type === 'checking' || u.type === 'downloading'}
              onClick={() => void bridge.update?.check()}
            >
              <Icon name="RefreshCw" size={12} /> Check for updates
            </button>
          )}
        </div>
      </div>
      <p className="settings-note">New releases install from GitHub — Kaisola checks in the background and updates on restart.</p>
    </>
  )
}
