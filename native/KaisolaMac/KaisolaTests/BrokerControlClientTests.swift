import Foundation
import KaisolaBrokerProtocol
import XCTest
@testable import KaisolaMacPreview

/// The controller lane's contract: its sealed method set is exactly the six
/// mutations the native app needs, every request carries the owner identity,
/// and the connection refuses brokers that predate role enforcement.
final class BrokerControlClientTests: XCTestCase {
    func testControlMethodSetIsExactlyTheNativeMutationSurface() {
        XCTAssertEqual(
            Set(ControlBrokerMethod.allCases.map(\.rawValue)),
            [
                "terminal.create",
                "terminal.attach",
                "terminal.write",
                "terminal.resize",
                "terminal.kill",
                "terminal.detachOwner",
            ]
        )
    }

    func testControlMethodsNeverOverlapObserverPolicyReads() {
        let controlMethods = Set(ControlBrokerMethod.allCases.map(\.rawValue))
        let observerMethods = Set(ObserveOnlyBrokerMethod.allCases.map(\.rawValue))
        XCTAssertTrue(controlMethods.isDisjoint(with: observerMethods))
        // Every control method is one the observer policy explicitly forbids,
        // proving the two lanes partition the wire surface.
        XCTAssertTrue(controlMethods.isSubset(of: ObserveOnlyBrokerPolicy.forbiddenTerminalMethods))
    }

    func testSessionStorePersistsOwnershipAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-session-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native-sessions.json")

        let first = NativeSessionStore(fileURL: file)
        let owner = first.ownerID()
        XCTAssertTrue(owner.hasPrefix("native-"))
        first.upsert(NativeOwnedSession(
            id: "term-nproj_abc-1",
            projectID: "nproj_abc",
            cwd: "/tmp/example",
            title: "example",
            createdAt: 1
        ))

        let second = NativeSessionStore(fileURL: file)
        XCTAssertEqual(second.ownerID(), owner)
        XCTAssertTrue(second.owns(terminalID: "term-nproj_abc-1"))
        XCTAssertFalse(second.owns(terminalID: "term-proj_electron"))

        second.remove(terminalID: "term-nproj_abc-1")
        XCTAssertFalse(NativeSessionStore(fileURL: file).owns(terminalID: "term-nproj_abc-1"))
    }

    func testProjectIdentityIsDeterministicAndNamespaced() {
        let one = NativeSessionStore.projectID(forDirectory: "/Users/example/code/app")
        let two = NativeSessionStore.projectID(forDirectory: "/Users/example/code/app/")
        let other = NativeSessionStore.projectID(forDirectory: "/Users/example/code/other")
        XCTAssertEqual(one, two)
        XCTAssertNotEqual(one, other)
        XCTAssertTrue(one.hasPrefix("nproj_"))
        XCTAssertFalse(one.hasPrefix("proj_"))
    }

    func testCorruptStoreDegradesToEmptyRegistry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-session-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native-sessions.json")
        try Data("not json".utf8).write(to: file)

        let store = NativeSessionStore(fileURL: file)
        XCTAssertEqual(store.sessions(), [])
        XCTAssertTrue(store.ownerID().hasPrefix("native-"))
    }
}
