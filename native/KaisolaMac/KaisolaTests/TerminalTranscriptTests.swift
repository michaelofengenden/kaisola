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

        // The dynamic color the view actually applies must resolve to exactly
        // those two values, so the sheet follows a mid-session appearance flip.
        let dynamic = TerminalTranscriptSearch.matchHighlightColor
        assertResolves(dynamic, under: .darkAqua, to: dark)
        assertResolves(dynamic, under: .aqua, to: light)
    }

    private func assertResolves(
        _ dynamic: NSColor,
        under appearanceName: NSAppearance.Name,
        to expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let appearance = NSAppearance(named: appearanceName) else {
            return XCTFail("Missing appearance \(appearanceName.rawValue)", file: file, line: line)
        }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = dynamic.usingColorSpace(.sRGB)
        }
        guard let resolved, let expected = expected.usingColorSpace(.sRGB) else {
            return XCTFail("Highlight did not resolve to an sRGB color", file: file, line: line)
        }
        XCTAssertEqual(resolved.redComponent, expected.redComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, expected.greenComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, expected.blueComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(resolved.alphaComponent, expected.alphaComponent, accuracy: 0.002, file: file, line: line)
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
}
