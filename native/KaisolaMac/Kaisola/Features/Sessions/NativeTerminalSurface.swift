import AppKit
import SwiftTerm
import SwiftUI

extension Notification.Name {
    /// Posted when a `file:` OSC 8 link is activated in a terminal surface, so
    /// the shell can open it in Kaisola's built-in file preview instead of
    /// Finder. `userInfo["url"]` is the file `URL`; `userInfo["line"]` is an
    /// optional `Int` line target parsed from a trailing `:LINE` citation.
    static let kaisolaOpenFileLink = Notification.Name("kaisolaOpenFileLink")
}

/// Redraws only a terminal card when its document advances. The parent shell
/// passes stable configuration and closures, while the high-frequency document
/// lives in a dedicated observable object that does not invalidate the rest of
/// the IDE chrome.
struct TerminalSurfaceFeedView<Content: View>: View {
    @ObservedObject var feed: TerminalSurfaceFeed
    private let content: (TerminalDocument) -> Content

    init(
        feed: TerminalSurfaceFeed,
        @ViewBuilder content: @escaping (TerminalDocument) -> Content
    ) {
        self.feed = feed
        self.content = content
    }

    var body: some View {
        content(feed.document)
    }
}

struct NativeTerminalSurface: NSViewRepresentable {
    /// A restrained increase over SwiftTerm's default metrics keeps dense shell
    /// output readable while preserving correct cursor, selection, and resize
    /// geometry inside the terminal renderer itself.
    static let comfortableLineSpacing: CGFloat = CGFloat(NativePreviewSettings.terminalLineSpacingDefault)

    let output: String
    let streamEpoch: String?
    let endOffset: Int64?
    var scrollback: TerminalScrollback? = nil
    var surfaceDelta: TerminalSurfaceDelta? = nil
    /// Initial directory used to resolve the relative file citations emitted
    /// by agent CLIs. OSC 7 updates replace it as the shell changes directory.
    var workingDirectory: URL? = nil
    // Input exists only for sessions the native app owns; observed sessions
    // keep the sealed read-only view whose send path is compiled away.
    var isOwned: Bool = false
    /// Terminal font size (⌘+/⌘−/⌘0 via NativePreviewSettings).
    var fontSize: Double = NativePreviewSettings.terminalFontDefault
    var fontFamily: String = TerminalFontOptions.systemMonoSentinel
    var fontWeight: String = "regular"
    var lineSpacing: Double = NativePreviewSettings.terminalLineSpacingDefault
    /// Scrollback depth in lines. See `NativePreviewSettings.terminalScrollbackLines`.
    var scrollbackLines: Int = NativePreviewSettings.terminalScrollbackDefault
    /// Whether OSC 52 may write the system clipboard from this surface
    /// (Settings > Terminal, off by default).
    var allowsClipboardWrite: Bool = false
    /// Native macOS Terminal by default; Kaisola keeps Electron palette parity.
    var paletteMode: TerminalPaletteMode = .native
    /// Paper palette on light appearances, ink on dark.
    var lightSurface: Bool = false
    /// Identity used to retain this terminal's parsed view across the SwiftUI
    /// teardown a project tab switch causes. Nil disables retention.
    var sessionID: String? = nil
    /// Launch command of the agent CLI running here (`claude`, `codex`, …), so
    /// a dropped image can use the attachment syntax that CLI understands.
    var agentLaunchCommand: String? = nil
    var onInput: ((String) -> Void)? = nil
    var onResize: ((_ columns: Int, _ rows: Int) -> Void)? = nil
    /// Live OSC title changes (auto-naming owned sessions).
    var onTitleChange: ((String) -> Void)? = nil
    /// Live BEL from the PTY. Historical replay is intentionally suppressed by
    /// the coordinator so an old bell never resurrects an attention alert.
    var onBell: (() -> Void)? = nil
    /// Invoked when the user reaches the oldest row SwiftTerm can render and
    /// deliberately scrolls upward again. The host opens the immutable broker
    /// transcript from there; historical ANSI is never prepended into the live
    /// parser or allowed to mutate the PTY screen.
    var onHistoryBoundary: (() -> Void)? = nil
    /// AppKit gave this surface keyboard focus (a click into the grid, or a
    /// programmatic first-responder move). The shell uses it to keep the pane
    /// focus ring truthful about where typing will land.
    var onKeyboardFocus: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        // Claim the retained pair here, before `makeNSView`, so the view and the
        // render state that describes it can never be mismatched. See
        // `TerminalSurfaceCache` for why they must move together.
        if let sessionID,
           let claimed = TerminalSurfaceCache.shared.claim(sessionID: sessionID, isOwned: isOwned) {
            claimed.coordinator.reusedView = claimed.view
            return claimed.coordinator
        }
        return Coordinator()
    }

    static func dismantleNSView(_ view: ReadOnlyTerminalView, coordinator: Coordinator) {
        // SwiftUI has removed the card (a project switch, a closed pane). Park
        // the view and its render state so returning to this project re-attaches
        // the already-parsed terminal instead of replaying the transcript.
        guard let sessionID = coordinator.retainedSessionID else { return }
        coordinator.prepareForRetention()
        view.onHistoryBoundary = nil
        // Parked surfaces must not retain the shell (and its AppModel) through
        // a focus callback that can no longer describe anything on screen.
        view.onKeyboardFocus = nil
        TerminalSurfaceCache.shared.store(
            sessionID: sessionID,
            view: view,
            coordinator: coordinator
        )
    }

    func makeNSView(context: Context) -> ReadOnlyTerminalView {
        let font = TerminalFontOptions.resolveFont(family: fontFamily, size: fontSize, weightRaw: fontWeight)
        context.coordinator.retainedSessionID = sessionID
        if let reused = context.coordinator.reusedView {
            context.coordinator.reusedView = nil
            configureReusedView(reused, context: context)
            return reused
        }
        let view: ReadOnlyTerminalView = isOwned
            ? OwnedTerminalView(frame: .zero, font: font)
            : ReadOnlyTerminalView(frame: .zero, font: font)
        // SwiftTerm's overlay scroller follows the system auto-hide policy and
        // can therefore make a scrollable terminal look as though it has no
        // scrollbar. Its legacy style is still a native NSScroller, but keeps
        // the track visible like the standalone Terminal app.
        view.scrollerStyle = .legacy
        view.lineSpacing = CGFloat(NativePreviewSettings.clampedTerminalLineSpacing(lineSpacing))
        // SwiftTerm's default is 500 lines — about a dozen screens — which is
        // why scrolling up appeared to just stop. The Electron terminal this
        // replaced ran 5000. Applied once here: SwiftTerm's resize, font, theme,
        // and reset paths all rebuild from `options.scrollback`, which this
        // updates, so it survives for the life of the view.
        view.changeScrollback(NativePreviewSettings.clampedTerminalScrollback(scrollbackLines))
        view.configureAdvertisedGraphicsCapabilities()
        view.configureSemanticPromptMarks()
        view.configureJumpToLiveBottomAffordance()
        view.terminalDelegate = context.coordinator
        view.configureTerminalTheme(light: lightSurface, mode: paletteMode)
        view.allowMouseReporting = isOwned
        view.configureLinkInteraction()
        Self.configureKeyboardInput(on: view)
        view.agentLaunchCommand = agentLaunchCommand
        view.onHistoryBoundary = onHistoryBoundary
        view.paneSessionID = sessionID
        view.onKeyboardFocus = onKeyboardFocus
        view.setAccessibilityLabel(isOwned ? "Terminal" : "Read-only terminal output")
        TerminalScrollGestureMonitor.install()
        let coordinator = context.coordinator
        view.onUsableLayout = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.flushPendingInitialRender(to: view)
            coordinator.repinAfterLayout(view)
            coordinator.synchronizeCurrentGeometry(from: view)
        }
        context.coordinator.onInput = onInput
        context.coordinator.setResizeHandler(onResize, synchronizing: view)
        context.coordinator.onTitleChange = onTitleChange
        context.coordinator.onBell = onBell
        context.coordinator.allowsClipboardWrite = allowsClipboardWrite
        context.coordinator.setBaseWorkingDirectory(workingDirectory)
        context.coordinator.apply(
            scrollback: scrollback ?? TerminalScrollback(output),
            epoch: streamEpoch,
            endOffset: endOffset,
            surfaceDelta: surfaceDelta,
            to: view
        )
        return view
    }

    /// Re-attach a retained view. Only the bindings that can have changed while
    /// it was parked are refreshed — crucially the transcript is NOT re-fed,
    /// because the coordinator that came back with it already records exactly
    /// which bytes this view holds. `updateNSView` runs immediately after and
    /// applies any delta that arrived in the meantime.
    private func configureReusedView(_ view: ReadOnlyTerminalView, context: Context) {
        let coordinator = context.coordinator
        view.scrollerStyle = .legacy
        view.terminalDelegate = coordinator
        view.configureTerminalTheme(light: lightSurface, mode: paletteMode)
        view.allowMouseReporting = isOwned
        Self.configureKeyboardInput(on: view)
        view.agentLaunchCommand = agentLaunchCommand
        view.onHistoryBoundary = onHistoryBoundary
        view.paneSessionID = sessionID
        view.onKeyboardFocus = onKeyboardFocus
        view.configureAdvertisedGraphicsCapabilities()
        view.configureSemanticPromptMarks()
        view.configureJumpToLiveBottomAffordance()
        view.onUsableLayout = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.flushPendingInitialRender(to: view)
            coordinator.repinAfterLayout(view)
            coordinator.synchronizeCurrentGeometry(from: view)
        }
        coordinator.onInput = onInput
        coordinator.setResizeHandler(onResize, synchronizing: view)
        coordinator.onTitleChange = onTitleChange
        coordinator.onBell = onBell
        coordinator.allowsClipboardWrite = allowsClipboardWrite
        coordinator.setBaseWorkingDirectory(workingDirectory)
    }

    func updateNSView(_ view: ReadOnlyTerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.setResizeHandler(onResize, synchronizing: view)
        context.coordinator.onTitleChange = onTitleChange
        context.coordinator.onBell = onBell
        context.coordinator.allowsClipboardWrite = allowsClipboardWrite
        context.coordinator.setBaseWorkingDirectory(workingDirectory)
        view.agentLaunchCommand = agentLaunchCommand
        view.onHistoryBoundary = onHistoryBoundary
        view.paneSessionID = sessionID
        view.onKeyboardFocus = onKeyboardFocus
        let desired = TerminalFontOptions.resolveFont(family: fontFamily, size: fontSize, weightRaw: fontWeight)
        let desiredLineSpacing = CGFloat(NativePreviewSettings.clampedTerminalLineSpacing(lineSpacing))
        if abs(view.lineSpacing - desiredLineSpacing) > 0.001 {
            view.lineSpacing = desiredLineSpacing
        }
        let desiredScrollback = NativePreviewSettings.clampedTerminalScrollback(scrollbackLines)
        if view.getTerminal().options.scrollback != desiredScrollback {
            view.changeScrollback(desiredScrollback)
        }
        if view.font.fontName != desired.fontName || abs(view.font.pointSize - desired.pointSize) > 0.1 {
            view.font = desired
        }
        if view.themeKey != Self.themeKey(light: lightSurface, mode: paletteMode) {
            view.configureTerminalTheme(light: lightSurface, mode: paletteMode)
        }
        context.coordinator.apply(
            scrollback: scrollback ?? TerminalScrollback(output),
            epoch: streamEpoch,
            endOffset: endOffset,
            surfaceDelta: surfaceDelta,
            to: view
        )
    }

    private static func themeKey(light: Bool, mode: TerminalPaletteMode) -> String {
        "\(mode.rawValue):\(light ? "light" : "dark")"
    }

    /// Keep Option available to the active keyboard layout. Hard-wiring it to
    /// Meta turns international-layout characters such as @, brackets, braces,
    /// pipes, tildes, and dead-key accents into escape sequences. A future user
    /// preference may opt into Meta explicitly; the safe native default is off.
    @MainActor
    static func configureKeyboardInput(on view: ReadOnlyTerminalView) {
        view.optionAsMetaKey = false
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var onInput: ((String) -> Void)?
        var onResize: ((_ columns: Int, _ rows: Int) -> Void)?
        var onTitleChange: ((String) -> Void)?
        var onBell: (() -> Void)?
        /// Mirrors Settings > Terminal. See `TerminalClipboardWriteRequest`.
        var allowsClipboardWrite = false
        /// Injected so a test can prove the OSC 52 gate without writing to the
        /// developer's real pasteboard.
        var clipboard: NSPasteboard = .general
        static let bellNotificationCooldown: TimeInterval = 2
        private var lastDeliveredBellAt: TimeInterval?
        /// SwiftTerm reports OSC 0/2 titles synchronously while `updateNSView`
        /// feeds a render delta. Agent TUIs can emit these on every repaint;
        /// forwarding them immediately lets AppModel publish while SwiftUI is
        /// still evaluating the representable, which SwiftUI explicitly marks
        /// as undefined behavior. Keep only the newest title in the current
        /// turn and deliver it after the view update has unwound.
        private var pendingTitleChange: String?
        private var titleChangeDeliveryScheduled = false
        private static let titleChangeDebounceInterval: TimeInterval = 0.1
        private(set) var workingDirectory: URL?
        private var baseWorkingDirectory: URL?
        private var renderedEpoch: String?
        private var renderedStartOffset: Int64?
        private var renderedEndOffset: Int64?
        private var hasRendered = false
        private(set) var directDeltaApplyCount = 0
        private(set) var scrollbackFlattenCount = 0
        private var resourceFixtureReceiptEmitted = false
        /// Large retained transcripts are replayed a slice per main-actor turn
        /// instead of monopolizing the click that mounted the pane. SwiftTerm's
        /// parser is streaming, so escape sequences may safely span slices.
        static let progressiveReplayThresholdBytes = 256 * 1_024
        static let progressiveReplayChunkCharacters = 32 * 1_024
        private var progressiveReplayTask: Task<Void, Never>?
        private(set) var isProgressivelyReplaying = false
        private var queuedDuringProgressiveReplay: (
            output: String,
            epoch: String?,
            endOffset: Int64?
        )?
        private var queuedPagedDuringProgressiveReplay: (
            scrollback: TerminalScrollback,
            epoch: String?,
            endOffset: Int64?,
            surfaceDelta: TerminalSurfaceDelta?
        )?

        /// The standalone resource launcher starts its warm-up only after this
        /// receipt proves the exact page-native transcript reached SwiftTerm.
        /// Ordinary visual fixtures and every production session compile this
        /// path but never opt into it.
        @MainActor
        private func emitResourceFixtureReceiptIfRequested(
            scrollback: TerminalScrollback,
            endOffset: Int64?,
            view: ReadOnlyTerminalView
        ) {
            guard !resourceFixtureReceiptEmitted else { return }
            let environment = ProcessInfo.processInfo.environment
            guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
                  environment["KAISOLA_NATIVE_RESOURCE_RECEIPT"] == "1",
                  let expectedBytes = environment["KAISOLA_NATIVE_RESOURCE_SCROLLBACK_BYTES"]
                    .flatMap(Int.init),
                  expectedBytes > 0 else { return }
            resourceFixtureReceiptEmitted = true
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "ok": scrollback.byteCount == expectedBytes,
                "expectedBytes": expectedBytes,
                "actualBytes": scrollback.byteCount,
                "pages": scrollback.pages.count,
                "pageLimitBytes": TerminalScrollback.targetPageBytes,
                "mutableTailLimitBytes": TerminalScrollback.mutableTailBytes,
                "scrollbackLines": view.getTerminal().options.scrollback,
                "renderedEndOffset": endOffset ?? -1,
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            ) else { return }
            FileHandle.standardOutput.write(
                Data("KAISOLA_NATIVE_RESOURCE_FIXTURE_READY=".utf8) + data + Data("\n".utf8)
            )
        }

        /// SwiftUI creates NSViewRepresentables at `.zero` before assigning the
        /// real pane bounds. Replaying ANSI history at that placeholder width
        /// makes SwiftTerm wrap at the wrong column count, then reflow on zoom or
        /// tab return (the visible doubled-line/blank-line artifact). Keep only
        /// the newest snapshot until the terminal has usable geometry.
        private var pendingInitialRender: (output: String, epoch: String?, endOffset: Int64?)?
        private var pendingPagedInitialRender: (
            scrollback: TerminalScrollback,
            epoch: String?,
            endOffset: Int64?,
            surfaceDelta: TerminalSurfaceDelta?
        )?
        var isAwaitingInitialLayout: Bool {
            pendingInitialRender != nil || pendingPagedInitialRender != nil
        }
        /// Reconstructing a terminal view means feeding retained PTY history
        /// through SwiftTerm again. That history can contain cursor/color/device
        /// queries. SwiftTerm correctly answers those queries through `send`,
        /// but answering a historical query a second time injects replies such
        /// as `ESC[1;1R` and `OSC 11;rgb:...` into the *live* shell. The shell is
        /// usually back at a prompt by then, so the replies become visible input
        /// and corrupt the next command. Suppress only reconstruction replies;
        /// fresh incremental output still receives normal terminal responses.
        private var suppressReplayReplies = false
        /// Last geometry delivered by either SwiftTerm's delegate or an
        /// explicit usable-layout reconciliation. Layout can fire repeatedly
        /// without a grid change; the host should see one level transition,
        /// not a stream of duplicate resize requests.
        private var lastReportedColumns: Int?
        private var lastReportedRows: Int?

        deinit {
            progressiveReplayTask?.cancel()
        }

        /// Parked surfaces must not retain an AppModel through their closures.
        /// Clearing the resize handler also makes the next owned reattachment
        /// an explicit activation, which force-synchronizes current geometry.
        func prepareForRetention() {
            onInput = nil
            onResize = nil
            onTitleChange = nil
            onBell = nil
        }

        /// BEL-heavy TUIs may emit several bytes for one logical prompt. Keep
        /// the first signal immediate and collapse the repaint burst; the
        /// AttentionCenter additionally keeps one live entry per session.
        static func shouldDeliverBell(
            lastDeliveredAt: TimeInterval?,
            now: TimeInterval
        ) -> Bool {
            guard now.isFinite else { return false }
            guard let lastDeliveredAt, lastDeliveredAt.isFinite else { return true }
            return now < lastDeliveredAt
                || now - lastDeliveredAt >= bellNotificationCooldown
        }

        /// Bind the current controller capability. A nil-to-live transition is
        /// a state-reconciliation boundary, not merely another SwiftUI update:
        /// the PTY may have changed while this renderer was observed or parked.
        func setResizeHandler(
            _ handler: ((_ columns: Int, _ rows: Int) -> Void)?,
            synchronizing view: ReadOnlyTerminalView
        ) {
            let activated = onResize == nil && handler != nil
            onResize = handler
            if activated {
                synchronizeCurrentGeometry(from: view, force: true)
            }
        }

        /// Reconcile the renderer's level-triggered geometry after AppKit has
        /// assigned usable bounds. SwiftTerm normally emits `sizeChanged`, but
        /// it intentionally emits nothing when a cached view returns at the same
        /// pixel size; that is exactly when a remotely-resized PTY still needs a
        /// fresh authoritative desktop size.
        func synchronizeCurrentGeometry(
            from view: ReadOnlyTerminalView,
            force: Bool = false
        ) {
            guard view.hasUsableRenderGeometry else { return }
            let dimensions = view.getTerminal().getDims()
            reportGeometry(columns: dimensions.cols, rows: dimensions.rows, force: force)
        }

        private func reportGeometry(columns: Int, rows: Int, force: Bool = false) {
            guard columns > 0, rows > 0, let onResize else { return }
            guard force || lastReportedColumns != columns || lastReportedRows != rows else { return }
            lastReportedColumns = columns
            lastReportedRows = rows
            onResize(columns, rows)
        }

        /// Keep a shell-reported OSC 7 directory across ordinary SwiftUI
        /// updates. Reset only when the represented session's base directory
        /// actually changes (including switching a retained surface to a new
        /// session), otherwise every output frame would snap relative links
        /// back to the launch directory after the user ran `cd`.
        func setBaseWorkingDirectory(_ directory: URL?) {
            let normalized = directory?.standardizedFileURL
            guard normalized != baseWorkingDirectory else {
                if workingDirectory == nil { workingDirectory = normalized }
                return
            }
            baseWorkingDirectory = normalized
            workingDirectory = normalized
        }

        // Sticky-scroll pinning (Electron parity). While `userUnpinned` is false
        // the surface snaps back to the newest output after every feed so it
        // stays glued to live output across feeds/resizes/tab switches; only a
        // deliberate user scroll up flips it true, and scrolling back to the
        // bottom flips it back. `isFeeding` masks the scroll callbacks the
        // terminal emits synchronously while we feed (and while we snap to the
        // bottom) so output-driven scrolls are never mistaken for user intent.
        /// Set while a retained view is being handed from `makeCoordinator` to
        /// `makeNSView`, so the two always agree on which view this render state
        /// describes.
        var reusedView: ReadOnlyTerminalView?
        /// Session this coordinator's render state belongs to, so the pair can
        /// be parked under the right key on teardown.
        var retainedSessionID: String?

        private var userUnpinned = false
        private var isFeeding = false
        /// SwiftTerm returns exactly 1.0 at the live bottom and a ratio below it
        /// for every other row. Do not add an epsilon: with 20,000 retained rows,
        /// 0.999 still covers roughly the newest 20 rows and misclassifies a real
        /// light scroll as pinned.
        private static let pinnedThreshold = 1.0

        @MainActor
        func apply(
            scrollback: TerminalScrollback,
            epoch: String?,
            endOffset: Int64?,
            surfaceDelta: TerminalSurfaceDelta? = nil,
            to view: ReadOnlyTerminalView
        ) {
            view.updateAccessibilityValue(from: scrollback)
            if isProgressivelyReplaying {
                queuedPagedDuringProgressiveReplay = (
                    scrollback,
                    epoch,
                    endOffset,
                    surfaceDelta
                )
                return
            }
            if !hasRendered, !view.hasUsableRenderGeometry {
                pendingPagedInitialRender = (
                    scrollback,
                    epoch,
                    endOffset,
                    surfaceDelta
                )
                return
            }
            pendingPagedInitialRender = nil
            let startOffset = endOffset.map { $0 - Int64(scrollback.byteCount) }

            if !hasRendered {
                if scrollback.byteCount > Self.progressiveReplayThresholdBytes {
                    beginProgressiveReplay(
                        scrollback: scrollback,
                        epoch: epoch,
                        startOffset: startOffset,
                        endOffset: endOffset,
                        to: view
                    )
                    return
                }
                feed(pages: scrollback.pages, to: view, suppressReplies: true)
                renderedEpoch = epoch
                renderedStartOffset = startOffset
                renderedEndOffset = endOffset
                hasRendered = true
                return
            }

            if epoch == renderedEpoch, endOffset == renderedEndOffset {
                return
            }
            if let surfaceDelta,
               surfaceDelta.epoch == epoch,
               surfaceDelta.epoch == renderedEpoch,
               surfaceDelta.startOffset == renderedEndOffset,
               surfaceDelta.endOffset == endOffset {
                if !surfaceDelta.data.isEmpty {
                    feed(surfaceDelta.data, to: view, suppressReplies: false)
                }
                renderedStartOffset = endOffset.map { $0 - Int64(scrollback.byteCount) }
                renderedEndOffset = surfaceDelta.endOffset
                directDeltaApplyCount += 1
                return
            }

            if epoch == renderedEpoch,
               let oldEnd = renderedEndOffset,
               let newEnd = endOffset,
               let newStart = startOffset,
               newStart >= 0,
               oldEnd >= newStart,
               newEnd >= oldEnd,
               let suffix = scrollback.suffix(droppingUTF8Bytes: oldEnd - newStart),
               suffix.reduce(into: Int64(0), { $0 += Int64($1.utf8.count) }) == newEnd - oldEnd {
                feed(pages: suffix, to: view, suppressReplies: false)
                renderedStartOffset = newStart
                renderedEndOffset = newEnd
                return
            }

            if epoch != renderedEpoch || startOffset != renderedStartOffset || endOffset != renderedEndOffset {
                view.feed(text: "\u{1B}[?1049l")
                view.resetSemanticPromptMarks()
                view.getTerminal().resetToInitialState()
                userUnpinned = false
                hasRendered = false
                if scrollback.byteCount > Self.progressiveReplayThresholdBytes {
                    beginProgressiveReplay(
                        scrollback: scrollback,
                        epoch: epoch,
                        startOffset: startOffset,
                        endOffset: endOffset,
                        to: view
                    )
                    return
                }
                feed(pages: scrollback.pages, to: view, suppressReplies: true)
            }
            renderedEpoch = epoch
            renderedStartOffset = startOffset
            renderedEndOffset = endOffset
            hasRendered = true
        }

        @MainActor
        func apply(
            output: String,
            epoch: String?,
            endOffset: Int64?,
            surfaceDelta: TerminalSurfaceDelta? = nil,
            to view: ReadOnlyTerminalView
        ) {
            view.updateAccessibilityValue(from: output)
            if isProgressivelyReplaying {
                // Preserve only the newest immutable broker frame. Once the
                // historical replay finishes, ordinary offset reconciliation
                // appends exactly the bytes that arrived while it was running.
                queuedDuringProgressiveReplay = (output, epoch, endOffset)
                return
            }
            if !hasRendered, !view.hasUsableRenderGeometry {
                pendingInitialRender = (output, epoch, endOffset)
                return
            }
            pendingInitialRender = nil
            let outputBytes = Int64(output.utf8.count)
            let startOffset = endOffset.map { $0 - outputBytes }

            if !hasRendered {
                if output.utf8.count > Self.progressiveReplayThresholdBytes {
                    beginProgressiveReplay(
                        output: output,
                        epoch: epoch,
                        startOffset: startOffset,
                        endOffset: endOffset,
                        to: view
                    )
                    return
                }
                if !output.isEmpty { feed(output, to: view, suppressReplies: true) }
                renderedEpoch = epoch
                renderedStartOffset = startOffset
                renderedEndOffset = endOffset
                hasRendered = true
                return
            }

            // AppModel publishes the exact coalesced broker frame alongside
            // the retained reconstruction string. When our rendered cursor is
            // contiguous, feed that frame directly: no suffix search and no
            // scan through a document that may be tens of MiB long.
            if let surfaceDelta,
               surfaceDelta.epoch == epoch,
               surfaceDelta.epoch == renderedEpoch,
               surfaceDelta.startOffset == renderedEndOffset,
               surfaceDelta.endOffset == endOffset {
                if !surfaceDelta.data.isEmpty {
                    feed(surfaceDelta.data, to: view, suppressReplies: false)
                }
                renderedStartOffset = startOffset
                renderedEndOffset = surfaceDelta.endOffset
                directDeltaApplyCount += 1
                return
            }

            if epoch == renderedEpoch,
               let oldEnd = renderedEndOffset,
               let newEnd = endOffset,
               let newStart = startOffset,
               newStart >= 0,
               oldEnd >= newStart,
               newEnd >= oldEnd {
                if newEnd == oldEnd {
                    // A broker stream is immutable within an epoch. Equal byte
                    // bounds therefore mean SwiftTerm already has this view.
                    if newStart == renderedStartOffset { return }
                } else {
                    let bytesToSkip = oldEnd - newStart
                    if let suffix = outputSuffixBytes(output, droppingUTF8Bytes: bytesToSkip),
                       Int64(suffix.count) == newEnd - oldEnd {
                        feed(bytes: suffix, to: view, suppressReplies: false)
                        renderedStartOffset = newStart
                        renderedEndOffset = newEnd
                        return
                    }
                }
            }

            if epoch != renderedEpoch || startOffset != renderedStartOffset || endOffset != renderedEndOffset {
                // Leave the alternate screen before resetting. SwiftTerm's
                // `resetToInitialState` calls `activateNormalBuffer(clearAlt:
                // false)`, so the alt buffer keeps its old contents, and
                // `activateAltBuffer` only fills viewport rows when the buffer is
                // empty. Replaying a full-screen TUI's `ESC[?1049h` would
                // therefore re-enter a *stale* alt screen and paint over
                // leftovers instead of a blank one.
                view.feed(text: "\u{1B}[?1049l")
                view.resetSemanticPromptMarks()
                view.getTerminal().resetToInitialState()
                // A reset means a fresh stream state — effectively a remount. Any
                // prior scroll targeted the now-discarded scrollback, so re-pin to
                // live output (Electron parity: remounts follow the newest bytes).
                userUnpinned = false
                if !output.isEmpty { feed(output, to: view, suppressReplies: true) }
            }
            renderedEpoch = epoch
            renderedStartOffset = startOffset
            renderedEndOffset = endOffset
            hasRendered = true
        }

        /// Gives AppKit a chance to draw the newly opened card, then advances
        /// SwiftTerm in bounded pieces. This retains the complete transcript —
        /// there is no tail truncation or reduced terminal fidelity.
        @MainActor
        private func beginProgressiveReplay(
            output: String,
            epoch: String?,
            startOffset: Int64?,
            endOffset: Int64?,
            to view: ReadOnlyTerminalView
        ) {
            progressiveReplayTask?.cancel()
            isProgressivelyReplaying = true
            queuedDuringProgressiveReplay = nil
            progressiveReplayTask = Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard let self, let view, !Task.isCancelled else { return }

                var cursor = output.startIndex
                while cursor < output.endIndex, !Task.isCancelled {
                    let next = output.index(
                        cursor,
                        offsetBy: Self.progressiveReplayChunkCharacters,
                        limitedBy: output.endIndex
                    ) ?? output.endIndex
                    let isFinalChunk = next == output.endIndex
                    self.feed(
                        String(output[cursor..<next]),
                        to: view,
                        suppressReplies: true,
                        scrollAfter: isFinalChunk
                    )
                    cursor = next
                    if !isFinalChunk { await Task.yield() }
                }
                guard !Task.isCancelled else { return }

                self.renderedEpoch = epoch
                self.renderedStartOffset = startOffset
                self.renderedEndOffset = endOffset
                self.hasRendered = true
                self.isProgressivelyReplaying = false
                self.progressiveReplayTask = nil
                if let queued = self.queuedPagedDuringProgressiveReplay {
                    self.queuedPagedDuringProgressiveReplay = nil
                    self.queuedDuringProgressiveReplay = nil
                    self.apply(
                        scrollback: queued.scrollback,
                        epoch: queued.epoch,
                        endOffset: queued.endOffset,
                        surfaceDelta: queued.surfaceDelta,
                        to: view
                    )
                } else if let queued = self.queuedDuringProgressiveReplay {
                    self.queuedDuringProgressiveReplay = nil
                    self.apply(
                        output: queued.output,
                        epoch: queued.epoch,
                        endOffset: queued.endOffset,
                        to: view
                    )
                }
            }
        }

        /// Page-native reconstruction. No joined transcript is allocated;
        /// each page is split into the same cooperative SwiftTerm slices used
        /// by the legacy string compatibility path.
        @MainActor
        private func beginProgressiveReplay(
            scrollback: TerminalScrollback,
            epoch: String?,
            startOffset: Int64?,
            endOffset: Int64?,
            to view: ReadOnlyTerminalView
        ) {
            progressiveReplayTask?.cancel()
            isProgressivelyReplaying = true
            queuedPagedDuringProgressiveReplay = nil
            progressiveReplayTask = Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard let self, let view, !Task.isCancelled else { return }

                for (pageIndex, page) in scrollback.pages.enumerated() {
                    var cursor = page.startIndex
                    while cursor < page.endIndex, !Task.isCancelled {
                        let next = page.index(
                            cursor,
                            offsetBy: Self.progressiveReplayChunkCharacters,
                            limitedBy: page.endIndex
                        ) ?? page.endIndex
                        let isFinalChunk = pageIndex == scrollback.pages.count - 1
                            && next == page.endIndex
                        self.feed(
                            String(page[cursor..<next]),
                            to: view,
                            suppressReplies: true,
                            scrollAfter: isFinalChunk
                        )
                        cursor = next
                        if !isFinalChunk { await Task.yield() }
                    }
                }
                guard !Task.isCancelled else { return }

                self.renderedEpoch = epoch
                self.renderedStartOffset = startOffset
                self.renderedEndOffset = endOffset
                self.hasRendered = true
                self.isProgressivelyReplaying = false
                self.progressiveReplayTask = nil
                self.emitResourceFixtureReceiptIfRequested(
                    scrollback: scrollback,
                    endOffset: endOffset,
                    view: view
                )
                if let queued = self.queuedPagedDuringProgressiveReplay {
                    self.queuedPagedDuringProgressiveReplay = nil
                    self.apply(
                        scrollback: queued.scrollback,
                        epoch: queued.epoch,
                        endOffset: queued.endOffset,
                        surfaceDelta: queued.surfaceDelta,
                        to: view
                    )
                } else if let queued = self.queuedDuringProgressiveReplay {
                    self.queuedDuringProgressiveReplay = nil
                    self.apply(
                        output: queued.output,
                        epoch: queued.epoch,
                        endOffset: queued.endOffset,
                        to: view
                    )
                }
            }
        }

        /// Called by the terminal view's first real layout. It is intentionally
        /// idempotent because AppKit can lay out a view multiple times per frame.
        @MainActor
        func flushPendingInitialRender(to view: ReadOnlyTerminalView) {
            guard view.hasUsableRenderGeometry else { return }
            if let pendingPagedInitialRender {
                self.pendingPagedInitialRender = nil
                apply(
                    scrollback: pendingPagedInitialRender.scrollback,
                    epoch: pendingPagedInitialRender.epoch,
                    endOffset: pendingPagedInitialRender.endOffset,
                    surfaceDelta: pendingPagedInitialRender.surfaceDelta,
                    to: view
                )
                return
            }
            guard let pendingInitialRender else { return }
            self.pendingInitialRender = nil
            apply(
                output: pendingInitialRender.output,
                epoch: pendingInitialRender.epoch,
                endOffset: pendingInitialRender.endOffset,
                to: view
            )
        }

        @MainActor
        private func feed(
            pages: [String],
            to view: ReadOnlyTerminalView,
            suppressReplies: Bool
        ) {
            for (index, page) in pages.enumerated() where !page.isEmpty {
                feed(
                    page,
                    to: view,
                    suppressReplies: suppressReplies,
                    scrollAfter: index == pages.count - 1
                )
            }
        }

        /// Feeds `text` into the terminal and, unless the user has deliberately
        /// scrolled up, snaps the viewport back to the newest output so the
        /// surface stays glued to live output (Electron sticky-scroll parity).
        /// `isFeeding` stays set across both the feed and the snap so every
        /// scroll callback the terminal emits during this window is treated as
        /// output-driven, never as a user scroll.
        @MainActor
        private func feed(
            _ text: String,
            to view: ReadOnlyTerminalView,
            suppressReplies: Bool,
            scrollAfter: Bool = true
        ) {
            captureUserScrollBeforeOutput(to: view)
            isFeeding = true
            suppressReplayReplies = suppressReplies
            defer {
                suppressReplayReplies = false
                isFeeding = false
            }
            // SwiftTerm clears the current selection from both feedPrepare and
            // linefeed whenever mouse reporting is enabled. Mouse reporting
            // governs user events, not parser semantics, so suspend it only
            // around the feed and restore it before returning. Full-screen TUI
            // mouse input remains available while streamed output can no longer
            // erase text the user is selecting or about to copy.
            let restoresMouseReporting = view.allowMouseReporting
            view.allowMouseReporting = false
            view.feed(text: text)
            // Feeding and repinning both used to rebuild the semantic overlay.
            // Record cursor growth first, then paint exactly once after the
            // viewport reaches its final position for this output batch.
            view.observeSemanticPromptCursor(refreshDecorations: false)
            view.allowMouseReporting = restoresMouseReporting
            if scrollAfter, !userUnpinned {
                view.scrollToLiveBottom()
            } else {
                view.updateSemanticDecorations()
            }
            if suppressReplies {
                if scrollAfter { view.seedAccessibilityAnnouncementBaseline() }
            } else {
                view.noteLiveOutputForAccessibility()
            }
        }

        /// Byte-exact variant of `feed`, used by incremental reconciliation so a
        /// multi-byte character split across broker chunks never has to be
        /// re-materialised as a `String` first.
        @MainActor
        private func feed(
            bytes: ArraySlice<UInt8>,
            to view: ReadOnlyTerminalView,
            suppressReplies: Bool,
            scrollAfter: Bool = true
        ) {
            captureUserScrollBeforeOutput(to: view)
            isFeeding = true
            suppressReplayReplies = suppressReplies
            defer {
                suppressReplayReplies = false
                isFeeding = false
            }
            let restoresMouseReporting = view.allowMouseReporting
            view.allowMouseReporting = false
            view.feed(byteArray: bytes)
            view.observeSemanticPromptCursor(refreshDecorations: false)
            view.allowMouseReporting = restoresMouseReporting
            if scrollAfter, !userUnpinned {
                view.scrollToLiveBottom()
            } else {
                view.updateSemanticDecorations()
            }
            if suppressReplies {
                if scrollAfter { view.seedAccessibilityAnnouncementBaseline() }
            } else {
                view.noteLiveOutputForAccessibility()
            }
        }

        /// A PTY packet can arrive between AppKit's wheel event and SwiftTerm's
        /// delegate callback. Latch the user's position before feeding that
        /// packet, otherwise output wins the race and snaps the viewport to the
        /// bottom for one frame — the visible "spazz" while scrolling upward.
        @MainActor
        private func captureUserScrollBeforeOutput(to view: ReadOnlyTerminalView) {
            guard view.canScroll else { return }
            guard view.isUserScrollGesture else {
                reconcileExpiredGesturePin(to: view)
                return
            }
            // A precise upward trackpad gesture exists before SwiftTerm's
            // private sub-cell accumulator changes `scrollPosition`. Latch the
            // direction itself; otherwise a repaint in that gap records 1.0 and
            // leaves follow mode enabled. A downward gesture still re-pins only
            // once it has actually reached the live bottom.
            if TerminalScrollGestureMonitor.isScrollingUpward(for: view) {
                userUnpinned = true
            } else {
                userUnpinned = view.scrollPosition < Self.pinnedThreshold
            }
        }

        /// Re-enter sticky-scroll follow mode after the user deliberately
        /// returned to live output (the jump pill) or removed the scrollback
        /// they had scrolled into (Clear Terminal). Both are explicit intent,
        /// so unlike `reconcileExpiredGesturePin` this does not second-guess
        /// the current viewport position.
        @MainActor
        func resumeLiveFollow() {
            userUnpinned = false
        }

        /// Test seam for the pin state the pill and the clear command depend on.
        var isFollowingLiveOutput: Bool { !userUnpinned }

        /// A microscopic gesture can end before SwiftTerm's precise-delta
        /// accumulator crosses a terminal row. Once gesture attribution expires,
        /// exact live-bottom is authoritative again; clear only that phantom
        /// unpin, never a viewport that actually moved into scrollback.
        @MainActor
        private func reconcileExpiredGesturePin(to view: ReadOnlyTerminalView) {
            guard userUnpinned,
                  !view.isUserScrollGesture,
                  view.canScroll,
                  view.scrollPosition >= Self.pinnedThreshold else { return }
            userUnpinned = false
        }

        /// The already-rendered prefix, dropped by byte count.
        ///
        /// This deliberately does **not** round-trip through `String.Index`. The
        /// previous implementation ended with
        /// `byteIndex.samePosition(in: output)`, which returns nil unless the
        /// offset lands on a *grapheme cluster* boundary — and `\r\n` is a single
        /// Swift `Character`. Broker chunks split on UTF-8 codepoint boundaries
        /// and at every raw PTY read, so a CRLF (or an emoji + variation
        /// selector, a combining mark, a ZWJ sequence) straddling a chunk
        /// boundary made this return nil. That silently dropped the incremental
        /// path into the full clear-and-re-feed below — mid-session, while the
        /// user watched — which is what made agent output appear duplicated.
        ///
        /// A terminal is a byte stream; slice bytes. SwiftTerm's parser is
        /// streaming and already tolerates a codepoint split across feeds.
        private func outputSuffixBytes(
            _ output: String,
            droppingUTF8Bytes count: Int64
        ) -> ArraySlice<UInt8>? {
            guard count >= 0, let distance = Int(exactly: count) else { return nil }
            let bytes = Array(output.utf8)
            guard distance <= bytes.count else { return nil }
            return bytes[distance...]
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Reached only from OwnedTerminalView: the read-only subclass
            // swallows every byte before the delegate can see it.
            guard !suppressReplayReplies, let onInput, !data.isEmpty else { return }
            onInput(String(decoding: data, as: UTF8.self))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            reportGeometry(columns: newCols, rows: newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            pendingTitleChange = title
            if titleChangeDeliveryScheduled {
                NSObject.cancelPreviousPerformRequests(
                    withTarget: self,
                    selector: #selector(deliverPendingTitleChange),
                    object: nil
                )
            }
            titleChangeDeliveryScheduled = true
            // TerminalViewDelegate predates Swift concurrency but SwiftTerm's
            // AppKit surface invokes it on the main run loop. NSObject's
            // deferred selector keeps that invariant and avoids claiming this
            // mutable coordinator is Sendable merely to cross an isolation
            // boundary it never crosses at runtime. Resetting the selector for
            // every repaint makes this a true trailing debounce: only a title
            // that remains stable for the interval can reach persistence.
            perform(
                #selector(deliverPendingTitleChange),
                with: nil,
                afterDelay: Self.titleChangeDebounceInterval
            )
        }

        @objc private func deliverPendingTitleChange() {
            titleChangeDeliveryScheduled = false
            guard let title = pendingTitleChange else { return }
            pendingTitleChange = nil
            onTitleChange?(title)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory,
                  let reported = Self.parseWorkingDirectory(directory) else { return }
            workingDirectory = reported
        }
        func scrolled(source: TerminalView, position: Double) {
            // SwiftTerm delivers AppKit scroll callbacks on the main thread,
            // while its delegate protocol predates Swift concurrency metadata.
            // Ignore the scroll callbacks emitted while we feed output or snap to
            // the bottom; only a deliberate user scroll changes the pin state.
            guard !isFeeding else { return }
            guard let view = source as? ReadOnlyTerminalView else { return }
            MainActor.assumeIsolated { view.updateSemanticDecorations() }
            // `isFeeding` alone is a whitelist of one safe window against an
            // emitter with several unsafe ones — resize, the synchronized-output
            // timeout, and reset all fire `scrolled` with no user involved.
            // Require a real gesture instead.
            //
            // Also require scrollback to exist: on the alternate screen SwiftTerm
            // hardcodes `scrollPosition` to 0, so a fullscreen TUI such as Codex
            // would otherwise report "scrolled to the top" forever and
            // permanently unpin the surface. There is nothing to scroll away
            // from there.
            //
            // `assumeIsolated` rather than a hop: this delegate method is
            // nonisolated because the protocol predates Swift concurrency, but
            // AppKit delivers it on the main thread. Hopping would settle the pin
            // state a run-loop turn after the scroll that caused it.
            let gestureDriven = MainActor.assumeIsolated {
                view.isUserScrollGesture && view.canScroll
            }
            guard gestureDriven else { return }
            // `position` is the relative viewport position (1.0 at the live
            // bottom): leaving the bottom unpins, returning to it re-pins.
            userUnpinned = position < Self.pinnedThreshold
            TerminalScrollGestureMonitor.acknowledgeScrollPosition(for: view)
        }

        /// Re-snap to the newest output after a geometry change.
        ///
        /// Pinning was only ever re-applied inside `feed`, so a pane that
        /// changed size after its last byte arrived — exactly what a project tab
        /// switch does, since surfaces are rebuilt and laid out fresh — stayed
        /// wherever the reflow left it. Runs on the next turn so SwiftTerm's own
        /// resize/reflow has completed, and inside the `isFeeding` mask so the
        /// resulting scroll cannot be mistaken for user intent.
        @MainActor
        func repinAfterLayout(_ view: ReadOnlyTerminalView) {
            reconcileExpiredGesturePin(to: view)
            guard !userUnpinned, !isProgressivelyReplaying else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, !self.userUnpinned else { return }
                self.isFeeding = true
                view.scrollToLiveBottom()
                self.isFeeding = false
            }
        }

        /// Splits a `file:` OSC 8 link into its filesystem path and an optional
        /// trailing `:LINE` citation. Agent CLIs emit both `file:///a/b.swift:42`
        /// and the percent-encoded `file:///a/b.swift%3A42`; `URL.path` is already
        /// percent-decoded, so both collapse to the same string here. The colon is
        /// treated as a line number only when it is the last colon, is followed by
        /// digits, and leaves a non-empty path — so directory URLs and paths whose
        /// colon is not a citation pass through untouched.
        nonisolated static func parseFileLink(_ url: URL) -> (path: String, line: Int?) {
            let parsed = parsePathCitation(url.path)
            if parsed.line != nil { return (parsed.path, parsed.line) }
            if let fragment = url.fragment,
               fragment.first?.lowercased() == "l",
               let line = Int(fragment.dropFirst()),
               line > 0 {
                return (parsed.path, line)
            }
            return (parsed.path, nil)
        }

        enum LinkTarget: Equatable {
            case web(URL)
            case file(URL, line: Int?)
        }

        /// Resolve both real URLs and the path citations printed by Codex,
        /// Claude, compilers, test runners, and ripgrep. SwiftTerm recognizes
        /// these implicit paths but reports them verbatim, so the host must add
        /// the current directory and split `:LINE[:COLUMN]` before opening.
        nonisolated static func linkTarget(for rawLink: String, workingDirectory: URL?) -> LinkTarget? {
            let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty else { return nil }

            if let url = URL(string: link), let scheme = url.scheme?.lowercased() {
                switch scheme {
                case "http", "https", "mailto", "ftp":
                    return .web(url)
                case "file":
                    let parsed = parseFileLink(url)
                    guard !parsed.path.isEmpty else { return nil }
                    return .file(URL(fileURLWithPath: parsed.path).standardizedFileURL, line: parsed.line)
                default:
                    // A relative citation such as `Sources/App.swift:42` can be
                    // interpreted by Foundation as a custom scheme. Fall
                    // through and let the path parser make the safe decision.
                    break
                }
            }

            let parsed = parsePathCitation(link)
            guard !parsed.path.isEmpty else { return nil }
            let path = parsed.path.removingPercentEncoding ?? parsed.path
            let fileURL: URL
            if path.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: path)
            } else if path == "~" || path.hasPrefix("~/") {
                fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else {
                guard let workingDirectory else { return nil }
                fileURL = workingDirectory.appendingPathComponent(path)
            }
            return .file(fileURL.standardizedFileURL, line: parsed.line)
        }

        /// Returns the path plus the first navigation coordinate. A second
        /// numeric suffix is treated as a column and intentionally discarded:
        /// Kaisola's file preview currently navigates by line while preserving
        /// the full file path for `path:line:column` compiler citations.
        nonisolated private static func parsePathCitation(_ rawPath: String) -> (path: String, line: Int?) {
            // SwiftTerm's implicit-link range can include prose punctuation
            // immediately after a citation (most visibly `report.md;`). A
            // semicolon/comma cannot be a citation delimiter, so remove only
            // those terminal punctuation marks; do not broadly trim periods,
            // parentheses, or brackets that may legitimately belong to paths.
            let path = rawPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";,"))
            guard let final = splitTrailingCoordinate(path) else { return (path, nil) }
            if let preceding = splitTrailingCoordinate(final.path) {
                return (preceding.path, preceding.coordinate)
            }
            return (final.path, final.coordinate)
        }

        nonisolated private static func splitTrailingCoordinate(_ value: String) -> (path: String, coordinate: Int)? {
            guard let colon = value.lastIndex(of: ":") else { return nil }
            let token = value[value.index(after: colon)...]
            let path = String(value[..<colon])
            guard !path.isEmpty,
                  !token.isEmpty,
                  token.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let coordinate = Int(token),
                  coordinate > 0 else { return nil }
            return (path, coordinate)
        }

        nonisolated static func parseWorkingDirectory(_ rawDirectory: String) -> URL? {
            let raw = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if let url = URL(string: raw), url.isFileURL, !url.path.isEmpty {
                return URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
            }
            guard raw.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let target = Self.linkTarget(for: link, workingDirectory: workingDirectory) else { return }
            switch target {
            case .web(let url):
                if LocalhostDetector.isLocalDevURL(url) {
                    NotificationCenter.default.post(name: .kaisolaOpenBrowserCard, object: url)
                    return
                }
                NSWorkspace.shared.open(url)
            case .file(let fileURL, let line):
                // OSC 8 file links (agent CLIs cite files): open in Kaisola's
                // built-in preview via the shell rather than executing/revealing
                // the file through Launch Services. RootShellView observes
                // `.kaisolaOpenFileLink` and drives its file preview.
                var userInfo: [AnyHashable: Any] = ["url": fileURL]
                if let line { userInfo["line"] = line }
                userInfo["workspaceHint"] = workingDirectory
                    ?? fileURL.deletingLastPathComponent()
                NotificationCenter.default.post(
                    name: .kaisolaOpenFileLink,
                    object: nil,
                    userInfo: userInfo
                )
            }
        }
        func bell(source: TerminalView) {
            // Initial/progressive reconstruction can contain old BEL bytes.
            // Treat them like replayed terminal replies: render history, but do
            // not manufacture a new user-facing side effect.
            guard !suppressReplayReplies, let onBell else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard Self.shouldDeliverBell(lastDeliveredAt: lastDeliveredBellAt, now: now) else {
                return
            }
            lastDeliveredBellAt = now
            onBell()
        }
        /// One guidance toast per app run, not per pane: every terminal shares
        /// the same setting, so nagging once per surface would be noise.
        static var hasShownClipboardGuidance = false

        func clipboardCopy(source: TerminalView, content: Data) {
            // Initial/progressive reconstruction can contain an old OSC 52
            // write. Replaying it must render the bytes without reaching out
            // to the live pasteboard, the same rule `bell` already follows
            // for reconstructed history.
            guard !suppressReplayReplies else { return }
            switch TerminalClipboardWriteRequest.decide(
                content: content,
                consentGranted: allowsClipboardWrite,
                hasShownGuidance: Self.hasShownClipboardGuidance
            ) {
            case .copy(let text):
                clipboard.clearContents()
                clipboard.setString(text, forType: .string)
            case .refused(let showsGuidance):
                guard showsGuidance else { return }
                Self.hasShownClipboardGuidance = true
                ToastCenter.shared.show(
                    TerminalClipboardWriteRequest.guidanceMessage,
                    style: .info,
                    duration: 6
                )
            case .ignored:
                break
            }
        }

        /// Never granted. Answering would hand whatever the user last copied —
        /// a password, a token, a private path — to a program that may be on
        /// the far end of an SSH session. Returning nil makes SwiftTerm send no
        /// OSC 52 reply at all.
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// "Clear Terminal" for a surface whose history the broker owns.
///
/// A Kaisola terminal is not the authority on its own output: the broker keeps
/// an append-only spool and every renderer — this window, a popped-out window,
/// the transcript sheet, the phone companion — is reconstructed from it. There
/// is therefore nothing a clear could delete here that would stay deleted, and
/// deleting broker bytes would be the wrong promise to make from a View menu
/// item. Typing `clear` into the PTY is also wrong: it would land in whatever
/// the user (or an agent CLI) has half-composed at the prompt.
///
/// So this clears the *live renderer* only — erase the visible screen, drop
/// SwiftTerm's in-memory scrollback, home the cursor, and return to the live
/// bottom. The PTY is untouched and the coordinator's rendered byte cursor is
/// unchanged, so streaming output keeps appending incrementally rather than
/// forcing a full re-feed. A later full reconstruction (a stream-epoch change,
/// or a pane remounted from a project switch) legitimately repaints the earlier
/// output, and the retained transcript can always still reach it.
enum TerminalClearCommand {
    /// CUP home + ED 2 (erase display) + ED 3 (erase scrollback), fed through
    /// the parser instead of mutating SwiftTerm's buffers directly so cursor,
    /// wrap, and image state stay consistent with the renderer's own rules.
    static let escapeSequence = "\u{1B}[H\u{1B}[2J\u{1B}[3J"

    /// Shown when the command is invoked with no terminal to act on, because a
    /// silent no-op is exactly the failure this bundle exists to remove.
    static let noTerminalMessage = "Focus a terminal to clear it."
}

/// When the "jump to live output" pill is offered, and where it sits.
///
/// The pill is strictly a recovery affordance for a viewport the user moved:
/// it must never appear on a surface that cannot scroll, and never over a
/// full-screen TUI, where SwiftTerm pins `scrollPosition` to 0 on the
/// alternate buffer and "the bottom" has no meaning.
enum TerminalJumpToBottomPolicy {
    static let trailingInset: CGFloat = 12
    static let bottomInset: CGFloat = 10
    /// The legacy scroller keeps a permanently visible track on the right edge;
    /// clear it so the pill never sits under the user's scroll target.
    static let scrollerInset: CGFloat = 16

    static func isVisible(
        canScroll: Bool,
        isAtLiveBottom: Bool,
        isAlternateBuffer: Bool
    ) -> Bool {
        canScroll && !isAlternateBuffer && !isAtLiveBottom
    }

    static func frame(in bounds: NSRect, size: NSSize, flipped: Bool) -> NSRect {
        let x = max(bounds.minX, bounds.maxX - size.width - trailingInset - scrollerInset)
        let y = flipped
            ? max(bounds.minY, bounds.maxY - size.height - bottomInset)
            : bounds.minY + bottomInset
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

/// OSC 52 — "put this on the user's clipboard" — from a program running in the
/// terminal.
///
/// This is a genuinely useful capability (an agent CLI offering to copy a
/// command, `tmux`/`nvim` yanking over SSH) and a genuinely dangerous one: the
/// emitter can be any script, on either end of a remote session, and silently
/// replacing what a user is about to paste into their shell is a known attack
/// rather than a hypothetical. Kaisola therefore refuses the write unless the
/// user has explicitly granted it in Settings > Terminal, and tells them once
/// where the switch is instead of failing invisibly.
///
/// The *read* half is never granted: SwiftTerm asks through `clipboardRead`,
/// and returning nil there makes it send no reply at all, so no clipboard
/// contents can be exfiltrated to whatever is running in the pane.
enum TerminalClipboardWriteRequest {
    enum Decision: Equatable {
        /// Consent is granted and the payload is usable clipboard text.
        case copy(String)
        /// Consent is withheld. `showsGuidance` is true only for the first
        /// blocked attempt, so a chatty program cannot turn the refusal into a
        /// wall of toasts.
        case refused(showsGuidance: Bool)
        /// Nothing a person could have meant to paste.
        case ignored
    }

    /// A clipboard write is a short piece of text a human is about to paste.
    /// SwiftTerm has already base64-decoded the payload; this caps what is
    /// accepted so a runaway program cannot push megabytes onto the pasteboard.
    static let maximumPayloadBytes = 256 * 1_024

    static let guidanceMessage =
        "A terminal program tried to change your clipboard. Allow it in Settings > Terminal."

    static func decide(
        content: Data,
        consentGranted: Bool,
        hasShownGuidance: Bool
    ) -> Decision {
        // Validity is decided before consent on purpose: a malformed or absurd
        // payload was never a clipboard write, so it must not spend the single
        // guidance toast the user gets.
        guard !content.isEmpty,
              content.count <= maximumPayloadBytes,
              let text = String(data: content, encoding: .utf8),
              !containsRejectedControls(text) else { return .ignored }
        let payload = trimmingExecutionNewlines(text)
        guard !payload.isEmpty else { return .ignored }
        guard consentGranted else { return .refused(showsGuidance: !hasShownGuidance) }
        return .copy(payload)
    }

    /// Tab, newline, and carriage return are ordinary text; every other C0
    /// control (and DEL) is either a terminal command that escaped its parser
    /// or an attempt to hide part of the payload from whatever renders the
    /// paste. Neither belongs on a text pasteboard.
    private static func containsRejectedControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            guard value < 0x20 || value == 0x7F else { return false }
            return value != 0x09 && value != 0x0A && value != 0x0D
        }
    }

    /// Drop trailing newlines. Copying "text" and "text\n" is indistinguishable
    /// to the user, but pasting the second into a shell *runs* it — the classic
    /// OSC 52 auto-execute vector. Interior newlines are preserved.
    ///
    /// Scalars, not `Character`s: `\r\n` is a single Swift grapheme cluster, so
    /// a `Character`-based trim silently leaves a CRLF terminator in place —
    /// exactly the payload this is meant to defuse.
    private static func trimmingExecutionNewlines(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while let last = scalars.last, last == "\n" || last == "\r" {
            scalars.removeLast()
        }
        return String(scalars)
    }
}

/// The other half of focus synchronization: after the model moves its pane
/// focus, AppKit's first responder must follow, or the ring says one thing
/// while typing (and VoiceOver) go somewhere else.
@MainActor
enum TerminalKeyboardFocus {
    /// Never take the keyboard away from somewhere the user is typing. The
    /// field editor behind every `NSTextField` — the omnibar, a rename sheet,
    /// a chat composer — is an `NSText`, so this one check covers them all.
    static func canClaimFocus(from responder: NSResponder?) -> Bool {
        guard let responder else { return true }
        return !(responder is NSText)
    }

    @discardableResult
    static func moveFirstResponder(
        toSessionID id: String,
        in window: NSWindow? = NSApplication.shared.keyWindow
    ) -> Bool {
        guard let window,
              let root = window.contentView,
              let terminal = TerminalFocusResolver.terminal(in: root, paneID: id),
              window.firstResponder !== terminal,
              canClaimFocus(from: window.firstResponder) else { return false }
        return window.makeFirstResponder(terminal)
    }
}

/// Which terminal a window-level command acts on.
///
/// The model's focused pane is the surface the user can *see* highlighted, so
/// it wins; the AppKit first responder is the fallback for the moments before
/// the two agree. Refusing the command is deliberately preferred over
/// grabbing some other terminal in the window: when the focused pane is a
/// chat or Mesh surface (or the id is simply stale), acting on an unrelated
/// terminal elsewhere in the layout would be a surprise, not a convenience.
@MainActor
enum TerminalFocusResolver {
    static func focusedTerminal(in window: NSWindow?, paneID: String?) -> ReadOnlyTerminalView? {
        guard let window, let root = window.contentView else { return nil }
        if let paneID, let match = terminal(in: root, paneID: paneID) { return match }
        // A live first responder is still trustworthy evidence of where the
        // keyboard actually is right now. An arbitrary DFS match through the
        // rest of the view tree is not, so there is no further fallback.
        return window.firstResponder as? ReadOnlyTerminalView
    }

    /// Depth-first search for a terminal view. A nil `paneID` matches the first
    /// terminal found, which is what a single-pane window always wants.
    static func terminal(in root: NSView, paneID: String?) -> ReadOnlyTerminalView? {
        if let terminal = root as? ReadOnlyTerminalView,
           paneID == nil || terminal.paneSessionID == paneID {
            return terminal
        }
        for subview in root.subviews {
            if let match = terminal(in: subview, paneID: paneID) { return match }
        }
        return nil
    }
}

enum TerminalSemanticEvent: Equatable, Sendable {
    case promptStart(isSecondary: Bool)
    case commandStart
    case commandExecuted
    case commandFinished(exitCode: Int?)

    /// FinalTerm/OSC 133 and VS Code/OSC 633 lifecycle payloads are deliberately
    /// tiny. Refuse malformed or oversized strings before interpreting them so
    /// untrusted command output cannot turn navigation into an unbounded parser.
    static func parse(_ payload: ArraySlice<UInt8>) -> TerminalSemanticEvent? {
        guard !payload.isEmpty, payload.count <= 1_024,
              let value = String(bytes: payload, encoding: .utf8) else { return nil }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let marker = fields.first else { return nil }
        switch marker {
        case "A":
            return .promptStart(isSecondary: fields.dropFirst().contains("k=s"))
        case "B":
            return fields.count == 1 ? .commandStart : nil
        case "C":
            return .commandExecuted
        case "D":
            guard fields.count <= 2 else { return nil }
            guard fields.count == 2, !fields[1].isEmpty else {
                return .commandFinished(exitCode: nil)
            }
            guard fields[1].count <= 10,
                  let status = Int(fields[1]),
                  (0...Int(Int32.max)).contains(status) else { return nil }
            return .commandFinished(exitCode: status)
        default:
            return nil
        }
    }
}

struct TerminalSemanticPosition: Equatable, Comparable, Sendable {
    let row: Int
    let column: Int

    static func < (lhs: TerminalSemanticPosition, rhs: TerminalSemanticPosition) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

struct TerminalSemanticCommand: Equatable, Sendable {
    let id: Int
    var promptStart: TerminalSemanticPosition
    var inputStart: TerminalSemanticPosition?
    var executedAt: TerminalSemanticPosition?
    var finishedAt: TerminalSemanticPosition?
    var exitCode: Int?
    var maximumInputRow: Int
    var secondaryPromptRows: [Int]
}

enum TerminalSemanticDecorationPhase: Equatable, Sendable {
    case input
    case running
    case succeeded
    case failed
    case completed
}

struct TerminalSemanticDecoration: Equatable, Sendable {
    let startViewportRow: Int
    let endViewportRow: Int
    let phase: TerminalSemanticDecorationPhase
}

/// Bounded semantic command state reconstructed directly from the terminal
/// stream. Because OSC bytes stay in the broker spool, replay after a GUI
/// replacement rebuilds this index without a second persistence authority.
struct TerminalSemanticTracker: Equatable, Sendable {
    static let maximumCommands = 512

    private(set) var commands: [TerminalSemanticCommand] = []
    private var currentCommandID: Int?
    private var nextID = 1

    mutating func receive(_ event: TerminalSemanticEvent, at position: TerminalSemanticPosition) {
        switch event {
        case let .promptStart(isSecondary):
            if isSecondary, let index = currentIndex {
                if commands[index].secondaryPromptRows.last != position.row {
                    commands[index].secondaryPromptRows.append(position.row)
                }
                commands[index].maximumInputRow = max(commands[index].maximumInputRow, position.row)
                return
            }
            let command = TerminalSemanticCommand(
                id: nextID,
                promptStart: position,
                inputStart: nil,
                executedAt: nil,
                finishedAt: nil,
                exitCode: nil,
                maximumInputRow: position.row,
                secondaryPromptRows: []
            )
            nextID += 1
            commands.append(command)
            currentCommandID = command.id
            trimToBound()
        case .commandStart:
            ensureCurrent(at: position)
            guard let index = currentIndex else { return }
            commands[index].inputStart = position
            commands[index].maximumInputRow = max(commands[index].maximumInputRow, position.row)
        case .commandExecuted:
            ensureCurrent(at: position)
            guard let index = currentIndex else { return }
            commands[index].executedAt = position
        case let .commandFinished(exitCode):
            guard let index = currentIndex else { return }
            // FinalTerm defines D before C as an aborted edit. It is not a
            // command block and must not remain navigable as if it had run.
            guard commands[index].executedAt != nil else {
                commands.remove(at: index)
                currentCommandID = nil
                return
            }
            commands[index].finishedAt = position
            commands[index].exitCode = exitCode
            currentCommandID = nil
        }
    }

    mutating func observeCursor(at position: TerminalSemanticPosition) {
        guard let index = currentIndex,
              commands[index].inputStart != nil,
              commands[index].executedAt == nil else { return }
        commands[index].maximumInputRow = max(commands[index].maximumInputRow, position.row)
    }

    mutating func prune(before firstRetainedRow: Int) {
        commands.removeAll { command in
            let lastRow = command.finishedAt?.row
                ?? command.executedAt?.row
                ?? command.maximumInputRow
            return lastRow < firstRetainedRow
        }
        if let currentCommandID,
           !commands.contains(where: { $0.id == currentCommandID }) {
            self.currentCommandID = nil
        }
    }

    var activeInputRows: ClosedRange<Int>? {
        guard let index = currentIndex,
              let start = commands[index].inputStart,
              commands[index].executedAt == nil else { return nil }
        return start.row...max(start.row, commands[index].maximumInputRow)
    }

    func previousPrompt(before row: Int) -> TerminalSemanticPosition? {
        commands.lazy.reversed().map(\.promptStart).first { $0.row < row }
    }

    func nextPrompt(after row: Int) -> TerminalSemanticPosition? {
        commands.lazy.map(\.promptStart).first { $0.row > row }
    }

    func prompt(at row: Int) -> TerminalSemanticPosition? {
        commands.lazy.map(\.promptStart).first { $0.row == row }
    }

    /// Clips semantic command spans into the visible terminal viewport. The
    /// renderer consumes only these bounded rows; command text never enters the
    /// decoration model, and a partially visible command remains identifiable
    /// while the user scrolls through its output.
    func decorations(viewportTop: Int, rowCount: Int) -> [TerminalSemanticDecoration] {
        guard rowCount > 0 else { return [] }
        let viewportBottom = viewportTop + rowCount - 1
        return commands.enumerated().compactMap { index, command in
            let recordedEnd = command.finishedAt?.row
                ?? command.executedAt?.row
                ?? command.maximumInputRow
            let commandEnd: Int
            if command.finishedAt != nil, commands.indices.contains(index + 1) {
                commandEnd = min(recordedEnd, commands[index + 1].promptStart.row - 1)
            } else {
                commandEnd = recordedEnd
            }
            guard commandEnd >= viewportTop,
                  command.promptStart.row <= viewportBottom else { return nil }
            let phase: TerminalSemanticDecorationPhase
            if command.finishedAt != nil {
                if command.exitCode == 0 {
                    phase = .succeeded
                } else if command.exitCode != nil {
                    phase = .failed
                } else {
                    phase = .completed
                }
            } else if command.executedAt != nil {
                phase = .running
            } else {
                phase = .input
            }
            return TerminalSemanticDecoration(
                startViewportRow: max(0, command.promptStart.row - viewportTop),
                endViewportRow: min(rowCount - 1, commandEnd - viewportTop),
                phase: phase
            )
        }
    }

    private var currentIndex: Int? {
        guard let currentCommandID else { return nil }
        return commands.lastIndex { $0.id == currentCommandID }
    }

    private mutating func ensureCurrent(at position: TerminalSemanticPosition) {
        guard currentIndex == nil else { return }
        let command = TerminalSemanticCommand(
            id: nextID,
            promptStart: position,
            inputStart: nil,
            executedAt: nil,
            finishedAt: nil,
            exitCode: nil,
            maximumInputRow: position.row,
            secondaryPromptRows: []
        )
        nextID += 1
        commands.append(command)
        currentCommandID = command.id
        trimToBound()
    }

    private mutating func trimToBound() {
        guard commands.count > Self.maximumCommands else { return }
        commands.removeFirst(commands.count - Self.maximumCommands)
        if let currentCommandID,
           !commands.contains(where: { $0.id == currentCommandID }) {
            self.currentCommandID = nil
        }
    }
}

/// Converts two already-rendered terminal viewport snapshots into one bounded
/// VoiceOver utterance. The renderer has already interpreted ANSI/OSC/DCS, so
/// this policy never exposes the raw PTY stream. Line overlap handles the
/// ordinary scrolling case; a cursor-addressed repaint speaks only its newest
/// readable line instead of the whole viewport.
enum TerminalAccessibilityAnnouncementPolicy {
    static let throttleInterval: TimeInterval = 0.8
    static let maximumCharacters = 600

    static func announcement(previous: String, current: String) -> String? {
        let previous = normalizedSnapshot(previous)
        let current = normalizedSnapshot(current)
        guard !current.isEmpty, current != previous else { return nil }

        let candidate: String
        if current.hasPrefix(previous) {
            candidate = String(current.dropFirst(previous.count))
        } else {
            let oldLines = previous.split(separator: "\n", omittingEmptySubsequences: false)
            let newLines = current.split(separator: "\n", omittingEmptySubsequences: false)
            var overlap = min(oldLines.count, newLines.count)
            while overlap > 0,
                  !oldLines.suffix(overlap).elementsEqual(newLines.prefix(overlap)) {
                overlap -= 1
            }
            if overlap > 0, overlap < newLines.count {
                candidate = newLines.dropFirst(overlap).joined(separator: "\n")
            } else {
                candidate = newLines.last(where: {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }).map(String.init) ?? current
            }
        }

        let readable = readableText(candidate)
        guard !readable.isEmpty else { return nil }
        return String(readable.suffix(maximumCharacters))
    }

    private static func normalizedSnapshot(_ input: String) -> String {
        var lines = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func readableText(_ input: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A:
                scalars.append(scalar)
            case 0x20...0x7E, 0xA0...0x10FFFF:
                scalars.append(scalar)
            default:
                continue
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Drops both physical-key input and terminal-generated query replies. SwiftTerm
/// still provides native selection, copy, and Command-F search, but no byte can
/// flow from this view back to a PTY. The view claims keyboard focus when it
/// joins a window so Copy/Select All/Find reach it without a mouse, and exposes
/// the retained tail of the buffer as a read-only accessibility value.
class ReadOnlyTerminalView: TerminalView {
    static let accessibilityTailLimit = 8_000
    /// Prevent one trackpad momentum sequence from trying to present the same
    /// transcript sheet repeatedly while the live viewport remains at row 0.
    static let historyBoundaryRequestCooldown: TimeInterval = 0.75

    // Copy-on-write reference updated per stream apply in O(1); the bounded
    // tail is materialized only when accessibility actually asks for it.
    private var accessibilitySource: String = ""
    private var accessibilityAnnouncementBaseline = ""
    private var accessibilityAnnouncementNeedsBaseline = true
    private(set) var accessibilityAnnouncementIsScheduled = false
    private(set) var accessibilityAnnouncementScheduleCount = 0
    var accessibilityAnnouncementVoiceOverEnabled: () -> Bool = {
        NSWorkspace.shared.isVoiceOverEnabled
    }
    var accessibilityAnnouncementPoster: ((String) -> Void)?
    private(set) var semanticTracker = TerminalSemanticTracker()
    private var semanticHandlerInstalled = false
    private var semanticGridColumns: Int?
    private var semanticGridRows: Int?
    private var semanticDecorationView: TerminalSemanticDecorationView?
    /// The representable hands initial replay back through this callback after
    /// AppKit assigns the real terminal size.
    var onUsableLayout: (() -> Void)?
    /// Host-owned presentation hook for continuing beyond SwiftTerm's bounded
    /// in-memory row model into the broker's disk-backed transcript.
    var onHistoryBoundary: (() -> Void)?
    /// Stable surface identity of the pane this view renders. Window-level
    /// commands (Clear Terminal, pane focus moves) resolve a terminal through
    /// this rather than assuming the AppKit responder chain already agrees with
    /// the model's focused pane.
    var paneSessionID: String?
    /// Published to the shell when AppKit hands this view keyboard focus, so
    /// the pane focus ring follows a click into the terminal instead of staying
    /// on whichever pane was focused last.
    var onKeyboardFocus: (() -> Void)?
    private var jumpToLiveBottomButton: NSButton?
    private var lastHistoryBoundaryRequestAt = -TimeInterval.greatestFiniteMagnitude
    var hasUsableRenderGeometry: Bool {
        bounds.width > 1 && bounds.height > 1
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {}

    /// SwiftTerm checks registered OSC handlers before its built-ins, so OSC
    /// 133/633 support does not require patching the dependency parser. Both
    /// protocols share A/B/C/D lifecycle markers. The handlers record only
    /// bounded positions; they never trust or execute embedded command text.
    func configureSemanticPromptMarks() {
        guard !semanticHandlerInstalled else { return }
        semanticHandlerInstalled = true
        let decorationView = TerminalSemanticDecorationView(frame: bounds)
        decorationView.autoresizingMask = [.width, .height]
        decorationView.isHidden = true
        addSubview(decorationView, positioned: .above, relativeTo: nil)
        semanticDecorationView = decorationView
        reconcileSemanticPromptGrid()
        for code in [133, 633] {
            getTerminal().registerOscHandler(code: code) { [weak self] payload in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reconcileSemanticPromptGrid()
                    guard
                        let event = TerminalSemanticEvent.parse(payload),
                        let position = self.scrollInvariantCursorPosition() else { return }
                    self.semanticTracker.prune(before: self.getTerminal().buffer.totalLinesTrimmed)
                    self.semanticTracker.receive(event, at: position)
                    self.updateSemanticDecorations()
                }
            }
        }
    }

    func resetSemanticPromptMarks() {
        semanticTracker = TerminalSemanticTracker()
        updateSemanticDecorations()
    }

    /// A terminal resize can reflow every scrollback row. SwiftTerm does not
    /// expose a row-remapping callback, so stale coordinates are less useful
    /// than an empty index: discard them and let later/replayed marks rebuild
    /// trustworthy navigation bounds.
    func reconcileSemanticPromptGrid() {
        let dimensions = getTerminal().getDims()
        guard dimensions.cols > 0, dimensions.rows > 0 else { return }
        defer {
            semanticGridColumns = dimensions.cols
            semanticGridRows = dimensions.rows
        }
        guard let oldColumns = semanticGridColumns,
              let oldRows = semanticGridRows else { return }
        if oldColumns != dimensions.cols || oldRows != dimensions.rows {
            resetSemanticPromptMarks()
        }
    }

    /// Extend the active input region after each parsed output chunk. Echoed
    /// shell input and secondary prompts can wrap without emitting another OSC
    /// marker, so cursor observation supplies the conservative lower bound used
    /// by vertical Option-click.
    func observeSemanticPromptCursor(refreshDecorations: Bool = true) {
        // Plain shells and CLIs that do not emit OSC 133/633 have no active
        // input region. Avoid a binary search across the SwiftTerm buffer for
        // every streamed packet in that overwhelmingly common case.
        guard semanticTracker.activeInputRows != nil else { return }
        reconcileSemanticPromptGrid()
        guard let position = scrollInvariantCursorPosition() else { return }
        semanticTracker.prune(before: getTerminal().buffer.totalLinesTrimmed)
        semanticTracker.observeCursor(at: position)
        if refreshDecorations { updateSemanticDecorations() }
    }

    /// Cursor row in SwiftTerm's monotonic scroll-invariant coordinate space.
    /// This remains correct even while the user is reading older output: find
    /// the contiguous buffer end through the public invariant-line API, then
    /// subtract the live screen height rather than consulting `yDisp`.
    func scrollInvariantCursorPosition() -> TerminalSemanticPosition? {
        let terminal = getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        var lower = first
        var upper = first + terminal.options.scrollback + terminal.rows + 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if terminal.getScrollInvariantLine(row: middle) == nil {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let end = lower
        guard end > first else { return nil }
        let cursor = terminal.getCursorLocation()
        let activeTop = max(first, end - terminal.rows)
        return TerminalSemanticPosition(row: activeTop + cursor.y, column: cursor.x)
    }

    /// Command-Up/Down follows semantic prompt starts without sending bytes to
    /// the shell. If no mark exists in that direction SwiftTerm retains its
    /// ordinary key behavior.
    @discardableResult
    func navigateSemanticPrompt(
        backward: Bool,
        beforeScroll: (() -> Void)? = nil
    ) -> Bool {
        let terminal = getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        semanticTracker.prune(before: first)
        guard let destination = semanticPromptDestination(backward: backward) else { return false }
        beforeScroll?()
        scrollTo(row: max(0, destination.row - first), notifyAccessibility: true)
        updateSemanticDecorations()
        return true
    }

    /// Every path that can move the viewport already calls this — feeds, user
    /// scrolls, re-pins, layout, and reset — so it is also the single hook the
    /// jump-to-live-bottom pill reacts to. Keeping one hook is what stops the
    /// affordance from lagging a scroll by a run-loop turn.
    func updateSemanticDecorations() {
        updateJumpToLiveBottomVisibility()
        guard let semanticDecorationView else { return }
        // Preserve the one transition that hides an old overlay after reset,
        // while making the steady empty state free during ordinary streaming.
        guard !semanticTracker.commands.isEmpty || !semanticDecorationView.isHidden else { return }
        let terminal = getTerminal()
        let rowCount = terminal.rows
        let viewportTop = terminal.buffer.totalLinesTrimmed + terminal.getTopVisibleRow()
        let decorations = semanticTracker.decorations(
            viewportTop: viewportTop,
            rowCount: rowCount
        )
        semanticDecorationView.update(decorations: decorations, rowCount: rowCount)
    }

    func semanticPromptDestination(backward: Bool) -> TerminalSemanticPosition? {
        let terminal = getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        let viewportTop = first + terminal.getTopVisibleRow()
        let destination: TerminalSemanticPosition?
        if backward {
            // From between blocks, land on the closest prompt at or above the
            // viewport. Once that prompt is exactly at the top, move strictly
            // to the previous one rather than consuming a no-op shortcut.
            let boundary = semanticTracker.prompt(at: viewportTop) == nil
                ? viewportTop + 1
                : viewportTop
            destination = semanticTracker.previousPrompt(before: boundary)
        } else {
            destination = semanticTracker.nextPrompt(after: viewportTop)
        }
        return destination
    }

    @objc private func navigateToPreviousSemanticCommand(_ sender: Any?) {
        navigateSemanticPrompt(backward: true)
    }

    @objc private func navigateToNextSemanticCommand(_ sender: Any?) {
        navigateSemanticPrompt(backward: false)
    }

    /// Agent output should advertise navigation without requiring users to
    /// discover a hidden Command-click gesture. SwiftTerm supplies the path/URL
    /// detector and native underline renderer; hover mode makes the cue visible
    /// and activates a link with one ordinary click.
    func configureLinkInteraction() {
        linkReporting = .implicit
        linkHighlightMode = .hover
    }

    /// Match the underline with the standard macOS link cursor. SwiftTerm's
    /// built-in cursor rect is always an I-beam, so use its public link lookup
    /// with screen coordinates to distinguish a navigable cell.
    func terminalLink(at point: NSPoint) -> String? {
        guard let cell = terminalCell(at: point) else { return nil }
        return getTerminal().link(
            at: .screen(Position(col: cell.column, row: cell.row)),
            mode: .explicitAndImplicit
        )
    }

    /// Screen-relative cell under `point`.
    ///
    /// Exact rather than approximate: SwiftTerm's optimal frame width is
    /// `cellWidth * cols + scrollerWidth`, and it never hides its scroller, so
    /// subtracting the scroller recovers the true cell width.
    func terminalCell(at point: NSPoint) -> (column: Int, row: Int)? {
        guard bounds.contains(point) else { return nil }
        let dimensions = getTerminal().getDims()
        guard dimensions.cols > 0, dimensions.rows > 0 else { return nil }
        let optimal = getOptimalFrameSize().size
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
        let cellWidth = max(1, (optimal.width - scrollerWidth) / CGFloat(dimensions.cols))
        let cellHeight = max(1, optimal.height / CGFloat(dimensions.rows))
        let column = max(0, min(dimensions.cols - 1, Int(point.x / cellWidth)))
        let row = max(0, min(dimensions.rows - 1, Int((bounds.height - point.y) / cellHeight)))
        return (column, row)
    }

    /// True when the viewport is showing live output, so a screen row equals the
    /// row the cursor reports. On the alternate screen SwiftTerm reports
    /// `canScroll == false`, which is exactly the full-screen-TUI case.
    var isViewportAtLiveBottom: Bool {
        !canScroll || scrollPosition >= 1.0
    }

    private func updateLinkCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (terminalLink(at: point) == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    /// Whether this terminal is the thing under the pointer, and therefore
    /// entitled to set the cursor for this event.
    ///
    /// The link affordance is driven by a *local NSEvent monitor* rather than by
    /// SwiftTerm's own (non-open) mouse callbacks, and a local monitor sees every
    /// `.mouseMoved` in the window — not only the ones over this view. Its sole
    /// guard used to be `event.window === window`, so every mounted terminal
    /// stamped `NSCursor.iBeam` on every pointer motion anywhere in its window,
    /// including motion over the sidebar splitter and the pane and panel
    /// dividers. Those dividers set `resizeLeftRight` from a `.cursorUpdate`
    /// tracking area, which fires once on entry; the very next mouse-moved event
    /// put the I-beam straight back. That is the whole "the resize cursor does
    /// not appear reliably" report: the cursor was being set correctly and then
    /// immediately overwritten, a frame later, by a view the pointer was nowhere
    /// near.
    ///
    /// Containment alone is not enough, because a divider corridor deliberately
    /// *overhangs* the cards on either side of it — inside this view's bounds is
    /// exactly where the contested pixels are. So this asks AppKit the same
    /// question a click does: hit-test the window and require the answer to be
    /// this view or something inside it. A tracker sitting above the terminal
    /// then wins the cursor, and a terminal with nothing over it is unaffected.
    private func ownsPointer(for event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        // `visibleRect`, not `bounds`: a pane scrolled or clipped out from under
        // the pointer must not claim it.
        guard visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return false }
        guard let hit = window.contentView?.hitTest(event.locationInWindow) else { return false }
        var candidate: NSView? = hit
        while let view = candidate {
            if view === self { return true }
            candidate = view.superview
        }
        return false
    }
    private var linkInteractionMonitor: Any?
    private var linkPointerDownInView = false
    fileprivate var linkPointerDragged = false

    /// Terminal-style contextual commands. SwiftTerm provides the responder
    /// actions but no contextual menu of its own, so right-click previously
    /// offered none of the basic selection/copy controls users expect from a
    /// macOS terminal.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Terminal")
        addContextItem("Copy", action: #selector(copy(_:)), to: menu)
        semanticTracker.prune(before: getTerminal().buffer.totalLinesTrimmed)
        if !semanticTracker.commands.isEmpty {
            menu.addItem(.separator())
            let previous = addContextItem(
                "Previous Command",
                action: #selector(navigateToPreviousSemanticCommand(_:)),
                to: menu
            )
            previous.isEnabled = semanticPromptDestination(backward: true) != nil
            let next = addContextItem(
                "Next Command",
                action: #selector(navigateToNextSemanticCommand(_:)),
                to: menu
            )
            next.isEnabled = semanticPromptDestination(backward: false) != nil
        }
        menu.addItem(.separator())
        addContextItem("Select All", action: #selector(selectAll(_:)), to: menu)
        return menu
    }

    @discardableResult
    func addContextItem(
        _ title: String,
        action: Selector,
        to menu: NSMenu,
        at index: Int? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let index {
            menu.insertItem(item, at: index)
        } else {
            menu.addItem(item)
        }
        return item
    }

    /// Claim keyboard focus only from the window itself or its bare content
    /// view — never from a control the user is actually in (the sidebar list
    /// or the find bar's text field).
    static func shouldClaimFocus(currentFirstResponder: NSResponder?, window: NSWindow) -> Bool {
        currentFirstResponder == nil
            || currentFirstResponder === window
            || currentFirstResponder === window.contentView
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let linkInteractionMonitor {
                NSEvent.removeMonitor(linkInteractionMonitor)
                self.linkInteractionMonitor = nil
            }
            linkPointerDownInView = false
            linkPointerDragged = false
        } else if linkInteractionMonitor == nil {
            // SwiftTerm's mouse callbacks are intentionally non-open. A local
            // monitor adds the cursor affordance and keeps a selection drag
            // from becoming a click when it ends over a link. SwiftTerm still
            // owns hover detection, selection, and TUI mouse reporting.
            linkInteractionMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self,
                          let window = self.window,
                          event.window === window else { return }
                    switch event.type {
                    case .mouseMoved:
                        // Only when the pointer is actually ours; see
                        // `ownsPointer(for:)`. Without this the terminal
                        // overwrote every divider's resize cursor.
                        guard self.ownsPointer(for: event) else { break }
                        self.updateLinkCursor(for: event)
                    case .leftMouseDown:
                        // Match the cursor path's hit-test ownership guard. A
                        // divider corridor can deliberately overhang this
                        // terminal's bounds; a press there belongs to the
                        // divider, not to terminal link-selection state.
                        self.linkPointerDownInView = self.ownsPointer(for: event)
                        self.linkPointerDragged = false
                    case .leftMouseDragged where self.linkPointerDownInView:
                        self.linkPointerDragged = true
                        // `mouseUp` opens a hover-visible link. Temporarily
                        // require Command after a real selection drag so the
                        // selection completes without surprising navigation.
                        self.linkHighlightMode = .hoverWithModifier
                    case .leftMouseUp where self.linkPointerDownInView:
                        let restoreHover = self.linkPointerDragged
                        self.linkPointerDownInView = false
                        self.linkPointerDragged = false
                        if restoreHover {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.window != nil else { return }
                                self.configureLinkInteraction()
                            }
                        }
                    default:
                        break
                    }
                }
                return event
            }
        }
        guard let window else { return }
        if Self.shouldClaimFocus(currentFirstResponder: window.firstResponder, window: window) {
            // AppKit-only: a mounting pane (a restored window, a project
            // switch reattaching a retained view) legitimately needs *some*
            // first responder, but mounting is not a user action. Publishing
            // here would let whichever pane happens to mount last steal the
            // pane focus ring — and the broker observer role that follows it
            // — from the pane the model actually restored. Only a genuine
            // user gesture (`mouseDown` below) reports keyboard focus to the
            // model.
            window.makeFirstResponder(self)
        }
    }

    /// SwiftTerm declares `becomeFirstResponder()` `public`, not `open`, so a
    /// subclass in this module cannot observe focus acquisition directly. A
    /// mouse-down in the grid is exactly when AppKit hands this view the first
    /// responder, and it is precisely the desync the pane ring had: keyboard
    /// focus moved into this pane while the ring stayed on the previous one.
    override func mouseDown(with event: NSEvent) {
        publishKeyboardFocus()
        super.mouseDown(with: event)
    }

    /// Tell the shell that typing now lands here. The shell ignores a report
    /// for the pane it already rings, so repeat clicks cost nothing.
    func publishKeyboardFocus() {
        onKeyboardFocus?()
    }

    override func layout() {
        super.layout()
        layoutJumpToLiveBottomAffordance()
        updateSemanticDecorations()
        if hasUsableRenderGeometry {
            onUsableLayout?()
        }
    }

    /// NavigationSplitView may assign a representable's final frame without a
    /// separate AppKit layout pass. Initial terminal replay cannot depend on
    /// `layout()` alone or the left-tree surface can remain an empty canvas
    /// until the user resizes the window. Frame assignment is the earliest
    /// reliable point at which SwiftTerm has real rows and columns.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reconcileSemanticPromptGrid()
        updateSemanticDecorations()
        if hasUsableRenderGeometry {
            onUsableLayout?()
        }
    }

    /// Which palette is installed, so appearance/palette flips reconfigure once.
    private(set) var isLightTheme = false
    private(set) var themeKey = ""

    /// Installs either the clean native palette or the Electron-matched Kaisola
    /// palette. Both remain fully opaque so glass chrome never compromises a
    /// terminal's contrast.
    func configureTerminalTheme(light: Bool = false, mode: TerminalPaletteMode = .native) {
        let palette = TerminalTheme.palette(light: light, mode: mode)
        isLightTheme = light
        themeKey = "\(mode.rawValue):\(light ? "light" : "dark")"
        installColors(palette.ansi)
        nativeForegroundColor = palette.foreground
        nativeBackgroundColor = palette.background
        caretColor = palette.cursor
        selectedTextBackgroundColor = palette.selection
        useBrightColors = true
        wantsLayer = true
        layer?.backgroundColor = palette.background.cgColor
    }

    /// SwiftTerm advertises Sixel in its primary device attributes by default.
    /// Codex uses that capability to paint clipboard-image previews into the
    /// terminal grid; large previews can outlive a TUI reflow and overlap later
    /// rows while the user scrolls or output arrives. Keep clipboard attachment
    /// inside Codex, but withhold the unstable graphical preview capability so
    /// the CLI uses its text attachment fallback until the renderer has a
    /// continuous-output/resize-safe image lifecycle.
    func configureAdvertisedGraphicsCapabilities() {
        getTerminal().options.enableSixelReported = false
    }

    func updateAccessibilityValue(from output: String) {
        accessibilitySource = output
    }

    func updateAccessibilityValue(from scrollback: TerminalScrollback) {
        accessibilitySource = scrollback.accessibilityTail(
            maxCharacters: Self.accessibilityTailLimit
        )
    }

    /// Historical reconstruction is deliberately silent. Capture its final
    /// rendered viewport as the comparison baseline so the first live packet
    /// cannot make VoiceOver recite retained output from before the pane opened.
    func seedAccessibilityAnnouncementBaseline() {
        cancelAccessibilityAnnouncement()
        accessibilityAnnouncementBaseline = accessibilityTextSnapshot()
        accessibilityAnnouncementNeedsBaseline = false
    }

    /// A live feed only marks work pending. Snapshotting and diffing wait for
    /// the throttle boundary, so token-by-token output never scans the viewport
    /// token by token. Only the AppKit-focused pane may speak; background panes
    /// mark their baseline stale and resume without announcing a backlog.
    func noteLiveOutputForAccessibility() {
        guard accessibilityAnnouncementVoiceOverEnabled(),
              window?.firstResponder === self else {
            cancelAccessibilityAnnouncement()
            accessibilityAnnouncementNeedsBaseline = true
            return
        }
        if accessibilityAnnouncementNeedsBaseline {
            accessibilityAnnouncementBaseline = accessibilityTextSnapshot()
            accessibilityAnnouncementNeedsBaseline = false
            return
        }
        guard !accessibilityAnnouncementIsScheduled else { return }
        accessibilityAnnouncementIsScheduled = true
        accessibilityAnnouncementScheduleCount += 1
        perform(
            #selector(deliverAccessibilityAnnouncement),
            with: nil,
            afterDelay: TerminalAccessibilityAnnouncementPolicy.throttleInterval
        )
    }

    /// Deterministic test seam; production reaches the same delivery through
    /// the main-run-loop selector scheduled above.
    func deliverAccessibilityAnnouncementNow() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(deliverAccessibilityAnnouncement),
            object: nil
        )
        accessibilityAnnouncementIsScheduled = false
        deliverAccessibilityAnnouncement()
    }

    private func cancelAccessibilityAnnouncement() {
        guard accessibilityAnnouncementIsScheduled else { return }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(deliverAccessibilityAnnouncement),
            object: nil
        )
        accessibilityAnnouncementIsScheduled = false
    }

    @objc private func deliverAccessibilityAnnouncement() {
        accessibilityAnnouncementIsScheduled = false
        guard accessibilityAnnouncementVoiceOverEnabled(),
              window?.firstResponder === self else {
            accessibilityAnnouncementNeedsBaseline = true
            return
        }

        let current = accessibilityTextSnapshot()
        let previous = accessibilityAnnouncementBaseline
        accessibilityAnnouncementBaseline = current
        accessibilityAnnouncementNeedsBaseline = false
        guard let announcement = TerminalAccessibilityAnnouncementPolicy.announcement(
            previous: previous,
            current: current
        ) else { return }

        if let accessibilityAnnouncementPoster {
            accessibilityAnnouncementPoster(announcement)
        } else {
            NSAccessibility.post(
                element: self,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    /// Snap the viewport to the newest output (Electron sticky-scroll parity).
    /// `scroll(toPosition:)` is SwiftTerm's public relative-scroll API — 1.0 is
    /// the live bottom — and is a harmless no-op when there is nothing to
    /// scroll, so callers can invoke it after every feed while pinned.
    func scrollToLiveBottom() {
        scroll(toPosition: 1)
        updateSemanticDecorations()
    }

    /// Erase the live renderer without touching the broker's retained history
    /// or the PTY. See `TerminalClearCommand` for why that is the only honest
    /// meaning "Clear Terminal" can have on a broker-backed surface.
    ///
    /// Refuses (returning `false`) while a retained transcript is still being
    /// fed in progressively: clearing now would only be half-undone a moment
    /// later when the next replay chunk repaints over it.
    @discardableResult
    func clearLiveScrollback() -> Bool {
        guard (terminalDelegate as? NativeTerminalSurface.Coordinator)?.isProgressivelyReplaying != true else {
            ToastCenter.shared.show(TerminalClearCommand.noTerminalMessage, style: .info)
            return false
        }
        feed(text: TerminalClearCommand.escapeSequence)
        // ED 3 resets `buffer.linesTop`, the coordinate space every recorded
        // OSC 133 mark lives in. Stale marks would decorate unrelated rows, so
        // drop the index and let later marks rebuild trustworthy bounds.
        resetSemanticPromptMarks()
        // The scrollback the user had scrolled into no longer exists, so the
        // pin state describing it is meaningless: follow live output again.
        resumeLiveFollow()
        scrollToLiveBottom()
        return true
    }

    /// Return the surface to sticky-scroll follow mode. Shared by the jump pill
    /// and by clearing, both of which end with the viewport at the live bottom.
    func resumeLiveFollow() {
        (terminalDelegate as? NativeTerminalSurface.Coordinator)?.resumeLiveFollow()
    }

    /// A small trailing pill offering the way back to live output. It exists
    /// only while the user is genuinely scrolled up; a permanently visible
    /// control would just be chrome over the terminal.
    func configureJumpToLiveBottomAffordance() {
        guard jumpToLiveBottomButton == nil else { return }
        let button = NSButton(
            title: "Latest",
            image: NSImage(
                systemSymbolName: "arrow.down.to.line.compact",
                accessibilityDescription: nil
            ) ?? NSImage(),
            target: self,
            action: #selector(jumpToLiveBottomClicked(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.isHidden = true
        button.toolTip = "Scroll to the newest output"
        button.setAccessibilityLabel("Scroll to latest output")
        button.setAccessibilityHelp("Returns this terminal to live output and resumes following it")
        addSubview(button, positioned: .above, relativeTo: nil)
        jumpToLiveBottomButton = button
        layoutJumpToLiveBottomAffordance()
    }

    @objc private func jumpToLiveBottomClicked(_ sender: Any?) {
        resumeLiveFollow()
        scrollToLiveBottom()
    }

    /// Visible only while the viewport is genuinely parked above live output.
    func updateJumpToLiveBottomVisibility() {
        guard let button = jumpToLiveBottomButton else { return }
        let visible = TerminalJumpToBottomPolicy.isVisible(
            canScroll: canScroll,
            isAtLiveBottom: isViewportAtLiveBottom,
            isAlternateBuffer: getTerminal().isCurrentBufferAlternate
        )
        guard button.isHidden == visible else { return }
        button.isHidden = !visible
        if visible { layoutJumpToLiveBottomAffordance() }
    }

    private func layoutJumpToLiveBottomAffordance() {
        guard let button = jumpToLiveBottomButton else { return }
        button.sizeToFit()
        button.frame = TerminalJumpToBottomPolicy.frame(
            in: bounds,
            size: button.frame.size,
            flipped: isFlipped
        )
    }

    /// Test seam: the affordance is a private subview, but its state is the
    /// whole contract ("only while scrolled up").
    var jumpToLiveBottomIsVisible: Bool {
        jumpToLiveBottomButton.map { !$0.isHidden } ?? false
    }

    @discardableResult
    func performJumpToLiveBottom() -> Bool {
        guard let button = jumpToLiveBottomButton, !button.isHidden else { return false }
        jumpToLiveBottomClicked(button)
        return true
    }

    /// Launch command of the CLI running in this pane (`claude`, `codex`, …), so
    /// a dropped image can use the attachment syntax that CLI understands. Nil
    /// for a plain shell, where a bare path is the correct thing to paste.
    var agentLaunchCommand: String?

    /// True only when a real user scroll gesture is in flight.
    ///
    /// SwiftTerm's `scrollWheel` is `public` rather than `open` and its
    /// `pageUp`/`pageDown` live in an extension, so none of them can be
    /// overridden from this module. A local event monitor observes the same
    /// gestures without subclassing.
    var isUserScrollGesture: Bool { TerminalScrollGestureMonitor.isActive(for: self) }

    /// Mirrors SwiftTerm's wheel-routing decision without touching its private
    /// accumulator: normal-buffer events use native scrollback unless the
    /// application requested mouse reports and Shift did not bypass them.
    func wheelUsesNativeScrollback(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        let shiftBypassesMouseReporting = event.modifierFlags.contains(.shift)
            && !terminal.mouseShiftCapture
        return !terminal.isCurrentBufferAlternate
            && canScroll
            && (!allowMouseReporting
                || terminal.mouseMode == .off
                || shiftBypassesMouseReporting)
    }

    /// A second upward gesture at row zero is the explicit seam between the
    /// interactive renderer and immutable history. Returning `true` means the
    /// request was accepted; the wheel event itself still reaches SwiftTerm and
    /// remains a harmless top-edge no-op. Alternate-screen TUIs never enter
    /// this lane because `canScroll` is false there.
    @discardableResult
    func requestHistoryBeyondTop(
        scrollingDeltaY: CGFloat,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard scrollingDeltaY > 0,
              canScroll,
              getTerminal().getTopVisibleRow() == 0,
              let onHistoryBoundary,
              now - lastHistoryBoundaryRequestAt >= Self.historyBoundaryRequestCooldown else {
            return false
        }
        lastHistoryBoundaryRequestAt = now
        onHistoryBoundary()
        return true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? { accessibilityTextSnapshot() }

    private func accessibilityTextSnapshot() -> String {
        let terminal = getTerminal()
        let dimensions = terminal.getDims()
        if dimensions.cols > 0, dimensions.rows > 0 {
            let viewportTop = max(0, terminal.getTopVisibleRow())
            let rendered = terminal.getText(
                start: Position(col: 0, row: viewportTop),
                end: Position(
                    col: dimensions.cols,
                    row: viewportTop + dimensions.rows
                )
            )
            if !rendered.isEmpty {
                return String(rendered.suffix(Self.accessibilityTailLimit))
            }
        }

        // Initial progressive replay can leave the parsed grid empty for a few
        // main-actor turns. Never expose the raw broker stream during that
        // window: replay only its bounded tail through the same parser used by
        // transcript export, so OSC/CSI/DCS bytes cannot reach VoiceOver.
        let rawTail = String(accessibilitySource.suffix(Self.accessibilityTailLimit))
        let plain = TerminalTranscriptSanitizer.plainPages(
            [rawTail],
            columns: max(2, dimensions.cols),
            rows: max(1, dimensions.rows)
        ).joined()
        return String(plain.suffix(Self.accessibilityTailLimit))
    }
}

/// Draws quiet, noninteractive command separators over marked terminal rows.
/// Row-boundary rules and an extremely light wash give shell output visible
/// block structure without changing the PTY grid or intercepting selection and
/// link clicks.
final class TerminalSemanticDecorationView: NSView {
    private var decorations: [TerminalSemanticDecoration] = []
    private var rowCount = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func update(decorations: [TerminalSemanticDecoration], rowCount: Int) {
        guard self.decorations != decorations || self.rowCount != rowCount else { return }
        self.decorations = decorations
        self.rowCount = rowCount
        isHidden = decorations.isEmpty || rowCount <= 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard rowCount > 0, !decorations.isEmpty else { return }
        let rowHeight = bounds.height / CGFloat(rowCount)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixel = 1 / max(1, scale)

        for decoration in decorations {
            let color: NSColor
            switch decoration.phase {
            case .input: color = .controlAccentColor
            case .running: color = .systemOrange
            case .succeeded: color = .systemGreen
            case .failed: color = .systemRed
            case .completed: color = .secondaryLabelColor
            }
            let top = bounds.maxY - CGFloat(decoration.startViewportRow) * rowHeight
            let bottom = bounds.maxY - CGFloat(decoration.endViewportRow + 1) * rowHeight
            let contentWidth = max(0, bounds.width - 16)
            color.withAlphaComponent(0.025).setFill()
            NSBezierPath.fill(
                NSRect(x: 0, y: bottom, width: contentWidth, height: max(0, top - bottom))
            )
            color.withAlphaComponent(0.72).setFill()
            NSBezierPath.fill(
                NSRect(
                    x: 0,
                    y: top - 2 * pixel,
                    width: min(42, contentWidth),
                    height: 2 * pixel
                )
            )
        }
    }
}

/// Records when the user last performed a scroll gesture, so terminal scroll
/// callbacks can be attributed to intent rather than to layout.
///
/// SwiftTerm emits `scrolled(source:position:)` from several paths that involve
/// no user at all — `Terminal.resize` (which every pane geometry change runs),
/// a one-second synchronized-output timeout that agent TUIs arm constantly via
/// DECSET 2026, and `resetToInitialState`. Each of those latched the surface's
/// "user scrolled away" flag, after which nothing ever re-pinned it; that is why
/// terminals came back from a project tab switch stranded mid-scrollback.
///
/// A local monitor is used because SwiftTerm exposes none of these entry points
/// for overriding: `scrollWheel` is `public`, not `open`, and `pageUp`/`pageDown`
/// are declared in an extension.
@MainActor
enum TerminalScrollGestureMonitor {
    /// How long after a gesture a scroll callback is still attributed to it.
    /// Comfortably covers a queued display pass without spanning the 1s
    /// synchronized-output timeout.
    static let recencyWindow: TimeInterval = 0.25

    private static var monitor: Any?
    private static var lastGestureTimestamp: TimeInterval = -.greatestFiniteMagnitude
    private static weak var lastGestureView: ReadOnlyTerminalView?
    private static var lastGestureWasUpward = false
    private static weak var activeScrollerGestureView: ReadOnlyTerminalView?

    /// Page keys SwiftTerm treats as scrollback navigation.
    private static let scrollKeyCodes: Set<UInt16> = [116, 121] // page up, page down

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .scrollWheel, .magnify, .swipe, .keyDown,
                .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            ]
        ) { event in
            if event.type == .leftMouseDown
                || event.type == .leftMouseDragged
                || event.type == .leftMouseUp {
                let view: ReadOnlyTerminalView?
                if event.type == .leftMouseDown {
                    view = terminalViewForScroller(at: event)
                    activeScrollerGestureView = view
                } else {
                    view = activeScrollerGestureView
                }
                if let view, event.window === view.window {
                    recordGesture(view: view, at: event.timestamp, scrollingUpward: false)
                }
                if event.type == .leftMouseUp {
                    activeScrollerGestureView = nil
                }
                return event
            }
            if event.type == .keyDown,
               let view = terminalView(for: event),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.keyCode == 126 || event.keyCode == 125 {
                let backward = event.keyCode == 126
                // Attribute the gesture before `scrollTo(row:)` invokes the
                // delegate synchronously; otherwise output can immediately
                // undo this explicit command jump.
                if view.navigateSemanticPrompt(
                    backward: backward,
                    beforeScroll: {
                        recordGesture(
                            view: view,
                            at: event.timestamp,
                            scrollingUpward: backward
                        )
                    }
                ) {
                    return nil
                }
            }
            if let view = terminalView(for: event),
               (event.type != .keyDown || scrollKeyCodes.contains(event.keyCode)) {
                if event.type == .scrollWheel {
                    recordGesture(
                        view: view,
                        at: event.timestamp,
                        scrollingUpward: event.scrollingDeltaY > 0
                            && view.wheelUsesNativeScrollback(event)
                    )
                } else if event.type == .keyDown {
                    recordGesture(
                        view: view,
                        at: event.timestamp,
                        scrollingUpward: view.canScroll && event.keyCode == 116
                    )
                } else {
                    recordGesture(
                        view: view,
                        at: event.timestamp,
                        scrollingUpward: false
                    )
                }
                if event.type == .scrollWheel {
                    // SwiftTerm uses positive `scrollingDeltaY` for upward
                    // movement. The monitor runs before its non-open
                    // `scrollWheel(with:)`, so a gesture that first reaches row
                    // zero stays in the terminal; only the next upward event
                    // crosses into the paged history surface.
                    _ = view.requestHistoryBeyondTop(
                        scrollingDeltaY: event.scrollingDeltaY,
                        now: event.timestamp
                    )
                } else if event.type == .keyDown, event.keyCode == 116 {
                    // Page Up is SwiftTerm's keyboard scrollback route.
                    // Repeating it at row zero should cross the same history
                    // seam as a continued trackpad gesture. Home/End are sent
                    // to the application and are intentionally not attributed.
                    _ = view.requestHistoryBeyondTop(
                        scrollingDeltaY: 1,
                        now: event.timestamp
                    )
                }
            }
            return event
        }
    }

    /// `NSEvent.timestamp` and `systemUptime` share the same time base.
    static func isActive(for view: ReadOnlyTerminalView) -> Bool {
        lastGestureView === view
            && ProcessInfo.processInfo.systemUptime - lastGestureTimestamp < recencyWindow
    }

    static func isScrollingUpward(for view: ReadOnlyTerminalView) -> Bool {
        isActive(for: view) && lastGestureWasUpward
    }

    /// A real SwiftTerm scroll callback supersedes the pending direction hint;
    /// from this point the exact public position is the pinning authority.
    static func acknowledgeScrollPosition(for view: ReadOnlyTerminalView) {
        guard lastGestureView === view else { return }
        lastGestureWasUpward = false
    }

    /// Test seam — lets the pin policy be exercised without synthesising events.
    static func noteGestureForTesting(
        view: ReadOnlyTerminalView,
        at timestamp: TimeInterval? = nil,
        scrollingUpward: Bool = true
    ) {
        lastGestureTimestamp = timestamp ?? ProcessInfo.processInfo.systemUptime
        lastGestureView = view
        lastGestureWasUpward = scrollingUpward
    }

    static func resetForTesting() {
        lastGestureTimestamp = -.greatestFiniteMagnitude
        lastGestureView = nil
        lastGestureWasUpward = false
        activeScrollerGestureView = nil
    }

    private static func recordGesture(
        view: ReadOnlyTerminalView,
        at timestamp: TimeInterval,
        scrollingUpward: Bool
    ) {
        lastGestureTimestamp = timestamp
        lastGestureView = view
        lastGestureWasUpward = scrollingUpward
    }

    /// Attribute mouse tracking only when it began on SwiftTerm's actual native
    /// NSScroller. Text selection and link clicks inside the terminal must not
    /// acquire permission to mutate sticky-scroll state.
    private static func terminalViewForScroller(at event: NSEvent) -> ReadOnlyTerminalView? {
        guard let window = event.window,
              let contentView = window.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        var foundScroller = false
        while let view = candidate {
            if view is NSScroller { foundScroller = true }
            if let terminal = view as? ReadOnlyTerminalView {
                return foundScroller ? terminal : nil
            }
            candidate = view.superview
        }
        return nil
    }

    private static func terminalView(for event: NSEvent) -> ReadOnlyTerminalView? {
        if event.type == .keyDown {
            return event.window?.firstResponder as? ReadOnlyTerminalView
        }
        guard let window = event.window,
              let contentView = window.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let view = candidate {
            if let terminal = view as? ReadOnlyTerminalView { return terminal }
            candidate = view.superview
        }
        return nil
    }
}

/// The writable variant for native-owned sessions: SwiftTerm's normal input
/// path stays intact and lands in the delegate's `send`, which the surface
/// forwards to the broker controller connection.
final class OwnedTerminalView: ReadOnlyTerminalView {
    private var fileDropActive = false

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send(source: self, data: data)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu(title: "Terminal")
        addContextItem("Paste", action: #selector(paste(_:)), to: menu, at: min(1, menu.items.count))
        return menu
    }

    /// Codex owns clipboard-image ingestion behind Control-V, while macOS
    /// users naturally invoke Command-V (including Edit > Paste). SwiftTerm's
    /// generic paste implementation only asks the pasteboard for text, so an
    /// image-only clipboard otherwise becomes a silent no-op. Forward the
    /// image-specific key to Codex only when an image is actually present;
    /// ordinary text continues through SwiftTerm's bracketed-paste path.
    override func paste(_ sender: Any) {
        if agentLaunchCommand == "codex",
           TerminalImageDrop.pasteboardContainsImage(.general) {
            send(source: getTerminal(), data: ArraySlice([0x16]))
            return
        }
        super.paste(sender)
    }

    /// ⌥-click moves the cursor to the click, the way iTerm2 and Terminal.app
    /// do — which is how you reposition inside an agent CLI's composer.
    ///
    /// Nothing in the stack implemented this: SwiftTerm reads `.shift` on the
    /// mouse paths and never `.option`, so a ⌥-click landed in a branch that
    /// does nothing. Worse, it wasn't inert — link activation ignores modifiers,
    /// so ⌥-clicking a path in the composer opened a file preview instead.
    ///
    /// This is synthesised as arrow keys, which is what terminal emulators
    /// actually do; there is no protocol-level "put the cursor here". The
    /// horizontal case needs only `getCursorLocation()`. Vertical movement is
    /// allowed solely when OSC 133 proves both rows are active prompt input.
    override func mouseUp(with event: NSEvent) {
        guard shouldHandleOptionClick(event),
              let cell = terminalCell(at: convert(event.locationInWindow, from: nil)),
              // A scrolled-back viewport row is not the cursor's screen row.
              isViewportAtLiveBottom
        else {
            super.mouseUp(with: event)
            return
        }

        // Claim the event either way. Returning without `super` is what
        // suppresses the link activation and mouse-report release below it.
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        // Outside a proven active OSC 133 input region, Up/Down can recall
        // history in shell and agent composers. Consume the vertical click
        // without emitting bytes when either row lies beyond those bounds.
        let verticalDelta = cell.row - cursor.y
        if verticalDelta != 0 {
            guard let cursorPosition = scrollInvariantCursorPosition(),
                  let inputRows = semanticTracker.activeInputRows else { return }
            let clickedRow = terminal.buffer.totalLinesTrimmed
                + terminal.getTopVisibleRow()
                + cell.row
            guard inputRows.contains(cursorPosition.row),
                  inputRows.contains(clickedRow) else { return }
        }

        let horizontalDelta = cell.column - cursor.x
        guard verticalDelta != 0 || horizontalDelta != 0 else { return }

        let applicationCursor = terminal.applicationCursor
        // Capped so a stray click on a very wide pane cannot spray hundreds of
        // bytes at the CLI.
        var payload: [UInt8] = []
        let verticalKey = verticalDelta > 0
            ? (applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            : (applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
        for _ in 0..<min(abs(verticalDelta), terminal.rows) {
            payload.append(contentsOf: verticalKey)
        }
        let horizontalKey = horizontalDelta > 0
            ? (applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
            : (applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
        for _ in 0..<min(abs(horizontalDelta), terminal.cols) {
            payload.append(contentsOf: horizontalKey)
        }
        send(source: terminal, data: ArraySlice(payload))
    }

    /// Option alone, a real click rather than the end of a drag-selection.
    private func shouldHandleOptionClick(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1, !linkPointerDragged else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
    }

    /// Finder/iTerm-style file drops are bracketed-pasted into the active CLI.
    /// Using SwiftTerm's paste path (rather than a raw broker write) preserves
    /// the terminal mode those TUIs negotiated.
    ///
    /// See `TerminalImageDrop` for why an image is staged and mentioned rather
    /// than pasted as a plain path — in short, a quoted path attaches nothing,
    /// and macOS screenshot filenames contain spaces that break `@` mentions.
    static func droppedFileText(_ urls: [URL], agentLaunchCommand: String?) -> String {
        droppedFilePlan(urls, agentLaunchCommand: agentLaunchCommand).text
    }

    static func droppedFilePlan(
        _ urls: [URL],
        agentLaunchCommand: String?
    ) -> TerminalImageDrop.InsertionPlan {
        TerminalImageDrop.insertionPlan(
            for: urls,
            syntax: TerminalImageDrop.syntax(forLaunchCommand: agentLaunchCommand)
        )
    }

    private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    private func setFileDropActive(_ active: Bool) {
        guard fileDropActive != active else { return }
        fileDropActive = active
        wantsLayer = true
        layer?.borderWidth = active ? 2 : 0
        layer?.borderColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor : nil
        layer?.cornerRadius = active ? 9 : 0
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = !droppedFileURLs(from: sender.draggingPasteboard).isEmpty
        setFileDropActive(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = !droppedFileURLs(from: sender.draggingPasteboard).isEmpty
        setFileDropActive(accepts)
        return accepts ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setFileDropActive(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !droppedFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setFileDropActive(false) }
        let urls = droppedFileURLs(from: sender.draggingPasteboard)
        let plan = Self.droppedFilePlan(urls, agentLaunchCommand: agentLaunchCommand)
        guard !plan.text.isEmpty else { return false }
        window?.makeFirstResponder(self)
        let terminal = getTerminal()
        if terminal.bracketedPasteMode {
            send(source: terminal, data: ArraySlice(Array("\u{1B}[200~".utf8)))
        }
        send(source: terminal, data: ArraySlice(Array(plan.text.utf8)))
        if terminal.bracketedPasteMode {
            send(source: terminal, data: ArraySlice(Array("\u{1B}[201~".utf8)))
        }
        if let warning = plan.warningMessage {
            ToastCenter.shared.show(warning, style: .error, duration: 5)
        }
        return true
    }

    /// Shift+Enter types a newline instead of submitting — ESC CR, the mapping
    /// Claude/Codex CLIs (and the Electron terminal) treat as "insert line
    /// break". SwiftTerm's `keyDown` isn't `open`, so the intercept rides a
    /// local monitor that only claims the event while this view is focused;
    /// it uninstalls when the view leaves its window (weak self keeps a
    /// stragglling monitor harmless).
    private var shiftEnterMonitor: Any?

    static func shouldHandleShiftEnter(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        keyCode == 36
            && modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            unregisterDraggedTypes()
            setFileDropActive(false)
            if let shiftEnterMonitor {
                NSEvent.removeMonitor(shiftEnterMonitor)
                self.shiftEnterMonitor = nil
            }
        } else if shiftEnterMonitor == nil {
            registerForDraggedTypes([.fileURL])
            shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard Self.shouldHandleShiftEnter(
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags
                ) else { return event }
                // Local monitors fire on the main thread; NSEvent itself must
                // stay outside the isolation hop (it isn't Sendable).
                let handled = MainActor.assumeIsolated { () -> Bool in
                    // Only claim the keystroke when THIS view is the first
                    // responder of the KEY window — otherwise a background
                    // window's terminal would swallow a Shift+Enter meant for
                    // whatever the user is actually focused on.
                    guard let self,
                          let window = self.window,
                          window.isKeyWindow,
                          window.firstResponder === self else { return false }
                    self.terminalDelegate?.send(source: self, data: ArraySlice([0x1B, 0x0D]))
                    return true
                }
                return handled ? nil : event
            }
        }
    }
}
