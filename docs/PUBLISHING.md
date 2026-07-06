# kaisola.com

Static marketing site for Kaisola. `index.html` is self-contained (one CSS block,
no build step); screenshots live in `assets/` (downscaled from `../screenshots/`).

## Publishing plan

The domain is registered at **Spaceship** and uses Spaceship's own nameservers
(`launch1.spaceship.net` / `launch2.spaceship.net`), so DNS records are managed in
the Spaceship dashboard — no nameserver change needed for any option below.

**Recommended: Cloudflare Pages or GitHub Pages** (both free, HTTPS included):

1. **GitHub Pages** (simplest, repo already on GitHub)
   - Push `website/` to a `gh-pages` branch (or point Pages at `/website` on main
     via a tiny deploy action).
   - Repo → Settings → Pages → set custom domain `kaisola.com`.
   - In Spaceship DNS add:
     - `A @ 185.199.108.153` (+ `.109`, `.110`, `.111` — the four Pages IPs)
     - `CNAME www michaelofengend.github.io`
   - Check "Enforce HTTPS" once the cert issues.

2. **Cloudflare Pages** (fastest edge, previews per commit)
   - `npx wrangler pages deploy website` (or connect the repo in the dashboard).
   - Add the custom domain in Pages; Spaceship DNS gets a
     `CNAME @ <project>.pages.dev` (Spaceship supports CNAME flattening at apex;
     if not, use the A/AAAA records Cloudflare shows).

Either way: keep `assets/hero-*.jpg` under ~250 KB each (they are), and update
`og:image` if the domain layout changes.

## Later

- Replace the GitHub release link with a versioned `download.kaisola.com` redirect.
- Add a changelog page fed from GitHub releases.
- Regenerate screenshots after the project-tabs feature lands (the tab strip is
  the hero motif — the real thing should match).
