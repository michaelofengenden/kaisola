import AppKit
import SwiftUI
import XCTest
@testable import Kaisola

/// A view whose position can be read back from AppKit once the panel is laid
/// out. SwiftUI text leaves no view of its own behind, so the tests below plant
/// one of these where the pull-request card's Confirm button sits and ask where
/// it landed.
private struct GitLayoutMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ nsView: Marker, context: Context) {}
}

/// The clean state used to be a plain `VStack`. `ContentUnavailableView` fills
/// whatever height it is offered, so History and Pull Request below it were
/// pushed past the panel's bottom edge with nothing to scroll — and a clean tree
/// with commits ahead of its upstream is exactly when the pull-request review is
/// open, the tallest card the panel ever shows, with Confirm and Cancel at its
/// foot.
///
/// Each test lays the real clean-state layout out at a pane size, then asks
/// AppKit whether the marker standing in for that foot can be brought on screen.
final class GitCleanTreeLayoutTests: XCTestCase {
    /// The panel is presented at 520x460 with a 42pt header over a divider, so
    /// the content itself gets this much.
    private static let paneWidth: CGFloat = 520
    private static let paneHeight: CGFloat = 417
    /// Deliberately cramped. The sheet is a fixed size today; the clean state
    /// must not depend on that staying true.
    private static let shortPaneHeight: CGFloat = 240

    /// Enough history that the sections alone (568pt) outgrow the pane, which is
    /// what an open pull-request review does in the real panel.
    private static let overflowingCommits = 30

    @MainActor
    func testOpenPullRequestReviewStaysReachableInTheGitPane() throws {
        let reach = try reachOfCleanTree(commits: Self.overflowingCommits, paneHeight: Self.paneHeight)
        XCTAssertFalse(reach.onScreen, "the case under test must actually outgrow the pane")
        XCTAssertTrue(reach.scrolled, "nothing scrolled, so the sections are wherever they were laid out")
        XCTAssertTrue(
            reach.reachable,
            "the foot of the pull-request review stayed off-panel with no way to scroll to it"
        )
    }

    @MainActor
    func testSectionsStayReachableOnAShortPane() throws {
        let reach = try reachOfCleanTree(commits: 15, paneHeight: Self.shortPaneHeight)
        XCTAssertFalse(reach.onScreen, "the case under test must actually outgrow the pane")
        XCTAssertTrue(reach.reachable, "a short pane left History and Pull Request stranded")
    }

    /// macOS does not scale SwiftUI text through `dynamicTypeSize`, so large
    /// text is expressed the way it actually reaches this layout: sections that
    /// render taller than the pane at the same commit count.
    @MainActor
    func testSectionsStayReachableUnderLargeText() throws {
        let reach = try reachOfCleanTree(
            commits: 12,
            paneHeight: Self.paneHeight,
            font: .system(size: 24)
        )
        XCTAssertFalse(reach.onScreen, "the case under test must actually outgrow the pane")
        XCTAssertTrue(reach.reachable, "large text left History and Pull Request stranded")
    }

    /// The other half of the fix: content that fits must look exactly as it did
    /// before — the placeholder still expands into the spare height and nothing
    /// scrolls.
    @MainActor
    func testRoomyPaneShowsEverythingWithoutScrolling() throws {
        let reach = try reachOfCleanTree(commits: 2, paneHeight: Self.paneHeight)
        XCTAssertTrue(reach.onScreen, "a clean tree that fits must be visible without scrolling")
        XCTAssertFalse(reach.scrolled, "content that fits must not have a scrollable overhang")
    }

    /// Control: the layout that shipped before this fix. If it ever stops
    /// stranding the sections, SwiftUI's sizing changed and the assertions above
    /// are no longer measuring the failure they were written against.
    @MainActor
    func testControlPlainStackStrandsTheSectionsBelowThePane() throws {
        let old = VStack(spacing: 0) {
            ContentUnavailableView("Working tree clean", systemImage: "checkmark.seal")
            sections(commits: Self.overflowingCommits, font: .caption)
        }
        let reach = try reach(of: old, paneHeight: Self.paneHeight)
        XCTAssertFalse(reach.onScreen)
        XCTAssertFalse(reach.scrolled)
        XCTAssertFalse(reach.reachable)
    }

    // MARK: - Harness

    /// Where the marker ended up: on screen as laid out, whether AppKit found
    /// anything to scroll, and whether it is on screen afterwards.
    private struct MarkerReach {
        let onScreen: Bool
        let scrolled: Bool
        let reachable: Bool
    }

    @MainActor
    private func reachOfCleanTree(
        commits: Int,
        paneHeight: CGFloat,
        font: Font = .caption
    ) throws -> MarkerReach {
        // The panel itself is never rendered — only the clean-state layout it
        // builds, with sections of a known height in place of the real ones.
        let panel = GitPanelView(repoRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        return try reach(
            of: panel.cleanTree { sections(commits: commits, font: font) },
            paneHeight: paneHeight
        )
    }

    @MainActor
    private func reach(of view: some View, paneHeight: CGFloat) throws -> MarkerReach {
        let pane = NSSize(width: Self.paneWidth, height: paneHeight)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: pane)
        // A window, not a bare hosting view: scrolling is a real AppKit clip
        // view moving, and it only happens in a laid-out hierarchy.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: pane),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let marker = try XCTUnwrap(Self.marker(in: host), "the sections never reached the view tree")
        let onScreen = host.bounds.contains(marker.convert(marker.bounds, to: host))
        let scrolled = marker.scrollToVisible(marker.bounds)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return MarkerReach(
            onScreen: onScreen,
            scrolled: scrolled,
            reachable: host.bounds.contains(marker.convert(marker.bounds, to: host))
        )
    }

    /// History and Pull Request at a known height: `commits` log rows, then the
    /// marker where the review card's Confirm button sits.
    @MainActor
    private func sections(commits: Int, font: Font) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("History").font(font.weight(.semibold))
            ForEach(0..<commits, id: \.self) { index in
                Text("abc1234 commit subject \(index)").font(font)
            }
            Text("Pull Request").font(font.weight(.semibold))
            GitLayoutMarker().frame(height: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private static func marker(in view: NSView) -> GitLayoutMarker.Marker? {
        if let marker = view as? GitLayoutMarker.Marker { return marker }
        for subview in view.subviews {
            if let marker = marker(in: subview) { return marker }
        }
        return nil
    }
}
