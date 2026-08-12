# kaisola.com relaunch

2026-08-08 · approved by Michael in session

## What

Recreate the kaisola.com website as a one-page marketing site plus a very
simple changelog page, hosted from this repo on GitHub Pages under the
existing custom domain. Positioning: **the fully Mac-native GUI for coding
agents**.

## Current state

- DNS already points kaisola.com at GitHub Pages (apex A records
  185.199.108-111.153; www CNAME to michaelofengend.github.io) but no Pages
  site is bound — GitHub serves 404. No site files exist in any repo.
- Every GitHub release publishes a stable `Kaisola.dmg` asset, so
  `https://github.com/michaelofengenden/kaisola/releases/latest/download/Kaisola.dmg`
  is a permanent download URL.
- `CHANGELOG.md` is user-facing plain prose but stale (stops at 0.1.105).
- `assets/kaisola-icon.png` is the app icon. No screenshots exist in-repo.

## Decisions (Michael)

- One-page marketing site at launch; no docs section yet.
- Lives in this repo (`site/`), deployed by a Pages workflow.
- Plus a very simple changelog page.
- Hero screenshot: captured from the dev app by Claude (staged workspace).

## Design

### Pages

- `site/index.html` — hero (H1 "The fully Mac-native GUI for coding
  agents.", subline from the README opener, "Download for Mac" primary
  button to the permanent DMG URL, "View on GitHub" secondary), one large
  app screenshot, the README's five pillars as short feature sections
  (agents first-class; many subscriptions, one app; an IDE around the
  agents; native all the way down; yours to extend), footer with GitHub /
  Changelog / © links. No analytics, no tracking, no external requests.
- `site/changelog.html` — GENERATED from `CHANGELOG.md`: version, date,
  bullets, newest first. Deliberately plain.
- `site/CNAME` — `kaisola.com`.
- `site/styles.css`, `site/assets/` (icon, screenshot images).

### Build and deploy

- No framework, no npm dependencies. `scripts/site-changelog.cjs` converts
  CHANGELOG.md's rigid structure (`## <version> — <date>` + `- ` bullets)
  into `changelog.html` using a small hand-rolled parser; it fails loudly on
  a heading it cannot parse rather than emitting broken HTML.
- `.github/workflows/site-deploy.yml`: on push to main touching `site/**`,
  `CHANGELOG.md`, or the generator, run the generator and deploy with
  actions/configure-pages + upload-pages-artifact + deploy-pages.
- Enable Pages on the repo (workflow build type) with custom domain
  kaisola.com; HTTPS enforced once the cert issues.

### Content upkeep

- Backfill `CHANGELOG.md` 0.1.106–0.1.113 now, in the file's existing
  user-facing prose style, from the release commits.
- Convention going forward: releases worth telling users about get a
  CHANGELOG entry; the site republishes automatically on push.

### Visual direction

- The site should feel like the app: quiet, native, measured — system font
  stack (-apple-system), dark-first with light support via
  prefers-color-scheme, restrained accent, generous whitespace, the app
  icon, no marketing gradients or mascots. Final direction is synthesized
  from a frontend-design draft plus an independent Codex design-collab pass
  (Michael's cross-model convention).

### Screenshot

- Launch the dev build, stage a real-looking workspace (project open,
  agent terminal running, file tree + preview visible), capture Retina PNG
  with `screencapture`. Optimize size (target < 500 KB per image).

## Not doing

- Docs section, blog, newsletter, analytics, waitlist, custom web fonts,
  JS beyond none-or-trivial (the site works with JS disabled).
- No iPhone Companion marketing beyond a mention (it ships with the app).

## Testing / acceptance

- `node scripts/site-changelog.cjs` output contains every CHANGELOG version
  heading, newest first; a node test pins the parser on a fixture.
- Workflow deploys green; `https://kaisola.com` serves the page over HTTPS
  with the download link resolving (HTTP 302 to the DMG).
- Page renders sensibly at 375 px and 1440 px widths; both color schemes.
