import Foundation
import SwiftUI

/// The ⌘L omnibar: a slim one-line bar to message the current agent chat from
/// anywhere. Type, hit Enter, the text lands in the selected chat (or a fresh
/// Claude chat in the active project when none is selected), and the bar
/// dismisses. Styled to match `CommandPaletteView` (material, rounded 12,
/// shadow). Escape dismisses without sending.
struct OmniBarView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                TextField("Message the current agent…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(submit)
            }
            // Live target: reflects the current selection/project so the user
            // always sees where Enter will send before committing.
            Text(OmniBarDispatch.targetDescription(model: model))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 28)   // align under the field, past the icon
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(radius: 24, y: 8)
        .onAppear { fieldFocused = true }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        OmniBarDispatch.send(trimmed, model: model)
        isPresented = false
    }
}

/// Where an omnibar message lands, and a live description of that target. The
/// decision order in `send` and `targetDescription` is kept in lockstep so the
/// caption never lies about where Enter will send.
enum OmniBarDispatch {
    /// Send `text` to the omnibar's current target:
    ///  1. the selected chat, else
    ///  2. a fresh chat with the first ACP-capable agent (Claude) in the active
    ///     project, else
    ///  3. the first open chat (no project context to create one in).
    /// A safe no-op — never a crash — when there is genuinely nowhere to send
    /// (no selection, no project, no chats).
    @MainActor
    static func send(_ text: String, model: AppModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let conversation = resolveTarget(model: model) else { return }
        deliver(trimmed, to: conversation)
    }

    /// A one-line description of where Enter would send, for the bar's caption.
    /// Mirrors `resolveTarget`'s decision order exactly.
    @MainActor
    static func targetDescription(model: AppModel) -> String {
        // 1. An explicitly selected chat.
        if let chatID = model.selectedChatID,
           let chat = model.chats.first(where: { $0.id == chatID }) {
            return "→ \(chat.conversation.title)"
        }
        // 2. No selection but an active project → a fresh chat lands here.
        if let directory = model.currentProjectDirectory, let agent = firstAcpAgent() {
            return "→ new \(agent.name) chat in \((directory.path as NSString).lastPathComponent)"
        }
        // 3. No project context → the first open chat, if any.
        if let chat = model.chats.first {
            return "→ \(chat.conversation.title)"
        }
        // 4. Nowhere to send.
        return "No chat or project available"
    }

    // MARK: - Decision

    /// The conversation `send` would target, creating a new chat when none is
    /// selected but a project context exists. Nil only when there is nowhere to
    /// send. Mirrors `targetDescription`.
    @MainActor
    private static func resolveTarget(model: AppModel) -> AcpConversation? {
        // 1. An explicitly selected chat wins.
        if let chatID = model.selectedChatID,
           let chat = model.chats.first(where: { $0.id == chatID }) {
            return chat.conversation
        }
        // 2. No selection: open a fresh chat with the first ACP-capable agent
        //    (Claude) in the active project, then target the chat it selected.
        if let directory = model.currentProjectDirectory, let agent = firstAcpAgent() {
            model.openChat(agent, inDirectory: directory)
            if let chatID = model.selectedChatID,
               let chat = model.chats.first(where: { $0.id == chatID }) {
                return chat.conversation
            }
        }
        // 3. No project context: fall back to the first open chat.
        return model.chats.first?.conversation
    }

    /// The first agent that has an ACP adapter (Claude in the shipped roster).
    private static func firstAcpAgent() -> AgentProfile? {
        AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil }
    }

    // MARK: - Delivery

    /// Send now if the conversation is already connected; otherwise hold the
    /// message until the chat's view-driven `start()` connects. A just-opened
    /// chat connects asynchronously and `AcpConversation.send` drops messages
    /// while disconnected, so the omnibar's "new chat" path would otherwise lose
    /// its very first message. Bounded so a failed start never leaks the task or
    /// holds the text indefinitely.
    @MainActor
    private static func deliver(_ text: String, to conversation: AcpConversation) {
        if conversation.isConnected {
            conversation.send(text)
            return
        }
        Task { @MainActor in
            for _ in 0..<300 {                                    // ~30s ceiling
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 100_000_000)   // 100ms
                if conversation.isConnected {
                    conversation.send(text)
                    return
                }
            }
        }
    }
}
