import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { useKaisola, dockShowsLiveCard, shellConfigDir, clampTermLineHeight, TERM_LINE_HEIGHTS, type ThemeMode, type PerfMode, type TabLayout, type CustomAgent, type TermBackground } from '../store/store'
import { bridge, isDesktop, type AcpAgent, type AppAuthStatus } from '../lib/bridge'
import type { AutonomyLevel } from '../domain/types'
import { useAgentRegistry, openAgentSession, type RegistryAgent } from '../lib/registry'
import { openConfigFile } from '../lib/userConfig'
import { useUpdateState } from '../lib/updates'
import { Icon } from './Icon'
import { GoogleIcon } from './ProviderIcon'
import { Dropdown } from './Dropdown'
import { UsageSettings } from './shell/LimitsButton'
import { openExtensionsCenter } from '../lib/extensions'
import { useModalFocus } from '../lib/useModalFocus'
import { signOutToOnboarding } from '../lib/signOut'
import { defaultHiddenTerminalResidentCap } from '../lib/terminalResidency'

// Current Claude models (for the direct API path). Checked 2026-07-09.
const CLAUDE_MODELS = [
  { value: 'claude-fable-5', name: 'Fable 5' },
  { value: 'claude-opus-4-8', name: 'Opus 4.8' },
  { value: 'claude-sonnet-5', name: 'Sonnet 5' },
  { value: 'claude-opus-4-7', name: 'Opus 4.7' },
  { value: 'claude-sonnet-4-6', name: 'Sonnet 4.6' },
  { value: 'claude-haiku-4-5', name: 'Haiku 4.5' },
]

// Aliases the Claude Code CLI resolves itself (`--model`): kept as aliases so
// they track the newest release without Kaisola updates.
const CLAUDE_TERMINAL_MODELS = [
  { value: 'default', name: 'Default', description: 'Whatever the CLI/account is set to' },
  { value: 'fable', name: 'Fable 5', description: 'Deepest reasoning, longest sessions' },
  { value: 'opus', name: 'Opus 4.8', description: 'Frontier Opus · fast-mode capable' },
  { value: 'sonnet', name: 'Sonnet 5', description: 'Everyday coding · 1M context' },
  { value: 'haiku', name: 'Haiku 4.5', description: 'Fastest for quick tasks' },
  { value: 'opusplan', name: 'Opus Plan', description: 'Opus plans, Sonnet executes' },
]

/** Multiple Claude subscriptions: each account is an isolated CLAUDE_CONFIG_DIR;
 * the ACTIVE project binds to one, and its Claude terminal runs under it —
 * accounts never bleed across project tabs. */
function ClaudeAccountsBlock() {
  const accounts = useKaisola((s) => s.claudeAccounts)
  const accountId = useKaisola((s) => s.claudeAccountId)
  const setAccountId = useKaisola((s) => s.setClaudeAccountId)
  const addAccount = useKaisola((s) => s.addClaudeAccount)
  const removeAccount = useKaisola((s) => s.removeClaudeAccount)
  const setEmail = useKaisola((s) => s.setClaudeAccountEmail)
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const launchClaude = useKaisola((s) => s.launchClaude)
  const pushToast = useKaisola((s) => s.pushToast)
  const [label, setLabel] = useState('')
  const [defaultEmail, setDefaultEmail] = useState<string | undefined>()
  // refresh signed-in identities (email from each dir's .claude.json) on mount
  useEffect(() => {
    void bridge.claude.accountInfo?.().then((r) => setDefaultEmail(r?.email))
    for (const a of useKaisola.getState().claudeAccounts) {
      void bridge.claude.accountInfo?.(a.configDir).then((r) => {
        if (r && r.email !== a.email) setEmail(a.id, r.email)
      })
    }
  }, [setEmail])
  const slug = label.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
  const newDir = slug ? `~/.claude-${slug}` : ''
  const signIn = (a?: { configDir: string; label: string }) => {
    const cmd = a
      ? `mkdir -p ${shellConfigDir(a.configDir)} && CLAUDE_CONFIG_DIR=${shellConfigDir(a.configDir)} claude /login`
      : 'claude /login'
    requestTerminal(cmd, { name: a ? `Claude login · ${a.label}` : 'Claude login' })
  }
  const bindProject = (id: string) => {
    setAccountId(id)
    // apply immediately: relaunch the project's Claude terminal under the account
    void launchClaude({ reveal: true })
    const name = id ? accounts.find((a) => a.id === id)?.label ?? 'account' : 'the default account'
    pushToast('info', `Claude is relaunching under ${name}.`)
  }
  const row = (a: { id: string; label: string; dir: string; email?: string; removable: boolean }) => (
    <div key={a.id || 'default'} style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0 }}>
      <Icon name="UserRound" size={12} />
      <span style={{ fontWeight: 500 }}>{a.label}</span>
      <span className="faint truncate" title={a.dir}>{a.email ?? 'not signed in'}</span>
      <span className="grow" />
      <button type="button" className="btn btn-ghost btn-sm" onClick={() => signIn(a.removable ? { configDir: a.dir, label: a.label } : undefined)} title={`Sign in in a terminal (${a.dir})`}>
        Sign in
      </button>
      {a.removable && (
        <button type="button" className="btn-icon btn-sm" onClick={() => removeAccount(a.id)} title="Remove account (keeps its files on disk)" aria-label={`Remove ${a.label} account`}>
          <Icon name="X" size={13} />
        </button>
      )}
    </div>
  )
  return (
    <>
      <div className="settings-row">
        <span className="settings-row-label">Claude accounts</span>
        <div className="settings-row-control" style={{ display: 'flex', flexDirection: 'column', alignItems: 'stretch', gap: 6, minWidth: 0 }}>
          {row({ id: '', label: 'Default', dir: '~/.claude', email: defaultEmail, removable: false })}
          {accounts.map((a) => row({ id: a.id, label: a.label, dir: a.configDir, email: a.email, removable: true }))}
          <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
            <input
              className="input"
              aria-label="New Claude account label"
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              placeholder="Add account — label (e.g. Work)"
              spellCheck={false}
              onKeyDown={(e) => { if (e.key === 'Enter' && newDir) { addAccount(label, newDir); setLabel('') } }}
            />
            <button type="button"
              className="btn btn-primary btn-sm"
              disabled={!newDir}
              onClick={() => { addAccount(label, newDir); setLabel('') }}
              title={newDir ? `Creates an isolated ${newDir}` : 'Give the account a label first'}
            >
              <Icon name="Plus" size={12} /> Add
            </button>
          </div>
        </div>
      </div>
      <div className="settings-row">
        <span className="settings-row-label">This project uses</span>
        <div className="settings-row-control">
          <Dropdown
            ariaLabel="Claude account for this project"
            value={accountId}
            options={[
              { value: '', name: 'Default account', description: '~/.claude' },
              ...accounts.map((a) => ({ value: a.id, name: a.label, description: a.email ?? a.configDir })),
            ]}
            onSelect={bindProject}
            align="right"
            title="Which Claude subscription this project's sessions run under"
          />
        </div>
      </div>
      <p className="settings-note">
        Each account is an isolated CLAUDE_CONFIG_DIR — sign in once per account. The binding is per
        project tab, so two projects can run two subscriptions side by side without mixing sessions.
      </p>
    </>
  )
}

/** Codex mirrors Claude's account isolation with CODEX_HOME. The selection is
 * project-scoped and is shared by ACP, terminal launches, login, and usage. */
function CodexAccountsBlock() {
  const accounts = useKaisola((s) => s.codexAccounts)
  const accountId = useKaisola((s) => s.codexAccountId)
  const setAccountId = useKaisola((s) => s.setCodexAccountId)
  const addAccount = useKaisola((s) => s.addCodexAccount)
  const removeAccount = useKaisola((s) => s.removeCodexAccount)
  const requestTerminal = useKaisola((s) => s.requestTerminal)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const projectId = useKaisola((s) => s.activeProjectId)
  const pushToast = useKaisola((s) => s.pushToast)
  const [label, setLabel] = useState('')
  const slug = label.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
  const newHome = slug ? `~/.codex-${slug}` : ''
  const shellPrefix = (codexHome?: string) => codexHome ? `CODEX_HOME=${shellConfigDir(codexHome)} ` : ''
  const signIn = (profile?: { label: string; codexHome: string }) => {
    const prefix = shellPrefix(profile?.codexHome)
    const mkdir = profile ? `mkdir -p ${shellConfigDir(profile.codexHome)} && ` : ''
    requestTerminal(`${mkdir}${prefix}codex login`, {
      cwd: workspacePath ?? undefined,
      name: profile ? `Codex login · ${profile.label}` : 'Codex login',
    })
  }
  const openCli = (profile?: { id: string; label: string; codexHome: string }) => {
    requestTerminal(`${shellPrefix(profile?.codexHome)}codex`, {
      cwd: workspacePath ?? undefined,
      name: profile ? `Codex · ${profile.label}` : 'Codex',
      singletonKey: `agent:codex::profile:${profile?.id || 'default'}:${projectId}`,
      restart: true,
    })
  }
  const bindProject = (id: string) => {
    setAccountId(id)
    const state = useKaisola.getState()
    for (const thread of state.assistantThreads.filter((candidate) => candidate.agentKey === 'codex')) {
      void bridge.acp.disconnect(`codex::${thread.id}`, projectId).catch(() => {})
    }
    const name = id ? accounts.find((account) => account.id === id)?.label ?? 'account' : 'the default account'
    pushToast('info', `Codex will reconnect under ${name}. Existing transcripts stay with their sessions.`)
  }
  const row = (profile: { id: string; label: string; codexHome: string; removable: boolean }) => (
    <div key={profile.id || 'default'} style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0 }}>
      <Icon name="UserRound" size={12} />
      <span style={{ fontWeight: 500 }}>{profile.label}</span>
      <span className="faint truncate" title={profile.codexHome}>{profile.codexHome}</span>
      <span className="grow" />
      <button type="button" className="btn btn-ghost btn-sm" onClick={() => signIn(profile.removable ? profile : undefined)}>Sign in</button>
      <button type="button" className="btn btn-ghost btn-sm" onClick={() => openCli(profile.removable ? profile : undefined)}><Icon name="SquareTerminal" size={11} /> CLI</button>
      {profile.removable && (
        <button type="button" className="btn-icon btn-sm" onClick={() => removeAccount(profile.id)} title="Remove account (keeps its files on disk)" aria-label={`Remove ${profile.label} account`}>
          <Icon name="X" size={13} />
        </button>
      )}
    </div>
  )
  return (
    <>
      <div className="settings-row">
        <span className="settings-row-label">Codex accounts</span>
        <div className="settings-row-control" style={{ display: 'flex', flexDirection: 'column', alignItems: 'stretch', gap: 6, minWidth: 0 }}>
          {row({ id: '', label: 'Default', codexHome: '~/.codex', removable: false })}
          {accounts.map((account) => row({ ...account, removable: true }))}
          <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
            <input
              className="input"
              aria-label="New Codex account label"
              value={label}
              onChange={(event) => setLabel(event.target.value)}
              placeholder="Add account — label (e.g. Work)"
              spellCheck={false}
              onKeyDown={(event) => { if (event.key === 'Enter' && newHome) { addAccount(label, newHome); setLabel('') } }}
            />
            <button type="button" className="btn btn-primary btn-sm" disabled={!newHome} onClick={() => { addAccount(label, newHome); setLabel('') }} title={newHome ? `Creates an isolated ${newHome}` : 'Give the account a label first'}>
              <Icon name="Plus" size={12} /> Add
            </button>
          </div>
        </div>
      </div>
      <div className="settings-row">
        <span className="settings-row-label">This project uses</span>
        <div className="settings-row-control">
          <Dropdown
            ariaLabel="Codex account for this project"
            value={accountId}
            options={[
              { value: '', name: 'Default account', description: '~/.codex' },
              ...accounts.map((account) => ({ value: account.id, name: account.label, description: account.codexHome })),
            ]}
            onSelect={bindProject}
            align="right"
            title="Which Codex subscription this project's sessions run under"
          />
        </div>
      </div>
      <p className="settings-note">
        Each profile is an isolated CODEX_HOME. Pick one per project; ACP chats, CLI login, terminal sessions, and the Usage panel use that same account.
      </p>
    </>
  )
}

/** A small information architecture keeps the rail scannable as capabilities
 * grow; on narrow windows the same entries become one horizontal category bar. */
const SECTIONS = [
  { id: 'general', name: 'General', icon: 'SlidersHorizontal' },
  { id: 'interface', name: 'Interface', icon: 'PanelsTopLeft' },
  { id: 'terminal', name: 'Terminal', icon: 'SquareTerminal' },
  { id: 'agents', name: 'Agents', icon: 'Bot' },
  { id: 'usage', name: 'Usage', icon: 'Gauge' },
  { id: 'guardrails', name: 'Guardrails', icon: 'ShieldCheck' },
  { id: 'models', name: 'Models & keys', icon: 'KeyRound' },
  { id: 'extensions', name: 'Extensions', icon: 'Blocks' },
  { id: 'literature', name: 'Literature', icon: 'BookOpen' },
  { id: 'advanced', name: 'Advanced', icon: 'Braces' },
] as const
type SectionId = (typeof SECTIONS)[number]['id']
const SECTION_GROUPS: ReadonlyArray<{ name: string; ids: readonly SectionId[] }> = [
  { name: 'Workspace', ids: ['general', 'interface', 'terminal'] },
  { name: 'Agents', ids: ['agents', 'usage', 'guardrails', 'models'] },
  { name: 'Integrations', ids: ['extensions', 'literature'] },
  { name: 'System', ids: ['advanced'] },
]

/** One quiet line under each pane title — sparse panes read as designed, not empty. */
const SECTION_DESC: Record<SectionId, string> = {
  general: 'Theme, native Live Glass or the lowest-memory Eco shell, and software updates.',
  usage: 'Live subscription windows for your signed-in Codex and Claude accounts.',
  interface: 'Workspace layout and quiet interface details.',
  extensions: 'Languages, previews, themes, and local development integrations installed in Kaisola.',
  terminal: 'Every terminal card — font size, weight, typeface, and cursor color.',
  agents: 'The CLIs in your + menu. Each runs with your existing install and login — Kaisola never proxies a model.',
  guardrails: 'What agents may do without you: autonomy, saved permission rules, and protected files.',
  models: 'Where AI features think, and the API keys they use — keys live in the OS keychain.',
  literature: 'Sources for the research corpus: PDF ingestion and citation lookups.',
  advanced: 'Disk-first renderer caching and editable JSON settings and keybindings.',
}
const SECTION_KEYWORDS: Record<SectionId, string> = {
  general: 'appearance theme light dark system liquid glass eco energy update account',
  interface: 'layout workspace panels sidebar tabs costs inbox diffs drafts wallpaper split',
  terminal: 'shell font size weight family cursor background',
  agents: 'provider cli acp codex claude custom connect login',
  usage: 'subscription limits tokens windows account',
  guardrails: 'autonomy permissions protected sensitive files approval rules',
  models: 'api keys reasoning provider local openai anthropic model',
  extensions: 'languages previews themes integrations plugins',
  literature: 'pdf citations grobid openalex corpus sources',
  advanced: 'renderer memory cache json keybindings hidden terminals',
}

const slug = (s: string) =>
  s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || 'agent'

/** Cursor color chips: the olive is the pre-0.1.7 accent look. */
const CURSOR_COLORS = ['#95a456', '#5aa9e6', '#d8a44a', '#e16a6a', '#5ec5c0']
const CURSOR_SWATCH_STYLE = {
  width: 14,
  height: 14,
  borderRadius: '50%',
  cursor: 'pointer',
  padding: 0,
  border: 'none',
  outlineOffset: 2,
} satisfies CSSProperties
const AUTO_CURSOR_SWATCH_STYLE = {
  ...CURSOR_SWATCH_STYLE,
  background: 'var(--text-1)',
  border: '1px solid var(--border-strong)',
} satisfies CSSProperties
const SETTINGS_DIALOG_STYLE = {
  width: '100vw',
  maxWidth: 'none',
  height: '100vh',
  maxHeight: 'none',
  margin: 0,
  border: 'none',
  padding: '7vh 0 0',
} satisfies CSSProperties

function SettingsToggle({ checked, onChange, label, title, disabled = false }: {
  checked: boolean
  onChange: (checked: boolean) => void
  label: string
  title?: string
  disabled?: boolean
}) {
  return (
    <button
      type="button"
      className="settings-toggle"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      title={title}
      disabled={disabled}
      onClick={() => onChange(!checked)}
    >
      <span aria-hidden="true" />
    </button>
  )
}

function AppAccountRow() {
  const [status, setStatus] = useState<AppAuthStatus | null>(null)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    let alive = true
    void bridge.appAuth.status().then((next) => { if (alive) setStatus(next) })
    const off = bridge.appAuth.onChanged((next) => { if (alive) { setStatus(next); setBusy(false) } })
    return () => { alive = false; off() }
  }, [])
  const signIn = async () => {
    setBusy(true)
    try {
      const next = await bridge.appAuth.signInGoogle()
      setStatus((current) => ({ ...(current ?? { configured: next.configured }), ...next }))
      if (!next.ok) setBusy(false)
    } catch {
      setBusy(false)
    }
  }
  const signOut = async () => {
    setBusy(true)
    try {
      const next = await signOutToOnboarding()
      if (next) setStatus(next)
    } finally {
      setBusy(false)
    }
  }
  const cancelSignIn = async () => {
    setBusy(false)
    try { setStatus(await bridge.appAuth.cancelGoogle()) } catch { /* remain in local mode */ }
  }
  return (
    <div className="settings-row">
      <span className="settings-row-label">Kaisola account</span>
      <div className="settings-row-control" style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <GoogleIcon size={14} />
        {status?.profile ? (
          <>
            <span className="truncate" title={status.profile.email}>{status.profile.name || status.profile.email}</span>
            <span className="faint" title={status.serverVerified ? 'Firebase ID token verified by the Kaisola server' : status.message}>
              {status.serverVerified ? 'Server verified' : 'Verification pending'}
            </span>
            <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => { void signOut() }}>Sign out</button>
          </>
        ) : status?.configured === false ? (
          <span className="faint" title={status.message}>Local mode</span>
        ) : (
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => { void (busy ? cancelSignIn() : signIn()) }}>
            {busy ? 'Cancel sign-in' : 'Sign in with Google'}
          </button>
        )}
      </div>
    </div>
  )
}

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
  const perfMode = useKaisola((s) => s.perfMode)
  const layoutMode = useKaisola((s) => s.layoutMode)
  const setLayoutMode = useKaisola((s) => s.setLayoutMode)
  const dockVisible = useKaisola((s) => s.dockOpen && dockShowsLiveCard(s))
  const setDock = useKaisola((s) => s.setDock)
  const tabLayout = useKaisola((s) => s.tabLayout)
  const setTabLayout = useKaisola((s) => s.setTabLayout)
  const wordDiffs = useKaisola((s) => s.wordDiffs)
  const setWordDiffs = useKaisola((s) => s.setWordDiffs)
  const showCosts = useKaisola((s) => s.showCosts)
  const setShowCosts = useKaisola((s) => s.setShowCosts)
  const inbox = useKaisola((s) => s.inbox)
  const setInbox = useKaisola((s) => s.setInbox)
  const draftRestore = useKaisola((s) => s.draftRestore)
  const setDraftRestore = useKaisola((s) => s.setDraftRestore)
  const wallpaperTint = useKaisola((s) => s.wallpaperTint)
  const setWallpaperTint = useKaisola((s) => s.setWallpaperTint)
  const claudeTerminalModel = useKaisola((s) => s.claudeTerminalModel)
  const setClaudeTerminalModel = useKaisola((s) => s.setClaudeTerminalModel)
  const claudeFastMode = useKaisola((s) => s.claudeFastMode)
  const setClaudeFastMode = useKaisola((s) => s.setClaudeFastMode)
  const setPerfMode = useKaisola((s) => s.setPerfMode)
  const autonomy = useKaisola((s) => s.autonomy)
  const setAutonomy = useKaisola((s) => s.setAutonomy)
  const defaultAutonomy = useKaisola((s) => s.defaultAutonomy)
  const setDefaultAutonomy = useKaisola((s) => s.setDefaultAutonomy)
  const workspacePath = useKaisola((s) => s.workspacePath)
  const termFontSize = useKaisola((s) => s.termFontSize)
  const setTermFontSize = useKaisola((s) => s.setTermFontSize)
  const termFontFamily = useKaisola((s) => s.termFontFamily)
  const setTermFontFamily = useKaisola((s) => s.setTermFontFamily)
  const termFontWeight = useKaisola((s) => s.termFontWeight)
  const setTermFontWeight = useKaisola((s) => s.setTermFontWeight)
  const termLineHeight = useKaisola((s) => clampTermLineHeight(s.termLineHeight))
  const setTermLineHeight = useKaisola((s) => s.setTermLineHeight)
  const termCursorColor = useKaisola((s) => s.termCursorColor)
  const setTermCursorColor = useKaisola((s) => s.setTermCursorColor)
  const termBackground = useKaisola((s) => s.termBackground)
  const setTermBackground = useKaisola((s) => s.setTermBackground)
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
  const [glass, setGlass] = useState<{ supported: boolean; active: boolean; enabled: boolean } | null>(null)
  const [section, setSection] = useState<SectionId>('general')
  const [search, setSearch] = useState('')
  const nativeDialogRef = useRef<HTMLDialogElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const searchRef = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (!open) return
    const dialog = nativeDialogRef.current
    if (!dialog) return
    const onBackdropMouseDown = (event: MouseEvent) => {
      if (event.target === dialog) setOpen(false)
    }
    dialog.addEventListener('mousedown', onBackdropMouseDown)
    if (!dialog.open) dialog.showModal()
    return () => {
      dialog.removeEventListener('mousedown', onBackdropMouseDown)
      if (dialog.open) dialog.close()
    }
  }, [open, setOpen])
  useModalFocus(open, panelRef)
  const [hiddenResidents, setHiddenResidents] = useState(() => {
    const fallback = defaultHiddenTerminalResidentCap(perfMode)
    const value = Number(localStorage.getItem('kaisola:hidden-terminal-residents') ?? fallback)
    return Number.isFinite(value) ? Math.min(8, Math.max(0, Math.round(value))) : fallback
  })

  // custom-agent form (hidden until "Custom…")
  const [adding, setAdding] = useState(false)
  const [newName, setNewName] = useState('')
  const [newCmd, setNewCmd] = useState('')
  const [newKind, setNewKind] = useState<'terminal' | 'acp'>('terminal')
  const [newGlob, setNewGlob] = useState('')
  // window transparency is a creation-time option — a want/live mismatch
  // after a perfMode switch shows the "Restart to finish applying" chip
  const [windowModeMismatch, setWindowModeMismatch] = useState(false)
  useEffect(() => {
    if (!isDesktop) return
    void bridge.windowMode().then((m) => setWindowModeMismatch(m.wantSolid !== m.liveSolid)).catch(() => {})
  }, [perfMode])

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
    setKeyMsg(null); setKey(''); setOaMsg(null); setOaKey(''); setAdding(false); setSearch('')
    const pane = useKaisola.getState().settingsPane
    setSection(SECTIONS.some((s) => s.id === pane) ? (pane as SectionId) : 'general')
    void refresh()
    void bridge.settings.hasApiKey().then((s) => { setPresent(s.present); setFromEnv(!!s.fromEnv) })
    void bridge.settings.hasOpenaiKey().then((s) => setOaPresent(s.present))
    if (isDesktop) void bridge.glass().then(setGlass)
    const onCtrl = bridge.acp.onControls(() => void refresh())
    return () => { onCtrl() }
  }, [open])

  if (!open) return null

  const providerConnections = (id: string) => agents.filter((a) => (a.presetId === id || a.key === id || a.key.startsWith(`${id}::`)) && a.connected)
  const isConnected = (id: string) => providerConnections(id).length > 0
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
    // ACP connections belong to concrete chat threads. Opening a card lets its
    // per-thread owner connect/resume; Settings never creates an orphan
    // provider-scoped session behind the UI.
    openAgentSession(a)
    setOpen(false)
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
    const result = await bridge.settings.clearApiKey()
    const state = await bridge.settings.hasApiKey()
    setPresent(state.present); setFromEnv(!!state.fromEnv)
    setKeyMsg(result.ok && !state.present ? 'Key removed from the keychain.' : result.message ?? 'The key could not be removed.')
  }
  const clearOaKey = async () => {
    const result = await bridge.settings.clearOpenaiKey()
    const state = await bridge.settings.hasOpenaiKey()
    setOaPresent(state.present)
    setOaMsg(result.ok && !state.present ? 'Key removed from the keychain.' : result.message ?? 'The key could not be removed.')
  }

  const inMenu = new Set(menu.map((a) => a.id))
  const available = registry.filter((a) => !a.custom && !inMenu.has(a.id))
  const rules = permissionRules.filter((r) => r.workspace === workspacePath)
  const normalizedSearch = search.trim().toLocaleLowerCase()
  const matchingSections = SECTIONS.filter((candidate) => !normalizedSearch
    || `${candidate.name} ${SECTION_DESC[candidate.id]} ${SECTION_KEYWORDS[candidate.id]}`.toLocaleLowerCase().includes(normalizedSearch))
  const matchingIds = new Set(matchingSections.map((candidate) => candidate.id))
  const chooseSection = (id: SectionId) => {
    setSection(id)
    useKaisola.getState().setSettingsOpen(true, id)
  }
  const updateSearch = (value: string) => {
    setSearch(value)
    const normalized = value.trim().toLocaleLowerCase()
    if (!normalized) return
    const first = SECTIONS.find((candidate) => `${candidate.name} ${SECTION_DESC[candidate.id]} ${SECTION_KEYWORDS[candidate.id]}`.toLocaleLowerCase().includes(normalized))
    if (first) chooseSection(first.id)
  }

  const agentRow = (a: RegistryAgent) => {
    const on = a.kind === 'acp' && isConnected(a.id)
    // one contextual PRIMARY action per row (the Zed/Claude pattern); install,
    // sign-in, docs, and removal live in the overflow menu
    const overflow = [
      ...(a.installCmd ? [{ value: 'install', name: 'Install CLI', description: a.installCmd }] : []),
      ...(a.login || a.deviceLogin ? [{ value: 'signin', name: 'Sign in', description: a.deviceLogin ? 'Device-code login' : a.login }] : []),
      ...(a.kind === 'acp' && a.terminalCommand ? [{ value: 'cli', name: 'Open CLI', description: a.terminalCommand }] : []),
      ...(a.docs ? [{ value: 'docs', name: 'Docs' }] : []),
      { value: 'remove', name: a.custom ? 'Remove agent' : 'Remove from + menu', description: on ? 'Existing chat sessions stay open' : undefined },
    ]
    const onOverflow = (value: string) => {
      if (value === 'install') runInTerminal(a.installCmd, `${a.name} Install`)
      else if (value === 'signin') signIn(a)
      else if (value === 'cli' && a.terminalCommand) {
        requestTerminal(a.terminalCommand, {
          cwd: workspacePath ?? undefined,
          name: `${a.name} CLI`,
          singletonKey: `agent:${a.id}::cli:launcher:${Date.now().toString(36)}`,
          restart: true,
        })
        setOpen(false)
      }
      else if (value === 'docs') void bridge.openExternal(a.docs!)
      else if (value === 'remove') {
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
            <button type="button" className="btn btn-primary btn-sm" onClick={() => openAgent(a)}><Icon name="SquareTerminal" size={12} /> Open</button>
          ) : (
            <button type="button" className="btn btn-primary btn-sm" onClick={() => openAgent(a)}>
              <Icon name={on ? 'MessageSquarePlus' : 'Plug'} size={12} /> {on ? 'New chat' : 'Connect'}
            </button>
          )}
          <Dropdown icon="Ellipsis" value="" placeholder="" options={overflow} onSelect={onOverflow} align="right" title="More" ariaLabel={`More actions for ${a.name}`} />
        </div>
      </div>
    )
  }

  return (
    <dialog
      ref={nativeDialogRef}
      className="focus-scrim"
      style={SETTINGS_DIALOG_STYLE}
      aria-labelledby="settings-title"
      onCancel={(event) => { event.preventDefault(); setOpen(false) }}
    >
      <div
        ref={panelRef}
        className="settings-panel-v2 settings-panel-v3"
        tabIndex={-1}
        onKeyDown={(event) => {
          if ((event.metaKey || event.ctrlKey) && event.key.toLocaleLowerCase() === 'f') {
            event.preventDefault()
            searchRef.current?.focus()
          }
        }}
      >
        <header className="settings-head">
          <Icon name="Settings" size={14} className="muted" />
          <span id="settings-title">Settings</span>
          <label className="settings-search">
            <Icon name="Search" size={12} />
            <input
              ref={searchRef}
              value={search}
              onChange={(event) => updateSearch(event.target.value)}
              onKeyDown={(event) => { if (event.key === 'Escape' && search) { event.preventDefault(); setSearch('') } }}
              placeholder="Search settings"
              aria-label="Search settings"
              spellCheck={false}
            />
            <kbd>⌘F</kbd>
          </label>
          <span className="grow" />
          <button type="button" className="btn-icon btn-sm" onClick={() => setOpen(false)} aria-label="Close"><Icon name="X" size={14} /></button>
        </header>
        <div className="settings-body-v3">
          <nav className="settings-nav" aria-label="Settings categories">
            {SECTION_GROUPS.map((group) => {
              const ids = group.ids.filter((id) => matchingIds.has(id))
              if (!ids.length) return null
              return <div className="settings-nav-group" key={group.name}>
              <div className="settings-nav-group-label">{group.name}</div>
              {ids.map((id) => {
                const s = SECTIONS.find((candidate) => candidate.id === id)!
                return (
                <button type="button"
                  key={s.id}
                  className="settings-nav-item"
                  data-active={section === s.id}
                  data-modal-autofocus={section === s.id ? true : undefined}
                  aria-current={section === s.id ? 'page' : undefined}
                  onClick={() => chooseSection(s.id)}
                >
                  <Icon name={s.icon} size={14} />
                  <span className="truncate">{s.name}</span>
                </button>
                )
              })}
            </div>})}
            {matchingSections.length === 0 && <div className="settings-search-empty" role="status">No settings found</div>}
          </nav>
          <div className="settings-pane">
            <div className="settings-pane-head">
              <div className="settings-pane-title">{SECTIONS.find((s) => s.id === section)?.name}</div>
              <p className="settings-pane-desc">{SECTION_DESC[section]}</p>
            </div>

            {section === 'general' && (
              <>
                <AppAccountRow />
                <div className="settings-choice-block">
                  <div className="settings-choice-head"><span>Theme</span><small>System follows macOS appearance</small></div>
                  <div className="settings-choice-grid" role="group" aria-label="Theme">
                    {([
                      { value: 'system', name: 'System', detail: 'Follow this Mac', icon: 'Monitor' },
                      { value: 'light', name: 'Light', detail: 'Quiet paper', icon: 'Sun' },
                      { value: 'dark', name: 'Dark', detail: 'Low-light ink', icon: 'Moon' },
                    ] as const).map((choice) => <button type="button" key={choice.value} data-active={themeMode === choice.value || undefined} aria-pressed={themeMode === choice.value} onClick={() => setThemeMode(choice.value as ThemeMode)}>
                      <Icon name={choice.icon} size={14} /><span><strong>{choice.name}</strong><small>{choice.detail}</small></span>
                    </button>)}
                  </div>
                </div>
                {glass?.supported && (
                  <div className="settings-row">
                    <span className="settings-row-label">Liquid Glass <span className="faint" style={{ fontWeight: 400 }}>· relaunch to apply</span></span>
                    <div className="settings-row-control">
                      <SettingsToggle
                        checked={glass.enabled}
                        label="Liquid Glass"
                        onChange={(enabled) => {
                          void bridge.glass({ enabled }).then(setGlass)
                          pushToast('info', 'Liquid Glass applies on the next launch.')
                        }}
                        title="Apple's glass material behind the shell"
                      />
                    </div>
                  </div>
                )}
                <div className="settings-choice-block">
                  <div className="settings-choice-head"><span>Appearance energy</span><small>Live Glass measured within 1% of Eco in the paired probe</small>
                    {windowModeMismatch && (
                      <button type="button"
                        className="settings-chip"
                        onClick={() => {
                          void bridge.reapplyWindow().then((result) => {
                            if (!result.ok) pushToast('info', result.message ?? 'Quit and reopen Kaisola when convenient to apply this appearance change.')
                          })
                        }}
                        title="Reopen only this window in place. Running terminals stay alive; Kaisola waits for any active agent turn or approval first."
                      >
                        Apply now
                      </button>
                    )}
                  </div>
                  <div className="settings-choice-grid settings-choice-grid-two" role="group" aria-label="Appearance energy">
                    {([
                      { value: 'glass', name: 'Live Glass', detail: 'Native chrome · fluid', icon: 'Sparkles' },
                      { value: 'eco', name: 'Eco', detail: 'Opaque · lowest memory', icon: 'Leaf' },
                    ] as const).map((choice) => <button type="button" key={choice.value} data-active={perfMode === choice.value || undefined} aria-pressed={perfMode === choice.value} onClick={() => setPerfMode(choice.value as PerfMode)}>
                      <Icon name={choice.icon} size={14} /><span><strong>{choice.name}</strong><small>{choice.detail}</small></span>
                    </button>)}
                  </div>
                </div>
                <p className="settings-note">Switching modes reopens only this window. Commands stay alive; projects, layouts, drafts, scrollback, and agent history rehydrate from disk.</p>
                {isDesktop && <UpdatesRow />}
              </>
            )}

            {section === 'usage' && <UsageSettings />}

            {section === 'interface' && (
              <>
                <div className="settings-row" data-setting="workspace-view">
                  <span className="settings-row-label">Workspace view <span className="faint" style={{ fontWeight: 400 }}>· switches live</span></span>
                  <div className="settings-row-control">
                    <Dropdown
                      ariaLabel="Workspace view"
                      value={layoutMode}
                      options={[
                        { value: 'studio', name: 'Files and sessions' },
                        { value: 'focus', name: 'Files only' },
                      ]}
                      onSelect={(v) => setLayoutMode(v as 'studio' | 'focus')}
                      align="right"
                      title="Choose whether session panels share the workspace with your files"
                    />
                  </div>
                </div>
                <div className="settings-row" data-setting="session-panels">
                  <span className="settings-row-label">Session panels <span className="faint" style={{ fontWeight: 400 }}>· agents and terminals</span></span>
                  <div className="settings-row-control">
                    <Dropdown
                      ariaLabel="Session panels"
                      value={dockVisible && layoutMode === 'studio' ? 'shown' : 'hidden'}
                      options={[
                        { value: 'shown', name: 'Shown' },
                        { value: 'hidden', name: 'Hidden' },
                      ]}
                      onSelect={(v) => setDock(v === 'shown')}
                      align="right"
                      title="Show or hide agent and terminal panels"
                    />
                  </div>
                </div>
                <div className="settings-row" data-setting="session-placement">
                  <span className="settings-row-label">Session placement <span className="faint" style={{ fontWeight: 400 }}>· left or top</span></span>
                  <div className="settings-row-control">
                    <Dropdown
                      ariaLabel="Session placement"
                      value={tabLayout === 'sidebar' ? 'left' : 'top'}
                      options={[
                        { value: 'left', name: 'Left sidebar · default' },
                        { value: 'top', name: 'Across top' },
                      ]}
                      onSelect={(v) => setTabLayout(v === 'left' ? 'sidebar' : 'bare')}
                      align="right"
                      title="Choose whether session tabs appear on the left or across the top"
                    />
                  </div>
                </div>
                <details className="settings-layout-advanced">
                  <summary>Advanced session styles</summary>
                  <div className="settings-row" data-setting="advanced-session-style">
                    <span className="settings-row-label">Top tab style <span className="faint" style={{ fontWeight: 400 }}>· optional</span></span>
                    <div className="settings-row-control">
                      <Dropdown
                        ariaLabel="Top tab style"
                        value={tabLayout === 'sidebar' ? 'bare' : tabLayout}
                        options={[
                          { value: 'bare', name: 'Standard' },
                          { value: 'shelf', name: 'Nested shelf' },
                          { value: 'runway', name: 'Neutral runway' },
                          { value: 'flat', name: 'Flat labels' },
                          { value: 'compact', name: 'Compact row' },
                        ]}
                        onSelect={(v) => setTabLayout(v as TabLayout)}
                        align="right"
                        title="Optional presentation styles for top session tabs"
                      />
                    </div>
                  </div>
                </details>
                {([
                  { label: 'Session cost chips', hint: 'what each agent session cost', value: showCosts, set: setShowCosts, title: 'A quiet $ chip on supported agent session cards — token totals on hover' },
                  { label: 'Cross-project inbox', hint: 'everything that needs you', value: inbox, set: setInbox, title: 'One bell in the tab strip rolling up waiting sessions and gates across every project tab' },
                  { label: 'Word-level diff highlights', hint: 'changed words light up', value: wordDiffs, set: setWordDiffs, title: 'Research diffs mark the exact words that changed, not just the lines' },
                  { label: 'Restore CLI drafts', hint: 'unsent text survives restarts', value: draftRestore, set: setDraftRestore, title: 'A draft typed into a CLI agent is retyped into the resumed session after a restart' },
                  { label: 'Wallpaper-tinted chrome', hint: 'glass follows your desktop', value: wallpaperTint, set: setWallpaperTint, title: 'The tab strip and rail veils adopt the average color of your wallpaper' },
                ] as const).map((row) => (
                  <div className="settings-row" key={row.label}>
                    <span className="settings-row-label">{row.label} <span className="faint" style={{ fontWeight: 400 }}>· {row.hint}</span></span>
                    <div className="settings-row-control">
                      <SettingsToggle
                        checked={row.value}
                        onChange={row.set}
                        label={row.label}
                        title={row.title}
                      />
                    </div>
                  </div>
                ))}
                <p className="settings-note">Each switch also lives in settings.json — automate them like everything else.</p>
              </>
            )}

            {section === 'extensions' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">Extension manager</span>
                  <div className="settings-row-control">
                    <button type="button"
                      className="btn btn-primary btn-sm"
                      onClick={() => { setOpen(false); openExtensionsCenter() }}
                    >
                      <Icon name="Blocks" size={13} /> Open Extensions
                    </button>
                  </div>
                </div>
                <p className="settings-note">
                  Browse installed and available language support, previews, themes, and reviewed local integrations.
                </p>
              </>
            )}

            {section === 'terminal' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">Font</span>
                  <div className="settings-row-control">
                    <Dropdown
                      ariaLabel="Terminal font size"
                      value={String(termFontSize)}
                      options={[8, 9, 10, 11, 12, 13, 14, 15, 16].map((n) => ({ value: String(n), name: `${n} px` }))}
                      onSelect={(v) => setTermFontSize(Number(v))}
                      align="right"
                      title="Size — ⌘+ / ⌘− anywhere"
                    />
                    <Dropdown
                      ariaLabel="Terminal font weight"
                      value={String(termFontWeight)}
                      options={[{ value: '400', name: 'Regular' }, { value: '500', name: 'Medium' }, { value: '700', name: 'Bold' }]}
                      onSelect={(v) => setTermFontWeight(Number(v))}
                      align="right"
                      title="Weight"
                    />
                    <Dropdown
                      ariaLabel="Terminal font family"
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
                  <span className="settings-row-label">Line spacing</span>
                  <div className="settings-row-control">
                    <Dropdown
                      ariaLabel="Terminal line spacing"
                      value={String(termLineHeight)}
                      options={[
                        { value: String(TERM_LINE_HEIGHTS.compact), name: 'Compact' },
                        { value: String(TERM_LINE_HEIGHTS.comfortable), name: 'Comfortable' },
                        { value: String(TERM_LINE_HEIGHTS.airy), name: 'Airy' },
                      ]}
                      onSelect={(v) => setTermLineHeight(Number(v))}
                      align="right"
                      title="Space between lines — the typeface itself is unchanged"
                    />
                  </div>
                </div>
                <div className="settings-row">
                  <span className="settings-row-label">Background</span>
                  <div className="settings-row-control">
                    <Dropdown
                      ariaLabel="Terminal background"
                      value={termBackground}
                      options={[
                        { value: 'paper', name: 'Paper (white)' },
                        { value: 'slate', name: 'Slate' },
                        { value: 'ink', name: 'Ink (dark)' },
                      ]}
                      onSelect={(v) => setTermBackground(v as TermBackground)}
                      align="right"
                      title="Terminal surface tone — independent of the app theme"
                    />
                  </div>
                </div>
                <div className="settings-row">
                  <span className="settings-row-label">Cursor color</span>
                  <div className="settings-row-control" style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <button type="button"
                      title="Match text color (default)"
                      aria-label="Use automatic terminal cursor color"
                      onClick={() => setTermCursorColor('auto')}
                      style={{
                        ...AUTO_CURSOR_SWATCH_STYLE,
                        outline: termCursorColor === 'auto' ? '2px solid var(--text-1)' : 'none',
                      }}
                    />
                    {CURSOR_COLORS.map((c) => (
                      <button type="button"
                        key={c}
                        title={c}
                        aria-label={`Use ${c} terminal cursor color`}
                        onClick={() => setTermCursorColor(c)}
                        style={{
                          ...CURSOR_SWATCH_STYLE,
                          background: c,
                          outline: termCursorColor === c ? '2px solid var(--text-1)' : 'none',
                        }}
                      />
                    ))}
                    <input
                      type="color"
                      aria-label="Custom terminal cursor color"
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
                    ariaLabel="Add agent"
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
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => void openConfigFile('settings')} title="customAgents / enabledAgents in settings.json — the automatable escape hatch">
                    <Icon name="Braces" size={12} /> Edit in settings.json
                  </button>
                </div>
                {adding && (
                  <>
                    <div className="settings-customform">
                      <input className="input" value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Name" spellCheck={false} autoFocus aria-label="Custom agent name" />
                      <input
                        className="input settings-input-full"
                        aria-label="Custom agent command"
                        value={newCmd}
                        onChange={(e) => setNewCmd(e.target.value)}
                        placeholder={newKind === 'acp' ? 'command --acp   (speaks ACP on stdio)' : 'command to run in a terminal'}
                        spellCheck={false}
                        onKeyDown={(e) => { if (e.key === 'Enter') addCustom() }}
                      />
                      <Dropdown
                        ariaLabel="Custom agent connection type"
                        value={newKind}
                        options={[{ value: 'terminal', name: 'Terminal' }, { value: 'acp', name: 'ACP chat' }]}
                        onSelect={(v) => setNewKind(v as 'terminal' | 'acp')}
                        align="right"
                        title="How this agent runs"
                      />
                      <button type="button" className="btn btn-primary btn-sm" disabled={!newName.trim() || !newCmd.trim()} onClick={addCustom}>
                        <Icon name="Check" size={12} /> Add
                      </button>
                      <button type="button" className="btn-icon btn-sm" onClick={() => setAdding(false)} title="Cancel" aria-label="Cancel adding custom agent"><Icon name="X" size={13} /></button>
                    </div>
                    <p className="settings-note">Runs this command on your machine with your login — only add agents you trust.</p>
                  </>
                )}
                <CodexAccountsBlock />
                <div className="hr" />
                <ClaudeAccountsBlock />
                <div className="hr" />
                <div className="settings-row">
                  <span className="settings-row-label">Claude terminal model <span className="faint" style={{ fontWeight: 400 }}>· the prepared per-project session</span></span>
                  <div className="settings-row-control">
                    <Dropdown value={claudeTerminalModel} options={CLAUDE_TERMINAL_MODELS} onSelect={setClaudeTerminalModel} align="right" title="Passed as --model; aliases resolve to the newest release" ariaLabel="Claude terminal model" />
                  </div>
                </div>
                <div className="settings-row">
                  <span className="settings-row-label">Fast mode <span className="faint" style={{ fontWeight: 400 }}>· Opus ↯ up to 2.5× faster, premium pricing</span></span>
                  <div className="settings-row-control">
                    <SettingsToggle
                      checked={claudeFastMode}
                      onChange={setClaudeFastMode}
                      label="Claude fast mode"
                      title="Injected as fastMode:true via the terminal's --settings file"
                    />
                  </div>
                </div>
                <p className="settings-note">
                  Fast mode bills usage credits at the fast-mode Opus rate ($10/$50 per MTok) and needs credits
                  enabled on your Claude account. Codex model &amp; reasoning effort follow ~/.codex/config.toml
                  (currently honored: GPT-5.6 Sol · ultra in the terminal; chat threads cap effort at xhigh until
                  the codex-acp adapter learns the new levels).
                </p>
              </>
            ))}

            {section === 'guardrails' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">Agent autonomy <span className="faint" style={{ fontWeight: 400 }}>· this project</span></span>
                  <div className="settings-row-control">
                    <Dropdown value={autonomy} options={[{ value: 'observe', name: 'Observe' }, { value: 'propose', name: 'Propose' }, { value: 'execute', name: 'Execute' }, { value: 'sprint', name: 'Sprint' }]} onSelect={(v) => setAutonomy(v as AutonomyLevel)} align="right" title="Observe auto-rejects; Propose asks; Execute/Sprint auto-allow" ariaLabel="Agent autonomy for this project" />
                  </div>
                </div>
                <div className="settings-row">
                  <span className="settings-row-label">Default autonomy <span className="faint" style={{ fontWeight: 400 }}>· every new project starts here</span></span>
                  <div className="settings-row-control">
                    <Dropdown value={defaultAutonomy} options={[{ value: 'observe', name: 'Observe' }, { value: 'propose', name: 'Propose' }, { value: 'execute', name: 'Execute' }, { value: 'sprint', name: 'Sprint' }]} onSelect={(v) => setDefaultAutonomy(v as AutonomyLevel)} align="right" title="Set auto permissions once, for every agent every time — Execute/Sprint auto-allow; the Claude terminal mirrors it (acceptEdits / bypassPermissions)" ariaLabel="Default agent autonomy" />
                  </div>
                </div>
                <p className="settings-note">
                  “Always allow” on a permission card saves a rule here. Files matching the globs are blocked on the
                  agents' file channel and never auto-allowed — even at Execute/Sprint.
                </p>
                {rules.map((r) => (
                  <div key={r.id} className="settings-row">
                    <Icon name="ShieldCheck" size={14} className="muted" />
                    <span className="settings-row-label">
                      <span className="mono">{r.resource === '*' ? `all ${r.action}` : r.resource}</span>
                      <span className="faint" style={{ fontWeight: 400 }}> · {r.action}</span>
                    </span>
                    <div className="settings-row-control">
                      <button type="button" className="btn-icon btn-sm" onClick={() => removePermissionRule(r.id)} title="Delete rule — ask again" aria-label={`Delete permission rule for ${r.resource}`}>
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
                      <button type="button" className="btn-icon btn-sm" onClick={() => setSensitiveGlobs(sensitiveGlobs.filter((x) => x !== g))} title="Remove glob" aria-label={`Remove sensitive file pattern ${g}`}>
                        <Icon name="Trash2" size={13} />
                      </button>
                    </div>
                  </div>
                ))}
                <div className="settings-keyrow">
                  <input
                    className="input settings-input-full"
                    aria-label="New sensitive file pattern"
                    value={newGlob}
                    onChange={(e) => setNewGlob(e.target.value)}
                    placeholder="**/credentials*.json"
                    spellCheck={false}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' && newGlob.trim()) { setSensitiveGlobs([...sensitiveGlobs, newGlob.trim()]); setNewGlob('') }
                    }}
                  />
                  <button type="button" className="btn btn-sm" disabled={!newGlob.trim()} onClick={() => { setSensitiveGlobs([...sensitiveGlobs, newGlob.trim()]); setNewGlob('') }}>
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
                      ariaLabel="Reasoning provider"
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
                        <input className="input settings-input-md" value={openaiModel} onChange={(e) => setOpenaiModel(e.target.value)} placeholder="gpt-4o-mini" spellCheck={false} aria-label="OpenAI model" />
                      </div>
                    </div>
                    <div className="settings-row">
                      <span className="settings-row-label">Endpoint</span>
                      <div className="settings-row-control">
                        <input className="input settings-input-md" value={openaiBaseUrl} onChange={(e) => setOpenaiBaseUrl(e.target.value)} placeholder="https://api.openai.com/v1" spellCheck={false} aria-label="OpenAI endpoint" />
                      </div>
                    </div>
                    {isDesktop && (
                      <div className="settings-keyrow">
                        <input className="input settings-input-full" type="password" value={oaKey} onChange={(e) => setOaKey(e.target.value)} placeholder={oaPresent ? 'OpenAI key saved — replace…' : 'sk-…'} spellCheck={false} aria-label="OpenAI API key" />
                        <button type="button" className="btn btn-primary btn-sm" onClick={() => void saveOaKey()} disabled={!oaKey.trim()}><Icon name="Check" size={13} /> Save</button>
                        {oaPresent && (
                          <button type="button" className="btn btn-ghost btn-sm" onClick={() => void clearOaKey()} title="Remove the stored OpenAI key"><Icon name="Trash2" size={13} /> Remove</button>
                        )}
                      </div>
                    )}
                    {oaMsg && <div className="settings-msg" role="status" aria-live="polite">{oaMsg}</div>}
                  </>
                )}
                {reasoningProvider === 'local' && (
                  <>
                    <div className="settings-row">
                      <span className="settings-row-label">Endpoint</span>
                      <div className="settings-row-control">
                        <input className="input settings-input-md" value={localBaseUrl} onChange={(e) => setLocalBaseUrl(e.target.value)} placeholder="http://localhost:11434/v1" spellCheck={false} aria-label="Local model endpoint" />
                      </div>
                    </div>
                    <div className="settings-row">
                      <span className="settings-row-label">Model</span>
                      <div className="settings-row-control">
                        <input className="input settings-input-md" value={localModel} onChange={(e) => setLocalModel(e.target.value)} placeholder="llama3.1" spellCheck={false} aria-label="Local model name" />
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
                    <Dropdown value={claudeModel} options={CLAUDE_MODELS} onSelect={setClaudeModel} align="right" title="Claude model" ariaLabel="Claude direct API model" />
                  </div>
                </div>
                <div className={`settings-status ${present ? 'on' : 'off'}`}>
                  <Icon name={present ? 'CircleCheck' : 'CircleDashed'} size={14} />
                  {present ? (fromEnv ? 'Anthropic key via ANTHROPIC_API_KEY' : 'Anthropic key in keychain') : 'No Anthropic key — only needed for the direct API'}
                </div>
                {isDesktop && (
                  <div className="settings-keyrow">
                    <input className="input settings-input-full" type="password" value={key} onChange={(e) => setKey(e.target.value)} placeholder="sk-ant-…" spellCheck={false} aria-label="Anthropic API key" />
                    <button type="button" className="btn btn-primary btn-sm" onClick={() => void saveKey()} disabled={!key.trim()}><Icon name="Check" size={13} /> Save</button>
                    {present && !fromEnv && (
                      <button type="button" className="btn btn-ghost btn-sm" onClick={() => void clearKey()} title="Remove the stored Anthropic key"><Icon name="Trash2" size={13} /> Remove</button>
                    )}
                  </div>
                )}
                {keyMsg && <div className="settings-msg" role="status" aria-live="polite">{keyMsg}</div>}
              </>
            )}

            {section === 'literature' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">GROBID endpoint</span>
                  <div className="settings-row-control">
                    <input className="input settings-input-md" value={grobidEndpoint} onChange={(e) => setGrobidEndpoint(e.target.value)} placeholder="http://localhost:8070" spellCheck={false} aria-label="GROBID endpoint" />
                  </div>
                </div>
                <p className="settings-note">Empty turns PDF ingestion off — “Ingest PDFs (GROBID)” needs an endpoint here.</p>
                <div className="settings-row">
                  <span className="settings-row-label">OpenAlex email <span className="faint" style={{ fontWeight: 400 }}>· polite pool</span></span>
                  <div className="settings-row-control">
                    <input className="input settings-input-md" value={openAlexMailto} onChange={(e) => setOpenAlexMailto(e.target.value)} placeholder="you@lab.edu" spellCheck={false} aria-label="OpenAlex contact email" />
                  </div>
                </div>
                <p className="settings-note">A contact email joins OpenAlex's polite pool, raising your rate limits.</p>
              </>
            )}

            {section === 'advanced' && (
              <>
                <div className="settings-row">
                  <span className="settings-row-label">Hidden terminal renderers <span className="faint" style={{ fontWeight: 400 }}>· processes always continue</span></span>
                  <div className="settings-row-control">
                    <Dropdown
                      ariaLabel="Hidden terminal renderers"
                      value={String(hiddenResidents)}
                      options={[
                        { value: '0', name: 'Disk only', description: 'Lowest memory; rebuild hidden terminal views from disk' },
                        { value: '1', name: 'Keep 1 warm', description: 'Faster recent-tab switching' },
                        { value: '2', name: 'Keep 2 warm', description: 'Balanced default; two instant terminal views' },
                        { value: '4', name: 'Keep 4 warm', description: 'Fastest switching; useful on large-memory Macs' },
                      ]}
                      onSelect={(value) => {
                        const count = Number(value)
                        setHiddenResidents(count)
                        localStorage.setItem('kaisola:hidden-terminal-residents', String(count))
                        window.dispatchEvent(new Event('kaisola:terminal-residency'))
                      }}
                      align="right"
                      title="Hidden PTYs and drafts always remain disk-backed; this controls only how many hidden xterm canvases stay in renderer memory"
                    />
                  </div>
                </div>
                <div className="settings-row">
                  <span className="settings-row-label">Configuration files</span>
                  <div className="settings-row-control">
                    <button type="button" className="btn btn-ghost btn-sm" onClick={() => void openConfigFile('settings')}><Icon name="Settings" size={12} /> settings.json</button>
                    <button type="button" className="btn btn-ghost btn-sm" onClick={() => void openConfigFile('keymap')}><Icon name="Keyboard" size={12} /> keymap.json</button>
                  </div>
                </div>
                <p className="settings-note">Eco keeps two recent terminal views warm by default; Glass keeps four. Hidden PTYs, drafts, scrollback, and histories stay disk-backed, and invisible views do not paint.</p>
              </>
            )}

          </div>
        </div>
      </div>
    </dialog>
  )
}

/**
 * Software updates — the running version, a manual check, and the live status
 * of the background flow (checks on launch + hourly, downloads silently,
 * the tab-strip pill appears when a restart applies it).
 */
function UpdatesRow() {
  const u = useUpdateState()
  const checking = u.type === 'checking' || !!u.checkingForLatest
  const preparing = u.type === 'downloading' && (u.percent ?? 0) >= 100
  const status =
    u.checkingForLatest ? `Checking for newer than ${u.version ?? 'downloaded update'}…`
    : u.type === 'checking' ? 'Checking…'
    : preparing ? `Preparing ${u.version ?? 'update'}…`
    : u.type === 'downloading' ? `Downloading ${u.version ?? 'update'}… ${u.percent ?? 0}%`
    : u.type === 'ready' ? `${u.version} downloaded`
    : u.type === 'installing' ? (u.message ?? 'Restarting…')
    : u.type === 'error' ? 'Update check failed'
    : 'Up to date'
  const error = u.checkError ?? (u.type === 'error' ? u.message : null)
  return (
    <>
      <div className="settings-row">
        <span className="settings-row-label">
          Updates {u.appVersion && <span className="faint" style={{ fontWeight: 400 }}>· v{u.appVersion}</span>}
        </span>
        <div className="settings-row-control">
          <span className="faint" title={error ?? undefined}>{status}</span>
          {(u.type === 'ready' || u.type === 'installing') && (
            <button type="button"
              className="btn btn-primary btn-sm"
              disabled={u.type === 'installing' || !!u.checkingForLatest}
              onClick={() => void bridge.update?.install()}
              title={u.checkingForLatest ? 'Waiting for the latest-version check to finish' : 'Restart into the fully prepared update'}
            >
              <Icon name="ArrowDownToLine" size={12} /> Restart to update
            </button>
          )}
          <button type="button"
            className="btn btn-sm"
            disabled={checking || u.type === 'downloading' || u.type === 'installing'}
            onClick={() => void bridge.update?.check()}
            title={u.type === 'ready' ? 'Check whether a newer release has shipped before restarting' : 'Check the release feed now'}
          >
            <Icon name="RefreshCw" size={12} /> Check for updates
          </button>
        </div>
      </div>
      {error && <p className="settings-note" style={{ color: 'var(--danger)' }}>{error}</p>}
      <p className="settings-note">New releases download themselves — Kaisola checks at launch, when the window regains focus, and hourly. The tab-strip pill restarts into the new build; quitting applies it too.</p>
    </>
  )
}
