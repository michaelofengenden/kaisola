/**
 * The bridge between the renderer and privileged capabilities.
 *
 * In Electron, `window.kaisola` (electron/preload.cjs) provides live model calls,
 * ACP agent connections, the OS-keychain key store, and real node-pty terminals.
 * In a plain browser (`npm run dev`) these are unavailable, so `webMock` keeps
 * the UI running with clear "desktop only" responses.
 */

import type { AutonomyLevel } from '../domain/types'

/** An Anthropic tool definition (its input_schema is a domain JSON schema). */
export interface ModelTool {
  name: string
  description?: string
  input_schema: Record<string, unknown>
}
export interface ModelRequest {
  system?: string
  messages?: Array<{ role: 'user' | 'assistant'; content: string }>
  maxTokens?: number
  model?: string
  /** 'openai' = local/OpenAI-compatible (free, default); 'anthropic' = paid API. */
  provider?: 'openai' | 'anthropic'
  /** Base URL for the OpenAI-compatible endpoint (e.g. Ollama http://localhost:11434/v1). */
  baseUrl?: string
  /** Optional bearer key for a hosted OpenAI-compatible endpoint (local needs none). */
  apiKey?: string
  /** Tell main to use the keychain-stored OpenAI key (the key never reaches the renderer). */
  useStoredKey?: boolean
  /** Force structured output: define a tool and (optionally) require it. */
  tools?: ModelTool[]
  toolChoice?: { type: 'tool'; name: string } | { type: 'auto' } | { type: 'any' }
  /** OpenAI strict structured output (response_format json_schema) — guaranteed conformance. */
  responseSchema?: { name: string; schema: Record<string, unknown> }
}
export interface ModelToolCall {
  id?: string
  name: string
  input: unknown
}
export interface ModelResult {
  ok: boolean
  noKey?: boolean
  model?: string
  text?: string
  /** Structured tool-call outputs (the emit_proposal channel). */
  toolCalls?: ModelToolCall[]
  stopReason?: string
  message?: string
}
export interface KeyStatus {
  ok: boolean
  present: boolean
  fromEnv?: boolean
}
/** One changed file in a worktree diff. */
export interface WorktreeFile {
  path: string
  additions: number
  deletions: number
}

/** A line of output (or the exit) from a sandboxed experiment run. */
export interface SandboxEvent {
  type: 'stdout' | 'stderr' | 'exit'
  data?: string
  code?: number
}
export interface CmdResult {
  ok: boolean
  code?: number
  stdout?: string
  stderr?: string
  message?: string
}
export interface FsEntry {
  name: string
  path: string
  dir: boolean
}
export interface FsSearchResult {
  ok: boolean
  entries?: FsEntry[]
  truncated?: boolean
  message?: string
}
export type FsReadMediaKind = 'text' | 'image' | 'pdf' | 'binary'
export interface FsReadResult {
  ok: boolean
  content?: string
  tooLarge?: boolean
  message?: string
  mediaKind?: FsReadMediaKind
  mime?: string
  dataUrl?: string
  previewUrl?: string
  /** PDF only: the file version — previewUrl is a stable per-path token, so
   * this is the renderer's only signal that the bytes changed (rebuilds). */
  mtimeMs?: number
  size?: number
  binary?: boolean
  unsupported?: boolean
}
export interface FsWatchEvent {
  root: string
  path: string
  name: string
  eventType: string
}
export interface FsWatchBatch {
  root: string
  seq: number
  events: FsWatchEvent[]
  error?: string
}
export interface FileTextZoomGesture {
  direction: 'in' | 'out'
}

export interface AssistantArchiveScope {
  projectId: string
  threadId: string
  epoch?: string
}

// ── ACP ──
export interface AcpPreset {
  id: string
  name: string
  login?: string // the CLI's login command (run in a terminal for browser OAuth)
  installCmd?: string // the CLI's install command
  deviceLogin?: { command: string; args: string[] } // headless device-code login (in-app card)
  docs?: string
  builtin?: boolean
  terminalOnly?: boolean
  terminalCommand?: string
  /** Reachable programmatically but never listed in menus (test wiring). */
  hidden?: boolean
}
export interface AuthEvent {
  phase: 'progress' | 'done' | 'failed'
  url?: string
  code?: string
  exitCode?: number
  error?: string
  tail?: string
}
export interface AcpMeta {
  presetId?: string
  name: string
  sessionId?: string
}
// session controls the agent declares — these drive the composer dropdowns
export interface AcpMode {
  id: string
  name: string
  description?: string
}
export interface AcpModes {
  currentModeId: string
  availableModes: AcpMode[]
}
export interface AcpConfigOption {
  id: string
  name: string
  description?: string
  category?: string // 'mode' | 'model' | 'thought_level' | …
  type?: string // 'select'
  currentValue: string
  options: Array<{ value: string; name: string; description?: string }>
}
export interface AcpModelInfo {
  modelId: string
  name: string
  description?: string
}
export interface AcpModelsField {
  currentModelId: string
  availableModels: AcpModelInfo[]
}
export interface AcpControls {
  modes: AcpModes | null
  models?: AcpModelsField | null
  configOptions: AcpConfigOption[]
}
export interface AcpAuthMethod {
  id: string
  name: string
  description?: string
}
export interface AcpAgent {
  key: string
  name?: string
  presetId?: string
  connected: boolean
  controls?: AcpControls
  authMethods?: AcpAuthMethod[]
  /** Project id the connection is scoped to ('' = unscoped/legacy). */
  scope?: string
  sessionId?: string
  cwd?: string
  mcpHttp?: boolean
  canLoadSession?: boolean
  promptImages?: boolean
  busy?: boolean
  autonomy?: string
}
/** A session/update payload (loose — agents vary). */
export interface AcpUpdate {
  sessionUpdate?: string
  content?: { type: string; text?: string }
  text?: string
  [k: string]: unknown
}
export interface AcpNotice {
  kind?: string
  text?: string
  method?: string
  code?: number
  agent?: string
  key?: string
  url?: string // an OAuth/authorization URL the agent printed
  scope?: string
}
export interface AcpTerminalInfo {
  terminalId: string
  command?: string
  label?: string
  cwd?: string
  agentKey?: string
  agentName?: string
  /** Owning project scope; terminal events are never dropped for background tabs. */
  scope?: string
}
/** An agent is blocked waiting for the human — rendered as an inline card. */
export interface AcpPermissionRequest {
  permId: string
  key: string
  agent: string
  title: string
  kind?: string
  options: Array<{ optionId: string; name: string; kind?: string }>
  /** Diff-shaped tool-call content: the actual change awaiting approval. */
  diffs?: Array<{ path: string; oldText: string; newText: string }>
  /** Touches a sensitive-glob file — card shows a warning, rules never cover it. */
  sensitive?: boolean
  /** Project id the asking connection is scoped to — routes the card to its owner. */
  scope?: string
}
/** A slimmed Claude Code hook event (UserPromptSubmit / PostToolUse / Stop). */
export interface ClaudeHookEvent {
  at: number
  event: 'UserPromptSubmit' | 'PostToolUse' | 'Stop' | string
  sessionId?: string
  cwd?: string
  tool?: string
  filePath?: string
  command?: string
  prompt?: string
}
/** One changed path since a checkpoint (A added / M modified / D deleted). */
export interface GitChange {
  status: string
  path: string
}
export interface GitStatusEntry {
  path: string
  code: string
}
/** A file row in the commit panel (index or worktree side). */
export interface GitStageEntry {
  path: string
  status: string
  untracked?: boolean
  /** Merge conflict (UU/AA/DD…) — resolve in the worktree, not stageable here. */
  conflicted?: boolean
}
export interface GitLogEntry {
  sha: string
  subject: string
  when: string
  author: string
}
/** One actionable line parsed out of a TeX log. */
export interface LatexIssue {
  file?: string
  line?: number
  message: string
  hint?: string
}
export interface LatexBuildResult {
  ok: boolean
  engine?: string
  /** Built PDF (may survive from an earlier run even when this build failed). */
  pdf?: string
  errors?: LatexIssue[]
  warnings?: LatexIssue[]
  logTail?: string
  /** No latexmk/tectonic/pdflatex on this machine. */
  missing?: boolean
  hint?: string
  message?: string
}
export interface LatexSyncResult {
  ok: boolean
  file?: string
  line?: number
  column?: number
  page?: number
  message?: string
}
export interface PdfInfoResult {
  ok: boolean
  path?: string
  pages?: number
  width?: number
  height?: number
  missing?: boolean
  message?: string
}
export interface PdfPageResult {
  ok: boolean
  page?: number
  url?: string
  width?: number
  height?: number
  scale?: number
  missing?: boolean
  message?: string
}
export interface TermSnapshot {
  output: string
  truncated?: boolean
  exited?: boolean
  exitStatus?: { exitCode: number; signal: string | null } | null
  viewState?: { scrollFromBottom?: number; cols?: number; rows?: number } | null
}
/** Live identity of a pty session — who's running, where (diff-broadcast). */
export interface TerminalMetaEvent {
  id: string
  fgProcess: string | null
  running: boolean
  cwd: string | null
  root: string | null
  repo: string | null
  branch: string | null
}
/** A human-gated write from an agent (hypothesis_propose / claim_assert over MCP). */
export interface McpProposalEvent {
  kind: 'hypothesis' | 'claim'
  args: Record<string, unknown>
  at: number
}

/** One external MCP server row (project .mcp.json or the user catalog). */
export interface McpServerRow {
  name: string
  scope: 'user' | 'project'
  kind: 'stdio' | 'http' | 'sse'
  /** Armed: rides ACP sessions + the claude boot config. */
  enabled: boolean
  /** Project scope only: the human approved this exact config (hash-keyed). */
  approved: boolean
  /** Display line: the command or the url (header values never leave main). */
  detail: string
}
/** On-demand health probe result (remote servers; stdio just acknowledges). */
export interface McpProbeResult {
  ok: boolean
  kind?: 'stdio' | 'http' | 'sse'
  serverName?: string
  version?: string
  toolCount?: number
  message?: string
}

/** A row in the shared agent-task ledger (coordination state, never research state). */
export interface LedgerTask {
  id: string
  project?: string | null
  title: string
  detail?: string
  status: 'open' | 'claimed' | 'in_progress' | 'blocked' | 'review' | 'done' | 'rejected' | string
  owner?: string
  createdBy?: string
  dependsOn?: string[]
  result?: string
  createdAt: number
  updatedAt: number
}

/** One rolling Codex rate-limit window (primary = 5h, secondary = weekly). */
export interface CodexWindow {
  usedPercent?: number
  windowDurationMins?: number
  resetsAt?: number // unix epoch seconds
}
export interface CodexUsage {
  ok: boolean
  message?: string
  email?: string
  plan?: string
  primary?: CodexWindow | null
  secondary?: CodexWindow | null
  updatedAt?: number
}
export interface ClaudeTokenSums { input: number; output: number; cacheRead: number; cacheWrite: number }
export interface ClaudeLimitWindow { usedPercent?: number; resetsAt?: number }
export interface ClaudeModelLimit extends ClaudeLimitWindow { label: string }
export interface ClaudeExtraUsage {
  enabled: boolean
  monthlyLimit?: number
  usedCredits?: number
  utilization?: number
  currency?: string
}
export interface ClaudeUsage {
  ok: boolean
  message?: string
  source?: 'agent-sdk' | 'status-line' | 'transcripts' | 'unavailable'
  sourceLabel?: string
  /** The structured SDK usage method is experimental; status-line fallback is stable. */
  experimental?: boolean
  updatedAt?: number
  stale?: boolean
  refreshError?: string
  subscriptionType?: string
  rateLimitsAvailable?: boolean
  limits?: {
    fiveHour?: ClaudeLimitWindow | null
    sevenDay?: ClaudeLimitWindow | null
    modelScoped?: ClaudeModelLimit[]
    extraUsage?: ClaudeExtraUsage | null
  }
  exists?: boolean
  /** Secondary local diagnostic; it is not a subscription percentage. */
  activity?: {
    fiveHour?: ClaudeTokenSums
    week?: ClaudeTokenSums
    lastActivity?: number
    scannedFiles?: number
    partial?: boolean
  }
  fiveHour?: ClaudeTokenSums
  week?: ClaudeTokenSums
  lastActivity?: number
  scannedFiles?: number
  /** True when safety caps excluded older transcript files. */
  partial?: boolean
}

export interface AcpConnectConfig {
  presetId?: string
  /** Renderer-stable logical connection id. Multiple UI threads using the
   * same preset must not share one provider session/context. */
  clientKey?: string
  /** Custom (user-added) agents: the exact ACP server command to spawn. */
  command?: string
  args?: string[]
  name?: string
  cwd?: string
  autonomy?: string
  /** Project id this connection belongs to — main keys the session by it, so
   * the same agent in two project tabs is two independent sessions. */
  scope?: string
  /** Extra env for the spawned agent (e.g. CLAUDE_CONFIG_DIR per account). */
  env?: Record<string, string>
  /** Resume this session id via session/load when the agent supports it —
   * restart continuity; a stale id silently falls back to a fresh session. */
  resumeSessionId?: string
  /** Claude Agent SDK session-creation effort. The Claude ACP adapter accepts
   * this through its namespaced `_meta`; other agents ignore it. */
  claudeEffort?: 'default' | 'low' | 'medium' | 'high' | 'xhigh' | 'max'
  /** Replace an existing live connection (used for session-creation settings). */
  forceReconnect?: boolean
}

export interface UpdateState {
  /** idle = up to date (or never checked); ready = downloaded, restart to apply. */
  type: 'idle' | 'checking' | 'downloading' | 'ready' | 'installing' | 'error'
  /** The version being downloaded / ready to install. */
  version?: string | null
  percent?: number
  message?: string | null
  /** A failed latest-version check can coexist with a valid downloaded build. */
  checkError?: string | null
  /** True while checking whether an already-downloaded build is still latest. */
  checkingForLatest?: boolean
  /** Last successful release-feed check (epoch milliseconds). */
  checkedAt?: number | null
  /** The running build's version. */
  appVersion?: string
  /** Monotonic main-process state version; prevents stale snapshot races. */
  revision?: number
}

export interface KaisolaBridge {
  env: 'electron' | 'web'
  smoke?: boolean
  model: {
    call(req: ModelRequest): Promise<ModelResult>
    stream(req: ModelRequest, onChunk: (text: string) => void): Promise<ModelResult>
  }
  acp: {
    presets(): Promise<AcpPreset[]>
    status(clientKeys?: string[], scope?: string): Promise<{ ok: boolean; agents: AcpAgent[] }>
    connect(config: AcpConnectConfig): Promise<{ ok: boolean; key?: string; agent?: AcpMeta; controls?: AcpControls; authMethods?: AcpAuthMethod[]; message?: string; resumed?: boolean }>
    disconnect(agentKey: string): Promise<{ ok: boolean }>
    cancel(agentKey: string): Promise<{ ok: boolean }>
    /** Keep/release a mounted-card lease; release parks only resumable idle agents. */
    lease(agentKey: string, leaseId: string, active: boolean, idleMs?: number, scope?: string): Promise<{ ok: boolean; leases?: number }>
    diagnostics?(): Promise<unknown>
    /** Live autonomy dial — update every connection this window owns in main. */
    setAutonomy(autonomy: AutonomyLevel): Promise<{ ok: boolean }>
    setMode(agentKey: string, modeId: string): Promise<{ ok: boolean; message?: string }>
    setModel(agentKey: string, modelId: string): Promise<{ ok: boolean; message?: string }>
    setConfigOption(agentKey: string, configId: string, value: string): Promise<{ ok: boolean; message?: string }>
    authenticate(agentKey: string, methodId: string): Promise<{ ok: boolean; pending?: boolean; message?: string }>
    prompt(agentKey: string, text: string, onUpdate: (u: AcpUpdate) => void, images?: { mimeType: string; data: string }[], scope?: string): Promise<{ ok: boolean; stopReason?: string; message?: string }>
    onNotice(cb: (n: AcpNotice) => void): () => void
    onControls(cb: (info: { key: string; controls: AcpControls }) => void): () => void
    onTerminal(cb: (info: AcpTerminalInfo) => void): () => void
    onPermission(cb: (req: AcpPermissionRequest) => void): () => void
    /** Main auto-resolved a pending permission (timeout / connection death). */
    onPermissionResolved(cb: (permId: string) => void): () => void
    respondPermission(permId: string, answer: { optionId?: string; decision?: 'allow' | 'reject' }): Promise<{ ok: boolean }>
    /** Push the sensitive-file globs main enforces on agents' fs channel. */
    setGuardrails?(globs: string[]): void
  }
  claude: {
    /** Constant path of the armed hooks settings file (undefined on web). */
    settingsPath?: string
    armHooks(): Promise<{ ok: boolean; settingsPath?: string; message?: string }>
    /** Merge Claude Code settings (e.g. { fastMode: true }) into the armed
     * --settings file — the next `claude` boot picks them up. */
    setSettingsFlags?(flags: Record<string, unknown>, configDir?: string, cwd?: string): Promise<{ ok: boolean; usageStatusLine?: boolean; message?: string }>
    rebind(): Promise<{ ok: boolean }>
    onEvent(cb: (ev: ClaudeHookEvent) => void): () => void
    /** Does <configDir>/projects/<cwd>/<sessionId>.jsonl still exist? Gates
     * --resume; `any` (any transcript for the cwd) gates the --continue fallback.
     * configDir = the account's CLAUDE_CONFIG_DIR ('' / undefined = ~/.claude). */
    sessionExists?(cwd: string, sessionId: string, configDir?: string): Promise<{ ok: boolean; exists: boolean; any?: boolean }>
    /** Who is signed in under a Claude config dir (multi-subscription labels). */
    accountInfo?(configDir?: string): Promise<{ ok: boolean; exists?: boolean; email?: string; org?: string }>
  }
  /** Subscription limits (the top-bar gauge). Codex uses app-server; Claude
   * uses the official Agent SDK with documented status-line fallback. */
  usage?: {
    codex(codexHome?: string, force?: boolean): Promise<CodexUsage>
    /** force bypasses the five-minute main-process cache (manual refresh). */
    claude(configDir?: string, force?: boolean, exactOnly?: boolean): Promise<ClaudeUsage>
    /** Per-session token sums grouped by model — the $ chip on session cards. */
    claudeSession(configDir: string | undefined, sessionId: string): Promise<{ ok: boolean; exists?: boolean; models?: Array<{ model: string; input: number; output: number; cacheRead: number; cacheWrite: number }> }>
  }
  /** The shared agent-task ledger — agents coordinate through it (via the
   * Kaisola MCP server); the human sees every change in the activity feed. */
  ledger?: {
    list(args?: { project?: string; status?: string }): Promise<{ ok: boolean; tasks: LedgerTask[] }>
    post(args: { project?: string; title: string; detail?: string; owner?: string; createdBy?: string }): Promise<{ ok: boolean; task?: LedgerTask; message?: string }>
    update(args: { id: string; status?: string; owner?: string; result?: string }): Promise<{ ok: boolean; task?: LedgerTask; message?: string }>
    onEvent(cb: (ev: { type: 'posted' | 'updated'; task: LedgerTask }) => void): () => void
  }
  /** The in-app MCP server every connected agent shares. */
  mcp?: {
    info(): Promise<{ ok: boolean; url?: string | null; configPath?: string | null; protocol?: string; transport?: string; toolCount?: number; humanGatedTools?: string[]; configReady?: boolean; auth?: string | null; host?: string | null }>
    /** An agent called a human-gated write tool → a pending Proposal. */
    onProposal?(cb: (ev: McpProposalEvent) => void): () => void
    /** External MCP servers: the workspace's .mcp.json (approval-gated) + the
     * user catalog. Armed servers ride every ACP session and the claude boot. */
    servers?(workspace: string | null): Promise<{ ok: boolean; servers: McpServerRow[]; userError?: string | null; projectError?: string | null; userConfigPath?: string; message?: string }>
    serverSet?(args: { workspace: string | null; scope: 'user' | 'project'; name: string; enabled: boolean }): Promise<{ ok: boolean; message?: string }>
    serverProbe?(args: { workspace: string | null; name: string }): Promise<McpProbeResult>
    /** Ensure the user config file exists (with a template) and return its path. */
    userConfig?(): Promise<{ ok: boolean; path?: string; message?: string }>
    /** Servers configured in sibling apps (Cursor / Claude Desktop / Claude CLI)
     * that the user catalog doesn't have yet — offered as a one-click import. */
    discover?(): Promise<{ ok: boolean; found: Array<{ name: string; origin: string }>; message?: string }>
    /** Import every discovered server into the user catalog, DISABLED. */
    importDiscovered?(): Promise<{ ok: boolean; imported: number; message?: string }>
    onServersChanged?(cb: () => void): () => void
    /** Write one server into the user catalog (trust-modal Install only). */
    serverAdd?(name: string, config: unknown, extensionId?: string): Promise<{ ok: boolean; created?: boolean; owned?: boolean; existing?: boolean; updated?: boolean; conflict?: boolean; message?: string }>
    /** Remove a user-scope server. Extension-owned removals preserve collisions
     * and user-edited records instead of deleting by name. */
    serverRemove?(name: string, extensionId?: string): Promise<{ ok: boolean; removed?: boolean; missing?: boolean; preserved?: boolean; modified?: boolean; conflict?: boolean; message?: string }>
    /** kaisola://mcp/install deeplinks — validated in main, consented here. */
    onInstallRequest?(cb: (req: { name: string; config: Record<string, unknown> }) => void): () => void
  }
  /** Declarative extension registry persisted and validated in main. */
  extensions?: {
    state(): Promise<{ ok: boolean; exists?: boolean; installed: Record<string, { version: string; installedAt: number; enabled: boolean; source: 'bundled' | 'development' }>; development: unknown[]; error?: string; message?: string }>
    set(id: string, record: { version: string; installedAt: number; enabled: boolean; source: 'bundled' | 'development' } | null): Promise<{ ok: boolean; message?: string }>
    inspectDev(sourcePath: string): Promise<{ ok: boolean; manifest?: unknown; message?: string }>
    registerDev(sourcePath: string): Promise<{ ok: boolean; manifest?: unknown; message?: string }>
    removeDev(id: string): Promise<{ ok: boolean; message?: string }>
  }
  git: {
    status(cwd: string): Promise<{ ok: boolean; notRepo?: boolean; root?: string; branch?: string | null; entries?: GitStatusEntry[] }>
    snapshot(cwd: string, label?: string): Promise<{ ok: boolean; notRepo?: boolean; sha?: string; ref?: string; message?: string }>
    changes(cwd: string, sha?: string): Promise<{ ok: boolean; notRepo?: boolean; files?: GitChange[]; message?: string }>
    show(cwd: string, sha: string, file: string): Promise<{ ok: boolean; content?: string; missing?: boolean }>
    restore(cwd: string, sha: string): Promise<{ ok: boolean; restored?: number; trashed?: number; message?: string }>
    /** The commit panel: index (staged) vs worktree (unstaged) file lists. */
    stageStatus(cwd: string): Promise<{ ok: boolean; notRepo?: boolean; root?: string; branch?: string | null; hasHead?: boolean; staged?: GitStageEntry[]; unstaged?: GitStageEntry[]; message?: string }>
    stage(cwd: string, paths: string[]): Promise<{ ok: boolean; message?: string }>
    unstage(cwd: string, paths: string[]): Promise<{ ok: boolean; message?: string }>
    commit(cwd: string, message: string): Promise<{ ok: boolean; sha?: string; summary?: string; message?: string }>
    log(cwd: string, n?: number): Promise<{ ok: boolean; notRepo?: boolean; commits?: GitLogEntry[] }>
  }
  /** Headless LaTeX build: parsed errors, never a terminal of log spew. */
  latex: {
    build(texPath: string): Promise<LatexBuildResult>
    syncFromPdf(req: { pdfPath: string; page: number; x: number; y: number }): Promise<LatexSyncResult>
  }
  settings: {
    setApiKey(key: string): Promise<{ ok: boolean; message?: string }>
    hasApiKey(): Promise<KeyStatus>
    clearApiKey(): Promise<{ ok: boolean }>
    setOpenaiKey(key: string): Promise<{ ok: boolean; message?: string }>
    hasOpenaiKey(): Promise<KeyStatus>
    clearOpenaiKey(): Promise<{ ok: boolean }>
    /** Locations of the user config files (settings.json / keymap.json). */
    paths?(): Promise<{ dir: string; settings: string; keymap: string }>
  }
  terminal: {
    create(id: string, cwd?: string, cols?: number, rows?: number): Promise<{ ok: boolean; cwd?: string; shell?: string; message?: string; existed?: boolean } & Partial<TermSnapshot>>
    write(id: string, data: string): Promise<{ ok: boolean }>
    resize(id: string, cols: number, rows: number): Promise<{ ok: boolean }>
    snapshot(id: string): Promise<TermSnapshot>
    attach(id: string): Promise<TermSnapshot>
    /** Unmount xterm only; the pty continues and scrollback moves to disk. */
    detachRenderer(id: string, viewState?: { scrollFromBottom?: number; cols?: number; rows?: number }): Promise<{ ok: boolean }>
    diagnostics?(): Promise<Array<{ id: string; visible: boolean; ramBytes: number; diskBytes: number; pid?: number; exited: boolean }>>
    signal(id: string, signal?: string): Promise<{ ok: boolean }>
    kill(id: string): Promise<{ ok: boolean }>
    run(command: string, cwd?: string): Promise<CmdResult>
    onData(id: string, cb: (data: string) => void): () => void
    onExit(id: string, cb: (code: number) => void): () => void
    onMeta(cb: (meta: TerminalMetaEvent) => void): () => void
  }
  /** Append-only transcript storage for turns outside the renderer's recent
   * working set. IPC returns unknown records deliberately; the renderer
   * validates the archive boundary before rendering them. */
  assistantArchive?: {
    append(scope: AssistantArchiveScope, batchId: string, turns: unknown[]): Promise<{ ok: boolean; count?: number; duplicate?: boolean; retryable?: boolean; message?: string }>
    info(scope: AssistantArchiveScope): Promise<{ ok: boolean; total: number; message?: string }>
    page(scope: AssistantArchiveScope, before?: number, limit?: number): Promise<{ ok: boolean; turns: unknown[]; before?: number; total?: number; hasMore?: boolean; bytes?: number; message?: string }>
    clear(scope: AssistantArchiveScope): Promise<{ ok: boolean; message?: string }>
  }
  auth: {
    start(command: string, args: string[], onEvent: (ev: AuthEvent) => void): string
    cancel(id: string): Promise<{ ok: boolean }>
  }
  fs: {
    list(dir: string): Promise<{ ok: boolean; entries?: FsEntry[]; message?: string }>
    search(root: string, query: string): Promise<FsSearchResult>
    index(root: string): Promise<{ ok: boolean; files?: string[]; truncated?: boolean; message?: string }>
    read(path: string): Promise<FsReadResult>
    /** Image bytes as base64 (png/jpeg/gif/webp, ≤8 MB) — for ACP image blocks. */
    readImage(path: string): Promise<{ ok: boolean; mimeType?: string; data?: string; size?: number; message?: string }>
    write(path: string, content: string): Promise<{ ok: boolean; message?: string }>
    create(path: string, dir?: boolean): Promise<{ ok: boolean; message?: string }>
    rename(from: string, to: string): Promise<{ ok: boolean; message?: string }>
    trash(path: string): Promise<{ ok: boolean; message?: string }>
    reveal(path: string): Promise<{ ok: boolean }>
    pdfInfo(path: string): Promise<PdfInfoResult>
    pdfPage(path: string, page: number, scale?: number): Promise<PdfPageResult>
    watch(root: string, cb: (ev: FsWatchBatch) => void): () => void
  }
  grobid: {
    process(req: { pdfUrl?: string; endpoint?: string }): Promise<{ ok: boolean; tei?: string; message?: string }>
  }
  /** Git-worktree isolation for file-mutating coding agents (pure local git). */
  worktree: {
    create(req: { repo: string; taskId: string }): Promise<{ ok: boolean; path?: string; branch?: string; base?: string; message?: string }>
    /** `repo` lets main rehydrate a worktree it forgot across a relaunch. */
    finalize(req: { taskId: string; message?: string; repo?: string }): Promise<{ ok: boolean; committed?: boolean; message?: string }>
    diff(req: { taskId: string }): Promise<{ ok: boolean; patch?: string; files?: WorktreeFile[]; message?: string }>
    merge(req: { taskId: string; repo?: string }): Promise<{ ok: boolean; conflicted?: boolean; message?: string }>
    remove(req: { taskId: string; repo?: string }): Promise<{ ok: boolean; message?: string }>
    list(req: { repo: string }): Promise<{ ok: boolean; raw?: string }>
  }
  codex: {
    /** Run a one-shot prompt through `codex exec` (your ChatGPT/Codex subscription). */
    exec(req: { prompt: string; cwd?: string }): Promise<{ ok: boolean; text?: string; message?: string }>
  }
  sandbox: {
    available(): Promise<{ docker: boolean }>
    run(
      req: { mode?: 'mock' | 'docker' | 'e2b'; image?: string; command?: string; cwd?: string; env?: Record<string, string> },
      onEvent: (e: SandboxEvent) => void,
    ): Promise<{ ok: boolean; code?: number; message?: string }>
  }
  db: {
    /** Synchronous read (so persist rehydration stays sync). */
    getSync(key: string): string | null
    /** Synchronous write — used to flush the last state on quit. */
    setSync(key: string, value: string): boolean
    set(key: string, value: string): Promise<{ ok: boolean; message?: string }>
    del(key: string): Promise<{ ok: boolean }>
    kind(): Promise<{ kind: 'sqlite' | 'json'; reason?: string }>
  }
  openExternal(url: string): Promise<{ ok: boolean }>
  pickFolder(): Promise<{ ok: boolean; path?: string; message?: string }>
  pickFiles(): Promise<{ ok: boolean; paths?: string[] }>
  /** Liquid Glass preference (macOS 26+; needs a relaunch to apply). */
  glass(patch?: { enabled: boolean }): Promise<{ supported: boolean; active: boolean; enabled: boolean; fallback?: string | null }>
  /** Perf-mode window plumbing: transparency is a creation-time option — set()
   *  persists what the NEXT window should be; a want/live mismatch drives the
   *  Settings "Restart to finish applying" chip. */
  windowMode(patch?: { solidWindow?: boolean; solidBg?: string }): Promise<{ wantSolid: boolean; liveSolid: boolean }>
  /** Quit and relaunch (used to apply a window-mode change). */
  relaunch(): Promise<void>
  /** Apply a creation-time mode by swapping only this renderer window. Main's
   * PTYs/agent turns remain alive; after repeated swaps a manual restart may be
   * requested without automatically terminating work. */
  reapplyWindow(): Promise<{ ok: boolean; unchanged?: boolean; restartRequired?: boolean; busy?: boolean; awaitingPermission?: boolean; message?: string }>
  /** Wallpaper-sampled glass wash (macOS; failures degrade to the theme tint). */
  glassWash: {
    sample(): Promise<{ ok: boolean; avg?: { r: number; g: number; b: number }; blurDataUrl?: string; screen?: { x: number; y: number; w: number; h: number } }>
    onRefresh(cb: () => void): () => void
  }
  /** Multi-window: full slot windows + terminal pop-outs + project-tab menu wiring. */
  windows?: {
    newWindow(): Promise<{ ok: boolean }>
    pop(termId: string, title?: string, hue?: string): Promise<{ ok: boolean; existed?: boolean }>
    onPopClosed(cb: (info: { termId: string }) => void): () => void
    /** Native File-menu New Tab (⌘T). */
    onNewTab(cb: () => void): () => void
    /** Native File-menu Close Tab (⌘W). */
    onCloseTab(cb: () => void): () => void
    /** Native File-menu Reopen Closed Tab (⌘⌥T). */
    onReopenTab(cb: () => void): () => void
    /** Native Window-menu tab click → activate this project id. */
    onActivateTab(cb: (id: string) => void): () => void
    /** Push the current tab list so main can rebuild the Window menu. */
    tabsChanged(list: Array<{ id: string; title: string; active: boolean }>): void
    /** Set the native window title to the active project (empty → the app name). */
    setTitle(title: string): void
    /** Tear-off: ship a project (tab + persisted slice) to a NEW OS window. */
    detachProject(payload: { tab: unknown; slice: unknown; at?: { x: number; y: number }; popped?: string[] }): Promise<{ ok: boolean }>
    /** The new window receives the torn-off project here after it boots. */
    onAdoptProject(cb: (payload: { tab: unknown; slice: unknown; popped?: string[] }) => void): () => void
  }
  /** In-app software updates — the GitHub releases feed via electron-updater. */
  update?: {
    /** Snapshot for late subscribers (the pill mounts after events may have fired). */
    state(): Promise<UpdateState>
    check(): Promise<{ ok: boolean; message?: string }>
    /** Quit and relaunch into the downloaded build. */
    install(): Promise<{ ok: boolean; message?: string }>
    onEvent(cb: (s: UpdateState) => void): () => void
  }
  /** Sync the native under-window material to the app theme. */
  setAppTheme?(theme: 'dark' | 'light' | 'system'): void
  /** Another window toggled the app theme — follow it. */
  onThemeChanged?(cb: (theme: 'dark' | 'light' | 'system') => void): () => void
  /** Drive the real window from the renderer-drawn traffic lights. */
  winCtl(action: 'close' | 'minimize' | 'fullscreen' | 'zoom'): void
  /** Native Electron pinch/page-zoom gestures, forwarded after main prevents page zoom. */
  onFileTextZoomGesture?(cb: (gesture: FileTextZoomGesture) => void): () => void
  /** Files the OS hands to the app (Finder double-click / "Open With" / dock drop). */
  onOpenExternalFile?(cb: (payload: { path: string }) => void): () => void
  /** Absolute path of a DataTransfer File dropped onto the window. */
  pathForFile?(file: File): string
}

const DESKTOP_ONLY = 'Available in the desktop app (npm run electron:dev).'
const webAssistantArchive = new Map<string, unknown[]>()
const webAssistantArchiveBatches = new Map<string, Set<string>>()
const webArchiveKey = (scope: AssistantArchiveScope) => JSON.stringify([scope.projectId, scope.threadId, scope.epoch ?? '0'])

const webMock: KaisolaBridge = {
  env: 'web',
  smoke: false,
  model: {
    async call() {
      return { ok: false, noKey: true, model: 'claude-opus-4-8', message: DESKTOP_ONLY }
    },
    async stream() {
      return { ok: false, noKey: true, message: DESKTOP_ONLY }
    },
  },
  acp: {
    async presets() {
      return []
    },
    async status() {
      return { ok: true, agents: [] }
    },
    async connect() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async disconnect() {
      return { ok: true }
    },
    async cancel() {
      return { ok: true }
    },
    async lease() {
      return { ok: true }
    },
    async diagnostics() {
      return {}
    },
    async setAutonomy() {
      return { ok: true }
    },
    async setMode() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async setModel() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async setConfigOption() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async authenticate() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async prompt() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    onNotice() {
      return () => {}
    },
    onControls() {
      return () => {}
    },
    onTerminal() {
      return () => {}
    },
    onPermission() {
      return () => {}
    },
    onPermissionResolved() {
      return () => {}
    },
    async respondPermission() {
      return { ok: false }
    },
  },
  claude: {
    async armHooks() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async rebind() {
      return { ok: true }
    },
    onEvent() {
      return () => {}
    },
  },
  git: {
    async status() {
      return { ok: false, notRepo: true }
    },
    async snapshot() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async changes() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async show() {
      return { ok: false }
    },
    async restore() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async stageStatus() {
      return { ok: false, notRepo: true }
    },
    async stage() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async unstage() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async commit() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async log() {
      return { ok: true, commits: [] }
    },
  },
  latex: {
    async build() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async syncFromPdf() {
      return { ok: false, message: DESKTOP_ONLY }
    },
  },
  settings: {
    async setApiKey() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async hasApiKey() {
      return { ok: true, present: false }
    },
    async clearApiKey() {
      return { ok: true }
    },
    async setOpenaiKey() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async hasOpenaiKey() {
      return { ok: true, present: false }
    },
    async clearOpenaiKey() {
      return { ok: true }
    },
  },
  terminal: {
    async create() {
      return { ok: false }
    },
    async write() {
      return { ok: false }
    },
    async resize() {
      return { ok: false }
    },
    async snapshot() {
      return { output: '' }
    },
    async attach() {
      return { output: '' }
    },
    async detachRenderer() {
      return { ok: true }
    },
    async diagnostics() {
      return []
    },
    async signal() {
      return { ok: false }
    },
    async kill() {
      return { ok: false }
    },
    async run() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    onData() {
      return () => {}
    },
    onExit() {
      return () => {}
    },
    onMeta() {
      return () => {}
    },
  },
  assistantArchive: {
    async append(scope, batchId, turns) {
      const key = webArchiveKey(scope)
      const batches = webAssistantArchiveBatches.get(key) ?? new Set<string>()
      if (batches.has(batchId)) return { ok: true, count: webAssistantArchive.get(key)?.length ?? 0, duplicate: true }
      const next = [...(webAssistantArchive.get(key) ?? []), ...turns]
      webAssistantArchive.set(key, next)
      batches.add(batchId)
      webAssistantArchiveBatches.set(key, batches)
      return { ok: true, count: next.length }
    },
    async info(scope) {
      return { ok: true, total: webAssistantArchive.get(webArchiveKey(scope))?.length ?? 0 }
    },
    async page(scope, before, limit = 60) {
      const turns = webAssistantArchive.get(webArchiveKey(scope)) ?? []
      const end = Math.min(turns.length, before ?? turns.length)
      const start = Math.max(0, end - limit)
      return { ok: true, turns: turns.slice(start, end), before: start, total: turns.length, hasMore: start > 0 }
    },
    async clear(scope) {
      const key = webArchiveKey(scope)
      webAssistantArchive.delete(key)
      webAssistantArchiveBatches.delete(key)
      return { ok: true }
    },
  },
  auth: {
    start() {
      return ''
    },
    async cancel() {
      return { ok: true }
    },
  },
  fs: {
    async list() {
      return { ok: false }
    },
    async search() {
      return { ok: false, entries: [] }
    },
    async index() {
      return { ok: false, files: [] }
    },
    async read() {
      return { ok: false }
    },
    async readImage() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async write() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async create() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async rename() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async trash() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async reveal() {
      return { ok: true }
    },
    async pdfInfo() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    async pdfPage() {
      return { ok: false, message: DESKTOP_ONLY }
    },
    watch() {
      return () => {}
    },
  },
  grobid: {
    async process() {
      return { ok: false, message: DESKTOP_ONLY }
    },
  },
  worktree: {
    async create() { return { ok: false, message: DESKTOP_ONLY } },
    async finalize() { return { ok: false, message: DESKTOP_ONLY } },
    async diff() { return { ok: false, message: DESKTOP_ONLY } },
    async merge() { return { ok: false, message: DESKTOP_ONLY } },
    async remove() { return { ok: true } },
    async list() { return { ok: false } },
  },
  codex: {
    async exec() {
      return { ok: false, message: DESKTOP_ONLY }
    },
  },
  sandbox: {
    async available() {
      return { docker: false }
    },
    async run() {
      return { ok: false, message: DESKTOP_ONLY }
    },
  },
  db: {
    getSync(key) {
      return typeof localStorage !== 'undefined' ? localStorage.getItem(key) : null
    },
    setSync(key, value) {
      if (typeof localStorage !== 'undefined') localStorage.setItem(key, value)
      return true
    },
    async set(key, value) {
      if (typeof localStorage !== 'undefined') localStorage.setItem(key, value)
      return { ok: true }
    },
    async del(key) {
      if (typeof localStorage !== 'undefined') localStorage.removeItem(key)
      return { ok: true }
    },
    async kind() {
      return { kind: 'json' as const }
    },
  },
  async openExternal(url) {
    window.open(url, '_blank', 'noopener')
    return { ok: true }
  },
  async pickFolder() {
    return { ok: false }
  },
  async pickFiles() {
    return { ok: false }
  },
  async glass() {
    return { supported: false, active: false, enabled: false }
  },
  async windowMode() {
    return { wantSolid: false, liveSolid: false }
  },
  async relaunch() {},
  async reapplyWindow() {
    return { ok: false }
  },
  glassWash: {
    async sample() {
      return { ok: false }
    },
    onRefresh() {
      return () => {}
    },
  },
  windows: {
    async newWindow() {
      return { ok: false }
    },
    async pop() {
      return { ok: false }
    },
    onPopClosed() {
      return () => {}
    },
    onNewTab() {
      return () => {}
    },
    onCloseTab() {
      return () => {}
    },
    onReopenTab() {
      return () => {}
    },
    onActivateTab() {
      return () => {}
    },
    tabsChanged() {
      /* no native menu on web */
    },
    setTitle() {
      /* the browser owns its own tab/title */
    },
    async detachProject() {
      return { ok: false }
    },
    onAdoptProject() {
      return () => {}
    },
  },
  winCtl() {
    /* the browser owns its own window chrome */
  },
}

declare global {
  interface Window {
    kaisola?: KaisolaBridge
  }
}

// ── ACP project scoping ─────────────────────────────────────────────────────
// One agent in two project tabs must be two independent sessions (a Claude
// subscription bound to project A must never answer project B). The store
// keeps `acpScope.current` = the active project id; every acp call composes
// `<presetId>@@<scope>` as the wire key, and incoming events are split back so
// call sites keep using bare preset ids. Unscoped keys (smoke tests, legacy)
// pass through untouched.
export const acpScope = { current: '' }
const SCOPE_SEP = '@@'
const scopedKey = (key: string) => (acpScope.current ? `${key}${SCOPE_SEP}${acpScope.current}` : key)
const scopedKeyFor = (key: string, scope?: string) => (scope ? `${key}${SCOPE_SEP}${scope}` : scopedKey(key))
const splitScopedKey = (raw: unknown): { key: string; scope: string } => {
  const s = String(raw ?? '')
  const i = s.indexOf(SCOPE_SEP)
  return i < 0 ? { key: s, scope: '' } : { key: s.slice(0, i), scope: s.slice(i + SCOPE_SEP.length) }
}
/** Events for the visible project (or unscoped) — background scopes are dropped
 * by transient consumers; permissions are ROUTED instead (App reads .scope). */
const scopeIsCurrent = (scope: string) => !scope || scope === acpScope.current

function scopeAcp(acp: KaisolaBridge['acp']): KaisolaBridge['acp'] {
  return {
    ...acp,
    status: async (clientKeys, explicitScope) => {
      const scopeForCall = explicitScope ?? (acpScope.current || undefined)
      const res = await acp.status(clientKeys, scopeForCall)
      const agents = (res.agents ?? [])
        .map((a) => { const { key, scope } = splitScopedKey(a.key); return { ...a, key, scope } })
        .filter((a) => !a.scope || a.scope === (scopeForCall ?? ''))
      return { ...res, agents }
    },
    connect: (config) => acp.connect({ ...config, scope: config.scope ?? (acpScope.current || undefined) }),
    disconnect: (k) => acp.disconnect(scopedKey(k)),
    cancel: (k) => acp.cancel(scopedKey(k)),
    lease: (k, leaseId, active, idleMs, scope) => acp.lease(scopedKeyFor(k, scope), leaseId, active, idleMs),
    setMode: (k, m) => acp.setMode(scopedKey(k), m),
    setModel: (k, m) => acp.setModel(scopedKey(k), m),
    setConfigOption: (k, c, v) => acp.setConfigOption(scopedKey(k), c, v),
    authenticate: (k, m) => acp.authenticate(scopedKey(k), m),
    prompt: (k, text, onUpdate, images, scope) => acp.prompt(scopedKeyFor(k, scope), text, onUpdate, images),
    onNotice: (cb) =>
      acp.onNotice((n) => {
        const { key, scope } = splitScopedKey(n.key)
        if (scopeIsCurrent(scope)) cb({ ...n, key, scope })
      }),
    onControls: (cb) =>
      acp.onControls((info) => {
        const { key, scope } = splitScopedKey(info.key)
        if (scopeIsCurrent(scope)) cb({ ...info, key })
      }),
    onTerminal: (cb) =>
      acp.onTerminal((info) => {
        const { key, scope } = splitScopedKey(info.agentKey)
        cb({ ...info, agentKey: info.agentKey ? key : info.agentKey, scope })
      }),
    onPermission: (cb) =>
      acp.onPermission((req) => {
        // never dropped — the card is parked in the OWNING project's slice
        const { key, scope } = splitScopedKey(req.key)
        cb({ ...req, key, scope })
      }),
  }
}

export const bridge: KaisolaBridge =
  typeof window !== 'undefined' && window.kaisola
    ? { ...window.kaisola, acp: scopeAcp(window.kaisola.acp) }
    : webMock

export const isDesktop = bridge.env === 'electron'
