import AppKit
import SwiftTerm

/// Owns stream replay, geometry, link routing, and delegate callbacks for one terminal surface.
extension NativeTerminalSurface {
    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        struct ReplayMetrics: Equatable {
            var fullReplayStarts: Int = 0
            var scheduledProgressiveBytes: Int = 0
            var progressiveBytesFed: Int = 0
            var synchronousReplayBytes: Int = 0
        }

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
        private(set) var replayMetrics = ReplayMetrics()
        /// Explicit second gate beneath `OwnedTerminalView`. A stale delegate
        /// call cannot cross an ownership transition even before AppModel and
        /// the broker perform their independent owner checks.
        private var isInputAuthorized = false
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
            isInputAuthorized = false
            onInput = nil
            onResize = nil
            setTitleChangeHandler(nil)
            onBell = nil
        }

        func setInputAuthorized(_ authorized: Bool) {
            isInputAuthorized = authorized
        }

        /// Revocation also discards a title waiting in the trailing debounce.
        /// Otherwise a title parsed while owned could publish into a callback
        /// rebound after a reconnect and mutate a now-observed session.
        func setTitleChangeHandler(_ handler: ((String) -> Void)?) {
            onTitleChange = handler
            guard handler == nil else { return }
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(deliverPendingTitleChange),
                object: nil
            )
            pendingTitleChange = nil
            titleChangeDeliveryScheduled = false
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
            // Skipped only on the path that is about to return having rendered
            // nothing. `updateNSView` runs this on every SwiftUI update, not
            // only on new output, and building the value walks the page table
            // and joins an 8,000-character tail — real work to restate a value
            // that cannot have changed, because the guard below returns exactly
            // when the epoch and end offset both match what is already drawn.
            //
            // Deliberately not gated on whether VoiceOver is running. That is
            // the larger saving, but the retained value would then be stale for
            // anyone enabling VoiceOver mid-session, and doing it correctly
            // needs a status-change signal to repopulate from. Not worth
            // guessing at for an allocation nobody has measured.
            if !(epoch == renderedEpoch && endOffset == renderedEndOffset) {
                view.updateAccessibilityValue(from: scrollback)
            }
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
                replayMetrics.fullReplayStarts += 1
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
                replayMetrics.synchronousReplayBytes += scrollback.byteCount
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
                replayMetrics.fullReplayStarts += 1
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
                replayMetrics.synchronousReplayBytes += scrollback.byteCount
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
                replayMetrics.fullReplayStarts += 1
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
                if !output.isEmpty {
                    replayMetrics.synchronousReplayBytes += output.utf8.count
                    feed(output, to: view, suppressReplies: true)
                }
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
                replayMetrics.fullReplayStarts += 1
                if !output.isEmpty {
                    replayMetrics.synchronousReplayBytes += output.utf8.count
                    feed(output, to: view, suppressReplies: true)
                }
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
            replayMetrics.scheduledProgressiveBytes += output.utf8.count
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
                    self.replayMetrics.progressiveBytesFed += output[cursor..<next].utf8.count
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
            replayMetrics.scheduledProgressiveBytes += scrollback.byteCount
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
                        self.replayMetrics.progressiveBytesFed += page[cursor..<next].utf8.count
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
            view.reconcileContinuousViewportAfterBufferChange()
            // Feeding and repinning both used to rebuild the semantic overlay.
            // Record cursor growth first, then paint exactly once after the
            // viewport reaches its final position for this output batch.
            view.observeSemanticPromptCursor(refreshDecorations: false)
            view.allowMouseReporting = restoresMouseReporting
            if scrollAfter, !userUnpinned {
                view.followLiveBottomForStreamedOutput()
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
            view.reconcileContinuousViewportAfterBufferChange()
            view.observeSemanticPromptCursor(refreshDecorations: false)
            view.allowMouseReporting = restoresMouseReporting
            if scrollAfter, !userUnpinned {
                view.followLiveBottomForStreamedOutput()
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
            guard isInputAuthorized,
                  !suppressReplayReplies,
                  let onInput,
                  !data.isEmpty else { return }
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
            MainActor.assumeIsolated {
                view.reconcileContinuousViewportAfterExternalScroll()
                view.updateSemanticDecorations()
            }
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
                // `layout()` fires this on every usable pass, so it is as
                // automatic as the output pin and must respect a gesture in
                // flight for the same reason.
                view.followLiveBottomForStreamedOutput()
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
                //
                // An agent cites a file by the name it used in prose, which is
                // rarely a path relative to the session's directory — so the
                // citation is resolved against the project before it is opened,
                // and a click that cannot find its file says so instead of
                // opening a tab onto nothing.
                let resolved = TerminalFileLinkResolver.resolve(
                    fileURL,
                    projectRoot: workingDirectory
                )
                switch resolved {
                case let .found(url):
                    var userInfo: [AnyHashable: Any] = ["url": url]
                    if let line { userInfo["line"] = line }
                    userInfo["workspaceHint"] = workingDirectory
                        ?? url.deletingLastPathComponent()
                    NotificationCenter.default.post(
                        name: .kaisolaOpenFileLink,
                        object: nil,
                        userInfo: userInfo
                    )
                case let .ambiguous(name, count):
                    ToastCenter.shared.show(
                        "\(count) files are named \(name). Open the one you want from Files.",
                        style: .info,
                        duration: 4
                    )
                case let .missing(name):
                    ToastCenter.shared.show(
                        "Couldn’t find \(name) in this project.",
                        style: .error,
                        duration: 4
                    )
                }
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
