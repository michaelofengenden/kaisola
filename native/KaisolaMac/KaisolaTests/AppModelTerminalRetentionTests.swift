import XCTest
@testable import Kaisola

/// The retained terminal deck was bounded by document *count* only.
///
/// Twelve documents, each free to grow to `TerminalDocument.maximumRetainedBytes`,
/// is 192 MiB of scrollback strings — reachable simply by touring long-lived
/// terminals. Count is the wrong unit for a memory budget: eleven idle shells
/// and one week-old agent log are not the same object.
///
/// The deck is therefore bounded in bytes as well, evicting least-recently-used
/// first. Mounted cards are exempt: a terminal card renders only while its feed
/// exists, so evicting a visible surface would replace live output with a
/// spinner.
@MainActor
final class AppModelTerminalRetentionTests: XCTestCase {
    private func evictions(
        _ order: [String],
        bytes: [String: Int] = [:],
        protected: Set<String> = [],
        maximumSurfaces: Int = AppModel.maximumRetainedTerminalSurfaces,
        maximumBytes: Int = AppModel.maximumRetainedTerminalBytes
    ) -> [String] {
        AppModel.retainedSurfaceEvictions(
            order: order,
            byteCount: { bytes[$0] ?? 0 },
            protected: protected,
            maximumSurfaces: maximumSurfaces,
            maximumBytes: maximumBytes
        )
    }

    private static let megabyte = 1_024 * 1_024

    func testTheBudgetIsStatedInBytesAndTracksThePerDocumentCap() {
        // 2026-08-06 spec §2c: 5 MiB per document (bytes past ~4 MiB were
        // renderer-unreachable), 12 surfaces, and the byte budget now binds
        // at the count-only worst case rather than sitting above it.
        XCTAssertEqual(TerminalDocument.maximumRetainedBytes, 5 * Self.megabyte)
        let countOnlyWorstCase = AppModel.maximumRetainedTerminalSurfaces
            * TerminalDocument.maximumRetainedBytes
        XCTAssertEqual(countOnlyWorstCase, 60 * Self.megabyte)
        XCTAssertLessThanOrEqual(AppModel.maximumRetainedTerminalBytes, countOnlyWorstCase)
    }

    func testNothingIsEvictedWhileBothBoundsHold() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(
            evictions(order, bytes: ["a": 8 * Self.megabyte, "b": 8 * Self.megabyte, "c": 8 * Self.megabyte]),
            []
        )
    }

    func testTheCountCapStillEvictsLeastRecentlyUsedFirst() {
        let order = (0..<(AppModel.maximumRetainedTerminalSurfaces + 2)).map { "t\($0)" }
        XCTAssertEqual(evictions(order), ["t0", "t1"])
    }

    func testTheByteBudgetEvictsUntilTheDeckFitsEvenUnderTheCountCap() {
        // Five documents, well under the count cap, 80 MiB against the
        // 48 MiB budget (spec §2c): the two oldest go.
        let order = ["a", "b", "c", "d", "e"]
        let bytes = Dictionary(uniqueKeysWithValues: order.map { ($0, 16 * Self.megabyte) })
        XCTAssertEqual(evictions(order, bytes: bytes), ["a", "b"])
    }

    func testEvictionStopsAsSoonAsTheDeckFits() {
        let order = ["a", "b", "c"]
        let bytes = ["a": 24 * Self.megabyte, "b": 16 * Self.megabyte, "c": 16 * Self.megabyte]
        XCTAssertEqual(evictions(order, bytes: bytes), ["a"])
    }

    func testMountedSurfacesAreNeverEvictedAndTheNextOldestGoesInstead() {
        let order = ["visible", "b", "c", "d"]
        let bytes = Dictionary(uniqueKeysWithValues: order.map { ($0, 40 * Self.megabyte) })
        XCTAssertEqual(evictions(order, bytes: bytes, protected: ["visible"]), ["b", "c"])
    }

    func testAProtectedDeckIsLeftAloneRatherThanBlankingACard() {
        let order = ["a", "b", "c"]
        let bytes = Dictionary(uniqueKeysWithValues: order.map { ($0, 64 * Self.megabyte) })
        XCTAssertEqual(
            evictions(order, bytes: bytes, protected: ["a", "b", "c"]),
            [],
            "A budget that blanks live terminals is worse than the memory it saves."
        )
    }

    func testTheNewestDocumentSurvivesEvenWhenItAloneExceedsTheBudget() {
        let order = ["a", "b"]
        let bytes = ["a": 8 * Self.megabyte, "b": 200 * Self.megabyte]
        XCTAssertEqual(
            evictions(order, bytes: bytes),
            ["a"],
            "The just-retained document is the one being published; dropping it would blank the selection."
        )
        XCTAssertEqual(evictions(["only"], bytes: ["only": 200 * Self.megabyte]), [])
    }

    func testTheCountCapAlsoRespectsMountedSurfaces() {
        var order = ["pinned"]
        order.append(contentsOf: (0..<AppModel.maximumRetainedTerminalSurfaces).map { "t\($0)" })
        XCTAssertEqual(evictions(order, protected: ["pinned"]), ["t0"])
    }

    // MARK: - protectedSurfaceIDs

    /// `focusTerminalSurface` unsubscribes the outgoing primary before
    /// re-subscribing it as a split, so mid-transition it is none of
    /// `selectedSessionID`, the primary document, a split document, or a
    /// pending split subscription — yet its card is still mounted in the
    /// active project's pane layout. It must be protected anyway.
    func testAnIDPresentOnlyInTheActivePaneLayoutIsProtected() {
        let protectedIDs = AppModel.protectedSurfaceIDs(
            splitDocumentIDs: [],
            pendingSplitSubscriptionIDs: [],
            selectedSessionID: "new-primary",
            primarySessionID: "new-primary",
            activePaneLayoutSessionIDs: ["new-primary", "mid-transition"]
        )
        XCTAssertTrue(protectedIDs.contains("mid-transition"))

        // And it survives an eviction pass that would otherwise take it as
        // the least-recently-used entry.
        let order = ["mid-transition", "b", "c", "d"]
        let bytes = Dictionary(uniqueKeysWithValues: order.map { ($0, 40 * Self.megabyte) })
        XCTAssertEqual(evictions(order, bytes: bytes, protected: protectedIDs), ["b", "c"])
    }

    /// An id that belongs to no active surface and sits outside the pane
    /// layout — e.g. a different project's terminal, or one the user closed
    /// — is not protected by the layout union.
    func testAnIDOutsideEveryMountedSetIsNotProtected() {
        let protectedIDs = AppModel.protectedSurfaceIDs(
            splitDocumentIDs: [],
            pendingSplitSubscriptionIDs: [],
            selectedSessionID: "new-primary",
            primarySessionID: "new-primary",
            activePaneLayoutSessionIDs: ["new-primary"]
        )
        XCTAssertFalse(protectedIDs.contains("elsewhere"))
    }
}

/// PR 12's acceptance claim, checked rather than asserted in a comment.
///
/// `AppModel.maximumRetainedTerminalBytes` carries a promise in prose — "96 MiB
/// comfortably holds six saturated terminals, or one saturated terminal plus a
/// deep deck of ordinary ones" — and the deck is capped at twelve surfaces.
/// Those are the numbers PR 12 says must hold for twelve long retained
/// sessions, and until now nothing checked that the eviction policy actually
/// delivers them at full scale: the existing cases use small synthetic sizes.
///
/// These drive the real constants at the real deck size. They cover the
/// in-process half of the acceptance; measuring the installed app's resident
/// memory under sustained streaming remains, and needs a signed build.
@MainActor
final class RetainedTerminalDeckAtScaleTests: XCTestCase {
    private static let megabyte = 1_024 * 1_024

    /// Bytes surviving after eviction, given each terminal's size.
    private func survivingBytes(
        _ sizes: [String: Int],
        order: [String],
        protected: Set<String> = []
    ) -> Int {
        let evicted = Set(AppModel.retainedSurfaceEvictions(
            order: order,
            byteCount: { sizes[$0] ?? 0 },
            protected: protected,
            maximumSurfaces: AppModel.maximumRetainedTerminalSurfaces,
            maximumBytes: AppModel.maximumRetainedTerminalBytes
        ))
        return order.filter { !evicted.contains($0) }.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    /// The worst case the cap exists to prevent: twelve terminals, every one
    /// saturated. A count-only bound allowed 192 MiB here.
    func testTwelveSaturatedTerminalsStayInsideTheBudget() {
        let order = (1...12).map { "terminal-\($0)" }
        let sizes = Dictionary(uniqueKeysWithValues: order.map {
            ($0, TerminalDocument.maximumRetainedBytes)
        })

        let surviving = survivingBytes(sizes, order: order)
        XCTAssertLessThanOrEqual(
            surviving,
            AppModel.maximumRetainedTerminalBytes,
            "Twelve saturated terminals must not exceed the stated 96 MiB"
        )
        XCTAssertLessThan(surviving, 192 * Self.megabyte, "…which is what count-only permitted")
    }

    /// The comment's first promise: six saturated terminals fit.
    func testSixSaturatedTerminalsAreHeldWithoutEviction() {
        let order = (1...6).map { "terminal-\($0)" }
        let sizes = Dictionary(uniqueKeysWithValues: order.map {
            ($0, TerminalDocument.maximumRetainedBytes)
        })
        XCTAssertEqual(
            survivingBytes(sizes, order: order),
            6 * TerminalDocument.maximumRetainedBytes,
            "96 MiB is exactly six saturated terminals; none should be evicted"
        )
    }

    /// The comment's second promise: one saturated terminal plus a deep deck of
    /// ordinary ones. An agent log beside eleven working shells is the shape a
    /// real day actually takes.
    func testOneSaturatedTerminalPlusADeepDeckOfOrdinaryOnesSurvives() {
        var sizes = ["agent-log": TerminalDocument.maximumRetainedBytes]
        var order = ["agent-log"]
        for index in 1...11 {
            let id = "shell-\(index)"
            order.append(id)
            sizes[id] = 2 * Self.megabyte
        }

        let evicted = AppModel.retainedSurfaceEvictions(
            order: order,
            byteCount: { sizes[$0] ?? 0 },
            protected: [],
            maximumSurfaces: AppModel.maximumRetainedTerminalSurfaces,
            maximumBytes: AppModel.maximumRetainedTerminalBytes
        )
        XCTAssertTrue(evicted.isEmpty, "16 + 22 MiB across twelve surfaces fits inside 96 MiB")
        XCTAssertLessThanOrEqual(order.count, AppModel.maximumRetainedTerminalSurfaces)
    }

    /// Touring long-lived terminals is exactly how the old bound was reached,
    /// so the budget has to hold across a long walk, not just a snapshot.
    func testTouringThirtyTerminalsNeverLetsTheDeckExceedTheBudget() {
        var order: [String] = []
        var sizes: [String: Int] = [:]
        for index in 1...30 {
            let id = "terminal-\(index)"
            order.append(id)
            // Alternate saturated and ordinary, so the walk crosses the byte
            // bound repeatedly rather than settling under it.
            sizes[id] = index.isMultiple(of: 2) ? TerminalDocument.maximumRetainedBytes : Self.megabyte

            let surviving = survivingBytes(sizes, order: order)
            XCTAssertLessThanOrEqual(
                surviving,
                AppModel.maximumRetainedTerminalBytes,
                "deck exceeded the budget after visiting \(index) terminals"
            )
            let evicted = Set(AppModel.retainedSurfaceEvictions(
                order: order,
                byteCount: { sizes[$0] ?? 0 },
                protected: [],
                maximumSurfaces: AppModel.maximumRetainedTerminalSurfaces,
                maximumBytes: AppModel.maximumRetainedTerminalBytes
            ))
            XCTAssertLessThanOrEqual(
                order.filter { !evicted.contains($0) }.count,
                AppModel.maximumRetainedTerminalSurfaces
            )
            order.removeAll { evicted.contains($0) }
        }
    }

    /// Mounted surfaces are exempt, so a full screen of visible terminals can
    /// legitimately exceed the budget — evicting one would blank a live card.
    /// What must not happen is the policy evicting them anyway.
    func testVisibleTerminalsAreNeverEvictedEvenWhenTheyAloneExceedTheBudget() {
        let order = (1...12).map { "terminal-\($0)" }
        let sizes = Dictionary(uniqueKeysWithValues: order.map {
            ($0, TerminalDocument.maximumRetainedBytes)
        })
        let evicted = AppModel.retainedSurfaceEvictions(
            order: order,
            byteCount: { sizes[$0] ?? 0 },
            protected: Set(order),
            maximumSurfaces: AppModel.maximumRetainedTerminalSurfaces,
            maximumBytes: AppModel.maximumRetainedTerminalBytes
        )
        XCTAssertTrue(evicted.isEmpty, "a mounted card must never be blanked to satisfy the budget")
    }
}
