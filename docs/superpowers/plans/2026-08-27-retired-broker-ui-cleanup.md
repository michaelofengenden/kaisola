# Retired broker UI cleanup implementation plan

> **For Michael:** Execute this plan with the test-driven-development workflow. Keep the compatibility protocol types and the teardown migration; remove only shipping presentation and recovery behavior that assumes a detached terminal broker.

**Goal:** Kaisola must stop presenting a global terminal connection, Reconnect action, or broker-era recovery guidance now that terminals are owned by `InProcessTerminalService`.

**Architecture:** Preserve `AppModel.ConnectionState` where it still sequences startup and supports existing test doubles. Derive visible terminal state from per-terminal facts (`ended`, `isOwned`, and input capability), and make the footer/account menu independent of the connection facade. Keep ACP and Companion reconnection behavior unchanged.

**Tech stack:** Swift, SwiftUI, AppKit accessibility fixtures, XCTest, Markdown help.

---

## Task 1: Remove global connection controls from the footer and account menu

**Files:**

- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift`
- Modify: `native/KaisolaMac/KaisolaTests/NativePreviewSettingsTests.swift`

1. Under the existing green `NativePreviewSettingsTests`, perform a behavior-preserving extraction of the inline account-menu rows into a typed `ConnectionFooterPresentation` model and make the shipping menu render exclusively from that model. Add separate signed-in and signed-out characterization assertions for the current menu contract, including the signed-in Reconnect action, so the model and real wiring cannot drift apart during the behavior change.
2. Change the hand-written menu expectations to authentication, Settings, Usage, version, and Copy Diagnostics, with no global connection status or recovery action. Separately characterize the footer controls and prove the adjacent notifications button remains present and functional. Run `npm run native:test:focus -- NativePreviewSettingsTests` and confirm only the retired menu rows fail while the footer-control invariant stays green.
3. Remove `state` and `reload` from `ConnectionFooter` and its call sites. Remove the Reconnect section, connection warning/avatar, “Sessions Ready,” and the connection field from copied diagnostics.
4. Keep the full account name and existing authentication, Settings, Usage, version, notifications footer control, and diagnostics behavior unchanged.
5. Run `npm run native:test:focus -- NativePreviewSettingsTests` and `git diff --check`.
6. Commit as `fix(ui): remove the retired broker reconnect control`.

## Task 2: Make terminal status local to each terminal

**Files:**

- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift`
- Modify: `native/KaisolaMac/KaisolaTests/SessionPaneLayoutTests.swift`

1. Under the existing green `SessionPaneLayoutTests`, extract the current inline terminal-header presentation into a resolver and wire the real header exclusively through it. Characterize the current output before changing behavior.
2. Add table-driven expectations for ended, interactive owner, temporarily inactive owner, and observer-only/non-owner. The hand-written expected labels must depend on per-terminal facts and input authority, not `AppModel.ConnectionState`. Run `npm run native:test:focus -- SessionPaneLayoutTests` and confirm the current resolver fails those expectations.
3. Change the resolver and real header to the local terminal facts. Remove the global “Reconnecting…” capsule and every connection-state branch from terminal-pane presentation.
4. Run `npm run native:test:focus -- SessionPaneLayoutTests` and `git diff --check`.
5. Commit as `fix(terminal): describe each terminal without broker state`.

## Task 3: Replace stale recovery guidance and user-visible broker errors

**Files:**

- Modify: `native/KaisolaMac/Kaisola/Features/Onboarding/OnboardingView.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/NewSessionChooserView.swift`
- Modify: `native/KaisolaMac/Kaisola/Features/Sessions/NativeTerminalSurface.swift`
- Modify: `native/KaisolaMac/Kaisola/App/AppModel.swift`
- Modify: `native/KaisolaMac/Kaisola/Broker/BrokerModels.swift`
- Modify: `native/KaisolaMac/KaisolaTests/OnboardingStateTests.swift`
- Modify: `native/KaisolaMac/KaisolaTests/NewSessionChooserTests.swift`
- Modify: `native/KaisolaMac/KaisolaTests/AppModelReconnectTests.swift`
- Modify: `native/KaisolaMac/KaisolaTests/BrokerModelsTests.swift`
- Modify: `native/KaisolaMac/KaisolaTests/NativeTerminalInteractionTests.swift`

1. Update or add one failing behavior assertion per affected state: no project selected, terminal startup in progress, a locally owned terminal is temporarily inactive, another window/Companion owns input, and an in-process terminal operation fails. Test temporary recovery and genuine observer-only authority separately in `NativeTerminalInteractionTests`.
2. Run `npm run native:test:focus -- OnboardingStateTests NewSessionChooserTests AppModelReconnectTests BrokerModelsTests NativeTerminalInteractionTests` and confirm each failure is the retired recovery guidance, not a test setup error.
3. Replace the copy with current facts: choose a project, terminals are preparing, input returns automatically, or another window/Companion controls input. Rename user-visible “session service” and socket-era errors to terminal-engine or operation-specific language.
4. Cover all audited shipping call sites, including empty-workspace view-only guidance, “input reconnects,” saved-session disconnection, “Terminal connection is recovering,” stale-connection Reload instructions, and the terminal-observer fallback error.
5. Do not rename internal `Broker*` types or remove reconnect logic for ACP/Companion. Preserve `AppModel`'s ten-second per-terminal automatic ownership recovery and make no promise stronger than that behavior.
6. Run `npm run native:test:focus -- OnboardingStateTests NewSessionChooserTests AppModelReconnectTests BrokerModelsTests NativeTerminalInteractionTests` and `git diff --check`.
7. Commit as `fix(copy): remove broker-era recovery guidance`.

## Task 4: Correct Help and verify the shipping surface

**Files:**

- Modify: `docs/user-guide.md`
- Protected, do not modify: `native/KaisolaMac/Kaisola/App/BrokerTeardownMigration.swift`

1. Rewrite the live Help guide so it says terminals end with Kaisola, session records retain their working folders, and fresh shells reopen on relaunch. Remove Connected/Reconnect, Login Item, detached helper, and “terminal processes survive quit/update” claims.
2. Leave already-marked historical design documents and `BrokerTeardownMigration` unchanged.
3. Search shipping Swift and live Help for user-visible `Reconnect`, `reconnect first`, `input reconnects`, `connection is recovering`, `isn't connected`, `stale connection`, `Reload to retry`, `session service`, `visible connection state`, `view-only`, Login Item/session-helper guidance, and terminal-survives-quit claims. Classify every remaining hit; ACP, Companion, and per-terminal ownership recovery are valid.
4. Run the selected native tests, then run the full Node suite with `npm run test:node`. Run the full native XCTest suite with:
   ```sh
   /usr/bin/xcodebuild \
     -project native/KaisolaMac/KaisolaMac.xcodeproj \
     -scheme Kaisola \
     -configuration Debug \
     -derivedDataPath /Users/michaelofengenden/Library/Developer/Xcode/DerivedData/KaisolaMac-almkjywkkvzvyddgvqosfhsfbaqv \
     -destination "platform=macOS,arch=$(uname -m)" \
     -disableAutomaticPackageResolution \
     -onlyUsePackageVersionsFromResolvedFile \
     -skipPackageUpdates \
     ONLY_ACTIVE_ARCH=YES \
     ARCHS="$(uname -m)" \
     SWIFT_COMPILATION_MODE=incremental \
     COMPILER_INDEX_STORE_ENABLE=NO \
     BUILD_ACTIVE_RESOURCES_ONLY=YES \
     KAISOLA_PACKAGE_BROKER_HELPER=0 \
     test
   ```
5. Exercise the account-menu model and terminal-header resolver through their real production wiring in focused tests. Inspect the rendered menu with AppKit accessibility in an isolated fixture if the existing harness can expose it without adding a new visual surface. Verify Help as Markdown and through its external Help route; do not claim an unavailable screenshot fixture ran.
6. Request independent code review, fix confirmed findings, rerun verification, then open a PR. Do not replace the installed app while it owns live ACP, PTY, or agent processes.
