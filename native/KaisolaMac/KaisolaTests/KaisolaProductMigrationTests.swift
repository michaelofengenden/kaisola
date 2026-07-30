import Foundation
import XCTest
@testable import Kaisola

final class KaisolaProductMigrationTests: XCTestCase {
    func testProductionCutoverCopiesOnlyMissingPreviewDefaultsOnce() {
        let suite = "kaisola-product-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("production", forKey: "appearance")

        KaisolaProductMigration.run(
            defaults: defaults,
            legacyDomain: [
                "appearance": "preview",
                "navigationLayout": "leftTree",
            ],
            currentBundleIdentifier: KaisolaProductMigration.productionBundleIdentifier
        )

        XCTAssertEqual(defaults.string(forKey: "appearance"), "production")
        XCTAssertEqual(defaults.string(forKey: "navigationLayout"), "leftTree")
        XCTAssertTrue(defaults.bool(forKey: KaisolaProductMigration.completionKey))

        KaisolaProductMigration.run(
            defaults: defaults,
            legacyDomain: ["navigationLayout": "topBar"],
            currentBundleIdentifier: KaisolaProductMigration.productionBundleIdentifier
        )
        XCTAssertEqual(defaults.string(forKey: "navigationLayout"), "leftTree")
    }

    func testMigrationDoesNothingOutsideProductionBundle() {
        let suite = "kaisola-product-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        KaisolaProductMigration.run(
            defaults: defaults,
            legacyDomain: ["appearance": "dark"],
            currentBundleIdentifier: "com.kaisola.mac.dev"
        )

        XCTAssertNil(defaults.object(forKey: "appearance"))
        XCTAssertFalse(defaults.bool(forKey: KaisolaProductMigration.completionKey))
    }
}
