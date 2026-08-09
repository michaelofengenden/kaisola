import AppKit
import SwiftUI
import XCTest
@testable import Kaisola

@MainActor
final class RootShellLayoutsTests: XCTestCase {
    func testLeftTreeShellRendersProjectsWorkspaceAndFooter() throws {
        XCTAssertEqual(
            RootShellRenderContract.regions(for: .leftTree),
            [.projects, .workspace, .footer]
        )

        let image = try renderRootShell(
            RootLeftTreeShell(actions: inertRootShellActions()) { _ in
                VStack {
                    Text("Projects")
                    Text("Footer")
                }
            } detail: { _ in
                Text("Workspace")
            }
        )

        XCTAssertEqual(image.size, NSSize(width: 720, height: 480))
        XCTAssertGreaterThan(image.tiffRepresentation?.count ?? 0, 1_000)
    }

    func testTopBarShellRendersAllFiveRegions() throws {
        XCTAssertEqual(
            RootShellRenderContract.regions(for: .topBar),
            [.projects, .quickActions, .sessions, .workspace, .footer]
        )

        let image = try renderRootShell(
            RootTopBarShell(actions: inertRootShellActions()) { _ in
                Text("Projects")
            } quickActions: { _ in
                Text("Quick Actions")
            } sessions: { _ in
                Text("Sessions")
            } detail: { _ in
                Text("Workspace")
            } footer: { _ in
                Text("Footer")
            }
        )

        XCTAssertEqual(image.size, NSSize(width: 720, height: 480))
        XCTAssertGreaterThan(image.tiffRepresentation?.count ?? 0, 1_000)
    }

    private func renderRootShell<Content: View>(_ content: Content) throws -> NSImage {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        let hostingView = NSHostingView(rootView: content.frame(width: 720, height: 480))
        hostingView.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: frame.size)
        image.addRepresentation(representation)
        window.contentView = nil
        return image
    }

    private func inertRootShellActions() -> RootShellActionModel {
        RootShellActionModel(
            openDroppedProjects: { _ in false },
            openProject: {},
            useLeftTreeNavigation: {},
            moveProject: { _, _ in },
            runQuickAction: { _, _ in },
            selectSession: { _ in },
            projectLaunchMenu: { _ in AnyView(EmptyView()) },
            projectContextMenu: { _ in AnyView(EmptyView()) },
            sessionContextMenu: { _ in AnyView(EmptyView()) },
            chatContextMenu: { _ in AnyView(EmptyView()) },
            meshContextMenu: { _ in AnyView(EmptyView()) },
            renameSurface: { _ in },
            closeChat: { _ in },
            deleteChat: { _ in },
            closeMesh: { _ in },
            deleteMesh: { _ in },
            deleteRecentlyClosed: { _ in }
        )
    }
}
