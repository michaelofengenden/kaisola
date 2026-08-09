import Darwin
import Foundation
import XCTest

@testable import Kaisola

final class PermissionRuleStoreConcurrencyTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-permission-rule-concurrency-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("permission-rules.json", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOverlappingAddsWaitForMutationLockAndPreserveBothRules() throws {
        let firstStore = PermissionRuleStore(fileURL: fileURL)
        let secondStore = PermissionRuleStore(fileURL: fileURL)
        let first = rule(id: "first", resource: "git *")
        let second = rule(id: "second", resource: "npm *")

        try runWhileHoldingMutationLock([
            { _ = firstStore.add(first) },
            { _ = secondStore.add(second) },
        ])

        XCTAssertEqual(
            Set(PermissionRuleStore(fileURL: fileURL).rules().map(\.id)),
            Set(["first", "second"])
        )
    }

    func testOverlappingAddAndRemoveWaitForMutationLockAndUseLatestRules() throws {
        let seedStore = PermissionRuleStore(fileURL: fileURL)
        _ = seedStore.add(rule(id: "remove-me", resource: "git *"))

        let addingStore = PermissionRuleStore(fileURL: fileURL)
        let removingStore = PermissionRuleStore(fileURL: fileURL)
        let retained = rule(id: "retained", resource: "npm *")

        try runWhileHoldingMutationLock([
            { _ = addingStore.add(retained) },
            { removingStore.remove(id: "remove-me") },
        ])

        XCTAssertEqual(
            PermissionRuleStore(fileURL: fileURL).rules().map(\.id),
            ["retained"]
        )
    }

    private func runWhileHoldingMutationLock(
        _ mutations: [@Sendable () -> Void]
    ) throws {
        let lockURL = directory.appendingPathComponent(".permission-rules.json.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        let ready = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        for mutation in mutations {
            ready.enter()
            completed.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                ready.leave()
                start.wait()
                mutation()
                completed.leave()
            }
        }

        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        for _ in mutations { start.signal() }
        XCTAssertEqual(
            completed.wait(timeout: .now() + 0.25),
            .timedOut,
            "Every mutation must wait for the store's shared advisory lock."
        )

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    }

    private func rule(id: String, resource: String) -> PermissionRule {
        PermissionRule(
            id: id,
            workspace: "/workspace",
            action: "execute",
            resource: resource,
            at: 0
        )
    }
}
