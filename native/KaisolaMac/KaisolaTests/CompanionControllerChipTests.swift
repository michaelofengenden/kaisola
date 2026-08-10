import AppKit
import KaisolaCore
import SwiftUI
import XCTest
@testable import Kaisola

/// The header's remote-control indicator (#305).
///
/// The shipped capsule drew a phone glyph next to "i…" in an ordinary
/// multi-pane header, which answers neither who is driving the terminal nor
/// whether that authority is still live. These cover both halves of the fix:
/// the width-tiered presentation that refuses to shorten a name past
/// legibility, and the identity and lease state that survive at every width in
/// the tooltip, the accessibility value, and the popover rows.
final class CompanionControllerChipTests: XCTestCase {
    private static let ttl = CompanionTerminalControl.leaseTTLMilliseconds
    private static let longName = "Michael Ofengenden's Personal iPhone 17 Pro Max"
    private static let accountScope = try! CompanionAccountScope(
        accountID: "controller-chip-test-account"
    )

    private func chip(
        name: String = "Michael's iPhone",
        tag: String? = nil,
        lease: CompanionControllerChip.Lease = .active,
        secondsRemaining: Int = 30
    ) -> CompanionControllerChip {
        CompanionControllerChip(
            deviceName: name,
            deviceTag: tag,
            lease: lease,
            secondsRemaining: secondsRemaining
        )
    }

    private func status(
        terminalID: String = "terminal-1",
        deviceID: String = "device-9f3a",
        expiresAt: Int64 = 30_000
    ) -> CompanionTerminalControlStatus {
        CompanionTerminalControlStatus(
            projectID: "project-1",
            terminalID: terminalID,
            deviceID: deviceID,
            connectionID: "connection-1",
            expiresAt: expiresAt
        )
    }

    private func device(id: String, name: String) -> CompanionPairedDeviceRecord {
        CompanionPairedDeviceRecord(
            deviceId: id,
            displayName: name,
            identityPublic: Data(repeating: 0x11, count: 32).base64EncodedString(),
            x25519StaticPublic: Data(repeating: 0x22, count: 32).base64EncodedString(),
            capabilities: [.observe, .terminalControl],
            pairedAt: 1_785_216_000_000,
            lastSeenAt: 1_785_216_060_000,
            accountScope: Self.accountScope
        )
    }

    // MARK: - Width tiers

    func testThreePresentationsAcrossThePaneWidthsTheGridProduces() {
        let subject = chip()
        XCTAssertEqual(subject.layout(paneWidth: 240), .compact)
        XCTAssertEqual(subject.layout(paneWidth: 420), .standard)
        XCTAssertEqual(subject.layout(paneWidth: 700), .expanded)
    }

    func testExpandedSaysTheLeaseStateInWordsAndStandardKeepsTheWholeName() {
        let subject = chip(lease: .expiring, secondsRemaining: 7)
        XCTAssertEqual(
            subject.presentation(paneWidth: 700).title,
            "Michael's iPhone · expiring"
        )
        XCTAssertEqual(subject.presentation(paneWidth: 400).title, "Michael's iPhone")
        XCTAssertNil(subject.presentation(paneWidth: 240).title)
    }

    /// The bug itself. No pane width may produce "i…", "M…", or any other
    /// prefix too short to name a device: below the floor the chip draws no
    /// text at all.
    func testNoPaneWidthDrawsAMeaninglessPrefix() {
        // The floor is asserted as a literal on purpose: reading it back from
        // the type under test would make this pass for any floor at all,
        // including the one that produced "i…".
        let names = ["iPhone", "Michael's iPhone", Self.longName, "📱", "Mac mini"]
        for name in names {
            for paneWidth in stride(from: 150.0, through: 1_600.0, by: 2.0) {
                guard let title = chip(name: name)
                    .presentation(paneWidth: CGFloat(paneWidth))
                    .title
                else { continue }
                guard title.hasSuffix("…") else { continue }
                XCTAssertGreaterThanOrEqual(
                    title.dropLast().count, 4,
                    "\"\(name)\" at \(paneWidth)pt truncated to \"\(title)\""
                )
            }
        }
        XCTAssertGreaterThanOrEqual(CompanionControllerChip.minimumLegibleCharacters, 4)
    }

    func testEveryLayoutTierIsReachableAtSomePaneWidth() {
        let subject = chip(name: Self.longName)
        let tiers = Set(
            stride(from: 150.0, through: 1_600.0, by: 2.0).map {
                subject.layout(paneWidth: CGFloat($0))
            }
        )
        XCTAssertTrue(tiers.contains(.compact))
        XCTAssertTrue(tiers.contains(.standard))
    }

    func testAPathologicalNameStopsGrowingInsteadOfEatingTheHeader() throws {
        let subject = chip(name: String(repeating: "device-", count: 40))
        let title = try XCTUnwrap(subject.presentation(paneWidth: 2_000).title)
        XCTAssertLessThanOrEqual(title.count, CompanionControllerChip.maximumDrawnCharacters)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testTruncationEndsOnAWordWhenOneIsClose() {
        XCTAssertEqual(
            chip(name: "Michael's iPhone 17 Pro").presentation(paneWidth: 340).title,
            "Michael's…"
        )
    }

    /// Larger Text buys fewer characters, so the chip steps down a presentation
    /// rather than truncating harder or overflowing the 32pt header.
    func testLargeTextStepsDownInsteadOfTruncatingHarder() {
        let subject = chip()
        let large = CompanionControllerChip.textScale(for: .accessibility3)
        let largest = CompanionControllerChip.textScale(for: .accessibility5)

        XCTAssertEqual(subject.layout(paneWidth: 700, textScale: 1), .expanded)
        XCTAssertEqual(subject.layout(paneWidth: 700, textScale: large), .standard)
        XCTAssertEqual(subject.layout(paneWidth: 420, textScale: largest), .compact)

        // Whatever it steps down to is still a name, not a letter.
        let stepped = subject.presentation(paneWidth: 700, textScale: large).title ?? ""
        XCTAssertGreaterThanOrEqual(stepped.replacingOccurrences(of: "…", with: "").count, 4)
        XCTAssertEqual(CompanionControllerChip.textScale(for: .large), 1)
        XCTAssertGreaterThan(largest, 2)
    }

    // MARK: - Identity and state survive every width

    func testFullIdentityAndStateSurviveInTheAssistivePresentations() {
        let subject = chip(name: Self.longName, tag: "9F3A", lease: .expiring, secondsRemaining: 6)
        let drawn = subject.presentation(paneWidth: 300).title ?? ""

        XCTAssertFalse(drawn.contains(Self.longName))
        XCTAssertTrue(subject.accessibilityValue.contains(Self.longName))
        XCTAssertTrue(subject.accessibilityValue.contains("9F3A"))
        XCTAssertTrue(subject.accessibilityValue.contains("6s"))
        XCTAssertTrue(subject.tooltip.contains(Self.longName))
        XCTAssertTrue(subject.tooltip.contains("6s"))
        XCTAssertEqual(subject.detailRows.first?.label, "Device")
        XCTAssertEqual(subject.detailRows.first?.value, "\(Self.longName) · 9F3A")
        XCTAssertTrue(subject.detailRows.contains { $0.value == "Expiring" })
    }

    func testCompactStillCarriesEverythingItStoppedDrawing() {
        let subject = chip(name: "Studio iPad", lease: .stale, secondsRemaining: 0)
        XCTAssertNil(subject.presentation(paneWidth: 230).title)
        XCTAssertEqual(subject.accessibilityLabel, "Remote control")
        XCTAssertTrue(subject.accessibilityValue.contains("Studio iPad"))
        XCTAssertTrue(subject.accessibilityValue.contains("expired"))
        XCTAssertTrue(subject.tooltip.contains("Studio iPad"))
        XCTAssertTrue(subject.detailRows.contains { $0.value == "Studio iPad" })
    }

    func testEachLeaseStateHasItsOwnGlyphSoColourIsNotTheOnlySignal() {
        let states: [CompanionControllerChip.Lease] = [.active, .expiring, .stale]
        XCTAssertEqual(Set(states.map { chip(lease: $0).symbolName }).count, 3)
        XCTAssertEqual(Set(states.map { chip(lease: $0).tone }).count, 3)
    }

    // MARK: - Lease transitions

    func testLeaseBandsFollowTheRenewalWindowAndThenGoStale() {
        let expiresAt: Int64 = 100_000
        let band = { (now: Int64) in
            CompanionControllerChip.lease(
                expiresAt: expiresAt, now: now, ttlMilliseconds: Self.ttl
            )
        }
        XCTAssertEqual(band(60_000), .active)
        XCTAssertEqual(band(91_000), .expiring)
        XCTAssertEqual(band(100_000), .stale)
        XCTAssertEqual(band(140_000), .stale)
    }

    func testTheSameSourceWalksActiveThroughStaleAsTheClockMoves() {
        let source = CompanionControllerChipSource(
            deviceName: "Michael's iPhone",
            expiresAt: 30_000
        )
        XCTAssertEqual(source.chip(now: 0).lease, .active)
        XCTAssertEqual(source.chip(now: 0).secondsRemaining, 30)
        XCTAssertEqual(source.chip(now: 25_000).lease, .expiring)
        XCTAssertEqual(source.chip(now: 25_000).secondsRemaining, 5)
        XCTAssertEqual(source.chip(now: 31_000).lease, .stale)
        XCTAssertEqual(source.chip(now: 31_000).secondsRemaining, 0)
        XCTAssertTrue(source.chip(now: 25_000).accessibilityValue.contains("5s"))
    }

    // MARK: - Roster resolution

    func testDuplicateDeviceNamesStayTellableApartAcrossPanes() {
        let devices = [
            device(id: "device-9f3a", name: "iPhone"),
            device(id: "device-b71c", name: "iPhone"),
        ]
        let first = CompanionControllerChipSource.resolve(
            status: status(terminalID: "terminal-1", deviceID: "device-9f3a"),
            pairedDevices: devices
        )
        let second = CompanionControllerChipSource.resolve(
            status: status(terminalID: "terminal-2", deviceID: "device-b71c"),
            pairedDevices: devices
        )
        XCTAssertEqual(first?.chip(now: 0).identity, "iPhone · 9F3A")
        XCTAssertEqual(second?.chip(now: 0).identity, "iPhone · B71C")
        XCTAssertTrue(first?.chip(now: 0).detailRows.contains { $0.label == "Why the suffix" } ?? false)
    }

    func testASingleDeviceKeepsItsPlainName() {
        let source = CompanionControllerChipSource.resolve(
            status: status(),
            pairedDevices: [device(id: "device-9f3a", name: "Michael's iPhone")]
        )
        XCTAssertNil(source?.deviceTag)
        XCTAssertEqual(source?.chip(now: 0).identity, "Michael's iPhone")
    }

    /// Revocation, release, expiry, and a dropped connection all clear the
    /// lease. The chip has to go with it: an indicator that outlives the
    /// authority it reports is worse than no indicator.
    func testRevocationRemovesTheChipEntirely() {
        XCTAssertNil(CompanionControllerChipSource.resolve(status: nil, pairedDevices: []))
        XCTAssertNil(
            CompanionControllerChipSource.resolve(
                status: nil,
                pairedDevices: [device(id: "device-9f3a", name: "iPhone")]
            )
        )
    }

    /// The reverse race: the roster entry is already gone but the lease has not
    /// been torn down yet. The chip must still report that something holds
    /// control.
    func testALeaseWithoutARosterEntryStillReportsControl() {
        let source = CompanionControllerChipSource.resolve(status: status(), pairedDevices: [])
        XCTAssertEqual(source?.chip(now: 0).identity, "Paired device")
    }

    func testMultiplePanesResolveTheirOwnControllerAndState() {
        let devices = [
            device(id: "device-9f3a", name: "Michael's iPhone"),
            device(id: "device-b71c", name: "Studio iPad"),
        ]
        let statuses = [
            status(terminalID: "terminal-1", deviceID: "device-9f3a", expiresAt: 30_000),
            status(terminalID: "terminal-2", deviceID: "device-b71c", expiresAt: 12_000),
        ]
        let first = CompanionControllerChipSource.resolve(
            status: statuses.first { $0.terminalID == "terminal-1" },
            pairedDevices: devices
        )
        let second = CompanionControllerChipSource.resolve(
            status: statuses.first { $0.terminalID == "terminal-2" },
            pairedDevices: devices
        )
        XCTAssertEqual(first?.chip(now: 5_000).deviceName, "Michael's iPhone")
        XCTAssertEqual(first?.chip(now: 5_000).lease, .active)
        XCTAssertEqual(second?.chip(now: 5_000).deviceName, "Studio iPad")
        XCTAssertEqual(second?.chip(now: 5_000).lease, .expiring)
    }

    // MARK: - The drawn capsule

    @MainActor
    private func capsuleWidth(
        paneWidth: CGFloat,
        proposal: CGFloat,
        name: String = "Michael's iPhone",
        layoutDirection: LayoutDirection = .leftToRight
    ) -> CGFloat {
        let view = CompanionControllerChipView(
            source: CompanionControllerChipSource(
                deviceName: name,
                expiresAt: CompanionControllerChipSource.milliseconds(Date()) + 30_000
            ),
            paneWidth: paneWidth
        )
        .environment(\.layoutDirection, layoutDirection)
        let host = NSHostingController(rootView: view)
        return host.sizeThatFits(in: NSSize(width: proposal, height: 32)).width
    }

    @MainActor
    func testTheDrawnCapsuleGrowsWithThePresentationItEarned() {
        let compact = capsuleWidth(paneWidth: 240, proposal: 400)
        let standard = capsuleWidth(paneWidth: 420, proposal: 400)
        let expanded = capsuleWidth(paneWidth: 700, proposal: 400)
        XCTAssertLessThan(compact, 46, "compact should be the two glyphs and nothing else")
        XCTAssertGreaterThan(standard, compact + 30)
        XCTAssertGreaterThan(expanded, standard + 30)
    }

    /// A squeezed header may shorten the pane title; it may not squeeze the
    /// capsule into an ellipsis. Under a 24pt proposal the capsule still
    /// reports the width its presentation asked for.
    @MainActor
    func testASqueezedHeaderCannotCompressTheCapsule() {
        let intrinsic = capsuleWidth(paneWidth: 420, proposal: 400)
        let squeezed = capsuleWidth(paneWidth: 420, proposal: 24)
        XCTAssertEqual(squeezed, intrinsic, accuracy: 0.5)
    }

    /// Control: the pattern this issue replaced. A one-line `Label` collapses
    /// into the proposal it is handed, and that collapse is what drew "i…". If
    /// it ever stops collapsing, the assertion above is no longer measuring the
    /// failure it was written against.
    @MainActor
    func testControlOneLineLabelCollapsesUnderTheSameProposal() {
        let old = Label("Michael's iPhone", systemImage: "iphone")
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
        let host = NSHostingController(rootView: old)
        let collapsed = host.sizeThatFits(in: NSSize(width: 24, height: 32)).width
        XCTAssertLessThan(collapsed, 60)
        XCTAssertLessThan(collapsed, capsuleWidth(paneWidth: 420, proposal: 24))
    }

    @MainActor
    func testRightToLeftDrawsTheSameCapsule() {
        for paneWidth in [240.0, 420.0, 700.0] {
            XCTAssertEqual(
                capsuleWidth(
                    paneWidth: CGFloat(paneWidth),
                    proposal: 400,
                    layoutDirection: .rightToLeft
                ),
                capsuleWidth(paneWidth: CGFloat(paneWidth), proposal: 400),
                accuracy: 0.5,
                "right-to-left changed the capsule's width at \(paneWidth)pt"
            )
        }
    }

    @MainActor
    func testALongDuplicateNameStillFitsInsideANormalPane() {
        // Worst realistic case: a long name plus the duplicate-device suffix in
        // the widest pane an ordinary grid gives one terminal.
        let width = capsuleWidth(
            paneWidth: 620,
            proposal: 620,
            name: "\(Self.longName) · 9F3A"
        )
        XCTAssertLessThan(width, 320, "the capsule outgrew the header it lives in")
    }
}
