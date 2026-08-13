import Foundation

/// An unfinished choice shown only in the current window. It deliberately has
/// no durable payload and never enters the workspace or broker state.
struct NewSessionDraft: Identifiable, Equatable, Sendable {
    let id: String
    let projectID: String
}

/// Window-local ownership for unfinished New Session tabs. Projects keep one
/// draft apiece so repeated presses focus the existing choice instead of
/// accumulating empty tabs.
struct NewSessionDraftState: Equatable, Sendable {
    private(set) var draftsByProject: [String: NewSessionDraft] = [:]
    private(set) var selectedDraftID: String?

    var selectedDraft: NewSessionDraft? {
        guard let selectedDraftID else { return nil }
        return draftsByProject.values.first { $0.id == selectedDraftID }
    }

    func draft(for projectID: String) -> NewSessionDraft? {
        draftsByProject[projectID]
    }

    @discardableResult
    mutating func begin(projectID: String) -> NewSessionDraft {
        if let existing = draftsByProject[projectID] {
            selectedDraftID = existing.id
            return existing
        }

        let draft = NewSessionDraft(
            id: "new-session-\(UUID().uuidString.lowercased())",
            projectID: projectID
        )
        draftsByProject[projectID] = draft
        selectedDraftID = draft.id
        return draft
    }

    mutating func selectDraft(_ id: String) {
        guard draftsByProject.values.contains(where: { $0.id == id }) else { return }
        selectedDraftID = id
    }

    mutating func selectRealSurface() {
        selectedDraftID = nil
    }

    mutating func cancel(projectID: String) {
        remove(projectID: projectID)
    }

    mutating func complete(projectID: String) {
        remove(projectID: projectID)
    }

    mutating func retainProjects(_ projectIDs: Set<String>) {
        draftsByProject = draftsByProject.filter { projectIDs.contains($0.key) }
        if selectedDraft == nil {
            selectedDraftID = nil
        }
    }

    private mutating func remove(projectID: String) {
        guard let removed = draftsByProject.removeValue(forKey: projectID) else { return }
        if selectedDraftID == removed.id {
            selectedDraftID = nil
        }
    }
}

enum NewSessionChoice: Equatable, Sendable {
    case terminal
    case agentTerminal(String)
    case chat(String)
    case mesh
}

struct NewSessionAgentOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
}

struct NewSessionChoiceCatalog: Equatable, Sendable {
    let terminalAgents: [NewSessionAgentOption]
    let chatAgents: [NewSessionAgentOption]

    static func make(
        agents: [NewSessionAgentOption],
        supportsChat: (String) -> Bool
    ) -> NewSessionChoiceCatalog {
        NewSessionChoiceCatalog(
            terminalAgents: agents,
            chatAgents: agents.filter { supportsChat($0.id) }
        )
    }

    static var live: NewSessionChoiceCatalog {
        make(
            agents: AgentRegistry.all.map {
                NewSessionAgentOption(id: $0.id, name: $0.name, symbol: $0.symbol)
            },
            supportsChat: { AcpAdapter.forAgent($0) != nil }
        )
    }
}
