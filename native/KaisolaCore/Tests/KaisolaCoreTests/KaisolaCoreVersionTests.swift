import XCTest
@testable import KaisolaCore
import KaisolaTestSupport

final class KaisolaCoreVersionTests: XCTestCase {
    func testCoreVersionStartsAtOne() {
        XCTAssertEqual(KaisolaCoreVersion.current, 1)
    }

    func testCanonicalCompanionFixtureIsReachableWithoutDuplication() throws {
        let url = try RepositoryFixtures.companionFixture(named: "hello")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["v"] as? Int, 1)
        XCTAssertEqual(object?["kind"] as? String, "hello")
    }
}
