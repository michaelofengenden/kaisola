import XCTest
@testable import Kaisola

/// Account/usage cards must paint from disk on launch rather than after a
/// multi-second helper verification plus one subprocess per account.
final class PlanUsageSnapshotStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plan-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> PlanUsageSnapshotStore {
        PlanUsageSnapshotStore(fileURL: directory.appendingPathComponent("snapshots.json"))
    }

    private func usage(plan: String, percent: Double) -> UsageCenter.ProviderPlanUsage {
        UsageCenter.ProviderPlanUsage(
            provider: "claude",
            displayName: "Claude",
            profileID: "personal",
            profileLabel: "Claude Personal",
            ok: true,
            sourceLabel: "claude",
            plan: plan,
            windows: [UsageCenter.PlanWindow(label: "5-hour", usedPercent: percent, resetsAt: 1_000)]
        )
    }

    func testRoundTripsAcrossProcesses() {
        let store = makeStore()
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(["ctx-a": .init(providers: [usage(plan: "max", percent: 16)], fetchedAt: fetchedAt)])

        // A fresh store instance stands in for the next launch.
        let reloaded = makeStore().entries()
        XCTAssertEqual(reloaded["ctx-a"]?.providers.first?.plan, "max")
        XCTAssertEqual(reloaded["ctx-a"]?.providers.first?.windows.first?.usedPercent, 16)
        XCTAssertEqual(reloaded["ctx-a"]?.fetchedAt, fetchedAt)
    }

    func testMissingFileIsEmptyRatherThanAnError() {
        XCTAssertTrue(makeStore().entries().isEmpty)
    }

    func testCorruptFileDegradesToEmpty() throws {
        let url = directory.appendingPathComponent("snapshots.json")
        try Data("not json".utf8).write(to: url)
        // A damaged cache must never block the live probe from running.
        XCTAssertTrue(PlanUsageSnapshotStore(fileURL: url).entries().isEmpty)
    }

    func testUnknownSchemaVersionIsIgnored() throws {
        let url = directory.appendingPathComponent("snapshots.json")
        try Data(#"{"schemaVersion":99,"entries":{}}"#.utf8).write(to: url)
        XCTAssertTrue(PlanUsageSnapshotStore(fileURL: url).entries().isEmpty)
    }

    func testKeepsTheNewestEntriesWhenBounded() {
        let store = makeStore()
        var entries: [String: PlanUsageSnapshotStore.Entry] = [:]
        for index in 0..<40 {
            entries["ctx-\(index)"] = .init(
                providers: [usage(plan: "max", percent: Double(index))],
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
        store.save(entries)

        let reloaded = makeStore().entries()
        XCTAssertEqual(reloaded.count, 24)
        // Newest survive, oldest are dropped.
        XCTAssertNotNil(reloaded["ctx-39"])
        XCTAssertNil(reloaded["ctx-0"])
    }

    func testFileIsOwnerReadableOnly() throws {
        let store = makeStore()
        store.save(["ctx": .init(providers: [usage(plan: "pro", percent: 1)], fetchedAt: Date())])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }
}
