# MCP/ACP implementation brief — research pass 2026-07-09 (night shift)

Source-verified against official docs + zed-industries/claude-code-acp source
(v0.57.0 `src/acp-agent.ts`). Shared notes for both agents (claude + codex).

## Load-bearing finding

ACP `session/new` carries `mcpServers[]`, and claude-code-acp declares
`mcpCapabilities: { http: true, sse: true }` in `initialize` and merges those
servers into the underlying Claude Code. **The universal way to give every
ACP agent Kaisola's MCP tools is `session/new.mcpServers`, not
`--mcp-config`** (which stays only for the prepared terminal Claude).

## Exact shapes

`session/new` params (env/headers are ARRAYS of {name,value}, unlike .mcp.json):

    { "cwd": "/abs/path",
      "mcpServers": [
        { "name": "kaisola", "command": "node", "args": ["srv.js"],
          "env": [ { "name": "TOKEN", "value": "x" } ] },
        { "type": "http", "name": "kaisola", "url": "http://127.0.0.1:PORT/mcp",
          "headers": [ { "name": "Authorization", "value": "Bearer …" } ] }
      ] }

- Send `initialize` (protocolVersion 1) first; gate http/sse entries on
  `agentCapabilities.mcpCapabilities`. Fallback for stdio-only agents:
  `{ command: "npx", args: ["-y", "mcp-remote", url] }`.
- claude-code-acp also advertises: promptCapabilities {image, embeddedContext},
  loadSession: true, sessionCapabilities {additionalDirectories, close, delete,
  fork, list, resume}, auth.logout.
- Modern model/effort/mode selection = generic `SessionConfigOption` via
  `session/update {sessionUpdate:"config_option_update", configOptions}` and
  `setSessionConfigOption({sessionId, configId, value})` — do NOT hardcode
  model menus. Legacy modes channel: SessionModeState + session/set_mode.
  Claude modes map to permission modes default/acceptEdits/plan/bypassPermissions.
- Plan updates: `session/update {sessionUpdate:"plan", entries:[{content,priority}]}`.
- Embedded terminals: terminal/create|output|wait_for_exit|kill|release.

`.mcp.json` cross-tool convention (store + terminal Claude):
- Root key `mcpServers` (Claude Code/Cursor/Desktop) vs `servers` (VS Code).
- stdio: {command, args[], env{}} · remote: {type:"http"|"sse", url, headers{}}.
  A url with NO type is a hard error in Claude Code.
- `${VAR}` / `${VAR:-default}` expansion in command/args/env/url/headers.
- Claude Code extras: oauth{clientId,callbackPort,scopes}, headersHelper,
  alwaysLoad, timeout. VS Code extras: inputs[] (promptString, password:true)
  referenced as `${input:id}`, `${env:VAR}`, envFile.
- Scope precedence (Claude Code): local > project (.mcp.json) > user > plugin.
  Project-scope servers need a trust prompt before first use.

Official registry: GET registry.modelcontextprotocol.io/v0/servers?search=&limit=&cursor=
→ { servers: [{ server: {name, description, repository, version, packages[],
remotes[]}, _meta }], metadata: { count, nextCursor } }. Descriptor, not config:
remotes[{type:"streamable-http",url}] → {type:"http",url}; packages npm →
{command:"npx",args:["-y",identifier,…]}, prompt for env isSecret/isRequired.

Deeplinks: Cursor = cursor://anysphere.cursor-deeplink/mcp/install?name=&config=BASE64(json);
VS Code = vscode:mcp/install?<url-encoded json> and `code --add-mcp '<json>'`.
Kaisola should register kaisola://mcp/install?name=&config=BASE64 + parse both
foreign forms + paste-JSON. Every install → trust modal before write.

## Ranked build list

1. Universal MCP passthrough via session/new (HIGH/LOW) — codex has mcpHttpEntry
   in flight in acpHandler.cjs; finish + gate on capabilities + stdio fallback.
2. One .mcp.json-shaped store (user + project scope) projected to ACP array
   shape, --mcp-config, and the UI (HIGH/MED). The object↔array env/headers
   conversion is the whole seam.
3. kaisola:// install deeplink + paste-JSON import + trust modal (HIGH/LOW-MED).
4. Registry-backed catalog in Settings (MED/MED).
5. Generic SessionConfigOption UI (MED-HIGH/MED) — replaces hardcoded pickers.
6. session/request_permission full option-kinds (allow/reject × once/always),
   persist "always" per project+server (HIGH safety/LOW-MED).
7. /mcp-style health panel: per-server status + tool counts + reauth (MED/MED).
8. Host-side OAuth only for servers Kaisola itself calls; agents own their own
   OAuth (skip building the full flow for agent-owned servers).

## Skips

.mcpb/.dxt bundle runtime (import config only); hardcoded model menus;
WebSocket MCP; featuring SSE for new servers (accept, don't promote); running
our own registry.
