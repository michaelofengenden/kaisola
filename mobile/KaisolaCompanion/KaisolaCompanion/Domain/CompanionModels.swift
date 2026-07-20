import Foundation

enum CompanionConnectionState: String, Codable, Hashable, Sendable {
    case preview
    case live
    case reconnecting
    case stale
    case offline

    var title: String {
        switch self {
        case .preview: "Preview mode"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .stale: "Cached"
        case .offline: "Offline"
        }
    }
}

enum CompanionSessionKind: String, Codable, Hashable, Sendable {
    case agent
    case terminal
    case panel
}

enum CompanionSessionStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case idle
    case running
    case waiting
    case done
    case failed

    var title: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .waiting: "Needs You"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

struct CompanionProjectCounts: Codable, Hashable, Sendable {
    var running: Int
    var waiting: Int
    var done: Int
    var failed: Int

    static let zero = CompanionProjectCounts(running: 0, waiting: 0, done: 0, failed: 0)
}

struct CompanionProject: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var repo: String?
    var branch: String?
    var connection: String
    var lastContactAt: Int64
    var counts: CompanionProjectCounts?
    var windowId: String? = nil
    var windowName: String? = nil
}

struct CompanionTurn: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Hashable, Sendable {
        case user
        case assistant
        case thought
        case tool
    }

    var role: Role
    var text: String
    var status: String?
    var at: Int64?
    var wireId: String? = nil

    var id: String { wireId ?? "\(role.rawValue):\(at ?? 0):\(text)" }

    enum CodingKeys: String, CodingKey {
        case role = "kind"
        case text
        case status
        case at
        case wireId = "id"
    }
}

struct CompanionSession: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var projectId: String
    var kind: CompanionSessionKind
    var title: String
    var status: CompanionSessionStatus
    var boardLane: String?
    var needsYou: Bool
    var unread: Bool
    var updatedAt: Int64
    var provider: String?
    var model: String?
    var mode: String?
    var branch: String?
    var summary: String?
    var startedAt: Int64?
    var turns: [CompanionTurn]?
    var terminalLines: [String]?
    /// Raw bounded ANSI stream used by SwiftTerm. `terminalLines` remains for
    /// lightweight previews and backward-compatible fixtures.
    var terminalOutput: String? = nil
    var terminalStreamEpoch: String? = nil
    var terminalEndOffset: Int64? = nil
    var windowId: String? = nil
}

struct CompanionAttention: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var projectId: String
    var sessionId: String?
    var kind: String
    var title: String
    var detail: String?
    var createdAt: Int64
    var severity: String
}

struct CompanionPermissionOption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var label: String
}

struct CompanionPermissionDiff: Codable, Hashable, Sendable {
    var relativePath: String
    var oldText: String
    var newText: String
}

struct CompanionPermission: Identifiable, Codable, Hashable, Sendable {
    var id: String { permId }

    let permId: String
    var projectId: String
    var sessionId: String?
    var agent: String
    var title: String
    var kind: String?
    var requestedAt: Int64
    var options: [CompanionPermissionOption]
    var diffs: [CompanionPermissionDiff]
    var revision: Int64? = nil
    var completeness: String? = nil
}

struct CompanionBoardCard: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var type: String
    var projectId: String
    var title: String
    var status: CompanionSessionStatus
    var needsYou: Bool
    var updatedAt: Int64
    var provider: String?
    var summary: String?
}

struct CompanionBoardColumn: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var sourceLabel: String?
    var count: Int
    var cards: [CompanionBoardCard]
}

struct CompanionBoard: Codable, Hashable, Sendable {
    var columns: [CompanionBoardColumn]
}

struct CompanionProjection: Codable, Hashable, Sendable {
    var projectionKind: String
    var revision: Int
    var generatedAt: Int64
    var freshness: String
    var projects: [CompanionProject]
    var sessions: [CompanionSession]
    var attention: [CompanionAttention]
    var permissions: [CompanionPermission]
    var board: CompanionBoard
}

struct CompanionSnapshotBody: Codable, Hashable, Sendable {
    var type: String
    var revision: Int
    var projection: CompanionProjection
}

struct CompanionSnapshotEnvelope: Codable, Hashable, Sendable {
    var v: Int
    var kind: String
    var desktopId: String
    var deviceId: String
    var connectionId: String
    var epoch: String
    var seq: Int
    var id: String
    var sentAt: Int64
    var body: CompanionSnapshotBody
}
