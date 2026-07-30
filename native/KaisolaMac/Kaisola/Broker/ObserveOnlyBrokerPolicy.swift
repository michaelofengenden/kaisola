import Foundation
import KaisolaBrokerProtocol

enum ObserveOnlyBrokerMethod: String, CaseIterable, Sendable {
    case status = "broker.status"
    case list = "terminal.list"
    case diagnostics = "terminal.diagnostics"
    case history = "terminal.history"
    case subscribe = "terminal.subscribe"
    case unsubscribe = "terminal.unsubscribe"
}

enum ObserveOnlyBrokerPolicy {
    static let forbiddenTerminalMethods: Set<String> = [
        "terminal.attach",
        "terminal.create",
        "terminal.write",
        "terminal.resize",
        "terminal.signal",
        "terminal.kill",
        "terminal.release",
        "terminal.scheduleRelease",
        "terminal.cancelRelease",
        "terminal.detachRenderer",
        "terminal.detachOwner",
        "terminal.agentTurn",
        "terminal.setFocused",
        "terminal.snapshot",
        "terminal.output",
        "terminal.waitForExit",
        "broker.shutdown",
    ]

    static func validate(_ method: String) throws -> ObserveOnlyBrokerMethod {
        guard BrokerWire.observerMethods.contains(method),
              let method = ObserveOnlyBrokerMethod(rawValue: method) else {
            throw ObserveOnlyBrokerPolicyError.methodRejected(method)
        }
        return method
    }
}

enum ObserveOnlyBrokerPolicyError: Error, Equatable, LocalizedError {
    case methodRejected(String)

    var errorDescription: String? {
        "Kaisola blocked a broker method outside its read-only contract."
    }
}
