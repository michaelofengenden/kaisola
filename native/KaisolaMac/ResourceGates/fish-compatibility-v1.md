# Fish compatibility matrix v1

Kaisola validates its generated Fish launcher against one immutable runtime in
the always-triggered `native-fish-compatibility` pull-request lane. A skipped,
missing, duplicated, or non-passing XCTest result fails that lane.

| Fish runtime | Support level | Required evidence |
| --- | --- | --- |
| Fish 4.8.1 | Required CI baseline | Official macOS app asset with SHA-256 `aec7606269bbd0af8ac29f66d7f50f32f72b1d68d3b278227ae3e94cf501bb7f`; generated-file syntax; custom config and quoted paths; native OSC 133 capability gate; status 17; PTY resize to 101×41. |
| Fish 4.8.x other than 4.8.1 | Upgrade candidate, not silently floating | Move the pin only in a reviewed change that records the new official checksum and passes the complete required lane. |
| Older Fish | Generated fallback compatibility, not a pinned binary guarantee | The required lane disables the native capability gate and executes the generated fallback events, including nonzero status and cancel. Older Fish releases are not claimed as supported until their exact binaries are added to this matrix. |

The app never edits `config.fish`. The test gives Fish an isolated `HOME` and
`XDG_CONFIG_HOME`, installs Kaisola's files beneath a path containing spaces and
quotes, and verifies that the custom user configuration still loads before the
app-owned `--init-command` integration.

The required lane uses the Fish executable inside the signed release bundle at
`Contents/Resources/base/usr/local/bin/fish`; the bundle's `Contents/MacOS/fish`
is an app launcher and is deliberately not treated as a shell executable.
