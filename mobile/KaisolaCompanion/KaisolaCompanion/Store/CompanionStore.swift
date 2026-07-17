import Foundation

@MainActor
final class CompanionStore: ObservableObject {
    @Published var connection: CompanionConnectionState
    @Published var projects: [CompanionProject]
    @Published var sessions: [CompanionSession]
    @Published var attention: [CompanionAttention]
    @Published var permissions: [CompanionPermission]
    @Published var selectedProjectId: String?
    @Published var previewReceipt: String?

    let isPreview: Bool
    let canControlAgents: Bool
    let canControlTerminals: Bool

    init(
        connection: CompanionConnectionState,
        projects: [CompanionProject],
        sessions: [CompanionSession],
        attention: [CompanionAttention],
        permissions: [CompanionPermission],
        selectedProjectId: String? = nil,
        isPreview: Bool,
        canControlAgents: Bool = false,
        canControlTerminals: Bool = false
    ) {
        self.connection = connection
        self.projects = projects
        self.sessions = sessions
        self.attention = attention
        self.permissions = permissions
        self.selectedProjectId = selectedProjectId ?? projects.first?.id
        self.isPreview = isPreview
        self.canControlAgents = canControlAgents
        self.canControlTerminals = canControlTerminals
    }

    static func preview(now: Date = .now) -> CompanionStore {
        CompanionPreviewData.store(now: now)
    }

    var needsYouCount: Int {
        let representedSessionIds = Set(permissions.compactMap(\.sessionId) + attention.compactMap(\.sessionId))
        let unrepresentedWaitingSessions = sessions.filter {
            $0.needsYou && $0.status == .waiting && !representedSessionIds.contains($0.id)
        }.count
        return permissions.count + attention.count + unrepresentedWaitingSessions
    }

    var visibleSessions: [CompanionSession] {
        guard let selectedProjectId else { return sessions }
        return sessions.filter { $0.projectId == selectedProjectId }
    }

    func project(for id: String) -> CompanionProject? {
        projects.first { $0.id == id }
    }

    func session(for id: String) -> CompanionSession? {
        sessions.first { $0.id == id }
    }

    func counts(for projectId: String) -> CompanionProjectCounts {
        let projectSessions = sessions.filter { $0.projectId == projectId }
        return CompanionProjectCounts(
            running: projectSessions.filter { $0.status == .running }.count,
            waiting: projectSessions.filter { $0.status == .waiting }.count,
            done: projectSessions.filter { $0.status == .done }.count,
            failed: projectSessions.filter { $0.status == .failed }.count
        )
    }

    func resolvePermission(_ permissionId: String, decision: String) {
        guard isPreview, let permission = permissions.first(where: { $0.id == permissionId }) else { return }
        permissions.removeAll { $0.id == permissionId }
        if let sessionId = permission.sessionId,
           let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].needsYou = false
            sessions[index].unread = false
            sessions[index].status = decision == "Allow once" ? .running : .done
            sessions[index].summary = decision == "Allow once"
                ? "Preview decision applied; agent resumed locally"
                : "Preview decision rejected locally"
        }
        previewReceipt = "Preview only: \(decision.lowercased())"
    }

    func acknowledge(_ attentionId: String) {
        guard isPreview else { return }
        attention.removeAll { $0.id == attentionId }
        previewReceipt = "Preview only: item acknowledged"
    }

    func sendPreviewPrompt(to sessionId: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPreview, !clean.isEmpty, let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        var turns = sessions[index].turns ?? []
        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        turns.append(CompanionTurn(role: .user, text: clean, at: nowMs))
        turns.append(CompanionTurn(
            role: .assistant,
            text: "Preview received. Live delivery will become available after the Mac is securely paired.",
            status: "preview",
            at: nowMs + 1
        ))
        sessions[index].turns = turns
        sessions[index].summary = clean
        previewReceipt = "Preview only: prompt added locally"
    }
}
