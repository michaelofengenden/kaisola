# Hono reachability and advisory closure

Receipt date: 2026-08-09

Kaisola's root package does not depend directly on Hono. The production
dependency chain recorded by `package-lock.json` is:

```text
@anthropic-ai/claude-agent-sdk 0.3.205 (direct dependency)
└── @modelcontextprotocol/sdk 1.30.0 (peer dependency)
    ├── hono 4.13.1
    └── @hono/node-server 2.0.12
```

The locked Hono version is newer than the common 4.12.34 fix for:

- `GHSA-8j4g-w8fx-2239`: CORS request-header regular-expression denial of service
- `GHSA-f23p-vx2j-j53r`: JSX `memo()` output leaking across render requests
- `GHSA-79qm-7rj5-m7r9`: connection-scoped response headers escaping the proxy helper
- `GHSA-54fx-42gc-7vw4`: adversarial language-tag algorithmic complexity

## Bundled and invoked surfaces

| Package or module | Repository install tree | Installed broker helper | First-party invocation |
| --- | --- | --- | --- |
| `hono` core | Transitive MCP SDK package | Not copied | None |
| `@hono/node-server` | Transitive MCP SDK package | Not copied | None |
| `hono/cors` | Present inside the transitive Hono package | Not copied | None |
| `hono/jsx` | Present inside the transitive Hono package | Not copied | None |
| `hono/proxy` | Present inside the transitive Hono package | Not copied | None |
| `hono/language` | Present inside the transitive Hono package | Not copied | None |

`scripts/native-broker-package.cjs` copies an explicit allowlist: the usage
sources, `node-pty`, and the Claude Agent SDK package. It does not copy Hono,
the MCP SDK peer tree, or `@hono/node-server`. A source scan of first-party
`runtime/` and `scripts/` JavaScript also finds no Hono import. Kaisola
therefore does not instantiate Hono or open a Hono listener. The detached
broker remains a raw `node:net` Unix-domain socket, while Companion listeners
remain native Network-framework listeners.

## Regression and audit gates

`tests/node/honoDependencyReachability.test.cjs` fails if the lock drops below
4.12.34, if first-party production JavaScript begins importing either Hono
package, or if this inventory loses a surface or advisory. Once the patched
floor is installed, the same test directly exercises the upstream
exploit-shaped cases for CORS parsing, per-render memo isolation, proxy
connection-header stripping, and adversarial language tags.

Run the production audit with:

```sh
npm audit --omit=dev --json
```

The audit may report unrelated packages independently; its Hono entry must be
absent, which proves these four advisory ranges no longer match the production
lock.
