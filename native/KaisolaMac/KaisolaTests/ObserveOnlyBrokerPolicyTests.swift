import XCTest
import KaisolaBrokerProtocol
@testable import Kaisola

final class ObserveOnlyBrokerPolicyTests: XCTestCase {
    func testOnlyTypedInventoryAndObserverLifecycleAreAllowed() throws {
        XCTAssertEqual(try ObserveOnlyBrokerPolicy.validate("broker.status"), .status)
        XCTAssertEqual(try ObserveOnlyBrokerPolicy.validate("broker.inventory"), .inventory)
        XCTAssertEqual(try ObserveOnlyBrokerPolicy.validate("terminal.list"), .list)
        XCTAssertEqual(try ObserveOnlyBrokerPolicy.validate("terminal.diagnostics"), .diagnostics)
        XCTAssertEqual(try ObserveOnlyBrokerPolicy.validate("terminal.history"), .history)
        XCTAssertEqual(try ObserveOnlyBrokerPolicy.validate("terminal.subscribe"), .subscribe)
        XCTAssertEqual(try ObserveOnlyBrokerPolicy.validate("terminal.unsubscribe"), .unsubscribe)
        XCTAssertEqual(Set(ObserveOnlyBrokerMethod.allCases.map(\.rawValue)), BrokerWire.observerMethods)
    }

    func testEveryKnownMutationIsRejectedLocally() {
        let requiredForbidden = [
            "terminal.attach", "terminal.create", "terminal.write", "terminal.resize",
            "terminal.signal", "terminal.kill", "terminal.release",
        ]
        for method in requiredForbidden {
            XCTAssertTrue(ObserveOnlyBrokerPolicy.forbiddenTerminalMethods.contains(method))
            XCTAssertThrowsError(try ObserveOnlyBrokerPolicy.validate(method)) { error in
                XCTAssertEqual(error as? ObserveOnlyBrokerPolicyError, .methodRejected(method))
            }
        }
    }

    func testUnknownReadLookingMethodsAlsoFailClosed() {
        XCTAssertThrowsError(try ObserveOnlyBrokerPolicy.validate("terminal.snapshot"))
        XCTAssertThrowsError(try ObserveOnlyBrokerPolicy.validate("broker.futureRead"))
    }
}
