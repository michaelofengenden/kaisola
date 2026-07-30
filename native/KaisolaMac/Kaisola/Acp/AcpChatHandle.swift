import Foundation

/// A live ACP chat in the app's chat list. Holds the conversation view-model;
/// identity is a synthetic per-open id (ACP sessions are app-scoped, not
/// broker-durable, so they need no broker terminal id).
struct AcpChatHandle: Identifiable {
    let id: String
    let agentID: String
    /// The project this chat belongs to. Chats are app-scoped processes, but
    /// navigation is project-scoped: they should sit beside that project's
    /// terminals and Mesh runs instead of floating in a global bucket.
    let workspaceDirectory: URL
    /// Immutable provider-account context for this continuation.
    let accountBinding: SessionAccountBinding?
    let conversation: AcpConversation

    init(
        id: String,
        agentID: String,
        workspaceDirectory: URL,
        accountBinding: SessionAccountBinding? = nil,
        conversation: AcpConversation
    ) {
        self.id = id
        self.agentID = agentID
        self.workspaceDirectory = workspaceDirectory
        self.accountBinding = accountBinding?.normalized
        self.conversation = conversation
    }

    var projectID: String {
        NativeSessionStore.projectID(forDirectory: workspaceDirectory.path)
    }
}
