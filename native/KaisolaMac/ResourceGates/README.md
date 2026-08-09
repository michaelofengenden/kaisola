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

The gate launches one private, broker-free process per fixture with its working
directory, `HOME`, and `CFFIXED_USER_HOME` pinned to the fixture root. Fixture
bytes are generated inside that process from fixed algorithms; no production
file or profile is read. Generation is excluded from latency but conservatively
remains inside the lifetime peak-memory observation.

| Fixture | Deterministic bound | Surface exercised |
| --- | --- | --- |
| `many-page` | 96 letter-size vector pages, 8 KiB–2 MiB | First page, pages 2/13/25/49/73/96, sustained scroll |
| `image-heavy` | Six distinct 896 × 896 high-entropy RGB images, 8–19 MiB | Decode, every subsequent page, sustained scroll |
| `malformed` | Exact 51-byte incomplete PDF object graph | Fail-closed rejection, no render metrics |
| `large-page` | One 14,400 × 14,400-point vector page, 512 B–1 MiB | First-page layout and draw |

Thresholds are intentionally loose enough for hosted macOS runners but finite
enough to catch a hung or eagerly decoded surface:

- first visible page: at most 3,000 ms;
- p95 subsequent paging: at most 750 ms;
- malformed rejection: at most 1,000 ms;
- sustained PDFView scrolling: 3 seconds, p95 callback interval at most 50 ms,
  maximum interval at most 250 ms, and callback coverage at least 0.80;
- per-fixture summed process-tree `phys_footprint_peak`: at most 768 MiB.

Each failure is emitted in the final JSON receipt as `{fixture, threshold,
observed, limit}`. The app receipt also proves optimized compilation, the exact
installed bundle path, fixture page/byte shape, and that no broker profile was
created.

The checked-in interaction matrix records the broader accessibility, session,
broker, update, and Companion evidence required at release milestones.
