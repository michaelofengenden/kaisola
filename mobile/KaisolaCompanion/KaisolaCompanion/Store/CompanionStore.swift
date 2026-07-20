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
    @Published private(set) var transportState: CompanionTransportState
    @Published private(set) var lastAckCursor: CompanionAckCursor?
    @Published private(set) var capabilities: Set<CompanionCapability>

    private var projectIdsByWindowId: [String: Set<String>]

    let isPreview: Bool
    var canControlAgents: Bool { capabilities.contains(.agentControl) }
    var canControlTerminals: Bool { capabilities.contains(.terminalControl) }

    init(
        connection: CompanionConnectionState,
        projects: [CompanionProject],
        sessions: [CompanionSession],
        attention: [CompanionAttention],
        permissions: [CompanionPermission],
        selectedProjectId: String? = nil,
        isPreview: Bool,
        canControlAgents: Bool = false,
        canControlTerminals: Bool = false,
        transportState: CompanionTransportState = .idle
    ) {
        self.connection = connection
        self.projects = projects
        self.sessions = sessions
        self.attention = attention
        self.permissions = permissions
        // Nil is a real "all projects" scope, not a missing default. Starting
        // there keeps Home totals honest after launch and reconnect.
        self.selectedProjectId = selectedProjectId
        self.isPreview = isPreview
        capabilities = Set<CompanionCapability>([.observe]
            + (canControlAgents ? [.agentControl] : [])
            + (canControlTerminals ? [.terminalControl] : []))
        self.transportState = transportState
        lastAckCursor = nil
        projectIdsByWindowId = [:]
    }

    static func preview(now: Date = .now) -> CompanionStore {
        CompanionPreviewData.store(now: now)
    }

    static func live(client: CompanionClient) -> CompanionStore {
        let store = CompanionStore(
            connection: .offline,
            projects: [],
            sessions: [],
            attention: [],
            permissions: [],
            isPreview: false,
            transportState: client.transport.state
        )
        store.bind(to: client)
        return store
    }

    func bind(to client: CompanionClient) {
        guard !isPreview else { return }
        client.onTransportState = { [weak self] state in
            guard let self else { return }
            transportState = state
            connection = state.storeState
        }
        client.onEnvelope = { [weak self, weak client] envelope in
            guard let self else { return }
            do {
                if try apply(envelope), let cursor = lastAckCursor {
                    try client?.acknowledge(cursor)
                }
            } catch {
                connection = .stale
            }
        }
        client.onCapabilities = { [weak self] capabilities in
            self?.capabilities = capabilities
        }
    }

    @discardableResult
    func apply(_ envelope: CompanionEnvelope) throws -> Bool {
        guard !isPreview else { return false }
        switch envelope.kind {
        case .snapshot:
            let snapshot = try envelope.body.decode(CompanionSnapshotBody.self)
            projects = snapshot.projection.projects
            sessions = snapshot.projection.sessions
            attention = snapshot.projection.attention
            permissions = snapshot.projection.permissions
            projectIdsByWindowId = Dictionary(grouping: projects.compactMap { project in
                project.windowId.map { ($0, project.id) }
            }, by: \.0).mapValues { Set($0.map(\.1)) }
            if let selectedProjectId,
               !projects.contains(where: { $0.id == selectedProjectId }) {
                self.selectedProjectId = nil
            }
            connection = snapshot.projection.freshness == "live" ? .live : .stale
        case .event:
            guard lastAckCursor == nil || envelope.epoch == lastAckCursor?.epoch else {
                connection = .stale
                return false
            }
            if let cursor = lastAckCursor, envelope.seq <= cursor.seq { return false }
            try applyEvent(envelope)
        case .hello:
            let hello = try envelope.body.decode(CompanionHelloBody.self)
            capabilities = Set(hello.capabilities)
            connection = .live
            return false
        case .receipt:
            // Maintenance and control receipts are correlated in the client.
            // They must not become global toasts (especially subscribe cleanup).
            return false
        case .error:
            previewReceipt = envelope.body.fields["message"]?.stringValue
            return false
        case .command, .ack:
            return false
        }

        if lastAckCursor == nil || envelope.kind == .snapshot {
            lastAckCursor = CompanionAckCursor(epoch: envelope.epoch, seq: envelope.seq)
            return true
        }
        return lastAckCursor?.accept(envelope) == true
    }

    private func applyEvent(_ envelope: CompanionEnvelope) throws {
        let fields = envelope.body.fields
        switch envelope.body.type {
        case "project.updated":
            if fields["removed"]?.boolValue == true {
                removeProjects(for: fields)
                return
            }
            guard let projectionValue = fields["projection"] else {
                return
            }
            let projection = try JSONDecoder().decode(
                CompanionProjection.self,
                from: CanonicalJSON.data(from: projectionValue)
            )
            merge(projection: projection, windowId: fields["windowId"]?.stringValue)
        case "session.updated":
            if let sessionValue = fields["session"] {
                let session = try JSONDecoder().decode(
                    CompanionSession.self,
                    from: CanonicalJSON.data(from: sessionValue)
                )
                upsert(session)
            } else if let sessionId = fields["sessionId"]?.stringValue,
                      let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                if let busy = fields["busy"]?.boolValue {
                    sessions[index].status = busy ? .running : .idle
                    if !busy {
                        sessions[index].updatedAt = fields["completedAt"]?.intValue ?? envelope.sentAt
                    }
                }
                sessions[index].terminalStreamEpoch = fields["streamEpoch"]?.stringValue
                sessions[index].terminalEndOffset = fields["offset"]?.intValue
            }
        case "attention.raised":
            var payload = fields
            payload.removeValue(forKey: "type")
            let item = try JSONDecoder().decode(
                CompanionAttention.self,
                from: CanonicalJSON.data(from: .object(payload))
            )
            upsert(item)
        case "attention.cleared":
            if let id = fields["id"]?.stringValue { attention.removeAll { $0.id == id } }
        case "agent.turn.delta":
            try applyAgentDelta(fields, sentAt: envelope.sentAt)
        case "agent.turn.completed":
            let sessionId = fields["sessionId"]?.stringValue ?? fields["targetId"]?.stringValue
            if let sessionId, let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].status = fields["ok"]?.boolValue == false ? .failed : .idle
                sessions[index].updatedAt = envelope.sentAt
            }
        case "agent.permission.requested":
            let body = try envelope.body.decode(CompanionPermissionRequestedBody.self)
            let permission = CompanionPermission(
                permId: body.permId,
                projectId: body.projectId,
                sessionId: body.sessionId ?? body.targetId,
                agent: body.agent,
                title: body.title,
                kind: body.kind,
                requestedAt: body.requestedAt ?? envelope.sentAt,
                options: body.options,
                diffs: body.diffs,
                revision: body.revision,
                completeness: body.completeness
            )
            if let index = permissions.firstIndex(where: { $0.id == permission.id }) { permissions[index] = permission }
            else { permissions.append(permission) }
        case "agent.permission.resolved":
            if let id = fields["permId"]?.stringValue { permissions.removeAll { $0.id == id } }
        case "terminal.output":
            let body = try envelope.body.decode(CompanionTerminalOutputBody.self)
            applyTerminalText(
                sessionId: body.terminalId,
                text: body.data,
                streamEpoch: body.streamEpoch,
                endOffset: body.endOffset,
                replace: false,
                sentAt: envelope.sentAt
            )
        case "terminal.snapshot":
            if let terminalId = fields["terminalId"]?.stringValue,
               let output = fields["output"]?.stringValue {
                applyTerminalText(
                    sessionId: terminalId,
                    text: output,
                    streamEpoch: fields["streamEpoch"]?.stringValue,
                    endOffset: fields["endOffset"]?.intValue,
                    replace: true,
                    sentAt: envelope.sentAt
                )
            } else if fields["snapshotRequired"]?.boolValue == true,
                      let terminalId = fields["terminalId"]?.stringValue,
                      let index = sessions.firstIndex(where: { $0.id == terminalId }) {
                sessions[index].terminalLines = []
                sessions[index].terminalOutput = ""
                sessions[index].terminalStreamEpoch = fields["streamEpoch"]?.stringValue
                sessions[index].terminalEndOffset = fields["endOffset"]?.intValue
            }
        case "terminal.exit":
            if let terminalId = fields["terminalId"]?.stringValue,
               let index = sessions.firstIndex(where: { $0.id == terminalId }) {
                sessions[index].status = .done
                sessions[index].updatedAt = envelope.sentAt
                sessions[index].terminalEndOffset = fields["offset"]?.intValue
            }
        default:
            break
        }
    }

    private func merge(projection: CompanionProjection, windowId: String?) {
        var incomingProjects = projection.projects
        var incomingSessions = projection.sessions
        if let windowId {
            for index in incomingProjects.indices {
                if incomingProjects[index].windowId == nil { incomingProjects[index].windowId = windowId }
            }
            for index in incomingSessions.indices {
                if incomingSessions[index].windowId == nil { incomingSessions[index].windowId = windowId }
            }
        }
        let projectIds = Set(incomingProjects.map(\.id))
        if let windowId {
            let removedProjectIds = (projectIdsByWindowId[windowId] ?? []).subtracting(projectIds)
            removeProjects(withIds: removedProjectIds)
            for owner in Array(projectIdsByWindowId.keys) where owner != windowId {
                projectIdsByWindowId[owner]?.subtract(projectIds)
                if projectIdsByWindowId[owner]?.isEmpty == true { projectIdsByWindowId.removeValue(forKey: owner) }
            }
            projectIdsByWindowId[windowId] = projectIds
        }
        let existingSessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let reconciledSessions = incomingSessions.map { incoming in
            reconcile(incoming: incoming, existing: existingSessions[incoming.id])
        }
        projects.removeAll { projectIds.contains($0.id) }
        projects.append(contentsOf: incomingProjects)
        sessions.removeAll { projectIds.contains($0.projectId) }
        sessions.append(contentsOf: reconciledSessions)
        attention.removeAll { projectIds.contains($0.projectId) }
        attention.append(contentsOf: projection.attention)
        permissions.removeAll { projectIds.contains($0.projectId) }
        permissions.append(contentsOf: projection.permissions)
    }

    private func reconcile(incoming: CompanionSession, existing: CompanionSession?) -> CompanionSession {
        guard let existing else { return incoming }
        var reconciled = incoming
        if reconciled.terminalLines == nil { reconciled.terminalLines = existing.terminalLines }
        if reconciled.terminalOutput == nil { reconciled.terminalOutput = existing.terminalOutput }
        if reconciled.terminalStreamEpoch == nil { reconciled.terminalStreamEpoch = existing.terminalStreamEpoch }
        if reconciled.terminalEndOffset == nil { reconciled.terminalEndOffset = existing.terminalEndOffset }
        reconciled.turns = reconcile(projectedTurns: reconciled.turns, existingTurns: existing.turns)
        return reconciled
    }

    private func reconcile(
        projectedTurns: [CompanionTurn]?,
        existingTurns: [CompanionTurn]?
    ) -> [CompanionTurn]? {
        guard let existingTurns, !existingTurns.isEmpty else { return projectedTurns }
        guard var projectedTurns else { return existingTurns }

        var matchedExisting = Set<Int>()
        for projectedIndex in projectedTurns.indices.reversed() {
            guard projectedTurns[projectedIndex].wireId == nil,
                  let existingIndex = existingTurns.indices.reversed().first(where: { index in
                      !matchedExisting.contains(index)
                          && existingTurns[index].wireId != nil
                          && turnsShareIdentity(projectedTurns[projectedIndex], existingTurns[index])
                  }) else { continue }
            let existing = existingTurns[existingIndex]
            projectedTurns[projectedIndex].wireId = existing.wireId
            if existing.text.hasPrefix(projectedTurns[projectedIndex].text),
               existing.text.count > projectedTurns[projectedIndex].text.count {
                projectedTurns[projectedIndex].text = existing.text
            }
            matchedExisting.insert(existingIndex)
        }

        for (index, turn) in existingTurns.enumerated()
        where turn.wireId != nil && turn.status == "streaming" && !matchedExisting.contains(index) {
            projectedTurns.append(turn)
        }
        return projectedTurns
    }

    private func turnsShareIdentity(_ projected: CompanionTurn, _ existing: CompanionTurn) -> Bool {
        guard projected.role == existing.role else { return false }
        if projected.text == existing.text { return true }
        guard !projected.text.isEmpty, !existing.text.isEmpty else { return false }
        return projected.text.hasPrefix(existing.text) || existing.text.hasPrefix(projected.text)
    }

    private func removeProjects(for fields: [String: JSONValue]) {
        var projectIds = Set<String>()
        if let projectId = fields["projectId"]?.stringValue { projectIds.insert(projectId) }
        if let windowId = fields["windowId"]?.stringValue {
            projectIds.formUnion(projectIdsByWindowId.removeValue(forKey: windowId) ?? [])
            if projects.contains(where: { $0.id == windowId }) { projectIds.insert(windowId) }
        }
        removeProjects(withIds: projectIds)
    }

    private func removeProjects(withIds projectIds: Set<String>) {
        guard !projectIds.isEmpty else { return }
        projects.removeAll { projectIds.contains($0.id) }
        sessions.removeAll { projectIds.contains($0.projectId) }
        attention.removeAll { projectIds.contains($0.projectId) }
        permissions.removeAll { projectIds.contains($0.projectId) }
        for owner in Array(projectIdsByWindowId.keys) {
            projectIdsByWindowId[owner]?.subtract(projectIds)
            if projectIdsByWindowId[owner]?.isEmpty == true { projectIdsByWindowId.removeValue(forKey: owner) }
        }
        if let selectedProjectId, projectIds.contains(selectedProjectId) {
            self.selectedProjectId = nil
        }
    }

    private func upsert(_ session: CompanionSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.append(session) }
    }

    private func upsert(_ item: CompanionAttention) {
        if let index = attention.firstIndex(where: { $0.id == item.id }) { attention[index] = item }
        else { attention.append(item) }
    }

    private func applyAgentDelta(_ fields: [String: JSONValue], sentAt: Int64) throws {
        guard let sessionId = fields["sessionId"]?.stringValue ?? fields["targetId"]?.stringValue,
              let index = sessions.firstIndex(where: { $0.id == sessionId }),
              let turnId = fields["turnId"]?.stringValue,
              let deltaValue = fields["delta"] else { return }
        let text: String?
        if let direct = deltaValue.stringValue { text = direct }
        else if let delta = deltaValue.objectValue {
            text = delta["text"]?.stringValue
                ?? delta["content"]?.objectValue?["text"]?.stringValue
        } else { text = nil }
        guard let text else { return }
        var turns = sessions[index].turns ?? []
        if let turnIndex = turns.firstIndex(where: { $0.wireId == turnId }) {
            turns[turnIndex].text += text
            turns[turnIndex].at = sentAt
        } else {
            turns.append(CompanionTurn(role: .assistant, text: text, status: "streaming", at: sentAt, wireId: turnId))
        }
        sessions[index].turns = turns
        sessions[index].summary = String(text.prefix(240))
        sessions[index].updatedAt = sentAt
    }

    private func applyTerminalText(
        sessionId: String,
        text: String,
        streamEpoch: String?,
        endOffset: Int64?,
        replace: Bool,
        sentAt: Int64
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let existing = replace ? "" : (sessions[index].terminalOutput
            ?? (sessions[index].terminalLines ?? []).joined(separator: "\n"))
        let bounded = String((existing + text).suffix(128_000))
        sessions[index].terminalOutput = bounded
        sessions[index].terminalLines = bounded.components(separatedBy: "\n")
        sessions[index].terminalStreamEpoch = streamEpoch
        sessions[index].terminalEndOffset = endOffset
        // The initial bounded snapshot replays historical bytes. Only a live
        // suffix is a new response and may advance the activity clock.
        if !replace { sessions[index].updatedAt = sentAt }
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
        guard isPreview,
              decision == "allow" || decision == "reject",
              let permission = permissions.first(where: { $0.id == permissionId }) else { return }
        let allowed = decision == "allow"
        permissions.removeAll { $0.id == permissionId }
        if let sessionId = permission.sessionId,
           let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].needsYou = false
            sessions[index].unread = false
            sessions[index].status = allowed ? .running : .done
            sessions[index].summary = allowed
                ? "Preview decision applied; agent resumed locally"
                : "Preview decision rejected locally"
        }
        previewReceipt = "Preview only: \(decision)"
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

    func appendUserTurn(to sessionId: String, text: String, commandId: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        var turns = sessions[index].turns ?? []
        turns.append(CompanionTurn(
            role: .user,
            text: clean,
            status: "sent",
            at: Int64(Date.now.timeIntervalSince1970 * 1_000),
            wireId: commandId
        ))
        sessions[index].turns = turns
        sessions[index].summary = clean
    }

    func showActionMessage(_ message: String) {
        previewReceipt = message
    }
}
