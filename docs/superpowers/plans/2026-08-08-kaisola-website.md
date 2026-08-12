# kaisola.com Relaunch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** kaisola.com serves a one-page marketing site + generated changelog from GitHub Pages out of this repo.

**Architecture:** Static `site/` directory; `scripts/site-changelog.cjs` turns CHANGELOG.md into changelog.html at deploy time; `.github/workflows/site-deploy.yml` publishes via the official Pages actions; custom domain kaisola.com (DNS already points at Pages).

**Tech Stack:** Hand-written HTML/CSS (no frameworks, no web fonts, no external requests, no required JS), Node ≥ 20 for the generator, `node --test` for its test.

## Global Constraints

- H1 exactly: "The fully Mac-native GUI for coding agents."
- Download URL exactly: `https://github.com/michaelofengenden/kaisola/releases/latest/download/Kaisola.dmg`
- Both color schemes via `prefers-color-scheme`; readable at 375 px and 1440 px.
- The generator fails loudly (non-zero exit) on unparseable CHANGELOG headings.
- Do not push mid-plan; one push at the end (release-on-push repo).

---

### Task 1: Backfill CHANGELOG.md (0.1.106–0.1.113)

**Files:**
- Modify: `CHANGELOG.md` (prepend 8 sections above `## 0.1.105 — 2026-08-04`)

- [ ] **Step 1:** For each version 0.1.106…0.1.113, read `git log v0.1.<n-1>..v0.1.<n> --oneline` and write 1–4 bullets in the file's established user-facing prose style (plain sentences about what the user gets, not commit messages). Dates from `gh release list`.
- [ ] **Step 2:** Verify: `grep -c "^## " CHANGELOG.md` grew by 8, versions strictly descending.
- [ ] **Step 3:** Commit: `git add CHANGELOG.md && git commit -m "docs: changelog catches up (0.1.106-0.1.113)"`

### Task 2: Changelog generator + test

**Files:**
- Create: `scripts/site-changelog.cjs`
- Test: `tests/node/site-changelog.test.cjs` (runs under existing `npm run test:node`)

**Interfaces:**
- Produces: `node scripts/site-changelog.cjs --changelog CHANGELOG.md --template site/changelog.template.html --output site/changelog.html`; module exports `renderChangelog(markdown)` returning `{html, versions}` for the test. Template contains `<!--CHANGELOG-->` placeholder.

- [ ] **Step 1:** Write the failing test: fixture markdown with two `## X.Y.Z — DATE` sections + bullets; assert `renderChangelog` emits both versions in order, escapes `<`/`&`, renders `**bold**` and `` `code` `` inline, and throws on a malformed heading (`## not-a-version`).
- [ ] **Step 2:** `npm run test:node` — new test FAILS (module missing).
- [ ] **Step 3:** Implement the parser (headings `^## (\d+\.\d+\.\d+) — (.+)$`, bullets `^- `, continuation lines indented; escape HTML first, then apply bold/code inline rules; unknown top-level lines throw).
- [ ] **Step 4:** `npm run test:node` — PASS.
- [ ] **Step 5:** Commit.

### Task 3: Site pages (index, changelog template, styles, assets)

**Files:**
- Create: `site/index.html`, `site/styles.css`, `site/changelog.template.html`, `site/CNAME` (content `kaisola.com`), `site/assets/kaisola-icon.png` (copied), `site/assets/hero-dark.png` + optionally `hero-light.png` (from Task 4)

- [ ] **Step 1:** Synthesize the visual direction from the frontend-design draft + Codex design-collab result; record the chosen palette/scale as CSS custom properties at the top of styles.css.
- [ ] **Step 2:** Build index.html per spec structure (hero, screenshot, five pillars, footer). Semantic HTML, no JS.
- [ ] **Step 3:** Build changelog.template.html sharing styles.css, with `<!--CHANGELOG-->` placeholder and a back-link home.
- [ ] **Step 4:** Generate changelog.html locally; open both pages in a browser (or render check via WebFetch after deploy); check 375/1440 px and both schemes.
- [ ] **Step 5:** Commit.

### Task 4: Hero screenshot

- [ ] **Step 1:** `npm run native:fast` (build+launch dev app), stage: project open, agent terminal visible, file tree + preview open.
- [ ] **Step 2:** `screencapture -x -l <windowid>` Retina PNG; downscale/compress to < 500 KB (`sips`); place in `site/assets/`.
- [ ] **Step 3:** Quit the dev app. Commit with Task 3 if not yet committed.

### Task 5: Deploy workflow + Pages enablement + verify live

**Files:**
- Create: `.github/workflows/site-deploy.yml`

- [ ] **Step 1:** Workflow: `on: push: branches: [main] paths: [site/**, CHANGELOG.md, scripts/site-changelog.cjs, .github/workflows/site-deploy.yml]`; jobs: checkout → setup-node 22 → run generator → configure-pages → upload-pages-artifact (path site/) → deploy-pages; permissions `pages: write, id-token: read`.
- [ ] **Step 2:** Enable Pages: `gh api -X POST repos/michaelofengenden/kaisola/pages -f build_type=workflow` then `gh api -X PUT repos/michaelofengenden/kaisola/pages -f cname=kaisola.com -f build_type=workflow`.
- [ ] **Step 3:** Push; watch site-deploy run green.
- [ ] **Step 4:** Verify: `curl -sI https://kaisola.com` → 200 (cert may lag; check `gh api repos/.../pages` https_enforced), download link → 302, changelog page lists 0.1.113 first. Fetch rendered pages and sanity-check markup.
- [ ] **Step 5:** Report live URLs to Michael.
