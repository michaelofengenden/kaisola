import Foundation

/// Adapter seam between the rail's live objects (`AttentionCenter`,
/// `BrokerTerminalRecord`, `AcpConversation`, `MeshSession`) and the
/// `QuietSessionStatus` grammar. Every rule here takes value inputs so the
/// behaviour the rail depends on is testable without a view, a broker, or a
/// running agent — the rail itself only reads properties and forwards them.
enum QuietStatusDerivation {
    /// Needs-you (amber) is a *permission ask* or a terminal *bell* — nothing
    /// else.
    ///
    /// `AppModel` raises a `.sessionResponded` entry on every working ->
    /// responded edge and a `.turnCompleted` entry when a chat turn finishes,
    /// so treating "any entry that is not `.turnCompleted`" as attention made
    /// every finished terminal amber and left `doneUnseen` (green) unreachable.
    /// Completion is modelled by `doneUnseen` + acknowledgement, not by amber.
    /// `.bell` is the one exception: a terminal BEL has no broker-modeled
    /// completion at all, so it must read as needs-you like a permission ask.
    static func needsAttention(kinds: [AttentionCenter.Kind]) -> Bool {
        kinds.contains(.permission) || kinds.contains(.bell)
    }

    /// The same rule against a live inbox, narrowed to one surface.
    static func needsAttention(entries: [AttentionCenter.Entry], for targetID: String) -> Bool {
        entries.contains {
            $0.targetID == targetID && ($0.kind == .permission || $0.kind == .bell)
        }
    }

    static func terminal(
        activity: AgentActivity,
        exited: Bool,
        hasPermissionAttention: Bool,
        respondedAcknowledged: Bool
    ) -> QuietSessionStatus {
        QuietSessionStatus.terminal(
            activity: activity,
            exited: exited,
            hasAttention: hasPermissionAttention,
            respondedAcknowledged: respondedAcknowledged
        )
    }

    static func chat(
        isRunning: Bool,
        isConnected: Bool,
        hasPendingPermission: Bool,
        hasPermissionAttention: Bool,
        statusMessage: String? = nil
    ) -> QuietSessionStatus {
        QuietSessionStatus.chat(
            isRunning: isRunning,
            isConnected: isConnected,
            hasPendingPermission: hasPendingPermission,
            hasAttention: hasPermissionAttention,
            statusMessage: statusMessage
        )
    }

    static func mesh(anyColumnRunning: Bool, hasPermissionAttention: Bool) -> QuietSessionStatus {
        QuietSessionStatus.mesh(stageIsIdle: !anyColumnRunning, hasAttention: hasPermissionAttention)
    }
}
