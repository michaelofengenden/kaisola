import Foundation
import KaisolaCore

/// The result an adapter reports for one `_session/steering` request.
///
/// Both shipping adapters answer with a single `outcome` string. Claude's
/// (`@agentclientprotocol/claude-agent-acp`) vocabulary is
/// `injected` / `startedNewTurn` / `promptRequired`; Codex's
/// (`@agentclientprotocol/codex-acp`) is `injected` / `startedNewTurn` /
/// `failed`. Anything else — an unknown string, a malformed body, or a JSON-RPC
/// error — is treated as `rejected`, which never loses the message.
enum AcpSteerOutcome: Equatable, Sendable {
    /// The message joined the turn that is already running. This is the only
    /// outcome the feature is actually for.
    case injected
    /// No turn was running by the time the request landed, so the adapter
    /// started a detached turn of its own with this message.
    case startedNewTurn
    /// No turn was running and the adapter honored our opt-in to keep the
    /// content host-owned, so nothing was sent.
    case promptRequired
    /// The adapter refused, or the request failed. Nothing was sent.
    case rejected(String)
}

/// Pure decision logic for injecting a queued follow-up into a running turn.
///
/// Sending mid-turn still QUEUES — that default is untouched. This is the
/// explicit per-row escape hatch: the user picks one queued message and asks
/// for it to reach the turn that is running right now.
enum AcpSteering {
    /// The extension request both adapters advertise. Named with the ACP
    /// leading-underscore convention for a non-core method.
    static let method = "_session/steering"

    /// Whether a queued row may offer the inject action.
    ///
    /// All three conditions are load-bearing. Without adapter support the
    /// request is a guaranteed `Method not found`; without a live connection
    /// there is nothing to send it over; and without a running turn there is no
    /// turn to inject into — the adapter would either start a detached turn or
    /// hand the content back. A button that can only fail is worse than no
    /// button, so the row stays a plain queued message instead.
    static func canInject(supportsSteering: Bool, isConnected: Bool, isRunning: Bool) -> Bool {
        supportsSteering && isConnected && isRunning
    }

    /// What the queue and the transcript must do once the adapter has answered.
    enum QueueDecision: Equatable, Sendable {
        /// The adapter took the message into the live turn. Drop it from the
        /// queue and show it in the transcript at this point in the turn.
        case delivered
        /// The running turn ended inside the request's flight time and the
        /// adapter started a turn of its own with this message. It has been
        /// sent, so it must leave the queue (re-queuing would send it twice),
        /// but the user is told that it landed as a new turn rather than
        /// steering the old one.
        case deliveredAsNewTurn(notice: String)
        /// Nothing was sent. The message stays exactly where it was — still
        /// queued, still in its original position — and the user is told why.
        /// The ordinary end-of-turn flush will dispatch it normally.
        case keptQueued(notice: String)
    }

    static func decide(_ outcome: AcpSteerOutcome) -> QueueDecision {
        switch outcome {
        case .injected:
            .delivered
        case .startedNewTurn:
            .deliveredAsNewTurn(
                notice: "The turn ended first, so the agent started a new turn with that message."
            )
        case .promptRequired:
            .keptQueued(
                notice: "The turn ended before that message could be injected — it is still queued."
            )
        case let .rejected(message):
            .keptQueued(notice: "The agent refused to take that message mid-turn: \(message)")
        }
    }

    /// Encode the request body. Shaped like the relevant subset of a
    /// `session/prompt`, which is exactly what both adapters parse.
    ///
    /// `_meta.steering.idleBehavior = "promptRequired"` is the Claude adapter's
    /// opt-in for host-owned idle fallback: without it an idle session silently
    /// starts a DETACHED turn whose `session/prompt` response we never see, so
    /// the turn's end would never reach us. Codex ignores the field and keeps
    /// its own `startedNewTurn` behavior, which `decide` handles honestly.
    static func requestParams(sessionID: String, text: String) -> JSONValue {
        .object([
            "sessionId": .string(sessionID),
            "prompt": .array([.object([
                "type": .string("text"),
                "text": .string(text),
            ])]),
            "_meta": .object([
                "steering": .object(["idleBehavior": .string("promptRequired")]),
            ]),
        ])
    }

    /// Decode the response body. An adapter that answers with an outcome we do
    /// not know must not be read as success: the safe reading is that nothing
    /// was delivered, which keeps the message queued.
    static func parseOutcome(_ result: JSONValue?) -> AcpSteerOutcome {
        switch result?.objectValue?["outcome"]?.stringValue {
        case "injected": .injected
        case "startedNewTurn": .startedNewTurn
        case "promptRequired": .promptRequired
        case "failed": .rejected("the adapter reported a failed steering request")
        case let other?: .rejected("unrecognized steering outcome \"\(other)\"")
        case nil: .rejected("the adapter sent no steering outcome")
        }
    }
}
