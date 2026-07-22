import Foundation
import KaisolaBrokerProtocol
import KaisolaCore

struct BrokerHello: Equatable, Sendable {
    let protocolVersion: Int
    let securityEpoch: Int
    let features: Set<String>
    let pid: Int32
    let startedAt: Int64
    let version: String
    let serverEnforcedObserver: Bool
}

struct BrokerStatus: Equatable, Sendable {
    let terminals: [BrokerTerminalRecord]

    init(status: JSONValue, diagnostics: JSONValue, live: JSONValue) throws {
        guard let statusObject = status.objectValue,
              statusObject["ok"]?.boolValue == true,
              statusObject["protocol"]?.intValue == Int64(BrokerWire.protocolVersion),
              statusObject["securityEpoch"]?.intValue == Int64(BrokerWire.securityEpoch) else {
            throw BrokerClientError.malformedResponse
        }
        guard let diagnosticValues = diagnostics.arrayValue,
              let liveValues = live.arrayValue else {
            throw BrokerClientError.malformedResponse
        }
        let liveByID = Dictionary(
            uniqueKeysWithValues: liveValues.compactMap { value -> (String, JSONValue)? in
                guard let object = value.objectValue, let id = object["id"]?.stringValue else { return nil }
                return (id, value)
            }
        )
        terminals = diagnosticValues.compactMap { value in
            BrokerTerminalRecord(value: value, liveValue: value.objectValue?["id"]?.stringValue.flatMap { liveByID[$0] })
        }
    }
}

struct BrokerTerminalRecord: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let projectID: String
    let pid: Int32?
    let exited: Bool
    let streamEpoch: String?
    let endOffset: Int64

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
    }

    init(id: String, projectID: String, pid: Int32?, exited: Bool, streamEpoch: String?, endOffset: Int64) {
        self.id = id
        self.projectID = projectID
        self.pid = pid
        self.exited = exited
        self.streamEpoch = streamEpoch
        self.endOffset = endOffset
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
    }
}

struct BrokerEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case output(epoch: String, startOffset: Int64, endOffset: Int64, data: String)
        case snapshotRequired
        case exit
        case activity
    }

    let ownerID: String
    let projectID: String
    let terminalID: String
    let kind: Kind

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
                  let data = payload["data"]?.stringValue else { return nil }
            kind = .output(epoch: epoch, startOffset: start, endOffset: end, data: data)
        case "terminal:observer-snapshot-required": kind = .snapshotRequired
        case "terminal:observer-exit": kind = .exit
        case "terminal:observer-activity": kind = .activity
        default: return nil
        }

        self.ownerID = ownerID
        self.projectID = projectID
        self.terminalID = terminalID
        self.kind = kind
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
    case identityChanged
    case observeFeatureMissing
    case connectionTimedOut
    case requestTimedOut
    case requestFailed(String)
    case socketFailure(Int32)
    case socketPathTooLong

    var errorDescription: String? {
        switch self {
        case .notConnected: "The terminal observer is not connected."
        case .connectionClosed: "The broker connection closed; running sessions remain on the detached broker."
        case .frameRejected: "The broker sent an invalid or oversized frame."
        case .malformedResponse: "The broker returned malformed read-only data."
        case .authenticationRejected: "The broker rejected the private observer handshake."
        case .protocolMismatch: "The running broker protocol is incompatible and was left untouched."
        case .securityEpochMismatch: "The running broker lacks project-scoped isolation."
        case .identityChanged: "The broker identity changed during the handshake."
        case .observeFeatureMissing: "The running broker does not advertise terminal observation."
        case .connectionTimedOut: "The private broker did not complete its observer handshake in time."
        case .requestTimedOut: "The broker did not answer a read-only observer request in time."
        case .requestFailed: "The broker rejected a read-only observer request."
        case let .socketFailure(code): "The private broker socket failed (\(code)); running sessions were not changed."
        case .socketPathTooLong: "The private broker socket path is too long for macOS."
        }
    }
}
