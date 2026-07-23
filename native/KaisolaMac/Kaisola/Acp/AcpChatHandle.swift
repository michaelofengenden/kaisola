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
    let conversation: AcpConversation

    var projectID: String {
        NativeSessionStore.projectID(forDirectory: workspaceDirectory.path)
    }
}
