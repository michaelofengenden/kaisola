# Extensions, previews, languages, and MCP: architecture research

Date: 2026-07-09
Scope: read-only architecture pass; no production code changed. Upstream source
snapshots are pinned below so the conclusions remain auditable.

## Executive decision

Build **one Extensions browser, but three separate trust/runtime lanes**:

1. **Declarative editor extensions** — languages, grammars, themes, icon themes,
   snippets, and preview registrations. These are data by default and can hot
   reload. They must not get Node/Electron access.
2. **Language/preview workers** — explicitly permissioned subprocesses or WASM
   modules for LSPs and document conversion. They run outside the renderer with
   a narrow JSON-RPC surface.
3. **MCP installations** — discovered through an MCP-registry adapter and stored
   in the existing user/project catalog. They have their own install, auth,
   trust, health, and agent-session lifecycle. Do not disguise an `npx` MCP
   server as a harmless theme extension.

This gives the requested Zed/VS Code-style screen without prematurely promising
VS Code extension compatibility. A full VS Code API/extension host is a product
of its own: VS Code runs extensions in a separate extension-host process, and
Theia's compatibility layer spans an Open VSX client, deployer, plugin host, RPC
bridge, workspace-trust service, and many packages. Kaisola should first support
a small, documented native surface and a **declarative-only VSIX import lane**.

## What Kaisola has now

### Languages and previews

- `src/components/CodeEditor.tsx:30-76` statically imports seven CodeMirror
  language packages and switches on file extension. There is no language
  registry, lazy package loader, LSP client, diagnostics store, completion
  provider, or extension contribution point.
- `electron/ipc/fsHandler.cjs:60-75` has a fixed map for PDF and image formats.
  `fs:read` dispatches through it at `:553-598`.
- `src/views/FilesView.tsx` supplies Markdown, sanitized HTML, editable SVG,
  images, and a strong PDF raster/native fallback. There is no provider
  registry or conflict/priority model for third-party previews.
- Any future interactive preview must not render in the main React document.
  The primary `BrowserWindow` has `contextIsolation: true` and
  `nodeIntegration: false`, but `sandbox: false` and `webviewTag: true`
  (`electron/main.cjs:302-324`). Use a separate sandboxed guest for extension UI.

### MCP

The backend is meaningfully ahead of the UI:

- User scope (`mcp-servers.json`) and project scope (`.mcp.json`) already merge.
- Project entries are disabled until a hash of the exact normalized spec is
  approved (`electron/ipc/mcpCatalog.cjs:1-13,90-125,146-180`). A changed command,
  URL, env, or header re-prompts. Keep this.
- ACP entries use the agent's HTTP/SSE capabilities; Claude's terminal config
  receives user entries (`:185-220`).
- Cursor, Claude Desktop, and Claude CLI configs can be imported, disabled by
  default (`:307-378`).
- Deep links are parsed in main and require a renderer confirmation that shows
  the exact command/URL and masks env values
  (`:397-429`, `src/components/shell/McpInstallModal.tsx:6-75`).
- The current UI is a 252px status popover with add-via-JSON, on/off, approve,
  import, and a remote probe (`AgentStatusButton.tsx:100-202,319-376`). It is not
  a searchable catalog and has no versions, publisher identity, license,
  repository, install variants, OAuth state, remove, edit, or update action.

### App updater

Keep app updates separate from extension updates. The current
`electron/ipc/updateHandler.cjs` is already moving toward the right explicit
state machine: it distinguishes feed check, download, preparation/staging,
ready, a check for a newer pending release, install, and watchdog recovery.
The Extensions service should report its own updates and only share presentation
(an Updates section and a restart-required badge), never updater state.

## Existing issues to fix before calling the MCP catalog production-ready

1. **The remote health probe is not a protocol-correct MCP client.**
   `mcpCatalog.cjs:225-263` accepts only `application/json`, sends `initialize`
   and then `tools/list`, does not send `notifications/initialized`, does not
   preserve `Mcp-Session-Id`, does not parse SSE event streams, and treats legacy
   SSE like Streamable HTTP. Valid stateful Streamable HTTP and SSE servers can
   therefore show as unreachable. Replace this with the official MCP SDK client
   and transports; do not grow the hand-rolled POST helper.
2. **Secrets can land in plaintext.** Imported configs and deep-link configs are
   copied verbatim. Avoiding `${VAR}` expansion prevents one leak, but a literal
   token in `env` or `headers` still gets written to `mcp-servers.json`. Store
   secret values in the OS keychain and persist only `secretRef`/input markers.
3. **Install/update identity is too weak.** `addUserServer` overwrites a same-name
   entry, keeps any old `disabled` bit, and has no origin, version, digest, or
   publisher metadata (`:419-429`). A successful modal can consequently claim a
   server is usable while an earlier disabled bit keeps it off. Same-name
   project entries are silently hidden when user scope wins (`:146-152`).
4. **No CRUD/lifecycle.** There is add/toggle but no remove, edit, pin, update,
   rollback, OAuth login/logout, or reload of already-running agent sessions.
5. **Health is optimistic for stdio.** A configured stdio server is painted
   green as "with session" without spawning or handshaking it. Status should be
   `configured`, `starting`, `ready`, `auth-needed`, `failed`, or `stopped`, and
   should be tied to a particular agent session or shared broker.
6. **Configuration bounds and canonicalization need hardening.** The 24-entry
   cap is arbitrary; install URLs have no decoded-size cap; spec hashes should
   sort map keys; workspace approvals should use a canonical/real path; command,
   URL scheme, header names, env names, and redirect behavior need validation.
7. **The registry is metadata, not a safety verdict.** The official MCP Registry
   authenticates namespaces but explicitly delegates code scanning to package
   registries/downstream aggregators. “Verified publisher” must never render as
   “safe to execute.”
8. **Do not seed archived reference servers as recommendations.** The
   `modelcontextprotocol/servers-archived` repository explicitly lists Brave
   Search and PostgreSQL, states that they are unmaintained, and provides no
   security guarantees. Catalog cards must come from a current registry/curated
   source with a checked maintenance state, not from an old screenshot or old
   package-name list. See
   [the archived-server warning](https://github.com/modelcontextprotocol/servers-archived).

## Upstream findings and what to adopt

### Zed

Pinned source: `zed-industries/zed@2c4e44704c37ee87e59ac84e3e17388178b28545`;
registry: `zed-industries/extensions@18118061e414e9a7965f45f3830f23a411d4ea2a`.

- Zed's versioned manifest separates `themes`, `icon_themes`, `languages`,
  `grammars`, `language_servers`, `context_servers`, snippets, debug adapters,
  and capabilities. Its `provides()` derives filter badges from contributions.
  See [extension_manifest.rs](https://github.com/zed-industries/zed/blob/2c4e44704c37ee87e59ac84e3e17388178b28545/crates/extension/src/extension_manifest.rs#L82-L151).
- Executable/download/npm capabilities are the intersection of what the
  manifest declares and what the host grants. A request must pass both checks.
  See [capability_granter.rs](https://github.com/zed-industries/zed/blob/2c4e44704c37ee87e59ac84e3e17388178b28545/crates/extension_host/src/capability_granter.rs#L7-L83).
- Extension code runs as WASM in an extension host, not in the editor renderer.
  This is the right long-term model; do not copy Zed's GPL code without a
  deliberate licensing decision.
- Zed's own MCP-extension guide says MCP server extensions are planned for
  deprecation in favor of the official MCP Registry. See
  [mcp-extensions.md](https://github.com/zed-industries/zed/blob/2c4e44704c37ee87e59ac84e3e17388178b28545/docs/src/extensions/mcp-extensions.md).
- Zed has dedicated Markdown, SVG, and CSV preview crates. The important design
  pattern is a provider per format, not a single general webview.

Adopt: manifest contribution categories, `provides` badges, dev-extension
install, WASM aspiration, explicit capability intersection, format-specific
preview providers. Do not adopt: MCP-as-extension as the primary marketplace.

### VS Code and Open VSX

Pinned source: `microsoft/vscode@a1b976d1f2a8c812eaf5e008a0c622c376aafc96`;
docs: `microsoft/vscode-docs@9475c2f33bc20e65242ed4f3e020813e7b61554d`.

- VS Code's manifest has engines compatibility, activation events, contribution
  points, dependencies/packs, runtime placement, and limited-workspace
  capabilities. See the
  [manifest reference](https://github.com/microsoft/vscode-docs/blob/9475c2f33bc20e65242ed4f3e020813e7b61554d/api/references/extension-manifest.md).
- Enablement is distinct from installation and can be global or workspace
  scoped; dependency/pack enablement and trust restrictions are reconciled by
  the service. See
  [extensionEnablementService.ts](https://github.com/microsoft/vscode/blob/a1b976d1f2a8c812eaf5e008a0c622c376aafc96/src/vs/workbench/services/extensionManagement/browser/extensionEnablementService.ts#L308-L430).
- Install/update/uninstall respect dependencies and local/remote/workspace
  placement. See
  [extensionManagementService.ts](https://github.com/microsoft/vscode/blob/a1b976d1f2a8c812eaf5e008a0c622c376aafc96/src/vs/workbench/services/extensionManagement/common/extensionManagementService.ts#L202-L279)
  and [its install path](https://github.com/microsoft/vscode/blob/a1b976d1f2a8c812eaf5e008a0c622c376aafc96/src/vs/workbench/services/extensionManagement/common/extensionManagementService.ts#L312-L545).
- Webviews default to isolated local-resource access, script-off, restricted
  `localResourceRoots`, and should use CSP. Persist serialized state instead of
  retaining hidden webviews. See
  [webview security guidance](https://github.com/microsoft/vscode-docs/blob/9475c2f33bc20e65242ed4f3e020813e7b61554d/api/extension-guides/webview.md#L431-L528)
  and [minimum capabilities/CSP](https://github.com/microsoft/vscode-docs/blob/9475c2f33bc20e65242ed4f3e020813e7b61554d/api/extension-guides/webview.md#L939-L973).
- VS Code manages MCP servers in the Extensions view but keeps MCP configuration,
  auth, server start/stop/restart, resources, tools, and trust as MCP concepts.
  Its current guide supports install links, workspace/global config,
  autodiscovery, extension-provided definitions, and CLI installs. See
  [MCP developer guide](https://github.com/microsoft/vscode-docs/blob/9475c2f33bc20e65242ed4f3e020813e7b61554d/api/extension-guides/ai/mcp.md#L238-L311).

Open VSX is the viable open registry for VSIX packages; Microsoft's Marketplace
must not be assumed to be a generally redistributable backend. Even with Open
VSX, Kaisola can initially consume only declarative contributions. Mark all
extensions that require `main`/`browser` activation as **incompatible**, rather
than installing them and failing mysteriously.

### Eclipse Theia and Open VSX server

Pinned source: `eclipse-theia/theia@3351cf1363eb15fad7088cfc9e6857377baf0acc`;
Open VSX: `eclipse-openvsx/openvsx@94fbbe2e239d4e05442b65647356094783b828cc`.

- Theia's Open VSX model tracks installed versioned/unversioned IDs, deployed,
  disabled, uninstalled, recommended, and search-result sets; search is
  debounced/cancelled and has a verified-only preference. See
  [vsx-extensions-model.ts](https://github.com/eclipse-theia/theia/blob/3351cf1363eb15fad7088cfc9e6857377baf0acc/packages/vsx-registry/src/browser/vsx-extensions-model.ts#L45-L175).
- Its resolver chooses a compatible target-platform version, avoids downgrades,
  downloads to a temp directory, then hands the artifact to a plugin deployer.
  See [vsx-extension-resolver.ts](https://github.com/eclipse-theia/theia/blob/3351cf1363eb15fad7088cfc9e6857377baf0acc/packages/vsx-registry/src/node/vsx-extension-resolver.ts#L41-L99).
- The scale of Theia's `plugin-ext`, `plugin-ext-vscode`, deployer, hosted plugin
  protocol, RPC, and trust packages is evidence that arbitrary VSIX runtime
  compatibility is not an MVP feature.
- Open VSX's current server has publish-time validation/scanning states and can
  reject enforced findings; it also produces package manifests with SHA-256 and
  signatures. See
  [ExtensionScanService.java](https://github.com/eclipse-openvsx/openvsx/blob/94fbbe2e239d4e05442b65647356094783b828cc/server/src/main/java/org/eclipse/openvsx/scanning/ExtensionScanService.java#L33-L38)
  and [ExtensionVersionIntegrityService.java](https://github.com/eclipse-openvsx/openvsx/blob/94fbbe2e239d4e05442b65647356094783b828cc/server/src/main/java/org/eclipse/openvsx/publish/ExtensionVersionIntegrityService.java#L67-L94).

Adopt: explicit installed/deployed/disabled states, cancellable paginated
search, target-platform compatibility, temp staging, version pinning, digest
verification. Do not mistake registry scanning for a local capability sandbox.

### Official MCP Registry

- The official Registry is a standardized metadata/namespace service. It points
  to npm/PyPI/OCI packages or remote endpoints; it does not host artifacts.
- It authenticates reverse-DNS/GitHub namespaces but delegates security scanning
  to package registries and downstream marketplaces.
- Its own architecture guide says host applications should normally consume a
  downstream aggregator conforming to the Registry OpenAPI interface, not bake
  the official endpoint into the host.
- Zed plans to move there. Kaisola should therefore define a `RegistrySource`
  adapter, ship a cached official/OpenAPI-compatible source for the MVP, and
  permit future curated/private sources without a schema rewrite.

Primary reference: [MCP Registry about/security](https://modelcontextprotocol.io/registry/about)
and [API reference](https://registry.modelcontextprotocol.io/docs). Source
snapshot: `modelcontextprotocol/registry@535941a30e92c88b5bc83ef4e951d4183ccf19db`.

### Traycer: what is legitimately reusable

Pinned public source: `traycerai/traycer@59a5bbd6948f7ae1802b81e3557ae58c3d438cb9`,
Apache-2.0.

The public repository exposes desktop/client UI, CLI, protocol contracts, tests,
and update orchestration. Its Host implementation and provider-specific usage
readers are not in scope. The repository explicitly says desktop never bundles
the Host and that CLI owns its install/update lifecycle; see
[resources/host/README.md](https://github.com/traycerai/traycer/blob/59a5bbd6948f7ae1802b81e3557ae58c3d438cb9/clients/desktop/resources/host/README.md).

Safe lessons from the public client/protocol:

- Normalize provider windows at the process boundary as `{usedPercent,
  resetsAt, durationMinutes}` and retain provider-specific detail in a tagged
  union. Codex has primary/secondary/extra windows and credits; Claude has
  5-hour, 7-day, model-scoped, and extra-usage fields. See
  [rate-limit schemas](https://github.com/traycerai/traycer/blob/59a5bbd6948f7ae1802b81e3557ae58c3d438cb9/protocol/src/host/rate-limit/schemas.ts#L56-L170).
- Model unavailable states explicitly (`cli_not_found`, `timeout`,
  `connection_failed`, `insufficient_permissions`, transient fetch failure,
  etc.) rather than collapsing them to zero usage. See
  [the reason schema](https://github.com/traycerai/traycer/blob/59a5bbd6948f7ae1802b81e3557ae58c3d438cb9/protocol/src/host/rate-limit/schemas.ts#L172-L279).
- Preserve last-known-good data across transient failures, dim it, and replace it
  only on authoritative unavailable states. See
  [rate-limit-envelope.ts](https://github.com/traycerai/traycer/blob/59a5bbd6948f7ae1802b81e3557ae58c3d438cb9/clients/gui-app/src/lib/rate-limits/rate-limit-envelope.ts#L21-L109).
- Serialize expensive CLI usage pulls, poll every five minutes, refresh on turn
  completion/manual request, and pause only when the document is hidden—not
  merely unfocused. See
  [rate-limit-queue-provider.tsx](https://github.com/traycerai/traycer/blob/59a5bbd6948f7ae1802b81e3557ae58c3d438cb9/clients/gui-app/src/providers/rate-limit-queue-provider.tsx#L13-L50)
  and [timing](https://github.com/traycerai/traycer/blob/59a5bbd6948f7ae1802b81e3557ae58c3d438cb9/clients/gui-app/src/lib/rate-limits/rate-limit-timing.ts).
- For direct code reuse, preserve Apache-2.0 notices. For ideas/UI behavior,
  implement independently. Do not infer or reverse-engineer the closed Host's
  credential endpoints or proprietary RPC internals.

## Proposed manifest and installation records

Use JSON with JSON Schema for the initial ecosystem. TOML can be accepted later
as a presentation format, but normalize to this structure in main.

```ts
interface ExtensionManifestV1 {
  schemaVersion: 1
  id: string                    // reverse-DNS or publisher.name
  name: string
  version: string
  description: string
  publisher: { id: string; displayName: string; verified?: boolean }
  repository?: string
  license: string
  engines: { kaisola: string }
  platforms?: Array<{ os: string; arch: string }>
  contributes: {
    languages?: LanguageContribution[]
    grammars?: GrammarContribution[]
    themes?: ThemeContribution[]
    iconThemes?: IconThemeContribution[]
    snippets?: SnippetContribution[]
    languageServers?: LanguageServerContribution[]
    previewers?: PreviewContribution[]
  }
  capabilities?: CapabilityRequest[]
}

type CapabilityRequest =
  | { kind: 'process.exec'; command: string; args: string[] }
  | { kind: 'network.fetch'; hosts: string[] }
  | { kind: 'fs.read'; scope: 'extension' | 'workspace' }
  | { kind: 'fs.write'; scope: 'workspace' }
  | { kind: 'webview'; scripts: boolean; remoteHosts: string[] }

interface InstalledExtension {
  id: string
  version: string
  source: { kind: 'kaisola' | 'openvsx' | 'dev'; registry?: string }
  digestSha256: string
  installPath: string
  installedAt: string
  enabledGlobally: boolean
  workspaceOverrides: Record<string, 'enabled' | 'disabled'>
  pinned: boolean
  autoUpdate: boolean
  grants: Array<{ capabilityHash: string; scope: 'global' | 'workspace' }>
  previousVersion?: { version: string; installPath: string; digestSha256: string }
}
```

Contribution minima:

```ts
interface LanguageContribution {
  id: string
  aliases?: string[]
  extensions?: string[]
  filenames?: string[]
  firstLine?: string
  configuration?: string
}

interface LanguageServerContribution {
  id: string
  languages: string[]
  command: PlatformCommand
  rootPatterns?: string[]
  initializationOptions?: unknown
}

interface PreviewContribution {
  id: string
  globs?: string[]
  mimeTypes?: string[]
  priority?: number
  output: 'text' | 'sanitized-html' | 'image' | 'table' | 'sandboxed-webview'
  command?: PlatformCommand       // worker lane only; never renderer exec
}
```

MCP is deliberately separate:

```ts
interface McpCatalogEntry {
  id: string
  name: string
  description: string
  version: string
  publisher: { namespace: string; verified: boolean }
  repository?: string
  license?: string
  source: { registry: string; publishedAt?: string }
  variants: McpInstallVariant[]   // remote, npm, pypi, oci, local command
  security?: { scanned?: boolean; warnings?: string[] }
}

interface McpInstallation {
  id: string
  version: string
  variantId: string
  scope: 'user' | 'workspace'
  workspace?: string
  enabled: boolean
  specHash: string
  configRevision: number
  secretRefs: Record<string, string> // values live in OS keychain
  source: { registry: string; entryId: string }
  status: 'configured' | 'starting' | 'ready' | 'auth-needed' | 'failed' | 'stopped'
  pinned: boolean
}
```

## Main-process services and IPC

Do not put registry traffic or package extraction in React/store code.

```text
ExtensionCatalogService
  search(query, filters, cursor)
  details(id, version?)
  installed()

ExtensionInstaller
  planInstall(source, id, version) -> manifest + requested capabilities
  install(plan, grants)            -> atomic staged install
  uninstall(id)
  setEnabled(id, scope, enabled)
  checkUpdates()
  applyUpdate(id)                  -> hot reload or restartRequired
  rollback(id)

ContributionRegistry
  languages / grammars / themes / icons / previews
  resolveForFile(path, mime)

LanguageServiceHost
  start/stop/restart server
  document open/change/close
  diagnostics/completion/hover/definition/references/rename

PreviewHost
  resolve(path) -> provider
  render(path, provider) -> typed render model or scoped guest URL

McpRegistryService
  search/details via RegistrySource adapters
  planInstall/install/edit/remove/setEnabled
  login/logout/reconnect/probe
  reloadAgentSessions (where the agent protocol supports it)
```

Renderer IPC must validate every argument again in main. Return metadata and
opaque IDs, never raw secret values or unrestricted file URLs.

## Install/update lifecycle

1. Fetch metadata and manifest; enforce response-size/time limits.
2. Resolve exact version and platform. Never install a floating `latest` recipe
   without recording the resolved version.
3. Show a plan: publisher/source, license, exact commands/URLs, requested
   capabilities, secret names, files contributed, restart/hot-reload behavior.
4. Download to a per-install temp directory. Verify expected SHA-256/signature.
5. Defend extraction: reject absolute paths, `..`, symlink escapes, duplicate
   normalized names, excessive file count/uncompressed bytes/compression ratio,
   device files, and postinstall scripts.
6. Parse and schema-validate before activation. The declared and granted
   capability sets are separate; the runtime gets their intersection.
7. Atomically rename staging to `<extensions>/<id>/<version>` and update the
   install record only after success. Keep one known-good previous version.
8. Hot reload data-only contributions. Restart only the affected worker for an
   LSP/preview worker. Require an app restart only for a host/runtime upgrade.
9. On failure, leave the previous version active and expose Retry / View log /
   Roll back. Never strand the UI in “Installing…”.

## Preview security boundary

- Built-in Markdown/HTML/table renderers should produce React/typed models or
  sanitized markup. No scripts, event handlers, forms, `iframe`, `object`, or
  arbitrary CSS from extensions.
- Remote images/resources are off by default. If enabled, rewrite through an
  allowlisted fetcher or disclose that opening a preview contacts the host.
- An interactive preview runs in a dedicated sandboxed guest:
  `sandbox: true`, `contextIsolation: true`, `nodeIntegration: false`, no
  preload with Node, ephemeral session partition, CSP `default-src 'none'`,
  scripts off unless granted, and resource URLs minted for the extension
  directory or selected document only.
- Guest messages use a versioned schema and a tiny command set. No generic
  `invoke(channel, args)` bridge and no direct filesystem access.
- A renderer crash/timeout disables only that provider and falls back to source
  or “Open externally.”

## Prioritized MVP that can start now

### P0 — foundation and honest UI (2-4 days)

1. Add an Extensions page matching the screenshots: search; All / Installed /
   Not Installed; category filters; cards with version, contribution badges,
   publisher, downloads/source, and Install/Uninstall/Enable. Back it with a
   real `ExtensionCatalogService` interface, even if the first source is a
   bundled seed.
2. Register today's seven languages and current previews as **built-in catalog
   entries**. This proves filters/state without introducing remote code.
3. Move MCP management into the same browser shell as a distinct `MCP Servers`
   category. Preserve the compact top-bar health popover as status, not install
   UI.
4. Add MCP edit/remove, collision handling, version/source metadata, decoded
   deeplink size limits, sorted spec hashes, canonical workspaces, and keychain
   secret inputs. Fix the stale-disabled-bit install bug.
5. Replace the hand-rolled MCP health probe with the official SDK transport.
6. Add loading/empty/offline/error/last-known-good states and cancellation to
   all catalog queries.

### P1 — useful breadth without arbitrary code (about 1 week)

1. Add curated, lazy CodeMirror language modules for TOML, Rust, Java, C/C++,
   Go, Bash, SQL, and LaTeX. Treat these as bundled/native extensions first.
2. Add built-in CSV table, structured JSON, and read-only notebook previews.
3. Add an MCP `RegistrySource` using the official OpenAPI shape with hourly
   caching and an explicit “namespace verified, code not audited” notice.
4. Install remote MCP servers directly; for package-based servers, pin exact
   package versions and show the exact command. Do not silently run package
   lifecycle scripts.
5. Separate installed/enabled/running and global/workspace states in the data
   model and UI.

### P2 — language intelligence and installable data packages (1-3 weeks)

1. Build a generic stdio LSP host in main using JSON-RPC/LSP protocol packages;
   map diagnostics, completion, hover, definition, references, rename, symbols,
   and formatting to CodeMirror extensions.
2. Package declarative Kaisola extensions as signed/hashed archives with atomic
   staging, rollback, dev-extension install, and hot reload.
3. Add themes/icon themes/snippets. Add a declarative-only VSIX importer for
   `contributes.languages`, grammars, themes, icon themes, and snippets; reject
   packages requiring `main`, `browser`, unsupported activation, or VS Code APIs.

### Later — executable ecosystem

- WASM component extension host with capability intersection, crash isolation,
  quotas, and a stable versioned API.
- Sandboxed interactive preview guests.
- Private/curated registry sources, organization allowlists, and enterprise
  policy.
- OAuth 2.1/PKCE for remote MCP and a shared MCP broker if Kaisola needs tool-
  level audit/policy independent of each agent client.
- Do **not** advertise arbitrary VS Code extension compatibility until there is a
  real compatible API host and test suite.

## Verification matrix

- Schema: malformed/unknown fields, incompatible engine/platform, contribution
  conflicts, dependency cycles, version ordering, migrations.
- Installer: interrupted download, digest mismatch, zip slip, symlink escape,
  archive bomb, partial rename, disk full, rollback, concurrent install/update,
  uninstall dependency warning.
- Trust: project config edit invalidates grant; user/workspace enablement;
  capability escalation on update re-prompts; secrets never cross renderer or
  logs; publisher verification is not shown as code safety.
- LSP: process crash/restart, root detection, multi-workspace isolation,
  document version ordering, cancellation, huge diagnostics, server log redaction.
- Preview: malicious HTML/SVG, remote tracking assets, guest navigation/popups,
  oversized file, provider timeout/crash, fallback path, cache invalidation.
- MCP: stdio + Streamable HTTP + stateful session header + legacy SSE, JSON and
  SSE response bodies, OAuth-needed, tool-list change, session reload, agent
  without HTTP/SSE capability, offline registry, stale cache.
- Updates: app update and extension update concurrently; newest pending app
  release replaces an older one; restart-required badge survives restart;
  data-only extension update hot reloads; failed update keeps prior version.

## Open-source prerequisite

Kaisola currently has no root `LICENSE` and no `license` field in `package.json`.
Choose and add a license, contribution policy, third-party notices process, and
extension SDK license before calling the IDE open source or accepting ecosystem
code. Behavioral inspiration is fine; direct source reuse must follow each
upstream license (VS Code MIT, Traycer Apache-2.0, Theia/Open VSX EPL-2.0, Zed's
copyleft licensing and per-extension licenses).
