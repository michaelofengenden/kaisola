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
    private var turnCounter = 0

    init(
        title: String,
        command: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String,
        mcpServers: [JSONValue] = [],
        client: AcpClient = AcpClient()
    ) {
        self.title = title
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.client = client
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
            pendingPermission = request
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
