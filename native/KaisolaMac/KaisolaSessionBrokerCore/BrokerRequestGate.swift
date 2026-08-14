import Foundation

public enum BrokerOverloadScope: String, Codable, Equatable, Sendable {
    case client
    case process
}

public struct BrokerOverload: Codable, Equatable, Sendable {
    public let scope: BrokerOverloadScope
    public let limit: Int

    public init(scope: BrokerOverloadScope, limit: Int) {
        self.scope = scope
        self.limit = limit
    }
}

public enum BrokerRequestAdmission: Sendable {
    case granted(BrokerRequestLease)
    case rejected(BrokerOverload)
}

public enum BrokerRequestGateError: Error, Equatable, Sendable {
    case invalidLimit
}

public actor BrokerRequestLease {
    private let releaseAction: @Sendable () async -> Void
    private var released = false

    init(releaseAction: @escaping @Sendable () async -> Void) {
        self.releaseAction = releaseAction
    }

    /// Returns true only for the transition which actually restores capacity.
    /// Repeated cleanup from cancellation and socket teardown is harmless.
    @discardableResult
    public func release() async -> Bool {
        guard !released else { return false }
        released = true
        await releaseAction()
        return true
    }
}

public actor BrokerRequestGate {
    public static let defaultPerClientLimit = 16
    public static let defaultProcessLimit = 128

    private let perClientLimit: Int
    private let processLimit: Int
    private var clientInFlight: [String: Int] = [:]
    private var processInFlight = 0

    public init() {
        perClientLimit = Self.defaultPerClientLimit
        processLimit = Self.defaultProcessLimit
    }

    public init(perClientLimit: Int, processLimit: Int) throws {
        guard perClientLimit > 0, processLimit > 0 else {
            throw BrokerRequestGateError.invalidLimit
        }
        self.perClientLimit = perClientLimit
        self.processLimit = processLimit
    }

    public func acquire(clientID: String) -> BrokerRequestAdmission {
        let clientCount = clientInFlight[clientID, default: 0]
        if clientCount >= perClientLimit {
            return .rejected(BrokerOverload(scope: .client, limit: perClientLimit))
        }
        if processInFlight >= processLimit {
            return .rejected(BrokerOverload(scope: .process, limit: processLimit))
        }

        clientInFlight[clientID] = clientCount + 1
        processInFlight += 1
        let lease = BrokerRequestLease { [gate = self] in
            await gate.release(clientID: clientID)
        }
        return .granted(lease)
    }

    private func release(clientID: String) {
        let clientCount = clientInFlight[clientID, default: 0]
        if clientCount <= 1 {
            clientInFlight.removeValue(forKey: clientID)
        } else {
            clientInFlight[clientID] = clientCount - 1
        }
        processInFlight = max(0, processInFlight - 1)
    }
}
