import Foundation

public enum CompanionConnectionState: String, Codable, Hashable, Sendable {
    case preview
    case live
    case reconnecting
    case stale
    case offline

    public var title: String {
        switch self {
        case .preview: "Preview mode"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .stale: "Cached"
        case .offline: "Offline"
        }
    }
}

public enum CompanionSessionKind: String, Codable, Hashable, Sendable {
    case agent
    case terminal
    case panel
}

public enum CompanionSessionStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case idle
    case running
    case waiting
    case done
    case failed

    public var title: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .waiting: "Needs You"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

public struct CompanionProjectCounts: Codable, Hashable, Sendable {
    public var running: Int
    public var waiting: Int
    public var done: Int
    public var failed: Int

    public init(running: Int, waiting: Int, done: Int, failed: Int) {
        self.running = running
        self.waiting = waiting
        self.done = done
        self.failed = failed
    }

    public static let zero = CompanionProjectCounts(running: 0, waiting: 0, done: 0, failed: 0)
}

public struct CompanionProject: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var repo: String?
    public var branch: String?
    public var connection: String
    public var lastContactAt: Int64
    public var counts: CompanionProjectCounts?
    public var windowId: String? = nil
    public var windowName: String? = nil

    public init(
        id: String,
        name: String,
        repo: String? = nil,
        branch: String? = nil,
        connection: String,
        lastContactAt: Int64,
        counts: CompanionProjectCounts? = nil,
        windowId: String? = nil,
        windowName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.repo = repo
        self.branch = branch
        self.connection = connection
        self.lastContactAt = lastContactAt
        self.counts = counts
        self.windowId = windowId
        self.windowName = windowName
    }
}

public struct CompanionTurn: Identifiable, Codable, Hashable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable {
        case user
        case assistant
        case thought
        case tool
    }

    public var role: Role
    public var text: String
    public var status: String?
    public var at: Int64?
    public var wireId: String? = nil

    public var id: String { wireId ?? "\(role.rawValue):\(at ?? 0):\(text)" }

    public init(
        role: Role,
        text: String,
        status: String? = nil,
        at: Int64? = nil,
        wireId: String? = nil
    ) {
        self.role = role
        self.text = text
        self.status = status
        self.at = at
        self.wireId = wireId
    }

    enum CodingKeys: String, CodingKey {
        case role = "kind"
        case text
        case status
        case at
        case wireId = "id"
    }
}

public struct CompanionSession: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var projectId: String
    public var kind: CompanionSessionKind
    public var title: String
    public var status: CompanionSessionStatus
    public var boardLane: String?
    public var needsYou: Bool
    public var unread: Bool
    public var updatedAt: Int64
    /// The most recent completed CLI turn. `updatedAt` may advance sooner as
    /// live terminal bytes arrive, so the two clocks must remain distinct.
    public var completedAt: Int64? = nil
    public var provider: String?
    public var model: String?
    public var mode: String?
    public var branch: String?
    public var summary: String?
    public var startedAt: Int64?
    public var turns: [CompanionTurn]?
    public var terminalLines: [String]?
    /// Raw bounded ANSI stream used by SwiftTerm. `terminalLines` remains for
    /// lightweight previews and backward-compatible fixtures.
    public var terminalOutput: String? = nil
    public var terminalStreamEpoch: String? = nil
    public var terminalEndOffset: Int64? = nil
    public var windowId: String? = nil

    public init(
        id: String,
        projectId: String,
        kind: CompanionSessionKind,
        title: String,
        status: CompanionSessionStatus,
        boardLane: String? = nil,
        needsYou: Bool = false,
        unread: Bool = false,
        updatedAt: Int64,
        completedAt: Int64? = nil,
        provider: String? = nil,
        model: String? = nil,
        mode: String? = nil,
        branch: String? = nil,
        summary: String? = nil,
        startedAt: Int64? = nil,
        turns: [CompanionTurn]? = nil,
        terminalLines: [String]? = nil,
        terminalOutput: String? = nil,
        terminalStreamEpoch: String? = nil,
        terminalEndOffset: Int64? = nil,
        windowId: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.kind = kind
        self.title = title
        self.status = status
        self.boardLane = boardLane
        self.needsYou = needsYou
        self.unread = unread
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.provider = provider
        self.model = model
        self.mode = mode
        self.branch = branch
        self.summary = summary
        self.startedAt = startedAt
        self.turns = turns
        self.terminalLines = terminalLines
        self.terminalOutput = terminalOutput
        self.terminalStreamEpoch = terminalStreamEpoch
        self.terminalEndOffset = terminalEndOffset
        self.windowId = windowId
    }
}

public struct CompanionAttention: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var projectId: String
    public var sessionId: String?
    public var kind: String
    public var title: String
    public var detail: String?
    public var createdAt: Int64
    public var severity: String

    public init(
        id: String,
        projectId: String,
        sessionId: String? = nil,
        kind: String,
        title: String,
        detail: String? = nil,
        createdAt: Int64,
        severity: String
    ) {
        self.id = id
        self.projectId = projectId
        self.sessionId = sessionId
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.severity = severity
    }
}

public struct CompanionPermissionOption: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct CompanionPermissionDiff: Codable, Hashable, Sendable {
    public var relativePath: String
    public var oldText: String
    public var newText: String

    public init(relativePath: String, oldText: String, newText: String) {
        self.relativePath = relativePath
        self.oldText = oldText
        self.newText = newText
    }
}

public struct CompanionPermission: Identifiable, Codable, Hashable, Sendable {
    public var id: String { permId }

    public let permId: String
    public var projectId: String
    public var sessionId: String?
    public var agent: String
    public var title: String
    public var kind: String?
    public var requestedAt: Int64
    public var options: [CompanionPermissionOption]
    public var diffs: [CompanionPermissionDiff]
    public var revision: Int64? = nil
    public var completeness: String? = nil

    public init(
        permId: String,
        projectId: String,
        sessionId: String? = nil,
        agent: String,
        title: String,
        kind: String? = nil,
        requestedAt: Int64,
        options: [CompanionPermissionOption],
        diffs: [CompanionPermissionDiff],
        revision: Int64? = nil,
        completeness: String? = nil
    ) {
        self.permId = permId
        self.projectId = projectId
        self.sessionId = sessionId
        self.agent = agent
        self.title = title
        self.kind = kind
        self.requestedAt = requestedAt
        self.options = options
        self.diffs = diffs
        self.revision = revision
        self.completeness = completeness
    }
}

public struct CompanionBoardCard: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var type: String
    public var projectId: String
    public var title: String
    public var status: CompanionSessionStatus
    public var needsYou: Bool
    public var updatedAt: Int64
    public var provider: String?
    public var summary: String?

    public init(
        id: String,
        type: String,
        projectId: String,
        title: String,
        status: CompanionSessionStatus,
        needsYou: Bool,
        updatedAt: Int64,
        provider: String? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.type = type
        self.projectId = projectId
        self.title = title
        self.status = status
        self.needsYou = needsYou
        self.updatedAt = updatedAt
        self.provider = provider
        self.summary = summary
    }
}

public struct CompanionBoardColumn: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var sourceLabel: String?
    public var count: Int
    public var cards: [CompanionBoardCard]

    public init(id: String, title: String, sourceLabel: String? = nil, count: Int, cards: [CompanionBoardCard]) {
        self.id = id
        self.title = title
        self.sourceLabel = sourceLabel
        self.count = count
        self.cards = cards
    }
}

public struct CompanionBoard: Codable, Hashable, Sendable {
    public var columns: [CompanionBoardColumn]

    public init(columns: [CompanionBoardColumn]) {
        self.columns = columns
    }
}

public struct CompanionProjection: Codable, Hashable, Sendable {
    public var projectionKind: String
    public var revision: Int
    public var generatedAt: Int64
    public var freshness: String
    public var projects: [CompanionProject]
    public var sessions: [CompanionSession]
    public var attention: [CompanionAttention]
    public var permissions: [CompanionPermission]
    public var board: CompanionBoard

    public init(
        projectionKind: String,
        revision: Int,
        generatedAt: Int64,
        freshness: String,
        projects: [CompanionProject],
        sessions: [CompanionSession],
        attention: [CompanionAttention],
        permissions: [CompanionPermission],
        board: CompanionBoard = CompanionBoard(columns: [])
    ) {
        self.projectionKind = projectionKind
        self.revision = revision
        self.generatedAt = generatedAt
        self.freshness = freshness
        self.projects = projects
        self.sessions = sessions
        self.attention = attention
        self.permissions = permissions
        self.board = board
    }
}

public struct CompanionSnapshotBody: Codable, Hashable, Sendable {
    public var type: String
    public var revision: Int
    public var projection: CompanionProjection

    public init(type: String, revision: Int, projection: CompanionProjection) {
        self.type = type
        self.revision = revision
        self.projection = projection
    }
}

public struct CompanionSnapshotEnvelope: Codable, Hashable, Sendable {
    public var v: Int
    public var kind: String
    public var desktopId: String
    public var deviceId: String
    public var connectionId: String
    public var epoch: String
    public var seq: Int
    public var id: String
    public var sentAt: Int64
    public var body: CompanionSnapshotBody

    public init(
        v: Int,
        kind: String,
        desktopId: String,
        deviceId: String,
        connectionId: String,
        epoch: String,
        seq: Int,
        id: String,
        sentAt: Int64,
        body: CompanionSnapshotBody
    ) {
        self.v = v
        self.kind = kind
        self.desktopId = desktopId
        self.deviceId = deviceId
        self.connectionId = connectionId
        self.epoch = epoch
        self.seq = seq
        self.id = id
        self.sentAt = sentAt
        self.body = body
    }
}
