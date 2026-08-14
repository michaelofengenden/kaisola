import Foundation
import OSLog

/// A small, privacy-preserving diagnostic trail for the shadow broker.
///
/// The transport never sends raw frames, tokens, client identifiers, or
/// request parameters here. Unknown method names are collapsed to a constant
/// marker before they reach either unified logging or the bounded snapshot.
public final class BrokerLog: @unchecked Sendable {
    public enum Event: Sendable {
        case serverStarted
        case serverStopped
        case connectionAccepted
        case connectionRejected
        case authenticationAccepted
        case authenticationRejected
        case protocolViolation
        case staleSocketRecovered
        case request(String)
    }

    private static let knownMethods: Set<String> = [
        "broker.status",
        "broker.inventory",
        "broker.shutdown",
        "broker.shutdownForUpdate",
        "broker.prepareRollingUpdate",
        "broker.cancelRollingUpdate",
        "broker.retireDraining",
        "terminal.list",
        "terminal.diagnostics",
        "terminal.subscribe",
        "terminal.unsubscribe",
        "terminal.create",
        "terminal.attach",
        "terminal.detachRenderer",
        "terminal.detachOwner",
        "terminal.write",
        "terminal.agentTurn",
        "terminal.resize",
        "terminal.signal",
        "terminal.kill",
        "terminal.release",
        "terminal.scheduleRelease",
        "terminal.cancelRelease",
        "terminal.setFocused",
        "terminal.controlLease",
    ]

    private let capacity: Int
    private let maximumEntryBytes: Int
    private let lock = NSLock()
    private var entries: [String] = []
    private let systemLogger = Logger(
        subsystem: "com.kaisola.mac.session-broker",
        category: "shadow"
    )

    public init(capacity: Int = 128, maximumEntryBytes: Int = 256) {
        self.capacity = min(max(capacity, 1), 1_024)
        self.maximumEntryBytes = min(max(maximumEntryBytes, 32), 1_024)
    }

    public func record(_ event: Event) {
        let entry: String
        switch event {
        case .serverStarted: entry = "server_started"
        case .serverStopped: entry = "server_stopped"
        case .connectionAccepted: entry = "connection_accepted"
        case .connectionRejected: entry = "connection_rejected"
        case .authenticationAccepted: entry = "authentication_accepted"
        case .authenticationRejected: entry = "authentication_rejected"
        case .protocolViolation: entry = "protocol_violation"
        case .staleSocketRecovered: entry = "stale_socket_recovered"
        case let .request(method):
            let safeMethod = Self.knownMethods.contains(method) ? method : "unrecognized"
            entry = "request method=\(safeMethod)"
        }

        let bounded = String(
            decoding: entry.utf8.prefix(maximumEntryBytes),
            as: UTF8.self
        )
        lock.lock()
        entries.append(bounded)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        lock.unlock()
        systemLogger.notice("\(bounded, privacy: .public)")
    }

    /// The extra arguments deliberately remain unused: this transport-facing
    /// API makes it difficult for a future call site to accidentally log them.
    public func recordRequest(
        method: String,
        clientID _: String? = nil,
        paramsDescription _: String? = nil
    ) {
        record(.request(method))
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
