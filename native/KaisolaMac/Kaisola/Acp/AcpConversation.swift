import Foundation
import KaisolaCore
import SwiftUI

/// One rendered row in the chat transcript.
enum AcpTranscriptRow: Identifiable, Equatable {
    case user(id: String, text: String)
    case message(id: String, text: String)
    case thought(id: String, text: String)
    case tool(AcpToolCall)
    case plan(id: String, entries: [AcpPlanEntry])

    var id: String {
        switch self {
        case let .user(id, _): "user-\(id)"
        case let .message(id, _): "msg-\(id)"
        case let .thought(id, _): "thought-\(id)"
        case let .tool(call): "tool-\(call.id)"
        case let .plan(id, _): "plan-\(id)"
        }
    }
}

/// Drives one ACP agent conversation and accumulates its streaming turn into a
/// transcript the chat view renders. Owns the AcpClient; runs on the main actor
/// so published transcript mutations are UI-safe.
@MainActor
final class AcpConversation: ObservableObject {
    @Published private(set) var rows: [AcpTranscriptRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var usage: AcpUsage?
    @Published private(set) var models: [AcpSessionInfo.Model] = []
    @Published private(set) var currentModelID: String?
    @Published var pendingPermission: AcpPermissionRequest?
    @Published private(set) var statusMessage: String?

    let title: String
    private let client: AcpClient
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let cwd: String
    private let mcpServers: [JSONValue]
    private let ruleStore: PermissionRuleStore
    private let sensitiveGlobs: [String]
    private var turnCounter = 0

    init(
        title: String,
        command: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String,
        mcpServers: [JSONValue] = [],
        client: AcpClient = AcpClient(),
        ruleStore: PermissionRuleStore = PermissionRuleStore(),
        sensitiveGlobs: [String] = AcpPermissionRules.defaultSensitiveGlobs
    ) {
        self.title = title
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.client = client
        self.ruleStore = ruleStore
        self.sensitiveGlobs = sensitiveGlobs
    }

    func start() async {
        await client.setEventHandler { [weak self] event in
            Task { @MainActor in self?.consume(event) }
        }
        do {
            let info = try await client.start(
                command: command,
                arguments: arguments,
                environment: environment,
                cwd: cwd,
                mcpServers: mcpServers
            )
            models = info.models
            currentModelID = info.currentModelID
            isConnected = true
            statusMessage = nil
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isConnected = false
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty, !isRunning else { return }
        turnCounter += 1
        rows.append(.user(id: "\(turnCounter)", text: trimmed))
        isRunning = true
        Task {
            do { try await client.prompt(trimmed) }
            catch {
                statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isRunning = false
            }
        }
    }

    func cancel() {
        Task { await client.cancel() }
    }

    func selectModel(_ id: String) {
        currentModelID = id
        Task { await client.setModel(id) }
    }

    func answerPermission(_ optionID: String) {
        guard let permission = pendingPermission else { return }
        pendingPermission = nil
        Task { await client.resolvePermission(id: permission.id, optionID: optionID) }
    }

    /// Grant this ask AND create a standing rule so future matching asks
    /// auto-allow. Refused for sensitive-file asks — those can never be
    /// rule-covered (the button is hidden in that case, this is defense in depth).
    func answerPermissionAlways() {
        guard let permission = pendingPermission else { return }
        if !AcpPermissionRules.requestIsSensitive(globs: sensitiveGlobs, title: permission.title, paths: permission.paths) {
            let derived = AcpPermissionRules.ruleForRequest(kind: permission.kind, title: permission.title)
            let rule = PermissionRule(
                id: UUID().uuidString,
                workspace: cwd,
                action: derived.action,
                resource: derived.resource,
                at: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            _ = ruleStore.add(rule)
        }
        answerAllowOnce(permission)
    }

    /// Route an incoming permission ask: sensitive files always surface a card;
    /// otherwise a matching standing rule auto-allows silently; else surface.
    private func handlePermission(_ request: AcpPermissionRequest) {
        if AcpPermissionRules.requestIsSensitive(globs: sensitiveGlobs, title: request.title, paths: request.paths) {
            pendingPermission = request
            return
        }
        if AcpPermissionRules.requestMatchesRule(ruleStore.rules(), workspace: cwd, kind: request.kind, title: request.title) != nil {
            answerAllowOnce(request)
            return
        }
        pendingPermission = request
    }

    /// Answer with the request's allow_once option (falling back to the first
    /// non-reject option, then the first option), never persisting allow_always.
    private func answerAllowOnce(_ request: AcpPermissionRequest) {
        if pendingPermission?.id == request.id { pendingPermission = nil }
        let option = request.options.first { $0.kind == "allow_once" }
            ?? request.options.first { !$0.kind.contains("reject") }
            ?? request.options.first
        guard let option else { return }
        Task { await client.resolvePermission(id: request.id, optionID: option.id) }
    }

    /// Whether the pending ask may be "always allowed" (hidden for sensitive files).
    var pendingPermissionAllowsRule: Bool {
        guard let permission = pendingPermission else { return false }
        return !AcpPermissionRules.requestIsSensitive(globs: sensitiveGlobs, title: permission.title, paths: permission.paths)
    }

    func stop() {
        Task { await client.stop() }
    }

    // MARK: - Stream accumulation

    private func consume(_ event: AcpEvent) {
        switch event {
        case let .turnItem(item):
            accumulate(item)
        case let .toolCallUpdate(id, status, content, title):
            if let index = rows.lastIndex(where: { if case let .tool(c) = $0 { return c.id == id } else { return false } }),
               case var .tool(call) = rows[index] {
                if let status { call.status = status }
                if let content, !content.isEmpty { call.content = content }
                if let title, !title.isEmpty { call.title = title }
                rows[index] = .tool(call)
            }
        case let .usage(usage):
            self.usage = usage
        case let .modelChanged(id):
            currentModelID = id
        case let .permission(request):
            handlePermission(request)
        case .turnEnded:
            isRunning = false
        case let .error(message):
            statusMessage = message
            isRunning = false
        case let .exited(code):
            isConnected = false
            isRunning = false
            statusMessage = code == 0 ? "The agent ended." : "The agent exited (code \(code))."
        }
    }

    /// Streaming chunks accumulate into the current agent message/thought so the
    /// transcript grows smoothly rather than one row per chunk.
    private func accumulate(_ item: AcpTurnItem) {
        switch item {
        case let .message(_, text):
            appendChunk(text, isThought: false)
        case let .thought(_, text):
            appendChunk(text, isThought: true)
        case let .toolCall(call):
            rows.append(.tool(call))
        case let .plan(entries):
            if let index = rows.lastIndex(where: { if case .plan = $0 { return true } else { return false } }) {
                rows[index] = .plan(id: "\(turnCounter)", entries: entries)
            } else {
                rows.append(.plan(id: "\(turnCounter)", entries: entries))
            }
        }
    }

    private func appendChunk(_ text: String, isThought: Bool) {
        let rowID = "\(turnCounter)"
        if let last = rows.last {
            if !isThought, case let .message(id, existing) = last, id == rowID {
                rows[rows.count - 1] = .message(id: id, text: existing + text)
                return
            }
            if isThought, case let .thought(id, existing) = last, id == rowID {
                rows[rows.count - 1] = .thought(id: id, text: existing + text)
                return
            }
        }
        rows.append(isThought ? .thought(id: rowID, text: text) : .message(id: rowID, text: text))
    }
}
