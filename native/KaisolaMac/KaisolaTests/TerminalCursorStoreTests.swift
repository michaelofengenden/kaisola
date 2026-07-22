import Darwin
import XCTest
@testable import KaisolaMacPreview

final class TerminalCursorStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/kaisola-cursors-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(root.path, 0o700)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCursorIsScopedByBrokerProjectAndTerminal() async throws {
        let store = TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        let target = scope(broker: "a", project: "project.one", terminal: "terminal:1")
        try await store.save(TerminalCursor(streamEpoch: "epoch-a", offset: 42), for: target)

        let saved = try await store.cursor(for: target)
        let otherBroker = try await store.cursor(
            for: scope(broker: "b", project: "project.one", terminal: "terminal:1")
        )
        let otherProject = try await store.cursor(
            for: scope(broker: "a", project: "project.two", terminal: "terminal:1")
        )
        let otherTerminal = try await store.cursor(
            for: scope(broker: "a", project: "project.one", terminal: "terminal:2")
        )

        XCTAssertEqual(saved, TerminalCursor(streamEpoch: "epoch-a", offset: 42))
        XCTAssertNil(otherBroker)
        XCTAssertNil(otherProject)
        XCTAssertNil(otherTerminal)
    }

    func testSameEpochNeverRegressesButAReplacementEpochCanRestartAtZero() async throws {
        let store = TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json"))
        let target = scope(broker: "a", project: "project.one", terminal: "terminal:1")
        try await store.save(TerminalCursor(streamEpoch: "epoch-a", offset: 42), for: target)
        try await store.save(TerminalCursor(streamEpoch: "epoch-a", offset: 12), for: target)
        let monotonic = try await store.cursor(for: target)
        XCTAssertEqual(monotonic?.offset, 42)

        try await store.save(TerminalCursor(streamEpoch: "epoch-b", offset: 0), for: target)
        let replacement = try await store.cursor(for: target)
        XCTAssertEqual(replacement, TerminalCursor(streamEpoch: "epoch-b", offset: 0))
    }

    func testArchiveUsesPrivateModeAndRefusesAWorldReadableReplacement() async throws {
        let file = root.appendingPathComponent("cursors.json")
        let store = TerminalCursorStore(fileURL: file)
        let target = scope(broker: "a", project: "project.one", terminal: "terminal:1")
        try await store.save(TerminalCursor(streamEpoch: "epoch-a", offset: 1), for: target)

        var metadata = stat()
        XCTAssertEqual(lstat(file.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o077, 0)

        _ = chmod(file.path, 0o644)
        do {
            _ = try await store.cursor(for: target)
            XCTFail("A public cursor archive must be refused")
        } catch {
            XCTAssertEqual(error as? TerminalCursorStore.StoreError, .unsafePath)
        }
    }

    func testSymlinkedStateDirectoryIsRefusedWithoutChangingItsTargetMode() async throws {
        let target = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        _ = chmod(target.path, 0o755)
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = TerminalCursorStore(fileURL: link.appendingPathComponent("cursors.json"))

        do {
            try await store.save(
                TerminalCursor(streamEpoch: "epoch-a", offset: 1),
                for: scope(broker: "a", project: "project.one", terminal: "terminal:1")
            )
            XCTFail("A symlinked cursor directory must be refused")
        } catch {
            XCTAssertEqual(error as? TerminalCursorStore.StoreError, .unsafePath)
        }

        var metadata = stat()
        XCTAssertEqual(lstat(target.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o755)
    }

    private func scope(broker: Character, project: String, terminal: String) -> TerminalCursorScope {
        TerminalCursorScope(
            brokerIdentity: String(repeating: String(broker), count: 64),
            projectID: project,
            terminalID: terminal
        )
    }
}
