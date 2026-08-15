Findings below. Read-only audit; nothing modified.

# Swift session broker — status of remaining-work item 2 (production packaging + default enablement)

Branch `fix/stale-generation-lock`, HEAD `1189537c9`. Docs: `docs/swift-session-broker-migration-plan.md` (726 lines), `docs/swift-session-broker-remaining-work.md` (82 lines; item 2 at lines 48-56).

## 1. Does `scripts/native-broker-package.cjs` support schema-2 native packages?

**Verification: yes. Production: no.** `/Users/michaelofengenden/Developer/Kaisola/scripts/native-broker-package.cjs` (554 lines)

EXISTS
- `contentDigestV2` (lines 90-123) — v2 domain, binds appRelease, launch kind/executable/ordered args, per-file role + machO arches + designated requirement.
- `contentDigest` dispatch (125-129), `roleFor` already maps `bin/kaisola-session-broker` → `session-broker-executable` (line 202).
- `validateNativeV2Manifest` (219-274): exactly one executable record, launch path must equal it, mode `0755`, machO arches exactly `["arm64"]`, requirement non-empty, args bounded/NUL-free, `--launch`/`--pty-child` reserved.
- `verifyPackage` (299-381): schema-2 nlink==1 on manifest and every file (304-306, 354-356), mutual exclusion of node/nodePty metadata (328-331), arch equality (366-369).
- `--verify` path is schema-agnostic (528-530). Node tests: `tests/node/nativeBrokerPackage.test.cjs` lines 183-338 (synthetic schema-2 fixture, ambiguity, unsafe args, weakened executable identity, hard links, hard-linked manifest).

MISSING
- `stagePackage` (413-502) can only build a **Node** package: it unconditionally lipos `bin/node` (430-442), copies `brokerSources` (14-33, 445-447), node-pty (449-461) and the Claude SDK (467-478), and emits `node`/`nodePty`/`claudeAgentSDK` metadata (487-489). It passes `schemaVersion: policy.schemaVersion` (483), so setting the policy to 2 makes its own `verifyPackage` fail at line 329-331. **There is no code path that produces a schema-2 package.**
- `parseArguments` (504-523) has no `--native-broker` / `--app-release-version` / `--app-release-build` / `--launch-arguments` options.
- `native/KaisolaMac/BrokerHelper/package-policy.json` is `schemaVersion: 1`, `packageVersion "1.1.0"`, and carries no `appRelease` block (the `policy.appRelease` comparison at 228-232 is dead today). One policy file = one package; there is no per-package policy.
- `signNestedCode` (394-411) is already correct for a native binary: `--options runtime --timestamp`, entitlements applied only to `bin/node` (line 406), so the Swift broker would get a hardened, JIT-free signature with no change. `native/KaisolaMac/BrokerHelper/BrokerHelper.entitlements` grants `allow-jit` + `allow-unsigned-executable-memory` (Node only).

## 2. Does the signed app bundle include a Swift broker? Is there a mixed-package catalog?

**No to both.**

- `native/KaisolaMac/project.yml` lines 49-72: `KaisolaSessionBroker` is `type: tool`, `ARCHS: arm64`, `SKIP_INSTALL: YES`, with an explicit comment (49-50): "the shipping app neither depends on it nor copies it into the bundle." The `Kaisola` app target's `dependencies` (119-129) list only `KaisolaBrokerBootstrap`, KaisolaCore, SwiftTerm, Sparkle. Only `KaisolaTests` (218-234) depends on it, `embed: false, link: false`.
- Scheme `Kaisola` (236-247) builds `Kaisola` + `KaisolaTests` only; `.github/workflows/release-candidate.yml:154-171` builds `-scheme Kaisola -configuration Release`, so the broker binary is never produced in a release build.
- The app's post-build packaging step (`project.yml:180-216`) invokes `native-broker-package.cjs` with `--runtime-arm64/--bootstrap/--entitlements` only. One output directory: `Contents/Resources/BrokerHelper`.
- Bundle root is hardcoded: `native/KaisolaMac/Shared/BrokerHelperPackage.swift:203-208` `bundledRoot` → `Resources/BrokerHelper`. No catalog file, no multi-package enumeration anywhere.
- An active test forbids embedding it: `native/KaisolaMac/KaisolaTests/SwiftSessionBrokerConfigurationTests.swift:212-225` `testBuiltKaisolaApplicationDoesNotEmbedTheShadowBrokerExecutable`.
- Two other consumers assume the broker package contains Node: `native/KaisolaMac/Kaisola/App/UsageCenter.swift:1677,1732-1733` (`package.usageScript`, `package.nodeExecutable`) and `native/KaisolaMac/Kaisola/Acp/CustomAdapterContainment.swift:169`. This is exactly the "mixed-package catalog" the plan describes at `docs/swift-session-broker-migration-plan.md:211-231`.

Schema-2 *decode/verify/stage* on the Swift side does exist and is well covered:
- `native/KaisolaMac/Shared/BrokerHelperPackage.swift`: `PackageKind` (53-56), decoder (101-145), `BrokerLaunchPayload` (157-160) with the standing comment at 154-156 ("BrokerLaunchConfiguration and BrokerBootstrapService remain pinned to the schema-1 Node launch"), `launchPayload` (182-192), `verify` schema-2 branch (276-292), `validateNativeLaunch` (436-463), `machOArchitectures` (465-526), `nativeContentDigest` (578-617), staging with `schema2Expectation` (707-806).
- `native/KaisolaCore/Sources/KaisolaBrokerProtocol/BrokerWire.swift:11-20`: `nodeHelperPackageSchema = 1`, `nativeHelperPackageSchema = 2`, `supportedHelperPackageSchemas`, and `helperPackageSchema = nodeHelperPackageSchema` — the deliberate pin, with the comment at 17-19.
- Tests: `native/KaisolaMac/KaisolaTests/BrokerHelperPackageTests.swift` (765 lines), schema-2 cases at 105, 154, 179, 209, 231, 243, 259, 275, 315, 331, 342, 360, 391.

Blocker inside that existing code: `verify` requires a non-nil `schema2Expectation` for any nativeV2 package (line 277). `verifyBundled` (210-215) never supplies one, and neither does `BrokerBootstrapService` (see §3). So a schema-2 package placed in the bundle today fails closed with `incompatibleManifest`.

## 3. Is there an opt-in selector for the Swift broker in the app?

**No.** Searched `runtimeKind`, `canary`, `KaisolaSessionBroker`, `swiftBroker`, `sessionBrokerRuntime` across all `.swift/.cjs/.ts/.json/.yml`.

- `runtimeKind` exists only inside the broker itself: `KaisolaSessionBrokerCore/BrokerProtocolTypes.swift:146,164,181,200`, `BrokerAuthentication.swift:151` (`"swift"`), `ShadowBrokerService.swift:1144,1177`. The app never reads it (no `runtimeKind` anywhere under `Kaisola/`).
- The only way to run the Swift broker is env markers read by `KaisolaSessionBrokerCore/ShadowBrokerConfiguration.swift:10-11` (`KAISOLA_SWIFT_BROKER_SHADOW`, `KAISOLA_SWIFT_BROKER_FRESH_PTY`) plus argv `--shadow-config <path>` / `--fresh-pty-config <path>` (lines 121-136). Those markers appear **only in tests** (`SwiftSessionBrokerFreshEndToEndTests.swift:509-510`, `SwiftSessionBrokerConfigurationTests.swift:20,240,299,349,415-416`). No script, no plist, no UI, no `UserDefaults`/`@AppStorage` key.
- App broker env flags that do exist (for orientation on where a dev gate would fit): `KAISOLA_NATIVE_DIRECT_HELPER` (`Kaisola/Broker/BrokerBootstrapClient.swift:136`), `KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER` (146), `KAISOLA_STAGED_BROKER_HELPER` (244), `KAISOLA_NATIVE_BROKER_PROFILE` / `KAISOLA_NATIVE_USE_DEV_PROFILE` (`Kaisola/Broker/BrokerInfo.swift:198,203`).
- Launch is single-path: `BrokerStartupCoordinator.live()` (`Kaisola/Broker/BrokerStartupCoordinator.swift:405-413`) → `BrokerBootstrapClient(directOnly: true)` → `packageManifest()` → `verifyBundled` → `stagedPackage` → `directLaunch` with `["--launch", configURL]` (`BrokerBootstrapClient.swift:236-269`).

**Deeper blocker than the selector itself:** the Swift broker does not implement the production launch contract at all.
- It accepts only `--shadow-config` / `--fresh-pty-config` (ShadowBrokerConfiguration.swift:121-136), not `--launch <BrokerLaunchConfiguration path>`, which is what `BrokerBootstrapService` appends and what the plan specifies (migration-plan.md:192-194).
- `ShadowBrokerConfiguration` carries only `protocol, securityEpoch, implementationVersion, packageSchema, contentDigest, token, socketPath` (exact-key set at lines 13-21). `BrokerLaunchConfiguration` (`Shared/BrokerLaunchConfiguration.swift:11-33`) additionally carries `packageVersion, packageRoot, infoFile, lockFile, storageDir, logFile, maximumLiveTerminals, startedAt, version, smoke`.
- Grep for `infoFile|lockFile|storageDir|logFile|flock` across `KaisolaSessionBrokerCore/*.swift` returns **nothing**: the Swift broker never writes `generations/<digest>.json`, never takes the `.lock`, never writes a log. `BrokerInfoLocator` (`Kaisola/Broker/BrokerInfo.swift:177+`) and `BrokerGenerationRegistry` discover brokers exclusively through those files, and `BrokerStartupCoordinator.launchGeneration` (1217-1268) polls `locator.locateGenerationMetadata(contentDigest:)` until timeout. A Swift broker launched today would be undiscoverable and time out.
- `ShadowBrokerConfiguration` hard-requires `packageSchema == 2` (line 58), so it can never be driven by the current schema-1 launch file — the two halves are pinned to opposite schemas.
- Version reporting: `BrokerServer.init` default `serviceVersion: "kaisola-swift-shadow"` (`BrokerServer.swift:46`) and `packageVersion` is never passed (`BrokerServer.swift:60-67` → `ShadowBrokerServiceConfiguration`), so hello/status report `packageVersion: null` (`ShadowBrokerService.swift:1138,1171`) and a fake version string. Item 2's "app-to-broker version reporting" is unimplemented.

Also pinned against schema 2 on the launch side:
- `Shared/BrokerLaunchConfiguration.swift:50` — `packageSchema == BrokerWire.helperPackageSchema` (i.e. 1).
- `BrokerBootstrap/BrokerBootstrapService.swift:43-46` — `verify(root:requireSignatures:)` with no `schema2Expectation`; 63-67 — hardcoded `package.nodeExecutable` + `[package.brokerScript.path, "--launch", …]`, ignoring `launchPayload`.
- `Kaisola/Broker/BrokerBootstrapClient.swift:162-168` — gates on `configuration.packageSchema == bundled.manifest.schemaVersion` (fine) but `verifiedPackage()` (143-148) supplies no expectation.

## 4. What do the `KaisolaSessionBroker*` targets contain, and what tests cover them?

`native/KaisolaMac/KaisolaSessionBroker/` — 1 file, 83 lines:
- `KaisolaSessionBrokerMain.swift`: `@main`, `--pty-child` self-spawn dispatch (13-15), `TerminationSignalMonitor` for SIGTERM/SIGINT (48-83), `ShadowBrokerConfiguration.load()` → `BrokerServer.run()` (27-41), test hook `KAISOLA_SWIFT_BROKER_TEST_SIGNAL_READY` (22-24).

`native/KaisolaMac/KaisolaSessionBrokerCore/` — 13 files, 6,597 lines:
- `BrokerServer.swift` (565) socket lifecycle, stale-socket recovery, peer-UID check, pre-auth caps.
- `ShadowBrokerService.swift` (1,343) request routing, status/inventory (`runtimeKind: "swift"` at 1144, 1177).
- `FreshTerminalStore.swift` (1,482) fresh-mode terminal registry, subscribers, create/write/resize/kill/release.
- `DarwinPTYProcess.swift` (1,013) + `DarwinPTYChild.swift` (153) real PTY.
- `TerminalOutputBuffer.swift` (520) bounded retention, UTF-8 split repair, offsets.
- `BrokerConnection.swift` (456) single ordered outbound writer.
- `BrokerProtocolTypes.swift` (300), `BrokerAuthentication.swift` (184, feature lists at 82-99), `ShadowBrokerConfiguration.swift` (296), `BrokerRequestGate.swift` (94), `BrokerLog.swift` (108).

Tests (all in `native/KaisolaMac/KaisolaTests/`, all registered as contract tests in `scripts/native-test-select.cjs:19-26`; path mapping at 292-301):
- `SwiftSessionBrokerFreshWireTests.swift` (2,029) — wire parity.
- `SwiftSessionBrokerFreshStoreTests.swift` (1,030), `SwiftSessionBrokerShadowIntegrationTests.swift` (769), `SwiftSessionBrokerFreshEndToEndTests.swift` (742), `SwiftSessionBrokerConfigurationTests.swift` (636), `SwiftSessionBrokerCoreTests.swift` (540), `SwiftSessionBrokerDarwinPTYTests.swift` (428), `SwiftSessionBrokerOutputTests.swift` (382).
- Packaging side: `BrokerHelperPackageTests.swift` (765), `BrokerLaunchConfigurationTests.swift` (210), `tests/node/nativeBrokerPackage.test.cjs`.

Not covered anywhere: launching the Swift broker through `BrokerBootstrapService`, generation-metadata publication, staged schema-2 package produced by the real packager (only synthetic fixtures), app-side selection.

## 5. What PR #830 completed vs remaining-work item 1

PR #830 = merge `b6e00c126`, branch `feat/swift-broker-live-output`, two commits:
- `7135a25e1` "feat(broker): stream ordered live output from the Swift broker" — touched `BrokerAuthentication.swift` (+27), `BrokerConnection.swift` (+216), `DarwinPTYProcess.swift` (+11), `FreshTerminalStore.swift` (+511), `ShadowBrokerService.swift` (+536), `TerminalOutputBuffer.swift` (+265), plus fresh wire/E2E/output tests (+1,407) and the remaining-work doc.
- `7c0d9706a` "fix(broker): answer terminal.create atomically and split primary reads" — create reply moved inside the output critical section; primary emissions split at ⅛ of the event-channel encoded cap so a 64 KiB PTY read is deliverable.

Completed: ordered `{type:'event'}` output frames, gapless snapshot→live, exit publication, bounded per-subscriber queues (Node clamps, 8-subscriber cap), forced snapshot-required marker with exact resubscribe cursor, truthful `terminal.unsubscribe`, close-by-instance-prefix, `terminal.history` paging. Documented at `docs/swift-session-broker-remaining-work.md:16-35`.

Still open under item 1 (`remaining-work.md:37-46`), none of it addressed by #830:
- `terminal:observer-activity` / `terminal.agentTurn` (no agent-turn tracking in fresh mode).
- `terminal-history-continuous-v1`, `terminal-attach-ack-v1` (restore-dependent).
- Observer coalescing (`terminal-observer-coalescing-v1` deliberately unadvertised).
- Exited record evicted by 64-record retention can drop a still-subscribed exited terminal.

Feature advertisement reflects this: `BrokerAuthentication.swift:92-99` `freshAdvertisedFeatures` = observe, history, observer-role, inventory, exit-status, observer-only-output. Missing vs Node: `brokerAdministrationFeature`, attach-ack, continuous history, rolling update, idempotency. Consequence for enablement: `BrokerControlClient.swift:1007-1010` rejects an administrator connection to a broker that does not advertise administration, and `1016-1021` rejects the sealed-legacy downgrade — so the coordinator's upgrade/retire lane cannot drive a Swift generation. Item 1's open bullets are therefore what blocks *default*, not what blocks a development-selected engine.

---

# Gap list, ordered for v0.1.125 ("arm64 Swift PTY engine behind explicit development selection; Node stays stable current")

**G1 — Swift broker cannot answer the production launch contract.** *(largest; everything else is packaging around it)*
`KaisolaSessionBroker/KaisolaSessionBrokerMain.swift:27-41` + `KaisolaSessionBrokerCore/ShadowBrokerConfiguration.swift:109-175`.
Add a third argv shape `--launch <path>` that decodes the full `BrokerLaunchConfiguration` field set (`Shared/BrokerLaunchConfiguration.swift:11-33`) under the same private-file checks already in `readPrivateConfiguration` (187-247), gated by a new env marker (e.g. `KAISOLA_SWIFT_BROKER_LAUNCH=1`) so an ordinary invocation still cannot enter it. Relax the `packageSchema == 2` hard requirement at line 58 into "2 for `--fresh-pty-config`, `supportedHelperPackageSchemas` for `--launch`", or carry the schema through as data. Then publish generation metadata: write `infoFile` atomically with the `BrokerInfo` key set (`Kaisola/Broker/BrokerInfo.swift:6-23`: `protocol, securityEpoch, implementationVersion, packageSchema, packageVersion, contentDigest, pid, socketPath, token, startedAt, version`), take `lockFile` `O_CREAT|O_EXCL` 0600 with the pid, and unlink both on shutdown — mirroring `runtime/node-broker/session-broker.cjs:902,967-968,1027-1063`. Feed `packageVersion` and `version` from the launch file into `ShadowBrokerServiceConfiguration` (`BrokerServer.swift:60-67`), replacing the `"kaisola-swift-shadow"` default at `BrokerServer.swift:46` — this is item 2's "app-to-broker version reporting".

**G2 — packager cannot emit a schema-2 package.**
`scripts/native-broker-package.cjs:413-502,504-523`. Add a native staging branch: new args `--native-broker <path> --app-release-version <v> --app-release-build <b> [--launch-argument <s>]`; when present, skip the Node/node-pty/SDK copies entirely, copy the executable to `bin/kaisola-session-broker` mode 0755, and emit `{schemaVersion:2, packageVersion, appRelease, brokerImplementationVersion, brokerProtocol, launch:{kind:'native', executable:'bin/kaisola-session-broker', arguments:[]}}`. `roleFor` (202), `createManifest` (276-297), `contentDigestV2`, `validateNativeV2Manifest` and `signNestedCode` already handle the rest unchanged. Requires a second policy source: either `package-policy.json` grows a `native` block or add `native/KaisolaMac/BrokerHelper/native-package-policy.json` with `schemaVersion: 2` + `appRelease`, selected by a `--policy` flag (today `policyFile` is a module constant at line 11).

**G3 — the binary is not in the bundle.**
`native/KaisolaMac/project.yml`: add `KaisolaSessionBroker` to the `Kaisola` target's `dependencies` (119-129) with `embed: false, link: false`, and extend the post-build script (180-216) with a second `native-broker-package.cjs` invocation writing `Resources/BrokerSessionHelper` (a distinct directory — never inside `BrokerHelper`, which is digest-sealed) from `${BUILT_PRODUCTS_DIR}/KaisolaSessionBroker`, passing `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` as the appRelease pair, gated on `Release|LocalRelease|KAISOLA_PACKAGE_BROKER_HELPER=1` like the existing block. Invert/rescope `SwiftSessionBrokerConfigurationTests.swift:212-225` to assert the executable appears only at `Contents/Resources/BrokerSessionHelper/bin/kaisola-session-broker` and nowhere else.

**G4 — no second package root / catalog.**
`Shared/BrokerHelperPackage.swift:203-208` (`bundledRoot` hardcodes `BrokerHelper`) and `210-215` (`verifyBundled` passes no `schema2Expectation`). Minimum for v0.1.125: add `bundledNativeRoot(bundle:)` → `Resources/BrokerSessionHelper` and a `verifyBundledNative(bundle:requireSignatures:expectation:)` that builds the `BrokerHelperPackageExpectation` (148-152) from `Bundle.main` `CFBundleShortVersionString`/`CFBundleVersion`. Leave `UsageCenter.swift:1677,1732` and `CustomAdapterContainment.swift:169` pointed at the untouched Node root — that keeps usage/ACP working without building the full catalog from migration-plan.md:211-231, which can wait for Phase 5.

**G5 — no selector.**
`Kaisola/Broker/BrokerStartupCoordinator.swift:405-413` (`live()`) and `Kaisola/Broker/BrokerBootstrapClient.swift:118-148`. Add an explicit development gate read once from the environment (e.g. `KAISOLA_SESSION_BROKER_RUNTIME=swift`, defaulting to `node`), threaded into `BrokerBootstrapClient` as a stored `runtime` alongside the existing `directOnly` (116), selecting which bundled root `verifiedPackage()` verifies. Everything downstream (`writeLaunchConfiguration` at `BrokerStartupCoordinator.swift:1358-1404`) is already manifest-driven and needs no change — it copies `package.schemaVersion` into `packageSchema` (1381) and derives `packageRoot` from `contentDigest`. Do not add UI; an env selector satisfies "explicit development selection" and cannot be reached by an ordinary user launch. Rollback to Node is then "unset the variable", and each runtime gets a distinct `contentDigest`, so the digest-addressed generation directories, sockets, and registry entries never collide.

**G6 — launch-path schema pins.**
Three one-line-class changes, all currently deliberate: `Shared/BrokerLaunchConfiguration.swift:50` (`packageSchema == BrokerWire.helperPackageSchema` → `BrokerWire.supportedHelperPackageSchemas.contains(packageSchema)`); `BrokerBootstrap/BrokerBootstrapService.swift:43-46` (pass a `schema2Expectation` derived from the launch file's `packageVersion` + a new appRelease pair, or from the sealed bundle); `BrokerBootstrap/BrokerBootstrapService.swift:63-67` (switch on `package.launchPayload` — `.node` keeps `[script, "--launch", path]`, `.native` becomes `arguments + ["--launch", path]` per migration-plan.md:192-194). Leave `BrokerWire.helperPackageSchema` (`BrokerWire.swift:20`) aliased to 1 so nothing else silently flips. Extend `BrokerLaunchConfigurationTests.swift` (210 lines) with a schema-2 accept case and a schema-2-with-Node-payload reject.

**G7 — release preflight and helper probe are schema-1 only.**
`scripts/native-release-preflight.cjs:265-280` requires `bin/node`, `bin/kaisola-broker-bootstrap`, `manifest.node.architectures`, and `manifest.schemaVersion !== 1` fails. `scripts/native-broker-helper-probe.cjs:362-363` dereferences `manifest.node.version` and line 227 launches through `bin/kaisola-broker-bootstrap`. For v0.1.125 the cheapest correct move: keep both pointed at the unchanged Node `BrokerHelper` (still the shipping current), and add a *separate* verification of the native root — `native-broker-package.cjs --verify <BrokerSessionHelper> --require-signatures` plus `requireExactArchitectures` on `bin/kaisola-session-broker` (`EXPECTED_ARCHITECTURES` is already `['arm64']`, line 12) — reported under a new `helper.native` block in the preflight receipt (335-345). A native equivalent of the probe's full PTY continuity run should follow in item 3 (reliability soak), not here.

**G8 — distribution signing does not know about a second root.**
`scripts/native-distribution-sign.cjs:46-48` (required-paths list) and `64-91` (`resealBrokerHelper` reseals exactly one directory with `BrokerHelper.entitlements`). Add a parallel reseal for `BrokerSessionHelper` **without** an entitlements argument (the Swift broker must not inherit `allow-jit` / `allow-unsigned-executable-memory`); `signNestedCode` already applies `--options runtime --timestamp` and only entitles `bin/node` (`native-broker-package.cjs:405-406`). Note the ordering constraint: resealing rewrites signatures, so the manifest must be regenerated or verified after signing, exactly as `stagePackage` does at 480-493.

**G9 — CI does not build or check the new artifact.**
`.github/workflows/release-candidate.yml:154-171` builds `-scheme Kaisola` only; add the broker target to the app's dependency graph (G3) so it builds implicitly, then extend the verify step at 178-193. `scripts/native-test-select.cjs:292-301` already routes `KaisolaSessionBroker*` file changes to the contract lane, so test selection needs nothing.

**G10 — do not attempt default enablement in v0.1.125.**
Blocked by item 1's open bullets (`remaining-work.md:37-46`) plus the administration-feature gate at `Kaisola/Broker/BrokerControlClient.swift:1007-1021` and the absent attach-ack/continuous-history features (`BrokerAuthentication.swift:92-99`). Node must remain the default `packageManifest()` result; the selector in G5 is the whole of item 2's "explicit opt-in selector and rollback" that is safe to ship now.