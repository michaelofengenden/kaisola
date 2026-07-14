# kaisola.com

The static marketing site. `index.html` is self-contained (one CSS block, no
build step); screenshots live in `assets/` (downscaled from `../screenshots/`,
which regenerate with `npm run shoot`).

## How it publishes

GitHub Pages, deployed by [`.github/workflows/site.yml`](../.github/workflows/site.yml):
every push to `main` that touches `site/**` uploads this folder as the Pages
artifact and deploys it. No build step, no branch juggling.

- **Domain**: `kaisola.com`, registered at Spaceship (Spaceship nameservers).
  DNS is set in the Spaceship dashboard: the four Pages `A` records on the apex
  (`185.199.108.153` … `.111`) and `CNAME www → michaelofengenden.github.io`.
- **HTTPS**: enforced; cert managed by GitHub.
- The custom domain lives in the repo's Pages settings (the `CNAME` file here is
  a belt-and-suspenders copy).

Keep `assets/hero-*.jpg` reasonably compressed, and update their alt text and
the page copy whenever the screenshots are regenerated. Update `og:image` in
`index.html` if the social-preview asset changes.

## Later

- Replace the GitHub release link with a versioned `download.kaisola.com` redirect.
- Add a changelog page fed from GitHub releases.
- Regenerate the product screenshots after a substantial shell or session-layout
  change so the public site continues to match the shipped app.
