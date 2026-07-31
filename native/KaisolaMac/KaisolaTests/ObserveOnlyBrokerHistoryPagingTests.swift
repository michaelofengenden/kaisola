import XCTest
@testable import Kaisola

/// Selecting a cold terminal used to drag its whole retained spool into memory.
///
/// `subscribe` paged backwards until it had accumulated 64 MiB — up to sixteen
/// sequential `terminal.history` requests, each with its own five-second
/// deadline — before the first frame could be published. Every visited terminal
/// then kept that string alive in the surface deck.
///
/// The renderer could never show most of it. SwiftTerm keeps
/// `NativePreviewSettings.terminalScrollbackDefault` lines and drops the rest
/// out of its circular buffer, so bytes beyond that depth are unreachable by
/// scrolling no matter how many were fetched. Deep history is the transcript
/// viewer's job; it pages the same broker request on demand against a frozen
/// cursor. Cold subscribe therefore fetches a tail, not a spool.
@MainActor
final class ObserveOnlyBrokerHistoryPagingTests: XCTestCase {
    private let policy = ObserverHistoryTailPolicy.self

    func testTailIsExactlyOneBrokerPageSoAColdSelectCostsAtMostOneRequest() {
        XCTAssertEqual(policy.coldSubscribeTailBytes, 4 * 1_024 * 1_024)
        XCTAssertEqual(
            policy.coldSubscribeTailBytes,
            policy.maximumPageBytes,
            "A tail deeper than one page would need a second round trip before the first frame."
        )
    }

    func testTheTailStillCoversEverythingTheRendererCanScrollTo() {
        // SwiftTerm's circular buffer, at a generously wide pane: 20,000 rows of
        // 200 columns plus CRLF. Retaining more bytes than this cannot surface a
        // single additional row — it only costs memory.
        let deepestRenderableBytes = NativePreviewSettings.terminalScrollbackDefault * (200 + 2)
        XCTAssertGreaterThanOrEqual(policy.coldSubscribeTailBytes, deepestRenderableBytes)
    }

    func testTheTailIsAFractionOfTheOldEagerRetainTarget() {
        // The old cold subscribe tried to fill the whole document trim cap on
        // every selection; the fixed one-page tail must stay a strict fraction
        // of that cap however the cap itself is tuned.
        XCTAssertLessThan(
            policy.coldSubscribeTailBytes,
            TerminalDocument.maximumRetainedBytes
        )
    }

    // MARK: - What a cold subscribe asks for

    func testASnapshotThatAlreadyCoversTheTailAsksForNothing() {
        XCTAssertNil(policy.coldTailRequestBytes(
            snapshotBytes: policy.coldSubscribeTailBytes,
            startOffset: 60 * 1_024 * 1_024
        ))
        XCTAssertNil(
            policy.coldTailRequestBytes(
                snapshotBytes: policy.coldSubscribeTailBytes + 1,
                startOffset: 60 * 1_024 * 1_024
            ),
            "The broker's own snapshot cap matches the tail, so the common cold select makes zero history requests."
        )
    }

    func testAStreamWithNoEarlierBytesAsksForNothing() {
        XCTAssertNil(policy.coldTailRequestBytes(snapshotBytes: 1_024, startOffset: 0))
    }

    func testAShortSnapshotTopsUpToTheTailInASingleRequest() {
        let snapshotBytes = 256 * 1_024
        XCTAssertEqual(
            policy.coldTailRequestBytes(
                snapshotBytes: snapshotBytes,
                startOffset: 60 * 1_024 * 1_024
            ),
            policy.coldSubscribeTailBytes - snapshotBytes
        )
    }

    func testTheRequestNeverExceedsOneBrokerPage() {
        XCTAssertEqual(
            policy.coldTailRequestBytes(snapshotBytes: 0, startOffset: 60 * 1_024 * 1_024),
            policy.maximumPageBytes
        )
    }

    func testTheRequestNeverExceedsWhatTheStreamActuallyHolds() {
        XCTAssertEqual(
            policy.coldTailRequestBytes(snapshotBytes: 0, startOffset: 900),
            900,
            "Asking past byte zero would spend a round trip on bytes that cannot exist."
        )
    }

    func testAnEmptySpoolAndAnOversizedSnapshotAreBothRefusedCleanly() {
        XCTAssertNil(policy.coldTailRequestBytes(snapshotBytes: -1, startOffset: 10))
        XCTAssertNil(policy.coldTailRequestBytes(snapshotBytes: 10, startOffset: -1))
    }
}
