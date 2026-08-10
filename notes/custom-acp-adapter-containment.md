# Custom ACP adapter containment boundary

Status: implemented for user-installed custom ACP adapters. Shipped Claude and
Codex adapters retain their existing launch contract.

## Threat model

A custom npm adapter is publisher-controlled code. Pinning and hashing prove
which code was approved; they do not make that code trustworthy. Kaisola's
runtime boundary therefore protects unrelated user data and credentials from a
malicious or compromised adapter, and prevents the adapter from escaping
through ACP services hosted by the app. It is not a boundary between the macOS
account and its owner, and it does not make npm installation itself untrusted
code execution: installation still runs the user's npm, but lifecycle scripts
are disabled and no installed code runs until approval is recorded.

## Always available inside the boundary

- stdio to Kaisola for ACP JSON-RPC;
- the exact integrity-verified adapter install, read-only;
- Kaisola's integrity-verified bundled Node executable;
- a private per-agent `HOME`, `TMPDIR`, XDG tree, and npm cache under Kaisola
  application support, read/write, mode `0700`;
- the selected Claude or Codex account directory, read/write, when the roster
  explicitly declares that credential context (needed for token refresh);
- only the matching provider's environment keys; and
- Apple's `system.sb` runtime baseline (system libraries, trust services, small
  amounts of platform metadata) plus workspace path metadata required to hold
  the session working directory.

The child environment is rebuilt rather than filtered in place. Its fixed
common keys are `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, private `HOME`/
`CFFIXED_USER_HOME`/`TMPDIR`/XDG paths, `NODE_REPL_HISTORY=/dev/null`, npm cache
and update-disable keys, locale/terminal presentation keys, and Kaisola's host
and session markers. Claude grants may add only `ANTHROPIC_API_KEY`,
`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `CLAUDE_CODE_OAUTH_TOKEN`, and
`CLAUDE_CONFIG_DIR`. Codex grants may add only `OPENAI_API_KEY`,
`OPENAI_BASE_URL`, `OPENAI_MODEL`, `CODEX_CONFIG`, and `CODEX_HOME`. A
credential-free adapter receives neither provider set. Variables such as
`AWS_*`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`, proxy settings, `SHELL`, `DYLD_*`, and
`NODE_OPTIONS` are never inherited.

## Reviewable optional privileges

The Settings row shows and persists a closed grant. The same grant is bound to
the pinned install record, so changing credentials, privileges, package bytes,
dependency graph, or the containment boundary version disables chat until the
user reviews and enables it again. The pinned tree and approval are re-verified
before every initial launch and restart.

| Privilege | Direct Seatbelt access | ACP/MCP host behavior |
| --- | --- | --- |
| Outbound network | Remote IP connections plus required macOS resolver/network services; no inbound listener or local Unix socket (the `system.sb` syslog exception is explicitly re-denied) | Enabled HTTP/SSE MCP entries, including their configured headers, are forwarded only with this grant |
| Read workspace | Read the canonical session workspace | `fs/read_text_file` is advertised and accepted, still subject to sensitive-path guards |
| Write workspace | Write the canonical session workspace | `fs/write_text_file` is advertised and accepted, still subject to containment and sensitive-path guards |
| Spawn child processes | Fork/exec inside the inherited Seatbelt and minimal environment; system executables become readable | Enabled stdio MCP entries, including their configured environment values, are forwarded only with this grant |

Kaisola's ACP `terminal/*` host bridge is never offered to custom adapters,
even with child-process access. That bridge is owned by the unsandboxed app and
would otherwise turn one JSON-RPC request into a process carrying Kaisola's
ordinary environment outside the adapter's Seatbelt. Custom adapters that need
subprocesses must use the reviewed in-sandbox child-process privilege.

## Fail-closed conditions

Chat does not resolve, or launch reports an actionable containment error, when:

- the roster has no current privilege review, declares an unknown credential or
  privilege, or the install record does not match it;
- the pinned adapter install drifts or escapes its canonical install root;
- `/usr/bin/sandbox-exec` is absent or non-executable;
- Kaisola's bundled Node package fails signature/inventory/hash verification;
- the npm executable requests a non-Node runtime;
- private state cannot be created as user-owned `0700` directories;
- the workspace or selected credential directory is missing; or
- the workspace, adapter install, and private state trees overlap; or
- a credential directory is not owned by the current user, is `/`, the account
  home, another broad system root, or overlaps the workspace, adapter install,
  trusted runtime, or private state tree.

There is no login-shell, system-Node, inherited-environment, or unsandboxed
fallback.

## Deliberate limits and residual risk

`sandbox-exec` and `system.sb` are deprecated/private macOS interfaces, so the
real generated profile is exercised by a macOS integration test. An OS that no
longer supports the boundary disables custom adapter chat until Kaisola adopts
a replacement. Outbound-network approval is destination-wide (remote IP,
including loopback), not domain-scoped. The existing verify-to-spawn interval
for the app-owned npm tree remains a same-user TOCTOU window; persistent drift
is caught, but closing the interval completely requires descriptor-based
execution. These limits are narrower and explicit; none silently restores
ordinary user access.
