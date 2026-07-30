# Native resource and interaction gates

Kaisola keeps performance evidence close to the native macOS target. Generated
receipts belong in `results/` and are intentionally ignored by Git.

The ordinary local checks are:

```sh
npm run native:resource -- --help
npm run native:resource-fixture -- --help
npm run native:frame-trace -- --help
npm run native:frame-cadence -- --help
```

Use `native-resource-gate.cjs` for bounded process-tree footprint samples,
`native-resource-fixture-gate.cjs` for the deterministic maximum-history
fixture, and the frame gates for scrolling and streaming cadence. Every gate
must receive an explicit app or receipt path and writes a machine-readable
result; none is part of the per-edit fast loop.

The checked-in interaction matrix records the broader accessibility, session,
broker, update, and Companion evidence required at release milestones.
