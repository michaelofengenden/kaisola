# Kaisola extensions

Kaisola's first extension API is intentionally declarative. Extensions can add
syntax modes, safe document previews, and MCP server definitions. They cannot
load JavaScript into the editor renderer, access Node, or call arbitrary IPC.

This is a native Kaisola format, not VS Code extension compatibility. VSIX
packages that depend on the VS Code runtime need a real isolated extension host
and are not accepted by this loader.

## Install a development extension

1. Create a folder containing `kaisola-extension.json`.
2. Open **Extensions** from the toolbar or command palette.
3. Choose **Install Dev Extension** and select the folder.
4. Review the exact contributions and MCP commands, then install.

The desktop main process reads and validates the manifest again. Installed
state lives in the app data directory; renderer storage is only a startup cache.

## Manifest v1

```json
{
  "id": "example.data-tools",
  "name": "Data tools",
  "version": "1.0.0",
  "description": "TOML syntax and tabular previews.",
  "author": "Example Contributors",
  "categories": ["Languages", "Grammars", "Previews"],
  "repository": "https://github.com/example/data-tools",
  "contributions": {
    "languages": [
      {
        "id": "example-toml",
        "name": "TOML",
        "extensions": ["toml"],
        "grammar": {
          "type": "simple",
          "atoms": ["true", "false", "inf", "nan"],
          "lineComments": ["#"]
        }
      }
    ],
    "previews": [
      {
        "id": "example-csv-table",
        "name": "CSV Table",
        "extensions": ["csv", "tsv"],
        "renderer": "csv"
      }
    ]
  }
}
```

Supported preview renderers are `csv`, `json`, `markdown`, and `html`. HTML is
sanitized: scripts, forms, frames, inline styles, and event handlers are
removed. CSV/JSON previews produce typed React output and have size/row caps.

The simple grammar supports:

- `keywords` and `atoms`
- `lineComments`, such as `//` or `#`
- `blockComments`, such as `["/*", "*/"]`
- quoted strings, numbers, identifiers, and common operators

## MCP contributions

```json
{
  "id": "example.docs-mcp",
  "name": "Example docs MCP",
  "version": "1.0.0",
  "description": "Adds a documentation server.",
  "author": "Example Contributors",
  "categories": ["MCP Servers"],
  "contributions": {
    "mcpServers": [
      {
        "name": "example-docs",
        "config": { "url": "https://docs.example.com/mcp" }
      }
    ]
  }
}
```

An MCP contribution can define one HTTPS URL, or a `command` plus `args` and
environment-variable names. Every install shows the exact definition before it
is written. Project `.mcp.json` entries keep their separate hash-based approval
gate. Registry or publisher identity is metadata, not a safety guarantee.

Do not put literal secrets in a development manifest. Secret-backed MCP inputs
need the planned keychain reference API before they can be distributed safely.

## Current boundary and roadmap

Bundled syntax/preview contributions hot-reload. A future executable extension
lane should use a separate WASM or worker host with explicit capabilities,
digests, atomic staging, rollback, and crash isolation. Language servers belong
in a supervised main-process LSP host; interactive previews belong in a
sandboxed guest with a restrictive CSP. Neither should execute inside the main
React document.
