import Foundation
import KaisolaBrokerProtocol
import KaisolaCore

struct BrokerHello: Equatable, Sendable {
    let protocolVersion: Int
    let securityEpoch: Int
    let implementationVersion: Int
    let packageSchema: Int?
    let packageVersion: String?
    let contentDigest: String?
    let features: Set<String>
    let pid: Int32
    let startedAt: Int64
    let version: String
    let serverEnforcedObserver: Bool

    init(
        protocolVersion: Int,
        securityEpoch: Int,
        implementationVersion: Int,
        packageSchema: Int?,
        packageVersion: String?,
        contentDigest: String? = nil,
        features: Set<String>,
        pid: Int32,
        startedAt: Int64,
        version: String,
        serverEnforcedObserver: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.securityEpoch = securityEpoch
        self.implementationVersion = implementationVersion
        self.packageSchema = packageSchema
        self.packageVersion = packageVersion
        self.contentDigest = contentDigest
        self.features = features
        self.pid = pid
        self.startedAt = startedAt
        self.version = version
        self.serverEnforcedObserver = serverEnforcedObserver
    }
}

struct BrokerTerminalCapacity: Equatable, Sendable {
    let liveTerminalCount: Int
    let maximumLiveTerminals: Int
    let availableTerminalSlots: Int

    init?(value: JSONValue) {
        guard let object = value.objectValue,
              let live = object["liveTerminalCount"]?.intValue.flatMap(Int.init(exactly:)),
              let maximum = object["maximumLiveTerminals"]?.intValue.flatMap(Int.init(exactly:)),
              let available = object["availableTerminalSlots"]?.intValue.flatMap(Int.init(exactly:)),
              live >= 0,
              maximum > 0,
              maximum <= BrokerWire.maximumConfigurableLiveTerminals,
              live <= maximum,
              available == maximum - live else { return nil }
        liveTerminalCount = live
        maximumLiveTerminals = maximum
        availableTerminalSlots = available
    }
}

struct BrokerStatus: Equatable, Sendable {
    let terminals: [BrokerTerminalRecord]
    /// Monotonic broker-wide mutation/activity fence sampled with this
    /// inventory. Nil is reserved for pre-generation legacy brokers.
    let activityEpoch: Int64?
    /// Present on observer/administrator diagnostics from upgraded brokers.
    /// Ordinary controller status intentionally omits this process-wide value.
    let terminalCapacity: BrokerTerminalCapacity?

    init(
        terminals: [BrokerTerminalRecord],
        activityEpoch: Int64? = nil,
        terminalCapacity: BrokerTerminalCapacity? = nil
    ) {
        self.terminals = terminals
        self.activityEpoch = activityEpoch
        self.terminalCapacity = terminalCapacity
    }

    init(
        status: JSONValue,
        diagnostics: JSONValue,
        live: JSONValue,
        expectedHello: BrokerHello
    ) throws {
        guard let statusObject = status.objectValue,
              statusObject["ok"]?.boolValue == true,
              let protocolVersion = statusObject["protocol"]?.intValue.flatMap(Int.init(exactly:)),
              let securityEpoch = statusObject["securityEpoch"]?.intValue.flatMap(Int.init(exactly:)),
              BrokerWire.accepts(
                  protocolVersion: protocolVersion,
                  securityEpoch: securityEpoch,
                  implementationVersion: statusObject["implementationVersion"]?.intValue.flatMap(Int.init(exactly:))
              ) else {
            throw BrokerClientError.malformedResponse
        }
        if let pid = statusObject["pid"]?.intValue,
           pid != Int64(expectedHello.pid) {
            throw BrokerClientError.identityChanged
        }
        if let startedAt = statusObject["startedAt"]?.intValue,
           startedAt != expectedHello.startedAt {
            throw BrokerClientError.identityChanged
        }
        if let implementationVersion = statusObject["implementationVersion"]?.intValue,
           implementationVersion != Int64(expectedHello.implementationVersion) {
            throw BrokerClientError.identityChanged
        }
        if let packageSchema = statusObject["packageSchema"]?.intValue,
           packageSchema != expectedHello.packageSchema.map(Int64.init) {
            throw BrokerClientError.identityChanged
        }
        if statusObject["packageVersion"] != nil || expectedHello.packageVersion != nil,
           statusObject["packageVersion"]?.stringValue != expectedHello.packageVersion {
            throw BrokerClientError.identityChanged
        }
        if statusObject["contentDigest"] != nil || expectedHello.contentDigest != nil,
           statusObject["contentDigest"]?.stringValue != expectedHello.contentDigest {
            throw BrokerClientError.identityChanged
        }
        let parsedActivityEpoch: Int64?
        if statusObject["activityEpoch"] != nil {
            guard let activityEpoch = statusObject["activityEpoch"]?.intValue,
                  activityEpoch > 0 else {
                throw BrokerClientError.malformedResponse
            }
            parsedActivityEpoch = activityEpoch
        } else {
            parsedActivityEpoch = nil
        }
        let parsedTerminalCapacity: BrokerTerminalCapacity?
        if let value = statusObject["terminalCapacity"] {
            guard let terminalCapacity = BrokerTerminalCapacity(value: value) else {
                throw BrokerClientError.malformedResponse
            }
            parsedTerminalCapacity = terminalCapacity
        } else {
            parsedTerminalCapacity = nil
        }
        guard let diagnosticValues = diagnostics.arrayValue,
              let liveValues = live.arrayValue else {
            throw BrokerClientError.malformedResponse
        }
        let liveByID = try Self.valuesByUniqueTerminalID(liveValues)
        var decodedTerminals: [BrokerTerminalRecord] = []
        decodedTerminals.reserveCapacity(diagnosticValues.count)
        var diagnosticIDs: Set<String> = []
        for (index, value) in diagnosticValues.enumerated() {
            guard let terminal = BrokerTerminalRecord(
                value: value,
                liveValue: value.objectValue?["id"]?.stringValue.flatMap { liveByID[$0] }
            ) else {
                throw BrokerInventoryError.invalidDiagnosticRow(index: index)
            }
            guard diagnosticIDs.insert(terminal.id).inserted else {
                throw BrokerClientError.malformedResponse
            }
            decodedTerminals.append(terminal)
        }
        terminals = decodedTerminals
        activityEpoch = parsedActivityEpoch
        terminalCapacity = parsedTerminalCapacity
    }

    static func validatedActivityEpoch(
        status: JSONValue,
        expectedHello: BrokerHello
    ) throws -> Int64? {
        try BrokerStatus(
            status: status,
            diagnostics: .array([]),
            live: .array([]),
            expectedHello: expectedHello
        ).activityEpoch
    }

    private static func valuesByUniqueTerminalID(_ values: [JSONValue]) throws -> [String: JSONValue] {
        var valuesByID: [String: JSONValue] = [:]
        for value in values {
            // Preserve the existing partial-response handling for rows that do
            // not carry a parseable ID; repeated parseable IDs are ambiguous.
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue else {
                continue
            }
            guard valuesByID.updateValue(value, forKey: id) == nil else {
                throw BrokerClientError.malformedResponse
            }
        }
        return valuesByID
    }
}

/// Whether an agent CLI is mid-turn. The broker owns this signal (a hidden
/// tab's turn still settles), broadcast on `terminal:observer-activity`.
enum AgentActivity: Equatable, Hashable, Sendable {
    case idle
    case working
    case responded(at: Int64)
}

struct BrokerTerminalRecord: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let projectID: String
    let pid: Int32?
    let exited: Bool
    let streamEpoch: String?
    let endOffset: Int64
    /// Exact durable bytes reported by the broker spool. This is informational:
    /// the UI never turns a warning threshold into implicit history deletion.
    let diskBytes: Int64
    /// Broker-authoritative PTY geometry. Companion control captures this on
    /// lease acquisition and restores it on release/expiry/disconnect so a
    /// phone resize never permanently reshapes the desktop session.
    let columns: Int?
    let rows: Int?
    /// Stable controller identity encoded in the broker's capability string.
    /// Retained so a native install can safely recover its registry after a
    /// profile switch without treating unrelated observed terminals as owned.
    let currentOwnerID: String?
    let lastOwnerID: String?
    /// Per-socket broker identity. Unlike the stable installation owner, this
    /// distinguishes which AppModel/controller connection currently owns the
    /// PTY when several Kaisola windows observe the same broker.
    let currentOwnerInstanceID: String?
    let lastOwnerInstanceID: String?
    /// Native-only generation identity. This is attached after a validated
    /// broker inventory and never accepted from the wire payload itself.
    let brokerGenerationID: String?
    let brokerPersistenceIdentity: String?
    /// The shell's live working directory as tracked by the broker (refreshed
    /// on its snapshot cadence). Resurrection reopens here after a reboot.
    var cwd: String?
    var agentActivity: AgentActivity

    var title: String {
        let tail = id.split(separator: ":").last.map(String.init) ?? id
        return tail.isEmpty ? "Terminal" : tail
    }

    init?(value: JSONValue, liveValue: JSONValue? = nil) {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              !id.isEmpty,
              id.count <= 240 else { return nil }
        let owner = object["owner"]?.stringValue
        let lastOwner = object["lastOwner"]?.stringValue
        guard let projectID = Self.projectID(from: owner) ?? Self.projectID(from: lastOwner) else {
            return nil
        }
        self.id = id
        self.projectID = projectID
        let live = liveValue?.objectValue
        self.pid = live?["pid"]?.intValue.flatMap(Int32.init(exactly:))
            ?? object["pid"]?.intValue.flatMap(Int32.init(exactly:))
        self.exited = object["exited"]?.boolValue ?? false
        self.streamEpoch = object["streamEpoch"]?.stringValue
        self.endOffset = object["endOffset"]?.intValue ?? 0
        self.diskBytes = max(0, object["diskBytes"]?.intValue ?? 0)
        self.columns = (live?["cols"] ?? object["cols"])?
            .intValue.flatMap(Int.init(exactly:))
        self.rows = (live?["rows"] ?? object["rows"])?
            .intValue.flatMap(Int.init(exactly:))
        self.currentOwnerID = Self.stableOwnerID(from: owner)
        self.lastOwnerID = Self.stableOwnerID(from: lastOwner)
        self.currentOwnerInstanceID = Self.instanceID(from: owner)
        self.lastOwnerInstanceID = Self.instanceID(from: lastOwner)
        self.brokerGenerationID = nil
        self.brokerPersistenceIdentity = nil
        self.cwd = (live?["cwd"] ?? object["cwd"])?.stringValue
        let busy = (live?["agentBusy"] ?? object["agentBusy"])?.boolValue ?? false
        if busy {
            self.agentActivity = .working
        } else if let completed = (live?["agentCompletedAt"] ?? object["agentCompletedAt"])?.intValue {
            self.agentActivity = .responded(at: completed)
        } else {
            self.agentActivity = .idle
        }
    }

    init(
        id: String,
        projectID: String,
        pid: Int32?,
        exited: Bool,
        streamEpoch: String?,
        endOffset: Int64,
        diskBytes: Int64 = 0,
        columns: Int? = nil,
        rows: Int? = nil,
        currentOwnerID: String? = nil,
        lastOwnerID: String? = nil,
        currentOwnerInstanceID: String? = nil,
        lastOwnerInstanceID: String? = nil,
        brokerGenerationID: String? = nil,
        brokerPersistenceIdentity: String? = nil,
        agentActivity: AgentActivity = .idle
    ) {
        self.id = id
        self.projectID = projectID
        self.pid = pid
        self.exited = exited
        self.streamEpoch = streamEpoch
        self.endOffset = endOffset
        self.diskBytes = max(0, diskBytes)
        self.columns = columns
        self.rows = rows
        self.currentOwnerID = currentOwnerID
        self.lastOwnerID = lastOwnerID
        self.currentOwnerInstanceID = currentOwnerInstanceID
        self.lastOwnerInstanceID = lastOwnerInstanceID
        self.brokerGenerationID = brokerGenerationID
        self.brokerPersistenceIdentity = brokerPersistenceIdentity
        self.agentActivity = agentActivity
    }

    func wasOwned(by stableOwnerID: String) -> Bool {
        currentOwnerID == stableOwnerID || lastOwnerID == stableOwnerID
    }

    private static func projectID(from owner: String?) -> String? {
        guard let owner, !owner.isEmpty else { return nil }
        let pieces = owner.split(separator: "|", omittingEmptySubsequences: false)
        let candidate: String
        if pieces.count >= 3 {
            candidate = pieces.dropFirst(2).joined(separator: "|")
        } else if pieces.count == 2 {
            candidate = "legacy"
        } else {
            return nil
        }
        guard candidate.range(of: #"^[a-zA-Z0-9_.:-]{1,160}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return candidate
    }

    private static func stableOwnerID(from owner: String?) -> String? {
        guard let owner, !owner.isEmpty else { return nil }
        let pieces = owner.split(separator: "|", omittingEmptySubsequences: false)
        guard pieces.count >= 3 else { return nil }
        let candidate = String(pieces[1])
        guard candidate.range(of: #"^[a-zA-Z0-9_.:-]{1,160}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return candidate
    }

    private static func instanceID(from owner: String?) -> String? {
        guard let owner, !owner.isEmpty else { return nil }
        let pieces = owner.split(separator: "|", omittingEmptySubsequences: false)
        guard pieces.count >= 3 else { return nil }
        let candidate = String(pieces[0])
        guard !candidate.isEmpty, candidate.count <= 160 else { return nil }
        return candidate
    }
}

struct TerminalCursor: Equatable, Sendable {
    let streamEpoch: String
    let offset: Int64
}

enum TerminalSubscriptionResult: Equatable, Sendable {
    case snapshot(TerminalSnapshot, resetReason: String?)
    case current(TerminalCursor)
}

struct TerminalSnapshot: Equatable, Sendable {
    let streamEpoch: String
    let output: String
    let startOffset: Int64
    let endOffset: Int64
    let truncated: Bool
    let exited: Bool
    /// The broker's code for a spool segment it could not read, when the
    /// snapshot it answered with is therefore not the whole retained tail.
    /// `nil` means the output is authoritative — including when it is empty,
    /// which a terminal that has produced nothing legitimately is.
    let readError: String?

    init(
        streamEpoch: String,
        output: String,
        startOffset: Int64,
        endOffset: Int64,
        truncated: Bool,
        exited: Bool,
        readError: String? = nil
    ) {
        self.streamEpoch = streamEpoch
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.truncated = truncated
        self.exited = exited
        self.readError = readError
    }

    init(value: JSONValue) throws {
        guard let object = value.objectValue,
              let streamEpoch = object["streamEpoch"]?.stringValue,
              let output = object["output"]?.stringValue,
              let startOffset = object["startOffset"]?.intValue,
              let endOffset = object["endOffset"]?.intValue,
              startOffset >= 0,
              endOffset >= startOffset,
              Int64(output.utf8.count) == endOffset - startOffset else {
            throw BrokerClientError.malformedResponse
        }
        self.streamEpoch = streamEpoch
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.truncated = object["truncated"]?.boolValue ?? false
        self.exited = object["exited"]?.boolValue ?? false
        // Older brokers never send the field; their snapshots stay
        // authoritative, exactly as they are today.
        self.readError = object["readError"]?.stringValue
    }
}

/// One bounded, immutable page from the detached broker's terminal spool.
/// Unlike a subscription snapshot, a history page is never replayed into the
/// live terminal emulator: it belongs to the read-only transcript surface.
struct TerminalHistoryPage: Equatable, Sendable, Identifiable {
    let streamEpoch: String
    let output: String
    let startOffset: Int64
    let endOffset: Int64
    let hasMore: Bool
    let truncated: Bool
    /// Same contract as `TerminalSnapshot.readError`: set when the page is
    /// short because a retained segment refused to be read.
    let readError: String?

    var id: Int64 { startOffset }

    init(
        streamEpoch: String,
        output: String,
        startOffset: Int64,
        endOffset: Int64,
        hasMore: Bool,
        truncated: Bool,
        readError: String? = nil
    ) {
        self.streamEpoch = streamEpoch
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.hasMore = hasMore
        self.truncated = truncated
        self.readError = readError
    }

    init(value: JSONValue, expectedEpoch: String, beforeOffset: Int64) throws {
        guard let object = value.objectValue,
              object["ok"]?.boolValue == true,
              let streamEpoch = object["streamEpoch"]?.stringValue,
              streamEpoch == expectedEpoch,
              let output = object["output"]?.stringValue,
              let startOffset = object["startOffset"]?.intValue,
              let endOffset = object["endOffset"]?.intValue,
              startOffset >= 0,
              endOffset >= startOffset,
              endOffset == beforeOffset,
              Int64(output.utf8.count) == endOffset - startOffset else {
            throw BrokerClientError.malformedResponse
        }
        self.streamEpoch = streamEpoch
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.hasMore = object["hasMore"]?.boolValue ?? false
        self.truncated = object["truncated"]?.boolValue ?? false
        self.readError = object["readError"]?.stringValue
    }
}

struct BrokerEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case output(epoch: String, startOffset: Int64, endOffset: Int64, data: String)
        case snapshotRequired
        case exit
        case activity(busy: Bool, completedAt: Int64?)
    }

    let ownerID: String
    let projectID: String
    let terminalID: String
    let kind: Kind

    init(ownerID: String, projectID: String, terminalID: String, kind: Kind) {
        self.ownerID = ownerID
        self.projectID = projectID
        self.terminalID = terminalID
        self.kind = kind
    }

    init?(frame: JSONValue) {
        guard let object = frame.objectValue,
              object["type"]?.stringValue == "event",
              let ownerID = object["ownerId"]?.stringValue,
              let projectID = object["projectId"]?.stringValue,
              let channel = object["channel"]?.stringValue,
              let payload = object["payload"]?.objectValue,
              let terminalID = payload["id"]?.stringValue else { return nil }

        let kind: Kind
        switch channel {
        case "terminal:observer-output":
            guard let epoch = payload["streamEpoch"]?.stringValue,
                  let start = payload["startOffset"]?.intValue,
                  let end = payload["endOffset"]?.intValue,
                  let data = payload["data"]?.stringValue,
                  Self.hasValidOutputRange(
                      startOffset: start,
                      endOffset: end,
                      data: data
                  ) else { return nil }
            kind = .output(epoch: epoch, startOffset: start, endOffset: end, data: data)
        case "terminal:observer-snapshot-required": kind = .snapshotRequired
        case "terminal:observer-exit": kind = .exit
        case "terminal:observer-activity":
            kind = .activity(
                busy: payload["busy"]?.boolValue ?? false,
                completedAt: payload["completedAt"]?.intValue
            )
        default: return nil
        }

        self.ownerID = ownerID
        self.projectID = projectID
        self.terminalID = terminalID
        self.kind = kind
    }

    private static func hasValidOutputRange(
        startOffset: Int64,
        endOffset: Int64,
        data: String
    ) -> Bool {
        guard startOffset >= 0,
              endOffset >= startOffset,
              let byteCount = Int64(exactly: data.utf8.count) else { return false }
        let (rangeByteCount, overflow) = endOffset.subtractingReportingOverflow(startOffset)
        return !overflow && rangeByteCount == byteCount
    }
}

enum BrokerClientError: Error, Equatable, LocalizedError {
    case notConnected
    case connectionClosed
    case frameRejected
    case malformedResponse
    case authenticationRejected
    case protocolMismatch
    case securityEpochMismatch
    case implementationMismatch
    case identityChanged
    case observeFeatureMissing
    case connectionTimedOut
    case requestTimedOut
    case terminalCapacityExceeded(maximum: Int)
    case requestFailed(String)
    case socketFailure(Int32)
    case socketPathTooLong

    var errorDescription: String? {
        switch self {
        case .notConnected: "The terminal observer is not connected."
        case .connectionClosed: "The terminal connection closed; running sessions were left untouched."
        case .frameRejected: "The session service sent an invalid or oversized message."
        case .malformedResponse: "The session service returned invalid read-only data."
        case .authenticationRejected: "Kaisola could not verify the private terminal connection."
        case .protocolMismatch: "The running session service is incompatible and was left untouched."
        case .securityEpochMismatch: "The running session service lacks project-scoped isolation."
        case .implementationMismatch: "The running session service is outside this Kaisola version's compatibility window."
        case .identityChanged: "The session service changed during the connection check."
        case .observeFeatureMissing: "The running session service cannot provide terminal observation."
        case .connectionTimedOut: "The private terminal connection did not become ready in time."
        case .requestTimedOut: "The session service did not answer a read-only request in time."
        case let .terminalCapacityExceeded(maximum):
            "The session service is already running its limit of \(maximum) terminals. Close one and try again."
        case .requestFailed: "The session service rejected a read-only request."
        case let .socketFailure(code): "The private terminal connection failed (\(code)); running sessions were not changed."
        case .socketPathTooLong: "The private terminal connection path is too long for macOS."
        }
    }
}

enum BrokerInventoryError: Error, Equatable, LocalizedError {
    case invalidDiagnosticRow(index: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidDiagnosticRow(index):
            "The session service returned an invalid terminal inventory row at index \(index); running sessions were left untouched."
        }
    }
}
