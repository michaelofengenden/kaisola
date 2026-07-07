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
}
export interface AcpTerminalInfo {
  terminalId: string
  command?: string
  label?: string
  cwd?: string
  agentKey?: string
  agentName?: string
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
export interface AcpConnectConfig {
  presetId?: string
  /** Custom (user-added) agents: the exact ACP server command to spawn. */
  command?: string
  args?: string[]
  name?: string
  cwd?: string
  autonomy?: string
}

export interface UpdateState {
  /** idle = up to date (or never checked); ready = downloaded, restart to apply. */
  type: 'idle' | 'checking' | 'downloading' | 'ready' | 'error'
  /** The version being downloaded / ready to install. */
  version?: string | null
  percent?: number
  message?: string | null
  /** The running build's version. */
  appVersion?: string
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
    status(): Promise<{ ok: boolean; agents: AcpAgent[] }>
    connect(config: AcpConnectConfig): Promise<{ ok: boolean; key?: string; agent?: AcpMeta; controls?: AcpControls; authMethods?: AcpAuthMethod[]; message?: string }>
    disconnect(agentKey: string): Promise<{ ok: boolean }>
    cancel(agentKey: string): Promise<{ ok: boolean }>
    /** Live autonomy dial — update every connection this window owns in main. */
    setAutonomy(autonomy: AutonomyLevel): Promise<{ ok: boolean }>
    setMode(agentKey: string, modeId: string): Promise<{ ok: boolean; message?: string }>
    setModel(agentKey: string, modelId: string): Promise<{ ok: boolean; message?: string }>
    setConfigOption(agentKey: string, configId: string, value: string): Promise<{ ok: boolean; message?: string }>
    authenticate(agentKey: string, methodId: string): Promise<{ ok: boolean; pending?: boolean; message?: string }>
    prompt(agentKey: string, text: string, onUpdate: (u: AcpUpdate) => void): Promise<{ ok: boolean; stopReason?: string; message?: string }>
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
    rebind(): Promise<{ ok: boolean }>
    onEvent(cb: (ev: ClaudeHookEvent) => void): () => void
    /** Does ~/.claude/projects/<cwd>/<sessionId>.jsonl still exist? Gates
     * --resume; `any` (any transcript for the cwd) gates the --continue fallback. */
    sessionExists?(cwd: string, sessionId: string): Promise<{ ok: boolean; exists: boolean; any?: boolean }>
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
    signal(id: string, signal?: string): Promise<{ ok: boolean }>
    kill(id: string): Promise<{ ok: boolean }>
    run(command: string, cwd?: string): Promise<CmdResult>
    onData(id: string, cb: (data: string) => void): () => void
    onExit(id: string, cb: (code: number) => void): () => void
    onMeta(cb: (meta: TerminalMetaEvent) => void): () => void
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
  glass(patch?: { enabled: boolean }): Promise<{ supported: boolean; active: boolean; enabled: boolean }>
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
    install(): Promise<{ ok: boolean }>
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

export const bridge: KaisolaBridge =
  typeof window !== 'undefined' && window.kaisola ? window.kaisola : webMock

export const isDesktop = bridge.env === 'electron'
