# PR 6 — Extensions and customization: spec (v1, 2026-08-03)

Tracker acceptance (PULL_REQUEST_FEATURES.md):

- Extensions declare capabilities and cannot silently gain filesystem or
  secret access.
- Invalid packages degrade to a disabled state with an actionable explanation.
- Installation and removal are reversible and workspace/account scoped.

## What exists (seam survey, 2026-08-03)

| Area | Today | Registry gap |
| --- | --- | --- |
| MCP packages | `McpConfigStore` — already a validated, capped (24), workspace-scoped registry with capability gating downstream (`AcpClient.sessionMcpServers` filters by adapter-declared `mcpHTTP`/`mcpSSE`) and read-only discovery that imports **disabled** | None structural; PR 6 treats it as the reference implementation |
| Custom agents | `AgentRegistry.builtIns` hardcoded (4); `CustomAgentStore` (cap 12) is data-driven but terminal-only; `AcpAdapter.forAgent` is a hardcoded switch (claude-code, codex) | Agents cannot reach the chat surface; adapter mapping is a switch |
| Editor themes | `TerminalPaletteMode` 2-case enum; 4 static palettes in `TerminalTheme` | Closed enum |
| Language grammars | `SyntaxHighlighter.Language` closed enum; two hardcoded switches (extension→language, language→rules) | Closed enum |
| Previews | `FilePreviewContent.load` hardcoded extension chain; view dispatch switch | Extension→kind mapping closed |

Shared persistence recipe (all four existing stores): JSON in
`~/Library/Application Support/com.kaisola.mac.preview`, 0700 dir / 0600 file,
temp-file + `replaceItemAt` atomic write, corrupt → empty, hard cap on entries.

## Design

### D1. Capability vocabulary — declared, never inferred

An extension entry declares what it is allowed to do by *kind*; the kinds are
closed and enforced at the integration seam, not by the extension:

- **data** (grammars, themes, preview mappings): no filesystem, no process, no
  network. Enforced structurally — these registries store plain values and the
  consumers never execute anything from them. Regex grammars compile under
  `NSRegularExpression` only.
- **process** (custom agents' ACP adapters, MCP stdio servers): may spawn a
  named command. Requires explicit user enablement per entry (imports and new
  entries start disabled), shows the exact command line it will run, and the
  spawn inherits the session's account/config isolation (CLAUDE_CONFIG_DIR /
  CODEX_HOME overlay) — never ambient secrets.
- **network** (MCP http/sse): https-only, credential-free URLs (existing
  `McpServerConfig.validationError` rules).

No registry entry can widen its kind: a theme cannot name a command; a custom
agent cannot add filesystem globs. Sensitive-path protection stays global
(`sensitiveGlobs`), not per-extension.

### D2. One store shape per registry

Each registry follows the `CustomAgentStore` recipe: `Codable` spec array,
hard cap, atomic write, corrupt → empty, plus a `validationError: String?`
computed on the spec (the `McpServerConfig` pattern). An entry with a non-nil
`validationError` is **kept but disabled**, and the settings row shows the
reason — that is the "degrade to disabled with an actionable explanation"
acceptance, applied uniformly.

### D3. The five slices

1. **Editor themes** (`TerminalThemeRegistry`)
   - `ThemeDefinition { id, title, light: Palette, dark: Palette }`; shipped
     definitions replace the `TerminalPaletteMode` cases; `terminalPalette`
     defaults key on id string with fallback to `native`.
   - `CustomThemeStore` (cap 12): user-scoped JSON; palette colors as hex
     strings; validation: parseable hex, 16 ANSI slots, distinct id.
   - Settings menu iterates registry; invalid entries listed disabled with
     reason.
2. **Custom agents reach chat** (`acpAdapter` on the roster)
   - Fold `builtIns` and `custom` into one data shape carrying optional
     `acpPackage: String?` (npm package spec) — the two shipped adapters move
     into the built-in entries' data.
   - `AcpAdapter.forAgent` becomes a roster lookup.
   - `CustomAgentSpec.acpPackage` validation: npm package-name shape, version
     tag allowed, no path/URL forms (registry packages only), length caps.
   - A custom agent with `acpPackage` set starts **disabled for chat** until
     the user enables it in settings, where the exact `npx <package>` line is
     shown (process capability, D1).
3. **Language grammars** (`GrammarRegistry`)
   - `LanguageGrammar { id, extensions: [String], rules: [Rule] }` — shipped
     grammars become data; `CustomGrammarStore` (cap 16) holds user grammars
     with regex patterns compiled at load; a pattern that fails to compile or
     exceeds length caps → entry disabled with the compiler's message.
   - `Role` stays the closed 5-role set (deliberate design constraint).
4. **Preview mappings** (`PreviewMappingRegistry`)
   - Data table `extensions → PreviewKind` consulted before the hardcoded
     chain; the binary sniff, size caps, and kind set stay fixed (safety and
     view code are not extensible). Custom mappings can only select existing
     kinds (cap 32).
5. **MCP registry** — no structural work; add the same disabled-with-reason
   row treatment in settings if any config fails validation (mostly exists).

### D4. Settings surface

One "Extensions" settings tab with a section per registry, following the
Accounts/Usage card vocabulary: entry rows with enable/disable, remove, and a
reason line when disabled. Add flows stay minimal (file-less: forms, not
package files).

### D5. Out of scope

- Marketplace/remote fetching of extensions (everything is local, typed in or
  imported from sibling tools' configs read-only).
- Pluggable preview *renderers* (new SwiftUI views can't come from data).
- Per-extension filesystem grants.

## Test plan

- Per store: cap enforcement, atomic-write/corrupt→empty, validation table
  (each invalid shape names its reason).
- Grammar/theme/preview registries: shipped data equals previous hardcoded
  behavior (golden tests: same language for same extension, same palette
  values, same preview kind per extension).
- Adapter lookup: claude-code/codex resolve exactly as the old switch did;
  custom agent without enablement never yields an adapter; enabled custom
  agent yields `npx <package>`.
- Chat-surface gating: `AcpAdapter.forAgent` returns nil for disabled entries
  (capability acceptance).

## Slice order and split

1 (themes) → 2 (agents/ACP) → 3 (grammars) → 4 (previews) → 5 (MCP polish).
Slices 3+4 are mechanical once 1 sets the store pattern.
