import Foundation
import SwiftUI

/// The ⌘L omnibar: a slim one-line bar to message the current agent chat from
/// anywhere. Type, hit Enter, the text lands in the selected chat (or a fresh
/// Claude chat in the active project when none is selected), and the bar
/// dismisses. When nothing can receive the message the bar stays open with the
/// draft intact and offers the two ways out (open a project, start a chat).
/// Styled to match `CommandPaletteView` (material, rounded 12, shadow). Escape
/// dismisses without sending.
struct OmniBarView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var text = ""
    /// Set when Enter found nowhere to send. Only changes the caption's wording
    /// and tone — the recovery buttons show whenever there is no target, so the
    /// way out is visible before the user commits a draft.
    @State private var submitRejected = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.kaisolaSecondary)
                TextField("Message the current agent…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    // Editing is a fresh attempt: drop the rejection wording and
                    // let the live caption speak again.
                    .onChange(of: text) { _, _ in submitRejected = false }
            }
            caption
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .shadow(radius: 24, y: 8)
        .onAppear { fieldFocused = true }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    /// Live target: reflects the current selection/project so the user always
    /// sees where Enter will send before committing. With no target it turns
    /// into the recovery prompt instead.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(captionText)
                .font(.caption)
                .foregroundStyle(submitRejected ? Color.orange : Color.kaisolaSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !OmniBarDispatch.hasTarget(model: model) {
                recoveryActions
            }
        }
        .padding(.leading, 28)   // align under the field, past the icon
    }

    private var captionText: String {
        submitRejected
            ? "\(OmniBarDispatch.noTargetCaption). Your draft is still here: open a project or start a chat, then press Return to send it."
            : OmniBarDispatch.targetDescription(model: model)
    }

    /// The two ways to give the omnibar somewhere to send. Both leave the bar
    /// up and the draft untouched, so Return works once a target exists.
    private var recoveryActions: some View {
        HStack(spacing: 12) {
            Button("Open Project…") { RootShellView.promptForOpenFolder(model: model) }
            if let agent = OmniBarDispatch.newChatAgent() {
                Button("New \(agent.name) Chat") { RootShellView.promptForNewChat(agent, model: model) }
            }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private func submit() {
        switch OmniBarDispatch.submit(text, model: model) {
        case .ignored:
            break
        case .delivered:
            text = ""
            isPresented = false
        case .noTarget:
            // The draft stays in the field and the bar stays up: nothing took
            // the message, so nothing may consume it.
            submitRejected = true
            fieldFocused = true
        }
    }
}

/// Where an omnibar message lands, and a live description of that target. The
/// decision order in `resolveTarget`, `hasTarget`, and `targetDescription` is
/// kept in lockstep so the caption never lies about where Enter will send.
enum OmniBarDispatch {
    /// What the bar should do with the draft after Enter.
    enum SubmitOutcome: Equatable {
        /// Nothing to send. Leave the bar exactly as it is.
        case ignored
        /// A conversation took the message. Clear the draft and dismiss.
        case delivered
        /// Nowhere to send. Keep the draft and the bar, and offer recovery.
        case noTarget
    }

    /// Caption shown when nothing can receive a message. Shared with the bar's
    /// recovery wording so the two never drift.
    static let noTargetCaption = "No chat or project available"

    /// Resolve the omnibar's target and deliver `text` to it, reporting what the
    /// bar should do next. The draft is only ever consumed on `.delivered`.
    @MainActor
    static func submit(_ text: String, model: AppModel) -> SubmitOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        guard let conversation = resolveTarget(model: model) else { return .noTarget }
        deliver(trimmed, to: conversation)
        return .delivered
    }

    /// Send `text` to the omnibar's current target:
    ///  1. the selected chat, else
    ///  2. a fresh chat with the first ACP-capable agent (Claude) in the active
    ///     project, else
    ///  3. the first open chat (no project context to create one in).
    /// A safe no-op — never a crash — when there is genuinely nowhere to send
    /// (no selection, no project, no chats); `false` reports that no-op so the
    /// caller can keep the draft.
    @discardableResult
    @MainActor
    static func send(_ text: String, model: AppModel) -> Bool {
        submit(text, model: model) == .delivered
    }

    /// Whether a target exists right now, answered without creating anything so
    /// the bar can offer recovery before the user commits a draft. Mirrors
    /// `resolveTarget`'s decision order.
    @MainActor
    static func hasTarget(model: AppModel) -> Bool {
        if let chatID = model.selectedChatID,
           model.chats.contains(where: { $0.id == chatID }) {
            return true
        }
        if model.currentProjectDirectory != nil, newChatAgent() != nil {
            return true
        }
        return !model.chats.isEmpty
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
        if let directory = model.currentProjectDirectory, let agent = newChatAgent() {
            return "→ new \(agent.name) chat in \((directory.path as NSString).lastPathComponent)"
        }
        // 3. No project context → the first open chat, if any.
        if let chat = model.chats.first {
            return "→ \(chat.conversation.title)"
        }
        // 4. Nowhere to send.
        return noTargetCaption
    }

    /// The first agent that has an ACP adapter (Claude in the shipped roster) —
    /// the agent both the no-selection path and the bar's recovery button use.
    static func newChatAgent() -> AgentProfile? {
        AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil }
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
        if let directory = model.currentProjectDirectory, let agent = newChatAgent() {
            model.openChat(agent, inDirectory: directory)
            if let chatID = model.selectedChatID,
               let chat = model.chats.first(where: { $0.id == chatID }) {
                return chat.conversation
            }
        }
        // 3. No project context: fall back to the first open chat.
        return model.chats.first?.conversation
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
