# Native resource and interaction gates

Kaisola keeps performance evidence close to the native macOS target. Generated
receipts belong in `results/` and are intentionally ignored by Git.

The ordinary local checks are:

```sh
npm run native:resource -- --help
npm run native:resource-fixture -- --help
npm run native:frame-trace -- --help
npm run native:frame-cadence -- --help
npm run native:pdf-preview-budget -- --help
npm run native:terminal-history-gate -- --help
```

Use `native-resource-gate.cjs` for bounded process-tree footprint samples,
`native-resource-fixture-gate.cjs` for the deterministic maximum-history
fixture, and the frame gates for scrolling and streaming cadence. Every gate
must receive an explicit app or receipt path and writes a machine-readable
result; none is part of the per-edit fast loop.

## Installed PDF preview budget

`native-pdf-preview-budget.cjs` refuses an Xcode `DerivedData/Build/Products`
path. Copy the optimized app to an installation directory first, then run:

```sh
ditto /path/to/Build/Products/LocalRelease/Kaisola.app \
  "/tmp/Applications/Kaisola PDF Budget QA.app"
npm run native:pdf-preview-budget -- \
  --app "/tmp/Applications/Kaisola PDF Budget QA.app" \
  --output native/KaisolaMac/ResourceGates/results/pdf-preview.json
```

The gate uses two private, broker-free launches of the same installed executable
per fixture, with each launch's working directory, `HOME`, and
`CFFIXED_USER_HOME` pinned to separate `generate-home` and `render-home`
directories under the private fixture root. The first launch only generates the
deterministic bytes at the root, emits their exact size and SHA-256, and exits cleanly.
The fresh second launch refuses a missing, changed, or symlinked artifact and
only loads and renders those prepared bytes. No production file or profile is
read.

| Fixture | Deterministic bound | Surface exercised |
| --- | --- | --- |
| `many-page` | 96 letter-size vector pages, 8 KiB–2 MiB | First page, pages 2/13/25/49/73/96, sustained scroll |
| `image-heavy` | Six distinct 896 × 896 high-entropy RGB images, 8–19 MiB | Decode, every subsequent page, sustained scroll |
| `malformed` | Exact 51-byte incomplete PDF object graph | Fail-closed rejection, no render metrics |
| `large-page` | One 14,400 × 14,400-point vector page, 512 B–1 MiB | First-page layout and draw |

Thresholds are intentionally loose enough for hosted macOS runners but finite
enough to catch a hung or eagerly decoded surface:

- first visible page: at most 3,000 ms;
- subsequent paging: **median** at most 250 ms, and no single page turn over
  3,000 ms. Two gates rather than one because a fixture turns 5 or 6 pages, and
  a 95th percentile over 5 samples is arithmetically the slowest of them: the
  old single "p95 at most 750 ms" was really "no page turn may ever exceed
  750 ms" wearing a percentile's name. That mattered because one turn is
  legitimately far slower than the rest — the jump to the last page of
  `image-heavy` measured 479, 512, 600, 632, 747, 771, 880 and 1,698 ms across
  eight runs while every other sample stayed under 150 ms. The median is the
  stable statistic (22–87 ms over those runs) and is what detects a regression;
  the ceiling is anchored to the first-visible-page budget, on the principle
  that a page turn must never cost as much as opening the document cold;
- malformed rejection: at most 1,000 ms;
- sustained PDFView scrolling: 3 seconds, p95 callback interval at most 50 ms,
  maximum interval at most 250 ms, and callback coverage at least 0.80;
- per-fixture render-process `phys_footprint_peak`: at most 768 MiB.

Each failure is emitted in the final JSON receipt as `{fixture, threshold,
observed, limit}`. The receipt reports the render process's current
`phys_footprint` separately from its lifetime peak, requires exactly that one
render process in the sample, and records that the generation process exited
before rendering began. It also proves optimized compilation, the exact
installed bundle path, fixture page/byte shape and digest, and that no broker
profile was created.

## Installed terminal-history qualification

The final installed-build terminal-history qualification is deliberately
separate from those disposable fixtures. See
[`terminal-history-gate-v1.md`](terminal-history-gate-v1.md) for the signed,
physical-trackpad protocol and the sealed receipt contract. Its snapshot path
is read-only (`broker.status` only), never adopts ownership, and never emits the
broker token, socket, owner, last-owner, or terminal working directory.

The checked-in interaction matrix records the broader accessibility, session,
broker, update, and Companion evidence required at release milestones.
