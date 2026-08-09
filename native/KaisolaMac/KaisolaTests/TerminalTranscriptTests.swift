import AppKit
import XCTest
@testable import Kaisola

@MainActor
final class TerminalTranscriptTests: XCTestCase {
    func testTranscriptPrependUsesMomentumPreservationWhenTheOSSupportsIt() {
        if #available(macOS 15.0, *) {
            XCTAssertTrue(TerminalTranscriptScrollPolicy.supportsVelocityPreservation)
        } else {
            XCTAssertFalse(TerminalTranscriptScrollPolicy.supportsVelocityPreservation)
        }
    }

    func testVisualFixtureReturnsOneExactSanitizablePage() throws {
        let page = try VisualTerminalTranscriptFixture.page(
            streamEpoch: "visual-shell",
            beforeOffset: Int64(VisualTerminalTranscriptFixture.output.utf8.count),
            maxBytes: 512 * 1_024
        )

        XCTAssertEqual(page.startOffset, 0)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.truncated)
        let plain = TerminalTranscriptSanitizer.plainPages([page.output]).joined()
        XCTAssertTrue(plain.contains("Kaisola retained terminal history"))
        XCTAssertTrue(plain.contains("café · 研究 · ✅"))
        XCTAssertFalse(plain.contains("\u{1B}"))
    }

    func testLegacyBrokerPagesFrozenRetainedDocumentInsteadOfFailing() throws {
        let output = "first\n" + String(repeating: "middle🙂\n", count: 90_000) + "last\n"
        let endOffset: Int64 = 9_000_000 + Int64(output.utf8.count)
        let context = AppModel.TerminalTranscriptContext(
            id: "terminal:legacy",
            title: "Legacy session",
            streamEpoch: "legacy-epoch",
            endOffset: endOffset,
            diskBytes: 1_024,
            fallbackOutput: output,
            fallbackStartOffset: 9_000_000,
            fallbackTruncated: true,
            brokerSupportsHistory: false,
            columns: 120,
            rows: 40
        )

        let newest = try AppModel.retainedTranscriptPage(
            context: context,
            beforeOffset: endOffset,
            maxBytes: 512 * 1_024
        )
        XCTAssertTrue(newest.output.hasSuffix("last\n"))
        XCTAssertTrue(newest.hasMore)
        XCTAssertTrue(newest.truncated)
        XCTAssertEqual(Int64(newest.output.utf8.count), newest.endOffset - newest.startOffset)

        var pages = [newest]
        while let first = pages.first, first.hasMore {
            pages.insert(try AppModel.retainedTranscriptPage(
                context: context,
                beforeOffset: first.startOffset,
                maxBytes: 512 * 1_024
            ), at: 0)
        }
        XCTAssertEqual(pages.map(\.output).joined(), output)
        XCTAssertEqual(pages.first?.startOffset, 9_000_000)
        XCTAssertFalse(pages.first?.hasMore ?? true)
    }

    func testLegacyBrokerFallbackRejectsMovingOrNonBoundaryCursor() throws {
        let context = AppModel.TerminalTranscriptContext(
            id: "terminal:legacy",
            title: "Legacy session",
            streamEpoch: "legacy-epoch",
            endOffset: 5,
            diskBytes: 0,
            fallbackOutput: "a🙂",
            fallbackStartOffset: 0,
            fallbackTruncated: false,
            brokerSupportsHistory: false,
            columns: 120,
            rows: 40
        )

        XCTAssertThrowsError(try AppModel.retainedTranscriptPage(
            context: context,
            beforeOffset: 2,
            maxBytes: 512
        ))
        XCTAssertThrowsError(try AppModel.retainedTranscriptPage(
            context: context,
            beforeOffset: 6,
            maxBytes: 512
        ))
    }

    func testSearchIsCaseAndDiacriticInsensitiveWithoutOverlappingMatches() {
        let text = "Résumé resume RESUME"
        let ranges = TerminalTranscriptSearch.ranges(in: text, query: "resume")

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(
            ranges.map { (text as NSString).substring(with: $0) },
            ["Résumé", "resume", "RESUME"]
        )
        XCTAssertEqual(
            TerminalTranscriptSearch.matchCount(in: [text, "resume"], query: "resume"),
            4
        )
        XCTAssertTrue(TerminalTranscriptSearch.ranges(in: text, query: "   ").isEmpty)
    }

    func testSearchWorkerCachesLargeTranscriptPreparationByGenerationAndAppearance() async throws {
        let worker = TerminalTranscriptSearchWorker()
        let padding = String(repeating: "0123456789abcdef", count: 30_000)
        let pages = [
            TerminalTranscriptSearchWorker.Page(id: 1, text: "Needle \(padding)"),
            TerminalTranscriptSearchWorker.Page(id: 2, text: "\(padding) résumé"),
        ]
        let request = TerminalTranscriptSearchWorker.Request(
            query: "  resume  ",
            generation: 7,
            dark: false
        )

        let first = try await worker.prepare(pages, request: request)
        let cached = try await worker.prepare(pages, request: request)

        XCTAssertEqual(first.matchCount, 1)
        XCTAssertEqual(first.pages.count, 2)
        XCTAssertEqual(cached.matchCount, first.matchCount)
        let cachedPreparationCount = await worker.preparationCount
        XCTAssertEqual(cachedPreparationCount, 1)

        _ = try await worker.prepare(
            pages,
            request: .init(query: "resume", generation: 7, dark: true)
        )
        let appearancePreparationCount = await worker.preparationCount
        XCTAssertEqual(appearancePreparationCount, 2)
    }

    func testTranscriptUsesTheConfiguredTerminalTypefaceAndWeight() {
        let menlo = TerminalTranscriptTypography.font(
            family: "Menlo",
            size: 17,
            weightRaw: "bold"
        )
        XCTAssertEqual(menlo.familyName, "Menlo")
        XCTAssertEqual(menlo.pointSize, 17, accuracy: 0.001)
        XCTAssertTrue(menlo.isFixedPitch)

        let sentinel = TerminalTranscriptTypography.font(
            family: TerminalFontOptions.systemMonoSentinel,
            size: 13,
            weightRaw: "regular"
        )
        XCTAssertTrue(sentinel.isFixedPitch)
        XCTAssertEqual(sentinel.pointSize, 13, accuracy: 0.001)
    }

    func testTranscriptFontSizeStaysInsideTheSettingsRange() {
        XCTAssertEqual(
            TerminalTranscriptTypography.clampedSize(200),
            NativePreviewSettings.terminalFontRange.upperBound,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TerminalTranscriptTypography.clampedSize(0),
            NativePreviewSettings.terminalFontRange.lowerBound,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TerminalTranscriptTypography.clampedSize(.nan),
            NativePreviewSettings.terminalFontDefault,
            accuracy: 0.001
        )
        XCTAssertEqual(TerminalTranscriptTypography.clampedSize(13), 13, accuracy: 0.001)
    }

    func testFindHighlightAdaptsToAppearanceAndStaysBehindTheText() {
        let light = TerminalTranscriptSearch.matchHighlight(dark: false)
        let dark = TerminalTranscriptSearch.matchHighlight(dark: true)

        XCTAssertNotEqual(light, dark)
        // A find highlight is a wash behind selectable text, never an opaque
        // block: fully opaque yellow made dark-appearance matches unreadable.
        for color in [light, dark] {
            XCTAssertLessThan(color.alphaComponent, 1)
            XCTAssertGreaterThan(color.alphaComponent, 0.15)
        }
    }

    func testHistoryStorageWarningIsSoftAndUsesExactBrokerBytes() {
        XCTAssertEqual(TerminalHistoryStoragePolicy.warningBytes(1_024), 1_073_741_824)
        XCTAssertFalse(TerminalHistoryStoragePolicy.isExceeded(
            diskBytes: 1_073_741_823,
            warningMiB: 1_024
        ))
        XCTAssertTrue(TerminalHistoryStoragePolicy.isExceeded(
            diskBytes: 1_073_741_824,
            warningMiB: 1_024
        ))
        XCTAssertEqual(TerminalHistoryStoragePolicy.budgetLabel(2_048), "2 GB")
        XCTAssertTrue(TerminalHistoryStoragePolicy.help(
            diskBytes: 1_073_741_824,
            warningMiB: 1_024
        ).contains("never deletes earlier output automatically"))
    }

    func testExportFileNameIsPortableAndNeverEmpty() {
        XCTAssertEqual(
            TerminalTranscriptExport.suggestedFileName(for: "Codex · Kaisola / main"),
            "codex-kaisola-main-transcript.txt"
        )
        XCTAssertEqual(
            TerminalTranscriptExport.suggestedFileName(for: "🤖"),
            "terminal-transcript.txt"
        )
    }

    func testSanitizerRemovesANSIAndPreservesUnicodeText() {
        let pages = TerminalTranscriptSanitizer.plainPages([
            "hello \u{1B}[31mred\u{1B}[0m hé\r\nnext\tcell"
        ])
        XCTAssertEqual(pages, ["hello red hé\nnext    cell"])
    }

    func testSanitizerCarriesControlStateAcrossPageBoundaries() {
        let pages = TerminalTranscriptSanitizer.plainPages([
            "before\u{1B}]8;;https://example.",
            "com\u{1B}\\linked\u{1B}]8;;\u{1B}\\ after\r",
            "\nend",
        ])
        XCTAssertEqual(pages.joined(), "beforelinked after\nend")
        XCTAssertFalse(pages.joined().contains("example.com"))
    }

    func testControlStringFilterReturnsPageBoundedOutputAcrossSplitOSC() {
        var filter = TerminalControlStringFilter()

        XCTAssertEqual(
            filter.consume("before\u{1B}]8;;https://example."),
            "before"
        )
        XCTAssertEqual(
            filter.consume("com\u{1B}\\linked"),
            "linked"
        )
        XCTAssertEqual(filter.finish(), "")
    }

    func testSanitizerDropsDCSAndC1ControlStrings() {
        let pages = TerminalTranscriptSanitizer.plainPages([
            "a\u{1B}Pprivate\u{1B}\\b\u{009D}secret\u{009C}c"
        ])
        XCTAssertEqual(pages, ["abc"])
    }

    func testSanitizerCollapsesCursorAddressedRepaints() {
        let pages = TerminalTranscriptSanitizer.plainPages([
            "\u{1B}[1;1HW\u{1B}[K",
            "\u{1B}[1;1HWork\u{1B}[K\u{1B}[1;1HWorking\u{1B}[K",
        ], columns: 80, rows: 24)

        XCTAssertEqual(pages.joined(), "Working")
        XCTAssertFalse(pages.joined().contains("WWork"))
    }

    func testSanitizerDropsSyntheticLeadingViewportPadding() {
        let pages = TerminalTranscriptSanitizer.plainPages([
            "\u{1B}[20;1Hretained output"
        ], columns: 80, rows: 24)

        XCTAssertEqual(pages, ["retained output"])
    }

    func testSanitizerKeepsStablePageCountAndReadableScrollback() {
        let pages = TerminalTranscriptSanitizer.plainPages([
            "first\r\nsecond",
            "\r\nthird🙂",
        ], columns: 80, rows: 2)

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.joined(), "first\nsecond\nthird🙂")
    }

    func testIncrementalPageJoinsWithoutRunningIntoTheNextPage() {
        let older = TerminalTranscriptSanitizer.incrementalPageText(
            output: "older tail",
            isLastLoadedPage: false
        )
        let newest = TerminalTranscriptSanitizer.incrementalPageText(
            output: "newest head",
            isLastLoadedPage: true
        )
        XCTAssertEqual(older + newest, "older tail\nnewest head")
        XCTAssertEqual(
            TerminalTranscriptSanitizer.incrementalPageText(output: "", isLastLoadedPage: false),
            ""
        )
    }

    func testIncrementalPageStillCollapsesCursorAddressedRepaints() {
        let page = TerminalTranscriptSanitizer.incrementalPageText(
            output: "\u{1B}[1;1HW\u{1B}[K\u{1B}[1;1HWork\u{1B}[K\u{1B}[1;1HWorking\u{1B}[K",
            isLastLoadedPage: true,
            columns: 80,
            rows: 24
        )
        XCTAssertEqual(page, "Working")
    }

    func testIncrementalPrependNeverRewritesAnAlreadyRenderedPage() {
        // Scroll-up used to replay every loaded page and re-apportion all
        // rendered text per prepend; the incremental path must render the new
        // page alone so existing renders stay byte-identical.
        let renderedFirst = TerminalTranscriptSanitizer.incrementalPageText(
            output: "newest page", isLastLoadedPage: true
        )
        _ = TerminalTranscriptSanitizer.incrementalPageText(
            output: "older page arriving later", isLastLoadedPage: false
        )
        XCTAssertEqual(
            renderedFirst,
            TerminalTranscriptSanitizer.incrementalPageText(output: "newest page", isLastLoadedPage: true)
        )
    }

    // MARK: - Search preparation failures

    private func searchRequest(
        query: String,
        generation: Int = 1,
        dark: Bool = false
    ) -> TerminalTranscriptSearchWorker.Request {
        TerminalTranscriptSearchWorker.Request(query: query, generation: generation, dark: dark)
    }

    private func searchPages() -> [TerminalTranscriptSearchWorker.Page] {
        [
            TerminalTranscriptSearchWorker.Page(id: 1, text: "build started\nNEEDLE in page one"),
            TerminalTranscriptSearchWorker.Page(id: 2, text: "NEEDLE again\nbuild finished"),
        ]
    }

    /// A worker error used to be swallowed, leaving the status bar on
    /// "Searching…" with no error and nothing to press. It has to land on an
    /// unavailable state that offers Retry.
    func testSearchWorkerErrorEndsTheSearchingLabelAndOffersRetry() async {
        var state = TerminalTranscriptSearchState()
        let request = searchRequest(query: "NEEDLE")
        XCTAssertEqual(state.status(for: request), .searching)

        state.willPrepare()
        let outcome = await TerminalTranscriptSearchState.outcome(debounce: nil) {
            throw TranscriptSearchFailure()
        }
        state.apply(outcome, for: request)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(state.status(for: request), .unavailable)
        XCTAssertEqual(state.status(for: request).label, "Search unavailable")
        XCTAssertTrue(state.status(for: request).needsRetry)
    }

    /// The transcript itself is plain selectable text with no highlights, so a
    /// failed preparation must leave every page rendering through that same
    /// fallback rather than blanking or holding stale highlights.
    func testFailedSearchPreparationKeepsThePlainTranscriptRendering() async throws {
        var state = TerminalTranscriptSearchState()
        let worker = TerminalTranscriptSearchWorker()
        let good = searchRequest(query: "NEEDLE")
        let prepared = try await worker.prepare(searchPages(), request: good)
        state.apply(.prepared(prepared), for: good)
        XCTAssertNotNil(state.highlighted(pageID: 1, for: good))

        let broken = searchRequest(query: "build", generation: 2)
        state.willPrepare()
        state.apply(
            await TerminalTranscriptSearchState.outcome(debounce: nil) {
                throw TranscriptSearchFailure()
            },
            for: broken
        )

        XCTAssertEqual(state.status(for: broken), .unavailable)
        XCTAssertNil(state.highlighted(pageID: 1, for: broken))
        XCTAssertNil(state.highlighted(pageID: 2, for: broken))
    }

    /// Every keystroke cancels the in-flight preparation. Cancellation is not
    /// a failure: reporting it as one would flash "Search unavailable" while
    /// the user is still typing.
    func testSupersededSearchPreparationIsNotReportedAsAFailure() async {
        var state = TerminalTranscriptSearchState()
        let request = searchRequest(query: "NEE")

        let task = Task { @MainActor in
            await TerminalTranscriptSearchState.outcome(debounce: .seconds(30)) {
                XCTFail("a cancelled debounce must never reach the worker")
                throw TranscriptSearchFailure()
            }
        }
        task.cancel()
        let outcome = await task.value
        state.apply(outcome, for: request)

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(state.status(for: request), .searching)
    }

    /// The failure belongs to the request that produced it. Typing on, or
    /// paging in older history, starts new work and must not inherit it.
    func testFailureClearsOnQueryAndGenerationChange() async {
        var state = TerminalTranscriptSearchState()
        let failed = searchRequest(query: "NEEDLE", generation: 3)
        state.willPrepare()
        state.apply(.failed, for: failed)
        XCTAssertEqual(state.status(for: failed), .unavailable)

        // Typing another character.
        state.willPrepare()
        XCTAssertEqual(state.status(for: searchRequest(query: "NEEDLES", generation: 3)), .searching)

        state.apply(.failed, for: failed)
        XCTAssertEqual(state.status(for: failed), .unavailable)

        // A newly prepended page bumps the rendered generation.
        state.willPrepare()
        XCTAssertEqual(state.status(for: searchRequest(query: "NEEDLE", generation: 4)), .searching)
    }

    /// Retry has to re-run a preparation whose request is identical to the one
    /// that failed, so it must produce a different `.task(id:)` identity and
    /// then be able to settle on a real match count.
    func testRetryStartsAFreshAttemptAndCanRecover() async throws {
        var state = TerminalTranscriptSearchState()
        let request = searchRequest(query: "NEEDLE")
        let failedAttempt = state.attemptID(for: request)
        state.willPrepare()
        state.apply(.failed, for: request)
        XCTAssertEqual(state.status(for: request), .unavailable)

        state.retry()
        XCTAssertNotEqual(state.attemptID(for: request), failedAttempt)
        XCTAssertEqual(state.status(for: request), .searching)

        state.willPrepare()
        let outcome = await TerminalTranscriptSearchState.outcome(debounce: nil) {
            let worker = TerminalTranscriptSearchWorker()
            return try await worker.prepare(searchPages(), request: request)
        }
        state.apply(outcome, for: request)

        XCTAssertEqual(state.status(for: request), .matches(2))
        XCTAssertEqual(state.status(for: request).label, "2 matches")
        XCTAssertNotNil(state.highlighted(pageID: 1, for: request))
    }
}

/// Stands in for whatever the search worker can throw that is not cancellation.
private struct TranscriptSearchFailure: Error {}
