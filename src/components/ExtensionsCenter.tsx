import { useEffect, useMemo, useRef, useState, type CSSProperties } from 'react'
import { bridge, isDesktop } from '../lib/bridge'
import {
  extensionCatalog,
  hydrateExtensions,
  isExtensionInstalled,
  onExtensionsOpen,
  parseExtensionManifest,
  registerDevelopmentExtension,
  removeDevelopmentExtension,
  setExtensionInstalled,
  useExtensions,
  type ExtensionCategory,
  type ExtensionManifest,
} from '../lib/extensions'
import { useKaisola } from '../store/store'
import { Icon } from './Icon'

type StatusFilter = 'all' | 'installed' | 'not-installed'
type CategoryFilter = 'All' | ExtensionCategory

const STATUS: Array<{ id: StatusFilter; label: string }> = [
  { id: 'all', label: 'All' },
  { id: 'installed', label: 'Installed' },
  { id: 'not-installed', label: 'Not Installed' },
]

const EXTENSIONS_DIALOG_STYLE = {
  width: '100vw',
  maxWidth: 'none',
  height: '100vh',
  maxHeight: 'none',
  margin: 0,
  border: 'none',
  padding: 0,
} satisfies CSSProperties
const REVIEW_DIALOG_STYLE = { ...EXTENSIONS_DIALOG_STYLE, padding: 24 } satisfies CSSProperties

const DOWNLOAD_FORMATTER = new Intl.NumberFormat('en-US')

function formatDownloads(value = 0) {
  return DOWNLOAD_FORMATTER.format(value)
}

// MCP server names are not extension identities. A same-named user server may
// have a different command or may be deliberately user-owned; only the
// extension installation record decides this card's state.
const installed = (extension: ExtensionManifest) => isExtensionInstalled(extension.id)

function contributionSummary(extension: ExtensionManifest) {
  const contributions = extension.contributions
  const parts: string[] = []
  if (contributions?.languages?.length) parts.push(`${contributions.languages.length} language${contributions.languages.length === 1 ? '' : 's'}`)
  if (contributions?.previews?.length) parts.push(`${contributions.previews.length} preview${contributions.previews.length === 1 ? '' : 's'}`)
  if (contributions?.mcpServers?.length) parts.push(`${contributions.mcpServers.length} MCP server${contributions.mcpServers.length === 1 ? '' : 's'}`)
  return parts.join(' · ')
}

function InstallReview({
  extension,
  busy,
  onCancel,
  onInstall,
}: {
  extension: ExtensionManifest
  busy: boolean
  onCancel: () => void
  onInstall: () => void
}) {
  const mcp = extension.contributions?.mcpServers ?? []
  const development = !!extension.sourcePath
  const dialogRef = useRef<HTMLDialogElement>(null)
  const onCancelRef = useRef(onCancel)
  useEffect(() => { onCancelRef.current = onCancel }, [onCancel])
  useEffect(() => {
    const dialog = dialogRef.current
    if (!dialog) return
    const onBackdropMouseDown = (event: MouseEvent) => {
      if (event.target === dialog) onCancelRef.current()
    }
    dialog.addEventListener('mousedown', onBackdropMouseDown)
    if (!dialog.open) dialog.showModal()
    return () => {
      dialog.removeEventListener('mousedown', onBackdropMouseDown)
      if (dialog.open) dialog.close()
    }
  }, [])
  return (
    <dialog
      ref={dialogRef}
      className="ext-review-scrim"
      style={REVIEW_DIALOG_STYLE}
      aria-labelledby="extension-install-title"
      onCancel={(event) => { event.preventDefault(); onCancel() }}
    >
      <section className="ext-review">
        <header>
          <div className="ext-mark" data-kind="development"><Icon name="Blocks" size={19} /></div>
          <div className="grow">
            <strong id="extension-install-title">Install “{extension.name}”?</strong>
            <p>{extension.id} · v{extension.version}</p>
          </div>
          <button type="button" className="btn-icon btn-sm" onClick={onCancel} aria-label="Close"><Icon name="X" size={14} /></button>
        </header>
        <div className="ext-review-body">
          <p className="ext-trust-note">
            <Icon name="ShieldCheck" size={14} />
            {development
              ? 'Kaisola only loads the declarative contributions below. This extension cannot execute renderer JavaScript.'
              : 'Review the exact server definition below. Installing makes it available to new agent sessions; registry identity is not a safety guarantee.'}
          </p>
          {extension.sourcePath && <div className="ext-review-source"><span>Folder</span><code>{extension.sourcePath}</code></div>}
          <div className="ext-review-source"><span>Adds</span><code>{contributionSummary(extension)}</code></div>
          {mcp.map((server) => (
            <div className="ext-review-command" key={server.name}>
              <span className="caps">MCP · {server.name}</span>
              <code>{server.config.url ?? [server.config.command, ...(server.config.args ?? [])].join(' ')}</code>
              {server.config.env && <small>Environment values remain placeholders until you configure them.</small>}
            </div>
          ))}
        </div>
        <footer>
          <button type="button" className="btn btn-sm" onClick={onCancel}>Cancel</button>
          <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={onInstall}>
            <Icon name={busy ? 'LoaderCircle' : 'PackagePlus'} size={13} className={busy ? 'spin' : undefined} />
            {busy ? 'Installing…' : 'Install extension'}
          </button>
        </footer>
      </section>
    </dialog>
  )
}

function ExtensionCard({
  extension,
  installed,
  busy,
  onToggle,
}: {
  extension: ExtensionManifest
  installed: boolean
  busy: boolean
  onToggle: (extension: ExtensionManifest, install: boolean) => void
}) {
  const isMcp = extension.categories.includes('MCP Servers')
  const isPreview = extension.categories.includes('Previews')
  return (
    <article className="ext-card" data-installed={installed || undefined}>
      <div className="ext-card-main">
        <div className="ext-mark" data-kind={isMcp ? 'mcp' : isPreview ? 'preview' : extension.sourcePath ? 'development' : 'language'}>
          <Icon name={isMcp ? 'ServerCog' : isPreview ? 'PanelTop' : extension.sourcePath ? 'Blocks' : 'Braces'} size={20} />
        </div>
        <div className="ext-card-copy">
          <div className="ext-title-row">
            <h2>{extension.name}</h2>
            <span className="ext-version">v{extension.version}</span>
            {extension.sourcePath && <span className="ext-dev-badge">Development</span>}
            {extension.categories.map((category) => <span className="ext-tag" key={category}>{category}</span>)}
          </div>
          <p className="ext-description">{extension.description}</p>
          <div className="ext-meta">
            <span><Icon name="UserRound" size={13} /> {extension.author}</span>
            {extension.sourcePath && <span className="truncate" title={extension.sourcePath}><Icon name="Folder" size={13} /> {extension.sourcePath}</span>}
          </div>
        </div>
      </div>
      <aside className="ext-card-side">
        <button type="button"
          className={installed ? 'btn btn-sm ext-uninstall' : 'btn btn-primary btn-sm ext-install'}
          disabled={busy}
          onClick={() => onToggle(extension, !installed)}
        >
          <Icon name={busy ? 'LoaderCircle' : installed ? 'Trash2' : 'Download'} size={14} className={busy ? 'spin' : undefined} />
          {busy ? (installed ? 'Removing…' : 'Installing…') : installed ? 'Uninstall' : 'Install'}
        </button>
        <span className="ext-downloads">
          {extension.downloads != null
            ? `Downloads: ${formatDownloads(extension.downloads)}`
            : extension.sourcePath
              ? 'Local development extension'
              : isMcp
                ? 'Curated source · review required'
                : 'Bundled with Kaisola'}
        </span>
        <div className="ext-links">
          {extension.repository ? (
            <button type="button" onClick={() => void bridge.openExternal(extension.repository!)} title="Open source repository" aria-label="Open source repository">
              <Icon name="Github" size={17} />
            </button>
          ) : <span />}
          <button type="button" title={contributionSummary(extension) || extension.id} aria-label="Extension details"><Icon name="Ellipsis" size={17} /></button>
        </div>
      </aside>
    </article>
  )
}

/**
 * A Zed-shaped extension center backed by Kaisola's declarative contribution
 * model. It is a full-screen work surface (not a cramped Settings subsection),
 * searchable by name/category/author, with install state shared by every
 * editor and preview through the extension registry.
 */
export function ExtensionsCenter() {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState<StatusFilter>('all')
  const [category, setCategory] = useState<CategoryFilter>('All')
  const [busy, setBusy] = useState<string | null>(null)
  const [pendingInstall, setPendingInstall] = useState<ExtensionManifest | null>(null)
  const [manifestWarnings, setManifestWarnings] = useState<string[]>([])
  const dialogRef = useRef<HTMLDialogElement>(null)
  const searchRef = useRef<HTMLInputElement>(null)
  const extensionState = useExtensions()
  const workspace = useKaisola((state) => state.workspacePath)
  const pushToast = useKaisola((state) => state.pushToast)

  useEffect(() => onExtensionsOpen(() => setOpen(true), () => setOpen(false)), [])
  useEffect(() => {
    const refresh = () => { void hydrateExtensions().then(setManifestWarnings) }
    refresh()
    let timer: number | undefined
    const onChanged = () => {
      window.clearTimeout(timer)
      timer = window.setTimeout(refresh, 80)
    }
    const off = bridge.extensions?.onChanged?.(onChanged)
    return () => { off?.(); window.clearTimeout(timer) }
  }, [])
  useEffect(() => {
    if (!open) return
    const dialog = dialogRef.current
    if (!dialog) return
    if (!dialog.open) dialog.showModal()
    const timer = window.setTimeout(() => searchRef.current?.focus(), 40)
    return () => {
      window.clearTimeout(timer)
      if (dialog.open) dialog.close()
    }
  }, [open])

  const catalog = useMemo(() => extensionCatalog(), [extensionState.revision])
  const categories = useMemo<CategoryFilter[]>(() => [
    'All',
    ...new Set(catalog.flatMap((extension) => extension.categories)),
  ], [catalog])
  useEffect(() => {
    if (!categories.includes(category)) setCategory('All')
  }, [categories, category])
  const visible = useMemo(() => {
    const needle = query.trim().toLowerCase()
    return catalog.filter((extension) => {
      const isInstalled = installed(extension)
      if (status === 'installed' && !isInstalled) return false
      if (status === 'not-installed' && isInstalled) return false
      if (category !== 'All' && !extension.categories.includes(category)) return false
      if (!needle) return true
      return [extension.name, extension.id, extension.author, extension.description, ...extension.categories]
        .join(' ')
        .toLowerCase()
        .includes(needle)
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog, query, status, category, extensionState.revision])

  const toggle = async (extension: ExtensionManifest, install: boolean) => {
    setBusy(extension.id)
    const servers = extension.contributions?.mcpServers ?? []
    const createdServers: string[] = []
    const preservedServers: string[] = []
    const wasInstalled = installed(extension)
    try {
      if (install) {
        if (extension.sourcePath) {
          const registered = await bridge.extensions?.registerDev(extension.sourcePath)
          if (registered && !registered.ok) throw new Error(registered.message ?? 'Could not register the development extension.')
        }
        for (const server of servers) {
          const result = await bridge.mcp?.serverAdd?.(server.name, server.config, extension.id)
          if (!result?.ok) throw new Error(result?.message ?? `Could not add ${server.name}.`)
          if (result.created) createdServers.push(server.name)
        }
        setExtensionInstalled(extension, true)
        pushToast('success', `${extension.name} installed.`)
      } else {
        for (const server of servers) {
          if (bridge.mcp?.serverRemove) {
            const result = await bridge.mcp.serverRemove(server.name, extension.id)
            if (!result.ok) throw new Error(result.message ?? `Could not remove ${server.name}.`)
            if (result.preserved) preservedServers.push(server.name)
          } else {
            const result = await bridge.mcp?.serverSet?.({ workspace, scope: 'user', name: server.name, enabled: false })
            if (result && !result.ok) throw new Error(result.message ?? `Could not disable ${server.name}.`)
          }
        }
        if (extension.sourcePath) removeDevelopmentExtension(extension.id)
        else setExtensionInstalled(extension, false)
        pushToast('info', preservedServers.length
          ? `${extension.name} uninstalled. ${preservedServers.join(', ')} was preserved because it is user-owned or edited.`
          : `${extension.name} uninstalled.`)
      }
    } catch (error) {
      // Roll back only records this attempt actually created, and prove ownership
      // again in main before deleting. Exact pre-existing matches are untouched.
      for (const name of createdServers) await bridge.mcp?.serverRemove?.(name, extension.id).catch(() => {})
      if (extension.sourcePath && !wasInstalled) removeDevelopmentExtension(extension.id)
      pushToast('error', String((error as Error)?.message ?? error))
    } finally {
      setBusy(null)
    }
  }

  const chooseDev = async () => {
    if (!isDesktop) {
      pushToast('info', 'Development extensions can be installed in the desktop app.')
      return
    }
    const picked = await bridge.pickFolder()
    if (!picked.ok || !picked.path) return
    if (bridge.extensions?.inspectDev) {
      const inspected = await bridge.extensions.inspectDev(picked.path)
      if (!inspected.ok) { pushToast('error', inspected.message ?? 'Could not inspect that extension.'); return }
      const manifest = inspected.manifest as ExtensionManifest | undefined
      if (!manifest?.id || !manifest.contributions) { pushToast('error', 'Main returned an invalid extension manifest.'); return }
      setPendingInstall(manifest)
      return
    }
    const manifestPath = `${picked.path.replace(/[\\/]$/, '')}/kaisola-extension.json`
    const read = await bridge.fs.read(manifestPath)
    if (!read.ok || typeof read.content !== 'string') { pushToast('error', 'That folder does not contain a readable kaisola-extension.json.'); return }
    try {
      const parsed = parseExtensionManifest(JSON.parse(read.content), picked.path)
      if (!parsed.ok) { pushToast('error', parsed.message); return }
      setPendingInstall(parsed.manifest)
    } catch {
      pushToast('error', 'kaisola-extension.json is not valid JSON.')
    }
  }

  const confirmInstall = async () => {
    if (!pendingInstall) return
    const extension = pendingInstall
    if (extension.sourcePath) registerDevelopmentExtension(extension, false)
    await toggle(extension, true)
    setPendingInstall(null)
  }

  if (!open) return null
  return (
    <dialog
      ref={dialogRef}
      className="extensions-surface"
      style={EXTENSIONS_DIALOG_STYLE}
      aria-label="Extensions"
      onCancel={(event) => {
        event.preventDefault()
        if (pendingInstall) setPendingInstall(null)
        else setOpen(false)
      }}
    >
      <header className="extensions-head">
        <div>
          <h1>Extensions</h1>
          <p>Languages, previews, and tools—installed locally and reviewable.</p>
        </div>
        <div className="extensions-head-actions">
          <button type="button" className="btn btn-sm" onClick={() => void chooseDev()}><Icon name="PackagePlus" size={14} /> Install Dev Extension</button>
          <button type="button" className="btn-icon" onClick={() => setOpen(false)} aria-label="Close extensions"><Icon name="X" size={17} /></button>
        </div>
      </header>
      <div className="extensions-filters">
        <label className="extensions-search">
          <Icon name="Search" size={18} />
          <input ref={searchRef} value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search extensions…" />
          {query && <button type="button" onClick={() => setQuery('')} aria-label="Clear search"><Icon name="X" size={14} /></button>}
        </label>
        <div className="extensions-status" role="tablist">
          {STATUS.map((item) => (
            <button type="button" key={item.id} data-active={status === item.id} onClick={() => setStatus(item.id)}>{item.label}</button>
          ))}
        </div>
      </div>
      <nav className="extensions-categories" aria-label="Extension categories">
        {categories.map((item) => <button type="button" key={item} data-active={category === item} onClick={() => setCategory(item)}>{item}</button>)}
      </nav>
      <main className="extensions-list">
        {manifestWarnings.map((warning) => (
          <div className="extensions-warning" key={warning}><Icon name="TriangleAlert" size={14} /> {warning}</div>
        ))}
        {visible.map((extension) => (
          <ExtensionCard
            key={extension.id}
            extension={extension}
            installed={installed(extension)}
            busy={busy === extension.id}
            onToggle={(item, install) => {
              if (install && item.contributions?.mcpServers?.length) setPendingInstall(item)
              else void toggle(item, install)
            }}
          />
        ))}
        {!visible.length && (
          <div className="extensions-empty">
            <Icon name="PackageSearch" size={30} />
            <strong>No extensions match</strong>
            <span>Try another search or clear the category filters.</span>
          </div>
        )}
      </main>
      <footer className="extensions-foot">
        <span><Icon name="ShieldCheck" size={13} /> Declarative extensions only; no unreviewed renderer code.</span>
        <span>{visible.length} of {catalog.length} extensions</span>
      </footer>
      {pendingInstall && <InstallReview extension={pendingInstall} busy={busy === pendingInstall.id} onCancel={() => setPendingInstall(null)} onInstall={() => void confirmInstall()} />}
    </dialog>
  )
}
