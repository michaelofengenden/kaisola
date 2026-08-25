import XCTest
@testable import Kaisola

/// Every branch of the thinking status derivation, as values. The row itself
/// only renders what `derive` hands it, so this is the behaviour the
/// transcript's status line depends on.
final class AcpThinkingStatusTests: XCTestCase {
    private func derive(
        isRunning: Bool = true,
        isConnected: Bool = true,
        hasPendingPermission: Bool = false,
        lastRow: AcpTranscriptRow? = nil
    ) -> AcpThinkingStatus? {
        AcpThinkingStatus.derive(
            isRunning: isRunning,
            isConnected: isConnected,
            hasPendingPermission: hasPendingPermission,
            lastRow: lastRow
        )
    }

    private func tool(_ title: String, status: AcpToolCall.Status) -> AcpTranscriptRow {
        .tool(AcpToolCall(id: "t", title: title, kind: "execute", status: status))
    }

    func testNoStatusAtRest() {
        XCTAssertNil(derive(isRunning: false))
        XCTAssertNil(derive(isRunning: false, lastRow: tool("Build", status: .inProgress)))
    }

    func testNoStatusWhileDisconnected() {
        XCTAssertNil(derive(isConnected: false))
    }

    func testNoStatusUnderAPendingPermission() {
        XCTAssertNil(derive(hasPendingPermission: true))
        XCTAssertNil(derive(
            hasPendingPermission: true,
            lastRow: tool("Build", status: .inProgress)
        ))
    }

    func testAnInProgressToolTitlesTheLine() {
        let status = derive(lastRow: tool("Running tests", status: .inProgress))
        XCTAssertEqual(status?.word, "Running tests")
        XCTAssertEqual(status?.isActive, true)
        XCTAssertEqual(status?.spoken, "Running tests, working")
    }

    func testAFinishedOrPendingToolReadsWorking() {
        XCTAssertEqual(derive(lastRow: tool("Build", status: .completed))?.word, "Working")
        XCTAssertEqual(derive(lastRow: tool("Build", status: .failed))?.word, "Working")
        XCTAssertEqual(derive(lastRow: tool("Build", status: .pending))?.word, "Working")
    }

    func testAThoughtReadsThinking() {
        let status = derive(lastRow: .thought(id: "1", text: "…"))
        XCTAssertEqual(status?.word, "Thinking")
        XCTAssertEqual(status?.spoken, "Thinking, working")
    }

    func testUserMessageAndEmptyTranscriptsReadWorking() {
        XCTAssertEqual(derive(lastRow: .user(id: "1", text: "go", failed: false))?.word, "Working")
        XCTAssertEqual(derive(lastRow: .message(id: "1", text: "on it"))?.word, "Working")
        XCTAssertEqual(derive(lastRow: nil)?.word, "Working")
    }

    func testAnOverlongToolTitleIsBoundedWithoutItsOwnEllipsis() throws {
        let title = "Running the complete adversarial verification suite across every fixture"
        XCTAssertGreaterThan(title.count, AcpThinkingStatus.maximumWordCharacters)
        let status = try XCTUnwrap(derive(lastRow: tool(title, status: .inProgress)))
        XCTAssertLessThanOrEqual(status.word.count, AcpThinkingStatus.maximumWordCharacters)
        XCTAssertTrue(title.hasPrefix(status.word))
        // The view appends the trailing ellipsis; the spoken form never has one.
        XCTAssertFalse(status.word.contains("…"))
        XCTAssertFalse(status.spoken.contains("…"))
    }

    func testABlankToolTitleFallsBackToWorking() {
        XCTAssertEqual(derive(lastRow: tool("   ", status: .inProgress))?.word, "Working")
    }

    func testTranscriptSectionsKeepWorkDistinctFromTheResponse() {
        XCTAssertEqual(
            AcpTranscriptRow.user(id: "u", text: "go", failed: false).transcriptSection,
            .user
        )
        XCTAssertEqual(
            AcpTranscriptRow.thought(id: "t", text: "considering").transcriptSection,
            .work
        )
        XCTAssertEqual(tool("Build", status: .inProgress).transcriptSection, .work)
        XCTAssertEqual(
            AcpTranscriptRow.message(id: "m", text: "done").transcriptSection,
            .response
        )
    }
}
