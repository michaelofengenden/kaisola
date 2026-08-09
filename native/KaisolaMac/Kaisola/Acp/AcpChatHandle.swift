import Foundation

/// Gates a restored provider continuation until its immutable named account is
/// present and the provider's own usage/auth probe confirms that it is signed
/// in. The gate is separate from `AcpConversation`: a blocked chat keeps its
/// transcript, draft, queue, pane, and account identity without manufacturing
/// an adapter process that can spin forever in a signed-out state.
@MainActor
final class ChatAccountAccess: ObservableObject {
    enum Phase: Equatable, Sendable {
        case resolving
        case ready
        case actionRequired(Reason)
    }

    enum Reason: Equatable, Sendable {
        case accountRemoved
        case signedOut
        case resolutionTimedOut
    }

    enum Transition: Equatable, Sendable {
        case unchanged
        case changed
        /// A persisted/provider resume identity must be discarded before this
        /// chat is allowed to start again.
        case requiresResumeInvalidation
    }

    enum RecoveryAction: String, CaseIterable, Equatable, Sendable {
        case signIn = "Sign In"
        case chooseAccount = "Choose Account"
        case preserveTranscript = "Keep Transcript"
    }

    struct Snapshot: Sendable {
        let profiles: [UsageAccountProfile]
        let readings: [UsageCenter.ProviderPlanUsage]
        let isRefreshing: Bool
        let now: Date
    }

    struct Presentation: Equatable, Sendable {
        let provider: String
        let account: String
        let headline: String
        let detail: String
        let showsActivityIndicator: Bool
        let actions: [RecoveryAction]
    }

    /// Five seconds is long enough for an already-cached provider reading to
    /// arrive, while keeping the restored pane decisively bounded. A later
    /// successful probe still unlocks the chat after this deadline.
    static let resolutionTimeout: TimeInterval = 5

    let binding: SessionAccountBinding?
    @Published private(set) var phase: Phase
    /// AppModel installs this hook so a timeout reached without another usage
    /// publication still clears the persisted/provider resume identity.
    var onResumeInvalidationRequired: (() -> Void)?

    private var deadline: Date
    private var lastSnapshot: Snapshot?
    private var timeoutTask: Task<Void, Never>?

    init(
        binding: SessionAccountBinding?,
        requiresResolution: Bool,
        now: Date = Date(),
        timeout: TimeInterval = ChatAccountAccess.resolutionTimeout
    ) {
        self.binding = binding?.normalized
        let needsNamedAccount = self.binding?.accountID != nil
        self.phase = requiresResolution && needsNamedAccount ? .resolving : .ready
        self.deadline = now.addingTimeInterval(max(0, timeout))
    }

    deinit { timeoutTask?.cancel() }

    var allowsAdapterStart: Bool {
        phase == .ready
    }

    var presentation: Presentation? {
        guard let binding, binding.accountID != nil else { return nil }
        switch phase {
        case .ready:
            return nil
        case .resolving:
            return Presentation(
                provider: binding.provider.displayName,
                account: binding.label,
                headline: "Checking account…",
                detail: "Confirming \(binding.provider.displayName) account “\(binding.label)” before restoring this chat.",
                showsActivityIndicator: true,
                actions: []
            )
        case let .actionRequired(reason):
            let detail: String
            switch reason {
            case .accountRemoved:
                detail = "The saved \(binding.provider.displayName) account “\(binding.label)” is no longer in Accounts. Its transcript and draft are still here."
            case .signedOut:
                detail = "The saved \(binding.provider.displayName) account “\(binding.label)” is signed out. Its transcript and draft are still here."
            case .resolutionTimedOut:
                detail = "Kaisola could not confirm \(binding.provider.displayName) account “\(binding.label)” in time. No agent process was left running."
            }
            return Presentation(
                provider: binding.provider.displayName,
                account: binding.label,
                headline: "Account action required",
                detail: detail,
                showsActivityIndicator: false,
                actions: RecoveryAction.allCases
            )
        }
    }

    /// Re-evaluate from the local account registry and the provider's existing
    /// auth-aware usage result. No credential contents enter this model.
    @discardableResult
    func reconcile(_ snapshot: Snapshot) -> Transition {
        lastSnapshot = snapshot
        guard let binding, let accountID = binding.accountID else {
            return apply(.ready)
        }

        let profile = snapshot.profiles.first { profile in
            guard profile.id == accountID, profile.provider == binding.provider else { return false }
            return SessionAccountBinding.resolve(
                provider: profile.provider,
                profile: profile,
                fallbackEnvironment: [:]
            )?.continuationKey == binding.continuationKey
        }
        guard profile != nil else {
            return apply(.actionRequired(.accountRemoved))
        }

        if let reading = snapshot.readings.first(where: {
            $0.provider == binding.provider.rawValue && $0.profileID == accountID
        }) {
            return apply(reading.ok ? .ready : .actionRequired(.signedOut))
        }

        if snapshot.isRefreshing {
            // A live chat stays usable while a refresh briefly clears the
            // reading. Restored/blocked chats continue to show bounded
            // resolution instead of being optimistically launched.
            if phase != .ready { _ = apply(.resolving) }
            scheduleTimeoutIfNeeded()
            return .unchanged
        }

        if snapshot.now >= deadline {
            return apply(.actionRequired(.resolutionTimedOut))
        }
        if phase != .ready { _ = apply(.resolving) }
        scheduleTimeoutIfNeeded()
        return .unchanged
    }

    /// Explicit Sign In starts a fresh bounded resolution window. Restoring a
    /// removed profile and authenticating can take longer than the launch-time
    /// window that originally exposed the action card.
    func beginRecovery(now: Date = Date()) {
        deadline = now.addingTimeInterval(Self.resolutionTimeout)
        _ = apply(.resolving)
        scheduleTimeoutIfNeeded()
    }

    private func apply(_ next: Phase) -> Transition {
        guard phase != next else { return .unchanged }
        let previous = phase
        phase = next
        if case .ready = next {
            timeoutTask?.cancel()
            timeoutTask = nil
        } else if case .actionRequired = next {
            timeoutTask?.cancel()
            timeoutTask = nil
        }
        if case .actionRequired = next,
           case .actionRequired = previous {
            return .changed
        }
        if case .actionRequired = next {
            onResumeInvalidationRequired?()
            return .requiresResumeInvalidation
        }
        return .changed
    }

    private func scheduleTimeoutIfNeeded() {
        guard phase == .resolving, timeoutTask == nil else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, var snapshot = self.lastSnapshot else { return }
            self.timeoutTask = nil
            snapshot = Snapshot(
                profiles: snapshot.profiles,
                readings: snapshot.readings,
                isRefreshing: false,
                now: Date()
            )
            _ = self.reconcile(snapshot)
        }
    }
}

/// A live ACP chat in the app's chat list. Holds the conversation view-model;
/// identity is a synthetic per-open id (ACP sessions are app-scoped, not
/// broker-durable, so they need no broker terminal id).
@MainActor
struct AcpChatHandle: Identifiable {
    let id: String
    let agentID: String
    /// The project this chat belongs to. Chats are app-scoped processes, but
    /// navigation is project-scoped: they should sit beside that project's
    /// terminals and Mesh runs instead of floating in a global bucket.
    let workspaceDirectory: URL
    /// Immutable provider-account context for this continuation.
    let accountBinding: SessionAccountBinding?
    /// The model this chat runs on, when it departs from the app default —
    /// applied as an environment override at adapter spawn.
    let modelOverride: String?
    /// Restored named-account availability and recovery actions. All chats own
    /// one gate; ordinary/new/default-account chats begin ready.
    let accountAccess: ChatAccountAccess
    let conversation: AcpConversation

    init(
        id: String,
        agentID: String,
        workspaceDirectory: URL,
        accountBinding: SessionAccountBinding? = nil,
        modelOverride: String? = nil,
        accountAccess: ChatAccountAccess? = nil,
        conversation: AcpConversation
    ) {
        self.id = id
        self.agentID = agentID
        self.workspaceDirectory = workspaceDirectory
        self.accountBinding = accountBinding?.normalized
        self.modelOverride = modelOverride
        self.accountAccess = accountAccess ?? ChatAccountAccess(
            binding: accountBinding,
            requiresResolution: false
        )
        self.conversation = conversation
    }

    var projectID: String {
        NativeSessionStore.projectID(forDirectory: workspaceDirectory.path)
    }

    /// Persist an adapter-confirmed fallback without rebuilding the live
    /// conversation or changing the immutable provider-account identity.
    func replacingModelOverride(with modelOverride: String?) -> AcpChatHandle {
        AcpChatHandle(
            id: id,
            agentID: agentID,
            workspaceDirectory: workspaceDirectory,
            accountBinding: accountBinding,
            modelOverride: modelOverride,
            accountAccess: accountAccess,
            conversation: conversation
        )
    }
}
