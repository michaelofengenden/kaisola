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
    private struct LaunchFailure: Equatable, Sendable {
        let draftID: String
        let message: String?
    }

    private(set) var draftsByProject: [String: NewSessionDraft] = [:]
    private(set) var selectedDraftID: String?
    private var launchingDraftIDsByProject: [String: String] = [:]
    private var launchFailuresByProject: [String: LaunchFailure] = [:]

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

    func isLaunching(projectID: String) -> Bool {
        guard let draft = draftsByProject[projectID] else { return false }
        return launchingDraftIDsByProject[projectID] == draft.id
    }

    func didLastLaunchFail(projectID: String) -> Bool {
        guard let draft = draftsByProject[projectID] else { return false }
        return launchFailuresByProject[projectID]?.draftID == draft.id
    }

    func lastLaunchFailureMessage(projectID: String) -> String? {
        guard let draft = draftsByProject[projectID],
              let failure = launchFailuresByProject[projectID],
              failure.draftID == draft.id else { return nil }
        return failure.message
    }

    /// A click starts work but does not consume the draft. The chooser remains
    /// the retry surface until the broker confirms a real terminal exists.
    @discardableResult
    mutating func beginLaunch(projectID: String) -> String? {
        guard let draft = draftsByProject[projectID],
              launchingDraftIDsByProject[projectID] == nil else { return nil }
        launchingDraftIDsByProject[projectID] = draft.id
        launchFailuresByProject.removeValue(forKey: projectID)
        selectedDraftID = draft.id
        return draft.id
    }

    @discardableResult
    mutating func finishLaunch(
        projectID: String,
        launchID: String,
        succeeded: Bool,
        failureMessage: String? = nil
    ) -> Bool {
        guard draftsByProject[projectID]?.id == launchID,
              launchingDraftIDsByProject[projectID] == launchID else { return false }
        launchingDraftIDsByProject.removeValue(forKey: projectID)
        if succeeded {
            remove(projectID: projectID)
        } else {
            let normalizedMessage = failureMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            launchFailuresByProject[projectID] = LaunchFailure(
                draftID: launchID,
                message: normalizedMessage.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return true
    }

    /// Dismissing a location/account picker is not a failed launch. Return the
    /// draft to its idle chooser state so the same option can be tried again.
    mutating func cancelLaunch(projectID: String, launchID: String) {
        guard draftsByProject[projectID]?.id == launchID,
              launchingDraftIDsByProject[projectID] == launchID else { return }
        launchingDraftIDsByProject.removeValue(forKey: projectID)
        launchFailuresByProject.removeValue(forKey: projectID)
    }

    mutating func cancel(projectID: String) {
        guard !isLaunching(projectID: projectID) else { return }
        remove(projectID: projectID)
    }

    mutating func complete(projectID: String) {
        remove(projectID: projectID)
    }

    mutating func retainProjects(_ projectIDs: Set<String>) {
        draftsByProject = draftsByProject.filter { projectIDs.contains($0.key) }
        launchingDraftIDsByProject = launchingDraftIDsByProject.filter {
            projectIDs.contains($0.key)
        }
        launchFailuresByProject = launchFailuresByProject.filter {
            projectIDs.contains($0.key)
        }
        if selectedDraft == nil {
            selectedDraftID = nil
        }
    }

    private mutating func remove(projectID: String) {
        launchingDraftIDsByProject.removeValue(forKey: projectID)
        launchFailuresByProject.removeValue(forKey: projectID)
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
