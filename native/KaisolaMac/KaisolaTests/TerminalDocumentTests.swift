import XCTest
@testable import Kaisola

final class TerminalDocumentTests: XCTestCase {
    func testVisualStreamingFixtureHasExactHistoryAndBoundedContiguousPackets() {
        let lines = VisualTerminalStreamingFixture.initialOutput
            .split(omittingEmptySubsequences: true) { $0.isNewline }
        XCTAssertEqual(lines.count, VisualTerminalStreamingFixture.historicalLineCount)
        XCTAssertTrue(lines.first?.contains("historical-anchor-0000") == true)
        XCTAssertTrue(lines.last?.contains("historical-anchor-0479") == true)
        XCTAssertEqual(VisualTerminalStreamingFixture.packetIndices.count, 240)
        XCTAssertEqual(
            VisualTerminalStreamingFixture.packet(index: 240),
            "\u{1B}]0;⠏ Kaisola\u{7}streaming-frame-0240  background output\r\n"
        )
        XCTAssertEqual(VisualTerminalStreamingFixture.finalMarker, "streaming-frame-0240")
    }

    func testVisualResourceFixtureProducesAnExactBoundedUTF8Workload() {
        let output = VisualTerminalResourceFixture.output(targetBytes: 2_053)
        let paged = VisualTerminalResourceFixture.scrollback(
            targetBytes: TerminalScrollback.targetPageBytes * 2 + 37
        )
        let maximum = VisualTerminalResourceFixture.scrollback(
            targetBytes: TerminalDocument.maximumRetainedBytes
        )

        XCTAssertEqual(output.utf8.count, 2_053)
        XCTAssertTrue(output.hasPrefix("0123456789abcdef"))
        XCTAssertEqual(VisualTerminalResourceFixture.output(targetBytes: 0), "")
        XCTAssertEqual(paged.byteCount, TerminalScrollback.targetPageBytes * 2 + 37)
        XCTAssertEqual(paged.pages.count, 3)
        XCTAssertTrue(paged.pages.allSatisfy { $0.utf8.count <= TerminalScrollback.targetPageBytes })
        XCTAssertTrue(paged.output.hasPrefix("0123456789abcdef"))
        XCTAssertEqual(maximum.byteCount, TerminalDocument.maximumRetainedBytes)
        XCTAssertEqual(TerminalScrollback.mutableTailBytes, 16 * 1_024)
        XCTAssertEqual(
            maximum.pages.count,
            TerminalDocument.maximumRetainedBytes / TerminalScrollback.targetPageBytes
        )
        XCTAssertTrue(maximum.pages.allSatisfy {
            $0.utf8.count == TerminalScrollback.targetPageBytes
        })
    }

    func testScrollbackPagesPreserveUtf8AndValueSemantics() {
        let source = String(repeating: "a", count: TerminalScrollback.targetPageBytes - 2)
            + "🙂"
            + String(repeating: "b", count: TerminalScrollback.targetPageBytes)
        let original = TerminalScrollback(source)
        var appended = original
        appended.append("tail")

        XCTAssertGreaterThanOrEqual(original.pages.count, 2)
        XCTAssertEqual(original.byteCount, source.utf8.count)
        XCTAssertEqual(original.output, source)
        XCTAssertEqual(appended.output, source + "tail")
        XCTAssertEqual(original.output, source)
    }

    func testIncrementalOutputNeverMutatesBeyondTheSmallTailBudget() {
        var scrollback = TerminalScrollback(String(repeating: "a", count: 512 * 1_024))
        scrollback.append("first")
        XCTAssertEqual(scrollback.pages.count, 2)
        XCTAssertEqual(scrollback.pages.last, "first")

        scrollback.append(String(repeating: "b", count: TerminalScrollback.mutableTailBytes - 5))
        XCTAssertEqual(scrollback.pages.count, 2)
        XCTAssertEqual(scrollback.pages.last?.utf8.count, TerminalScrollback.mutableTailBytes)

        scrollback.append("next")
        XCTAssertEqual(scrollback.pages.count, 3)
        XCTAssertEqual(scrollback.pages.last, "next")
    }

    func testScrollbackTrimDropsWholePagesAndRoundsToUnicodeBoundary() {
        let source = String(repeating: "a", count: TerminalScrollback.targetPageBytes)
            + String(repeating: "b", count: TerminalScrollback.targetPageBytes)
            + "🙂tail"
        var scrollback = TerminalScrollback(source)

        XCTAssertTrue(scrollback.trim(to: TerminalScrollback.targetPageBytes))
        XCTAssertLessThanOrEqual(scrollback.byteCount, TerminalScrollback.targetPageBytes)
        XCTAssertTrue(scrollback.output.hasSuffix("🙂tail"))
        XCTAssertEqual(scrollback.byteCount, scrollback.output.utf8.count)
    }

    func testScrollbackReturnsExactUtf8SuffixAcrossPageBoundary() throws {
        let prefix = String(repeating: "a", count: TerminalScrollback.targetPageBytes - 1)
        let source = prefix + "é" + "tail"
        let scrollback = TerminalScrollback(source)

        let suffix = try XCTUnwrap(scrollback.suffix(
            droppingUTF8Bytes: Int64(prefix.utf8.count)
        ))
        XCTAssertEqual(suffix.joined(), "étail")
        XCTAssertNil(scrollback.suffix(
            droppingUTF8Bytes: Int64(prefix.utf8.count + 1)
        ))
    }

    func testOutputBatchCoalescesOnlyContiguousUtf8Packets() throws {
        var batch = try XCTUnwrap(TerminalOutputBatch(
            projectID: "project.one",
            terminalID: "terminal.one",
            epoch: "epoch",
            startOffset: 5,
            endOffset: 7,
            data: "é"
        ))

        XCTAssertTrue(batch.append(epoch: "epoch", startOffset: 7, endOffset: 11, data: "🙂"))
        XCTAssertEqual(batch.startOffset, 5)
        XCTAssertEqual(batch.endOffset, 11)
        XCTAssertEqual(batch.data, "é🙂")
        XCTAssertFalse(batch.append(epoch: "epoch", startOffset: 12, endOffset: 13, data: "x"))
        XCTAssertFalse(batch.append(epoch: "other", startOffset: 11, endOffset: 12, data: "x"))
        XCTAssertNil(TerminalOutputBatch(
            projectID: "project.one",
            terminalID: "terminal.one",
            epoch: "epoch",
            startOffset: 0,
            endOffset: 1,
            data: "é"
        ))
    }

    func testLoadingDocumentBindsBlankCanvasToSelectedSession() {
        let document = TerminalDocument.loading(sessionID: "terminal:new")
        XCTAssertEqual(document.sessionID, "terminal:new")
        XCTAssertEqual(document.output, "")
        XCTAssertNil(document.cursor)
        XCTAssertNil(document.errorMessage)
    }

    func testOrderedUtf8SuffixAdvancesByteCursor() throws {
        let snapshot = try TerminalSnapshot(value: .object([
            "streamEpoch": .string("epoch"),
            "output": .string("hello"),
            "startOffset": .integer(0),
            "endOffset": .integer(5),
            "truncated": .bool(false),
            "exited": .bool(false),
        ]))
        var document = TerminalDocument.empty.applying(.snapshot(snapshot, resetReason: nil), sessionID: "t1")

        XCTAssertTrue(document.append(epoch: "epoch", startOffset: 5, endOffset: 7, data: "é"))
        XCTAssertEqual(document.output, "helloé")
        XCTAssertEqual(document.cursor?.offset, 7)
        XCTAssertEqual(document.surfaceDelta, TerminalSurfaceDelta(
            epoch: "epoch",
            startOffset: 5,
            endOffset: 7,
            data: "é"
        ))
    }

    func testGapOrEpochMismatchRequiresReload() {
        var document = TerminalDocument(
            sessionID: "t1",
            output: "hello",
            cursor: TerminalCursor(streamEpoch: "epoch", offset: 5),
            truncated: false,
            exited: false,
            errorMessage: nil
        )
        XCTAssertFalse(document.append(epoch: "epoch", startOffset: 6, endOffset: 7, data: "x"))
        XCTAssertFalse(document.append(epoch: "other", startOffset: 5, endOffset: 6, data: "x"))
        XCTAssertEqual(document.output, "hello")
    }

    func testRetainedOutputStaysBoundedAtAUnicodeBoundary() {
        let prefix = String(repeating: "a", count: TerminalDocument.maximumRetainedBytes - 1)
        var document = TerminalDocument(
            sessionID: "t1",
            output: prefix,
            cursor: TerminalCursor(streamEpoch: "epoch", offset: Int64(prefix.utf8.count)),
            truncated: false,
            exited: false,
            errorMessage: nil
        )
        let start = Int64(prefix.utf8.count)

        XCTAssertTrue(document.append(epoch: "epoch", startOffset: start, endOffset: start + 4, data: "🙂"))
        XCTAssertLessThanOrEqual(document.output.utf8.count, TerminalDocument.maximumRetainedBytes)
        XCTAssertTrue(document.output.hasSuffix("🙂"))
        XCTAssertTrue(document.truncated)
        XCTAssertEqual(document.cursor?.offset, start + 4)
    }

    func testResetReasonMarksRetainedHistoryGap() throws {
        let snapshot = try TerminalSnapshot(value: .object([
            "streamEpoch": .string("epoch"),
            "output": .string("tail"),
            "startOffset": .integer(100),
            "endOffset": .integer(104),
            "truncated": .bool(false),
        ]))
        let document = TerminalDocument.empty.applying(
            .snapshot(snapshot, resetReason: "retention-gap"),
            sessionID: "t1"
        )
        XCTAssertTrue(document.truncated)
    }

    func testCursorResumeAppendsAnExactSuffixWithoutDroppingVisibleScrollback() throws {
        let initial = try TerminalSnapshot(value: .object([
            "streamEpoch": .string("epoch"),
            "output": .string("hello"),
            "startOffset": .integer(0),
            "endOffset": .integer(5),
        ]))
        let suffix = try TerminalSnapshot(value: .object([
            "streamEpoch": .string("epoch"),
            "output": .string(" world"),
            "startOffset": .integer(5),
            "endOffset": .integer(11),
            // The broker marks cursor-relative snapshots as truncated because
            // they omit the prefix; the UI already owns that exact prefix.
            "truncated": .bool(true),
        ]))
        let document = TerminalDocument.empty
            .applying(.snapshot(initial, resetReason: nil), sessionID: "t1")
            .applying(.snapshot(suffix, resetReason: nil), sessionID: "t1")

        XCTAssertEqual(document.output, "hello world")
        XCTAssertEqual(document.cursor, TerminalCursor(streamEpoch: "epoch", offset: 11))
        XCTAssertEqual(document.surfaceDelta, TerminalSurfaceDelta(
            epoch: "epoch",
            startOffset: 5,
            endOffset: 11,
            data: " world"
        ))
        XCTAssertFalse(document.truncated)
    }

    func testResetSnapshotReplacesAnIncompatibleVisiblePrefix() throws {
        let current = TerminalDocument(
            sessionID: "t1",
            output: "old",
            cursor: TerminalCursor(streamEpoch: "old-epoch", offset: 3),
            truncated: false,
            exited: false,
            errorMessage: nil
        )
        let replacement = try TerminalSnapshot(value: .object([
            "streamEpoch": .string("new-epoch"),
            "output": .string("new"),
            "startOffset": .integer(0),
            "endOffset": .integer(3),
        ]))
        let document = current.applying(
            .snapshot(replacement, resetReason: "epoch_mismatch"),
            sessionID: "t1"
        )

        XCTAssertEqual(document.output, "new")
        XCTAssertTrue(document.truncated)
    }
}
