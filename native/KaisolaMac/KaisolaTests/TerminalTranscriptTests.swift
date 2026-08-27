import AppKit
import XCTest
@testable import Kaisola

@MainActor
final class TerminalTranscriptTests: XCTestCase {
    func testInitialLoadFailureExposesRetryAndRetryClearsStaleErrorBeforeRequest() throws {
        var state = TerminalTranscriptInitialLoadState()

        let initial = try XCTUnwrap(state.begin(hasLoadedPages: false, endOffset: 4_096))
        XCTAssertEqual(initial, .initial)
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.canRetry)
        XCTAssertNil(state.failureMessage)

        XCTAssertNil(state.finishFailure("Broker unavailable", attempt: initial))
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.canRetry)
        XCTAssertEqual(state.failureMessage, "Broker unavailable")

        let retry = try XCTUnwrap(state.begin(hasLoadedPages: false, endOffset: 4_096))
        XCTAssertEqual(retry, .retry)
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.canRetry)
        XCTAssertNil(state.failureMessage, "Retry must clear the stale error before awaiting the broker")
    }

    func testInitialLoadRetryAnnouncesSuccessOrRepeatedFailureExactlyOnce() throws {
        var successState = TerminalTranscriptInitialLoadState()
        let firstFailure = try XCTUnwrap(successState.begin(hasLoadedPages: false, endOffset: 12))
        XCTAssertNil(successState.finishFailure("Offline", attempt: firstFailure))
        let successfulRetry = try XCTUnwrap(successState.begin(hasLoadedPages: false, endOffset: 12))

        XCTAssertEqual(
            successState.finishSuccess(attempt: successfulRetry),
            .init(message: "Terminal history loaded.", priority: .medium)
        )
        XCTAssertNil(successState.finishSuccess(attempt: successfulRetry), "An attempt can settle only once")
        XCTAssertFalse(successState.canRetry)
        XCTAssertNil(successState.failureMessage)

        var failureState = TerminalTranscriptInitialLoadState()
        let initial = try XCTUnwrap(failureState.begin(hasLoadedPages: false, endOffset: 12))
        XCTAssertNil(failureState.finishFailure("Timed out", attempt: initial))
        let retry = try XCTUnwrap(failureState.begin(hasLoadedPages: false, endOffset: 12))

        XCTAssertEqual(
            failureState.finishFailure("Timed out again", attempt: retry),
            .init(
                message: "Terminal history still could not be loaded. Timed out again",
                priority: .high
            )
        )
        XCTAssertNil(failureState.finishFailure("duplicate", attempt: retry), "An attempt can settle only once")
        XCTAssertTrue(failureState.canRetry)
        XCTAssertEqual(failureState.failureMessage, "Timed out again")
    }

    func testInitialLoadGateRejectsEmptyHistoryLoadedPagesAndConcurrentActivation() throws {
        var state = TerminalTranscriptInitialLoadState()

        XCTAssertNil(state.begin(hasLoadedPages: false, endOffset: 0))
        XCTAssertNil(state.begin(hasLoadedPages: true, endOffset: 4_096))

        let attempt = try XCTUnwrap(state.begin(hasLoadedPages: false, endOffset: 4_096))
        XCTAssertNil(state.begin(hasLoadedPages: false, endOffset: 4_096))
        XCTAssertNil(state.finishFailure("late result", attempt: .retry))
        XCTAssertTrue(state.isLoading, "A result for another attempt must not release the in-flight gate")
        XCTAssertNil(state.finishSuccess(attempt: attempt))
        XCTAssertFalse(state.isLoading)
    }

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

    func testSearchPreparationFailureIsDistinctFromEmptyQueryAndNoMatches() throws {
        var state = TerminalTranscriptSearchPreparationState()
        let empty = TerminalTranscriptSearchWorker.Request(
            query: "   ",
            generation: 1,
            dark: false
        )
        XCTAssertEqual(state.presentation(for: empty), .hidden)

        let noMatches = TerminalTranscriptSearchWorker.Request(
            query: "absent",
            generation: 1,
            dark: false
        )
        let noMatchAttempt = state.begin(request: noMatches)
        XCTAssertEqual(state.presentation(for: noMatches), .searching)
        XCTAssertNil(state.finishSuccess(matchCount: 0, attempt: noMatchAttempt))
        XCTAssertEqual(state.presentation(for: noMatches), .matches(0))
        XCTAssertEqual(state.presentation(for: noMatches).visibleText, "0 matches")
        XCTAssertEqual(
            state.presentation(for: noMatches).accessibilityLabel,
            "No matches in loaded terminal transcript."
        )
        XCTAssertFalse(state.presentation(for: noMatches).canRetry)

        let failing = TerminalTranscriptSearchWorker.Request(
            query: "needle",
            generation: 2,
            dark: false
        )
        let failedAttempt = state.begin(request: failing)
        XCTAssertEqual(
            state.finishFailure("Search index unavailable.", attempt: failedAttempt),
            .init(
                message: "Terminal transcript search unavailable. Search index unavailable.",
                priority: .high
            )
        )
        XCTAssertEqual(
            state.presentation(for: failing),
            .unavailable(message: "Search index unavailable.")
        )
        XCTAssertEqual(state.presentation(for: failing).visibleText, "Search unavailable")
        XCTAssertEqual(
            state.presentation(for: failing).accessibilityLabel,
            "Search unavailable. Search index unavailable."
        )
        XCTAssertTrue(state.presentation(for: failing).canRetry)
    }

    func testSearchPreparationRetryRecoversFromAWorkerError() async throws {
        let worker = TerminalTranscriptSearchWorker { _, attempt in
            if attempt == 1 { throw TerminalTranscriptSearchPreparationTestError.unavailable }
        }
        let request = TerminalTranscriptSearchWorker.Request(
            query: "needle",
            generation: 7,
            dark: false
        )
        let pages = [TerminalTranscriptSearchWorker.Page(id: 1, text: "one needle")]
        var state = TerminalTranscriptSearchPreparationState()

        let firstAttempt = state.begin(request: request)
        do {
            _ = try await worker.prepare(pages, request: request)
            XCTFail("The controlled first preparation must fail")
        } catch {
            XCTAssertEqual(
                state.finishFailure(error.localizedDescription, attempt: firstAttempt),
                .init(
                    message: "Terminal transcript search unavailable. Search index unavailable.",
                    priority: .high
                )
            )
        }
        XCTAssertTrue(state.presentation(for: request).canRetry)

        let retry = state.begin(request: request)
        XCTAssertEqual(state.presentation(for: request), .searching)
        XCTAssertFalse(state.presentation(for: request).canRetry)
        let prepared = try await worker.prepare(pages, request: request)
        XCTAssertEqual(prepared.matchCount, 1)
        XCTAssertEqual(
            state.finishSuccess(matchCount: prepared.matchCount, attempt: retry),
            .init(
                message: "Terminal transcript search available. 1 match.",
                priority: .medium
            )
        )
        XCTAssertEqual(state.presentation(for: request), .matches(1))
        XCTAssertNil(
            state.finishSuccess(matchCount: prepared.matchCount, attempt: retry),
            "A retry may announce recovery only once"
        )
    }

    func testSearchPreparationCancellationRestoresTheRetryableFailure() async throws {
        let worker = TerminalTranscriptSearchWorker { _, _ in
            try Task.checkCancellation()
        }
        let request = TerminalTranscriptSearchWorker.Request(
            query: "needle",
            generation: 4,
            dark: false
        )
        let pages = [TerminalTranscriptSearchWorker.Page(id: 1, text: "needle")]
        var state = TerminalTranscriptSearchPreparationState()
        let firstAttempt = state.begin(request: request)
        _ = state.finishFailure("Search index unavailable.", attempt: firstAttempt)
        let retry = state.begin(request: request)

        let task = Task { try await worker.prepare(pages, request: request) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("The controlled preparation must observe cancellation")
        } catch is CancellationError {
            state.cancel(attempt: retry)
        } catch {
            XCTFail("Cancellation must not become a search failure: \(error)")
        }

        XCTAssertEqual(
            state.presentation(for: request),
            .unavailable(message: "Search index unavailable.")
        )
        XCTAssertTrue(state.presentation(for: request).canRetry)
    }

    func testSearchPreparationClearsFailureForQueryOrGenerationChangeAndIgnoresLateResults() {
        var state = TerminalTranscriptSearchPreparationState()
        let original = TerminalTranscriptSearchWorker.Request(
            query: "needle",
            generation: 1,
            dark: false
        )
        let staleAttempt = state.begin(request: original)
        _ = state.finishFailure("Search index unavailable.", attempt: staleAttempt)

        let changedQuery = TerminalTranscriptSearchWorker.Request(
            query: "different",
            generation: 1,
            dark: false
        )
        XCTAssertEqual(state.presentation(for: changedQuery), .searching)
        XCTAssertFalse(state.presentation(for: changedQuery).canRetry)
        let currentAttempt = state.begin(request: changedQuery)
        XCTAssertNil(state.finishFailure("Late original failure.", attempt: staleAttempt))
        XCTAssertEqual(state.presentation(for: changedQuery), .searching)
        XCTAssertNil(state.finishSuccess(matchCount: 2, attempt: currentAttempt))
        XCTAssertEqual(state.presentation(for: changedQuery), .matches(2))

        let changedGeneration = TerminalTranscriptSearchWorker.Request(
            query: "different",
            generation: 2,
            dark: false
        )
        XCTAssertEqual(state.presentation(for: changedGeneration), .searching)
        XCTAssertFalse(state.presentation(for: changedGeneration).canRetry)
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
}

private enum TerminalTranscriptSearchPreparationTestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Search index unavailable." }
}
