import AppKit
import Combine
import Foundation
import KaisolaBrokerProtocol

struct TerminalPasteProgress: Equatable, Sendable {
    let sentBytes: Int
    let totalBytes: Int
}

/// Foundation documents UserDefaults as thread-safe, but its Objective-C type
/// does not yet carry a Sendable annotation. This narrow box crosses executors
/// only for synchronous remove/synchronize/read-back operations while SQLite
/// holds the exact deletion receipt transaction.
private final class ChatDraftDefaultsCleanupContext: @unchecked Sendable {
    private let current: UserDefaults
    private let migrated: UserDefaults?

    init(current: UserDefaults, migrated: UserDefaults?) {
        self.current = current
        self.migrated = migrated
    }

    func erase(keys: [String]) throws {
        for key in keys {
            current.removeObject(forKey: key)
            migrated?.removeObject(forKey: key)
        }
        guard current.synchronize(), migrated?.synchronize() ?? true else {
            throw AcpTranscriptStore.StoreError.database(
                "deleted chat preferences could not be synchronized"
            )
        }
        guard keys.allSatisfy({ key in
            current.object(forKey: key) == nil
                && migrated?.object(forKey: key) == nil
        }) else {
            throw AcpTranscriptStore.StoreError.database(
                "deleted chat preferences could not be erased"
            )
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct MissingSessionRecovery: Equatable, Sendable {
        let sessionID: String
        let message: String
    }

    struct TerminalTranscriptContext: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let streamEpoch: String
        let endOffset: Int64
        let diskBytes: Int64
        /// A frozen, byte-exact document suffix for protocol-2 brokers that
        /// predate terminal-history-v1. Keeping this in the read-only context
        /// makes an in-place app upgrade useful without restarting its broker
        /// (and therefore without sacrificing the broker-owned PTY).
        let fallbackOutput: String
        let fallbackStartOffset: Int64
        let fallbackTruncated: Bool
        let brokerSupportsHistory: Bool
        /// Freeze the PTY geometry with the byte cursor so a read-only replay
        /// interprets cursor-addressed TUI frames exactly as the live terminal
        /// did instead of flattening every repaint into duplicated prose.
        let columns: Int
        let rows: Int
    }

    enum ConnectionState: Equatable {
        case looking
        case connecting
        case reconnecting(attempt: Int)
        case connected(version: String, pid: Int32, serverEnforcedObserver: Bool)
        case unavailable(String)

        var title: String {
            switch self {
            case .looking: "Finding saved sessions"
            case .connecting: "Connecting"
            case .reconnecting: "Reconnecting"
            case .connected: "Sessions Ready"
            case .unavailable: "Session Connection Unavailable"
            }
        }

        var detail: String? {
            switch self {
            case let .reconnecting(attempt):
                "Attempt \(attempt) · running terminals continue safely"
            case let .connected(version, _, serverEnforced):
                "Terminal continuity \(version) · \(serverEnforced ? "project isolation verified" : "read-only compatibility mode")"
            case let .unavailable(message): message
            default: nil
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var connectionState: ConnectionState = .looking
    /// Sealed helper parity is separate from socket health. A broker can be
    /// healthy but intentionally pending an update because it still owns a PTY.
    @Published private(set) var brokerUpgradeState: BrokerUpgradeState = .unknown
    /// Named rather than repeated, so chrome can tell "nothing to report yet"
    /// apart from an actual finding instead of matching on the sentence.
    static let brokerGenerationsUninspected = "Broker generations have not been inspected yet."
    @Published private(set) var brokerGenerationDetail: String = AppModel.brokerGenerationsUninspected
    @Published private(set) var brokerRollbackCandidates: [BrokerRollbackCandidate] = []
    @Published private(set) var sessions: [BrokerTerminalRecord] = []
    @Published var selectedSessionID: String?
    /// A new-window pop-out target that could not be resolved. Kept separate
    /// from ordinary selection so a failed target cannot collapse into the
    /// generic empty workspace and look like a successful blank window.
    @Published private(set) var missingSessionRecovery: MissingSessionRecovery?
    /// The primary document is intentionally not `@Published`: terminal bytes
    /// are a card-local concern, not an IDE-structure mutation. Mounted cards
    /// observe `TerminalSurfaceFeed` instances instead, while selection and
    /// snapshot changes still publish through the surrounding structural state.
    private(set) var terminalDocument = TerminalDocument.empty
    /// Recently viewed primary terminal documents stay mounted in the shell.
    /// Switching back to one is therefore an O(1) visibility change rather than
    /// a destructive SwiftTerm remount + full ANSI replay. The bounded order is
    /// least-recently-used first and caps both retained output and view memory.
    @Published private(set) var terminalSurfaceDocuments: [String: TerminalDocument] = [:]
    @Published private(set) var terminalSurfaceOrder: [String] = []
    private var terminalSurfaceFeeds: [String: TerminalSurfaceFeed] = [:]
    /// Keep a generous LRU of recently visited output in memory. Four panes may
    /// be visible at once, but retaining a dozen documents makes ordinary tab
    /// switching immediate without multiplying live SwiftTerm renderers. The
    /// broker's disk spool remains the durable, larger history boundary.
    nonisolated static let maximumRetainedTerminalSurfaces = 12
    /// Count alone is the wrong unit for a memory budget: a dozen documents,
    /// each free to grow to `TerminalDocument.maximumRetainedBytes`, is 192 MiB
    /// of scrollback strings — reachable simply by touring long-lived
    /// terminals. Retained bytes are therefore bounded too, evicting
    /// least-recently-used first. 96 MiB comfortably holds six saturated
    /// terminals, or one saturated terminal plus a deep deck of ordinary ones.
    // 48 MiB (was 96; 2026-08-06 spec §2c): with documents capped at 5 MiB
    // the old budget could never bind. This holds ~9 saturated documents and
    // makes the byte bound the real constraint again.
    nonisolated static let maximumRetainedTerminalBytes = 48 * 1_024 * 1_024
    /// Terminals this app created and may mutate. Everything else stays
    /// strictly observed no matter what the UI asks for.
    @Published private(set) var ownedTerminalIDs: Set<String> = []
    /// Persisted terminals the broker no longer holds (a reboot or broker
    /// death took their PTYs). Their panes survive layout normalization and
    /// `resurrectDormantTerminals()` respawns them at their recorded cwd.
    @Published private(set) var dormantTerminalIDs: Set<String> = []
    /// Resurrected terminals that were running an agent CLI: the pane shows a
    /// one-keystroke resume chip instead of auto-running the agent (usage cost
    /// and account binding are the user's call).
    @Published private(set) var pendingAgentResume: [String: String] = [:]
    private var resurrectionSweepInFlight = false
    /// Throttles the ownership self-heal (2026-08-07 phantom-owner incident:
    /// a refused attach used to be permanent until the user reloaded).
    private var lastAttachRetryAt: Date?
    /// Whether the connected broker accepted a controller connection; older
    /// brokers stay observe-only and hide every mutation affordance.
    @Published private(set) var controlAvailable = false
    /// Exact ended panes currently being recreated. Kept in the model so every
    /// window disables the same target and a double click cannot create two
    /// replacement PTYs from one ended card.
    @Published private(set) var reopeningTerminalIDs: Set<String> = []
    /// A phone holds the short Companion lease. Keep AppKit geometry callbacks
    /// from fighting its explicit PTY size until release restores the desktop
    /// geometry; surfaced by the session UI as a live remote-control state.
    @Published private(set) var companionControlledTerminalIDs: Set<String> = []
    /// Open ACP chat conversations, keyed by a synthetic chat id. These run
    /// independently of the broker (the adapter is a child of this app).
    @Published private(set) var chats: [AcpChatHandle] = []
    @Published var selectedChatID: String?
    /// Durable, stopped Chat and Mesh entries that have left the active layout
    /// but have not crossed the explicit permanent-delete boundary.
    @Published private var recentlyClosedPanes: [NativeRestorablePaneState] = []

    struct RecentlyClosedSurface: Identifiable, Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case chat
            case mesh
        }

        let id: String
        let projectID: String
        let title: String
        let kind: Kind
        let closedAt: Int64
    }
    /// Focused state machine for project-scoped terminal, chat, and Mesh cards.
    /// AppModel coordinates async owners; synchronous card transitions live in
    /// one explicit value API instead of being repeated across lifecycle code.
    @Published private var unifiedSessionCards = UnifiedSessionCardState()
    var paneLayouts: [String: SessionPaneLayout] { unifiedSessionCards.layouts }
    var focusedPaneID: String? { unifiedSessionCards.focusedPaneID }
    var keyboardFocusRequest: SurfaceKeyboardFocusRequest? {
        unifiedSessionCards.keyboardFocusRequest
    }
    var maximizedPaneID: String? { unifiedSessionCards.maximizedPaneID }
    /// The project tab shown in the top-bar layout. Nil means the first project.
    @Published var selectedProjectName: String?
    /// Stable project identity used by interactive tabs/headers. Names are user
    /// editable and can collide, so routing actions by display name made some
    /// project tabs appear unclickable or target the wrong folder.
    @Published private(set) var selectedProjectID: String? {
        didSet {
            guard oldValue != selectedProjectID else { return }
            // Editors keep drafts in view-local state. Flush them synchronously
            // before changing the workspace root or unmounting the preview so
            // a project click behaves like an autosaving modern workbench.
            NotificationCenter.default.post(name: .kaisolaFlushFilePreviews, object: nil)
            previewedFileURL = nil
            previewedFileLine = nil
            browserCardURL = nil
            if let selectedProjectID { restoreSelectedFilePreview(for: selectedProjectID) }
        }
    }
    struct FileWorkbenchTab: Identifiable, Equatable, Sendable {
        var id: String { url.path }
        let url: URL
        var isPinned: Bool
        var line: Int?
    }
    struct WorkspaceFileRemovalSnapshot: Equatable, Sendable {
        struct IndexedTab: Equatable, Sendable {
            let index: Int
            let tab: FileWorkbenchTab
        }

        let projectID: String
        let removedTabs: [IndexedTab]
        let selectedPath: String?
        let visibleURL: URL?
        let visibleLine: Int?
        let lastVisibleURL: URL?
    }
    private final class WorkspaceTrashUndoTransaction {
        let original: URL
        let root: URL
        let actionName: String
        var move: WorkspaceFileOperations.TrashMove?
        var removalSnapshot: WorkspaceFileRemovalSnapshot?
        var isBusy = false

        init(
            original: URL,
            root: URL,
            actionName: String,
            move: WorkspaceFileOperations.TrashMove? = nil,
            removalSnapshot: WorkspaceFileRemovalSnapshot? = nil
        ) {
            self.original = original.standardizedFileURL
            self.root = root.standardizedFileURL
            self.actionName = actionName
            self.move = move
            self.removalSnapshot = removalSnapshot
        }
    }
    /// Ordered, project-scoped document decks. Only the selected document is
    /// mounted, so opening many files does not multiply TextKit/WebKit memory.
    @Published private(set) var fileTabsByProject: [String: [FileWorkbenchTab]] = [:]
    @Published private(set) var selectedFilePathByProject: [String: String] = [:]
    /// Window-local recovery stack for deliberate editor closes. Open decks
    /// already persist across launches; this bounded stack mirrors IDE
    /// "Reopen Closed Editor" behavior without expanding the durable schema.
    private var recentlyClosedFileTabsByProject: [String: [FileWorkbenchTab]] = [:]
    private static let maximumRecentlyClosedFileTabs = 32
    private struct FileNavigationRollback {
        let tabs: [FileWorkbenchTab]
        let selectedPath: String?
        let visibleURL: URL?
        let visibleLine: Int?
    }
    private var fileNavigationRollbacks: [String: FileNavigationRollback] = [:]
    /// Relative file decks whose project tab/root is temporarily unavailable
    /// (closed or moved). Retain them until Reopen/Locate supplies a safe root;
    /// otherwise a cold launch would erase the only recoverable tab metadata.
    private var deferredFileWorkspaceStates: [String: NativeProjectWorkspaceState] = [:]
    /// A file opened from the workspace rail / palette. It composes beside the
    /// active terminal/chat/Mesh surface instead of replacing that surface.
    @Published private(set) var previewedFileURL: URL? {
        didSet {
            if let previewedFileURL {
                lastPreviewedFileURL = previewedFileURL
            }
        }
    }
    /// The last file opened in the native app. Keeping this separate from
    /// `previewedFileURL` lets the bottom shelf hide/show the preview without
    /// throwing away the user's place in the file tree.
    @Published private(set) var lastPreviewedFileURL: URL?
    /// Line target for the previewed file (from a terminal :LINE citation);
    /// retained for a future editor scroll.
    @Published var previewedFileLine: Int?
    /// Latest symlink-safe, existing project file declared by a live ACP tool
    /// call. The shell follows it only while the user explicitly enables follow
    /// mode for the currently selected Chat or Mesh.
    @Published private(set) var latestAgentFileActivity: WorkspaceAgentFileActivity?
    private var agentFileActivitySequence: UInt64 = 0
    /// A local dev-server URL opened as an in-app browser card (Electron
    /// parity); non-nil raises a BrowserCardView in the detail pane.
    @Published var browserCardURL: URL?

    private let brokerPreparer: any BrokerInfoPreparing
    private let client: any ObserveOnlyBrokerServing
    private let controlClient: any BrokerControlServing
    private let sessionStore: NativeSessionStore
    private let cursorStore: TerminalCursorStore
    private let workspaceStateStore: NativeWorkspaceStateStore
    private let transcriptStore: AcpTranscriptStore
    /// Shared launch gate and recovery truth observed by the workspace and
    /// Settings surfaces.
    let projectAccountRecoveryCenter: ProjectAccountRecoveryCenter
    private let usageCenter: UsageCenter
    private let usageAccountStore: UsageAccountStore
    private let attentionCenter: AttentionCenter
    private let chatDraftDefaults: UserDefaults
    private let migratedChatDraftDefaults: UserDefaults?
    private let reconnectBackoff: BrokerReconnectBackoff
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let jitter: @Sendable () -> Double
    /// Optional suspension used by deterministic lifecycle tests. Production
    /// passes nil; the hook runs only after the first deletion probe and
    /// before the final probe immediately preceding chat materialization.
    private let beforeRecentlyClosedChatMaterialization: (@Sendable (String) async -> Void)?
    /// Optional deterministic race seam after the complete workspace archive
    /// has been read but before its deletion receipts are reconciled. Nil in
    /// production; tests use it to coordinate another window's exact delete.
    private let afterWorkspaceRestorationRead: (@Sendable () async -> Void)?
    /// Optional deterministic suspension after an active archived chat has
    /// finished its fallible reads but before the final deletion authorization
    /// and materialization boundary. Production passes nil.
    private let beforeRestoredChatMaterialization: (@Sendable (String) async -> Void)?
    /// Optional deterministic suspension after a Recently Closed chat's legacy
    /// draft has been read but before any migration write is allowed. Nil in
    /// production; tests use it to place deletion on that exact boundary.
    private let beforeRecentlyClosedLegacyDraftMigration: (@Sendable (String) async -> Void)?
    private var selectedSession: BrokerTerminalRecord?
    private var activeBrokerIdentity: String?
    private var activeBrokerTopology: BrokerGenerationTopology?
    private var activeBrokerTopologyProvider: (any BrokerGenerationTopologyProviding)?
    private var connectedBrokerFeatures: Set<String> = []
    private var activeBrokerUpgradeMonitor: (any BrokerUpgradeMonitoring)?
    private var activeBrokerRollbackController: (any BrokerGenerationRollbackServing)?
    private var reconnectTask: Task<Void, Never>?
    private var cursorSaveTask: Task<Void, Never>?
    private var inventoryRefreshTask: Task<Void, Never>?
    private var consecutiveInventoryFailures = 0
    private struct DesktopTerminalGeometry: Equatable, Sendable {
        let columns: Int
        let rows: Int
        var key: String { "\(columns)x\(rows)" }
    }
    private var terminalResizeTasks: [String: Task<Void, Never>] = [:]
    private var terminalResizeGeneration: [String: Int] = [:]
    /// Latest AppKit geometry is desired state, not a disposable edge. It is
    /// retained while ownership/control is unavailable and replayed after a
    /// reconnect or Companion lease, preventing a transient 20-column PTY from
    /// surviving underneath a visually wide terminal.
    private var desiredTerminalGeometry: [String: DesktopTerminalGeometry] = [:]
    private var lastTerminalSize: [String: String] = [:]
    static let terminalResizeDebounceNanoseconds: UInt64 = 40_000_000
    private struct PendingTerminalInput: Sendable {
        let projectID: String
        let data: String
        let opensAgentTurn: Bool
        let generation: UInt64
        let pasteGeneration: UInt64?
        let byteCount: Int
    }
    private var terminalInputQueues: [String: [PendingTerminalInput]] = [:]
    private var terminalInputDrainTasks: [String: Task<Void, Never>] = [:]
    /// Ownership is a revocable capability. Bytes accepted under one
    /// generation must never drain after that capability disappears and a
    /// later controller reattaches to the same PTY.
    private var terminalInputGenerations: [String: UInt64] = [:]
    /// Keep individual broker writes below the documented node-pty boundary.
    /// Ordinary keystrokes stay one packet; an intentional large paste is
    /// streamed in UTF-8-safe chunks and exposes acknowledged progress.
    nonisolated static var terminalWritePayloadByteLimit: Int {
        BrokerWire.terminalWritePayloadBytes
    }
    private var nextTerminalPasteGeneration: UInt64 = 0
    private var terminalPasteGenerationByTerminalID: [String: UInt64] = [:]
    @Published private(set) var terminalPasteProgressByTerminalID: [String: TerminalPasteProgress] = [:]
    static let terminalInputDiscardNoticeSuffix =
        ": unsent input was discarded. Try again after input reconnects."
    static let terminalInputDiscardAggregateNotice =
        "Unsent input was discarded after terminal control changed. Try again after input reconnects."
    private var terminalInputFailureNoticeAt: [String: Date] = [:]
    /// Terminals whose open agent turn the broker acknowledged. Local activity
    /// state only advances on a positive `terminal.agentTurn` reply, so the app
    /// never claims a turn the broker did not record.
    private var acknowledgedAgentTurnTerminalIDs: Set<String> = []
    /// Terminals whose last agent-turn signal the broker refused (or never
    /// answered). The broker counts these idle while a turn is really running,
    /// so a rolling cutover could retire their generation underneath the agent.
    @Published private(set) var agentTurnSignalFailureTerminalIDs: Set<String> = []
    private var agentTurnSignalFailureNoticeAt: [String: Date] = [:]
    /// A request-level terminal.write failure has an ambiguous outcome: the
    /// PTY may have received the bytes before its reply timed out. Keep durable
    /// ownership intact, but fail closed for input on only that terminal until
    /// the controller is explicitly re-established. This must not collapse all
    /// other owned surfaces into the global reconnect path.
    @Published private(set) var terminalInputDegradedIDs: Set<String> = []
    @Published private(set) var terminalInputRecoveringIDs: Set<String> = []
    /// Broker PTYs can emit hundreds of small packets in one display interval.
    /// Merge contiguous packets for 16 ms so a 64 MiB retained document is
    /// copied and published at most once per frame, while offsets and ordering
    /// remain byte exact and terminal input never waits on this path.
    private var pendingTerminalOutput: [String: TerminalOutputBatch] = [:]
    private var pendingTerminalOutputOrder: [String] = []
    private var terminalOutputFlushTask: Task<Void, Never>?
    private var terminalOutputFlushGeneration = 0
    static let terminalOutputFrameNanoseconds: UInt64 = 16_000_000
    /// One intent token per secondary subscription. Tokens fence late broker
    /// replies after minimize, promotion, reconnect, or a newer subscribe for
    /// the same terminal; a plain Set cannot distinguish those generations.
    private var pendingSplitSubscriptions: [String: UUID] = [:]
    /// Latest requested broker role for each secondary. A new open, minimize,
    /// or promotion invalidates suspended cursor/unsubscribe work so an older
    /// operation cannot erase a card the user has already reopened.
    private var splitIntentTokens: [String: UUID] = [:]
    private var connectionGeneration = 0
    /// Discards late subscription results after a faster subsequent tab click.
    private var terminalSelectionGeneration = 0
    private var shouldReconnect = false
    private var hasStarted = false
    private var restoredWorkspaceState = false
    private var isRestoringWorkspaceState = false
    private var workspaceSaveTasks: [String: Task<Void, Never>] = [:]
    private var pendingNewTranscriptChatIDs: Set<String> = []
    private var failedNewTranscriptChatIDs: Set<String> = []
    /// New Mesh manifests can briefly contain provisioning columns before the
    /// ACP object exists. Track the exact incarnation ids already established
    /// so a later failed provisioning step can abandon only its empty debris.
    private var provisionedTranscriptIDsByMeshID: [String: Set<String>] = [:]
    private let observerOwnerID = "kaisola-native"

    /// Disk-backed navigation state is cached in memory. `projects` is read by
    /// many SwiftUI branches on every streamed terminal update; decoding two
    /// JSON files repeatedly there turned normal output into main-thread I/O
    /// and was the largest source of the spinning cursor after opening folders.
    var persistedOpenProjects: [OpenProject] = []
    var persistedOwnedSessions: [NativeOwnedSession] = []
    var persistedSessionAliases: [String: String] = [:]
    var persistedPinnedIDs: Set<String> = []
    /// Set while the pin file on disk cannot be read. The last-known-good pin
    /// set stays on screen for as long as this is non-nil, and only an explicit
    /// reset clears the damaged file.
    var pinsUnreadable: SessionPinStore.LoadFailure?
    let pinStore: SessionPinStore
    private let adoptionStore: SessionAdoptionStore
    /// Projects already nudged about a stale instruction file this run —
    /// process-wide, because "once per run" must hold across windows and
    /// every window owns its own AppModel.
    private static var staleInstructionNudgesShown: Set<String> = []
    /// The adoption overlay, mirrored from `SessionAdoptionStore` so display
    /// grouping never reads a file per render. Presentation resolves a
    /// terminal's project through `displayProjectID(_:)`; broker RPCs never
    /// look here — they keep addressing the terminal's real `projectID`.
    @Published private(set) var sessionAdoptions: [String: String] = [:]

    init(
        brokerPreparer: any BrokerInfoPreparing = BrokerStartupCoordinator.live(),
        fallbackPreparer: (any BrokerInfoPreparing)? = nil,
        client: (any ObserveOnlyBrokerServing)? = nil,
        controlClient: (any BrokerControlServing)? = nil,
        sessionStore: NativeSessionStore = NativeSessionStore(),
        cursorStore: TerminalCursorStore = TerminalCursorStore(fileURL: NativePreviewPaths.terminalCursorStore),
        workspaceStateStore: NativeWorkspaceStateStore = .live,
        transcriptStore: AcpTranscriptStore = .live,
        projectAccountRecoveryCenter: ProjectAccountRecoveryCenter? = nil,
        adoptionStore: SessionAdoptionStore = SessionAdoptionStore(),
        pinStore: SessionPinStore = SessionPinStore(),
        usageCenter: UsageCenter = .shared,
        usageAccountStore: UsageAccountStore = UsageAccountStore(),
        attentionCenter: AttentionCenter = .shared,
        chatDraftDefaults: UserDefaults = .standard,
        migratedChatDraftDefaults: UserDefaults? = UserDefaults(
            suiteName: KaisolaProductMigration.legacyBundleIdentifier
        ),
        reconnectBackoff: BrokerReconnectBackoff = BrokerReconnectBackoff(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        jitter: @escaping @Sendable () -> Double = {
            Double.random(in: -1...1)
        },
        beforeRecentlyClosedChatMaterialization: (@Sendable (String) async -> Void)? = nil,
        afterWorkspaceRestorationRead: (@Sendable () async -> Void)? = nil,
        beforeRestoredChatMaterialization: (@Sendable (String) async -> Void)? = nil,
        beforeRecentlyClosedLegacyDraftMigration: (@Sendable (String) async -> Void)? = nil
    ) {
        self.brokerPreparer = brokerPreparer
        self.fallbackPreparer = fallbackPreparer
        let generationRoutes = BrokerGenerationRouteTable()
        self.client = client ?? BrokerGenerationObserverRouter(routes: generationRoutes)
        self.controlClient = controlClient ?? BrokerGenerationControlRouter(routes: generationRoutes)
        self.sessionStore = sessionStore
        self.cursorStore = cursorStore
        self.workspaceStateStore = workspaceStateStore
        self.transcriptStore = transcriptStore
        self.projectAccountRecoveryCenter = projectAccountRecoveryCenter
            ?? usageCenter.projectAccountRecoveryCenter
        self.adoptionStore = adoptionStore
        self.pinStore = pinStore
        self.usageCenter = usageCenter
        self.usageAccountStore = usageAccountStore
        self.attentionCenter = attentionCenter
        self.chatDraftDefaults = chatDraftDefaults
        self.migratedChatDraftDefaults = migratedChatDraftDefaults
        self.reconnectBackoff = reconnectBackoff
        self.sleep = sleep
        self.jitter = jitter
        self.beforeRecentlyClosedChatMaterialization = beforeRecentlyClosedChatMaterialization
        self.afterWorkspaceRestorationRead = afterWorkspaceRestorationRead
        self.beforeRestoredChatMaterialization = beforeRestoredChatMaterialization
        self.beforeRecentlyClosedLegacyDraftMigration =
            beforeRecentlyClosedLegacyDraftMigration
        let transientTitleRepairs = Dictionary(uniqueKeysWithValues: sessionStore
            .sessions()
            .compactMap { stored -> (String, String)? in
                let folder = (stored.cwd as NSString).lastPathComponent
                let agentName = stored.agentID.flatMap { AgentRegistry.profile(id: $0)?.name }
                guard let repaired = SessionTitleTracker.repairedPersistedCreationTitle(
                    title: stored.title,
                    lastAutoTitle: stored.lastAutoTitle,
                    agentName: agentName,
                    folder: folder
                ) else { return nil }
                return (stored.id, repaired)
            })
        sessionStore.repairTransientAutoTitles(transientTitleRepairs)
        let navigation = sessionStore.navigationSnapshot()
        persistedOpenProjects = navigation.projects
        persistedOwnedSessions = navigation.sessions
        persistedSessionAliases = navigation.sessionAliases
        reloadPersistedPins()
        sessionAdoptions = adoptionStore.adoptions()
        observeChatAccountAvailability()
        transcriptPersistenceHealthTask = Task { [weak self, transcriptStore] in
            let updates = await transcriptStore.persistenceHealthUpdates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.applyTranscriptPersistenceHealth(update)
            }
        }
    }

    deinit {
        transcriptPersistenceHealthTask?.cancel()
    }

    /// Installed visual receipts assert this concrete no-launch route rather
    /// than trusting the fixture environment flag that selected it.
    var usesBrokerFreeFixturePreparer: Bool {
        brokerPreparer is BrokerFreeFixturePreparer
    }

    /// Keeps each chat's usage observers alive only while that chat exists.
    /// Keying by id avoids retaining closed conversations and stale Usage rows.
    private var usageObservers: [String: Set<AnyCancellable>] = [:]
    /// Account registry/auth changes can invalidate an adapter while its pane
    /// remains open. Keep those non-destructive replacements alive through
    /// window teardown, one ordered task per affected chat.
    private var chatAccountInvalidationTasks: [String: Task<Void, Never>] = [:]
    private var chatAccountObservers = Set<AnyCancellable>()
    private let usageSourceID = UUID().uuidString.lowercased()
    /// Serializes transcript actor enqueues so an immediate quit cannot overtake
    /// the final streaming row or an explicit chat removal.
    private var transcriptPersistenceTask: Task<Void, Never>?
    private var transcriptPersistenceHealthTask: Task<Void, Never>?
    /// A closed chat is a tombstone for as long as buffered ACP events can
    /// still drain while the child process stops; those must not be allowed to
    /// enqueue a transcript write after the explicit deletion. Bounded by
    /// recency so a long-lived window cannot accumulate one entry per close.
    private(set) var explicitlyClosedChatIDs = BoundedIdentifierSet(
        limit: AppModel.closedChatTombstoneLimit
    )
    /// Comfortably more closes than any drain can still be racing, and small
    /// enough to stay a rounding error in a window's memory.
    static let closedChatTombstoneLimit = 256
    /// Draft writes are ordered just like transcripts. The final debounced
    /// composer value can therefore be queued and awaited during termination.
    private var draftPersistenceTask: Task<Void, Never>?
    private struct TerminalDraftResumeSeed: Equatable, Sendable {
        let text: String
        let sourceStableKey: String
    }
    /// CLI composers live inside terminal processes rather than SwiftUI text
    /// fields. Reconstruct their unsent text from owned-terminal input, debounce
    /// private archive writes, and keep restore timers separate from broker
    /// reconnect/session ownership tasks.
    private var terminalDraftTrackers: [String: TerminalAgentDraftTracker] = [:]
    private var terminalDraftDebounceTasks: [String: Task<Void, Never>] = [:]
    private var terminalDraftRestoreTasks: [String: Task<Void, Never>] = [:]
    private var pendingTerminalDraftRestores: [String: TerminalDraftResumeSeed] = [:]
    private var terminalLastOutputAt: [String: Date] = [:]
    /// Explicit chat closes start an async ACP shutdown. Keep those tasks until
    /// they finish (or until window teardown awaits them) so application
    /// termination cannot strand child adapters.
    private let chatShutdownTasks = ShutdownTaskRegistry()
    /// A durable Mesh may be restored by only one window model at a time.
    /// Main-actor isolation makes this a process-wide claim without locks.
    private static var claimedRestoredMeshIDs: Set<String> = []
    /// Restore and permanent Delete are mutually exclusive transitions. A
    /// stale menu in another window must not run either transition twice.
    private static var claimedRecentlyClosedSurfaceIDs: Set<String> = []
    /// Mesh panes this window intentionally did not adopt (owned by another
    /// window or temporarily unavailable on disk). The shared store preserves
    /// their latest descriptor when this window saves a partial snapshot.
    private var deferredMeshPanesByProject: [String: [NativeRestorablePaneState]] = [:]
    /// Hosted visual fixtures synthesize broker records but never establish a
    /// transport. Their teardown must persist local fixture state only.
    private var usesVisualFixtureTransport = false
    /// Child surfaces are observable objects of their own. Relay their live
    /// state changes so project activity badges and tabs update immediately.
    private var surfaceObservers: [String: AnyCancellable] = [:]
    /// What the shell actually shows about a chat, as opposed to everything a
    /// conversation publishes.
    ///
    /// Views outside the chat surface read these through the conversation at
    /// render time — the strip and the rail want a title, a running dot, a
    /// permission badge. None of them render the transcript. So the shell needs
    /// to be invalidated when one of these changes, and not when a token
    /// arrives, which is what a blanket re-broadcast could not distinguish.
    private struct ChatSurfaceSummary: Equatable {
        let title: String
        let isRunning: Bool
        let isConnected: Bool
        let statusMessage: String?
        let pendingPermissionCount: Int
        let queuedCount: Int
        let hasRows: Bool
        let usage: AcpUsage?
    }
    private var chatSurfaceSummaries: [String: ChatSurfaceSummary] = [:]
    private var surfaceSummaryCheckScheduled = false
    /// The same idea for Mesh. The shell shows a title, a running dot, a stage
    /// word, and builds a run-target list from column worktrees. `MeshView`
    /// renders the columns and their transcripts, but it holds the session as
    /// its own `@ObservedObject`, so it keeps updating from the session
    /// directly and does not depend on this re-broadcast.
    private struct MeshSurfaceSummary: Equatable {
        let title: String
        let anyRunning: Bool
        let stage: String
        let columnTargets: [String]
    }
    private var meshSurfaceSummaries: [String: MeshSurfaceSummary] = [:]
    /// The separate native-profile broker used when Electron's is incompatible.
    private let fallbackPreparer: (any BrokerInfoPreparing)?
    /// True when this window is connected to the app's own separate broker
    /// (Electron's remains untouched beside it).
    @Published private(set) var usingSeparateBroker = false

    /// A project grouping for the sidebar/tabs: a stable id, a display name,
    /// its optional local directory, and its live sessions. Explicitly-opened
    /// project tabs appear even with no sessions.
    struct ProjectGroup: Identifiable, Equatable {
        let id: String
        let name: String
        let directory: URL?
        let sessions: [BrokerTerminalRecord]
        /// Tab tint (hex RGB) chosen by the user, nil = default.
        var colorHex: String?
        /// Sessions currently in an agent "working" state — the activity badge.
        var workingCount: Int = 0
        /// Finished turns that still need the user's attention. This remains
        /// visible after `workingCount` returns to zero and clears on visit.
        var attentionCount: Int = 0
    }

    /// Turns a relaunch would abort, across every project in this window.
    ///
    /// Terminals are deliberately excluded: native-created terminals live in the
    /// detached broker and survive app quit, relaunch, and update, resuming from
    /// their exact byte cursor. ACP chats and Mesh columns are in-process child
    /// processes that `teardown()` stops, so those are the only turns a restart
    /// actually interrupts. Kept cheap and separate from `projects`, which
    /// regroups and sorts everything.
    var interruptibleTurnCount: Int {
        chats.filter(\.conversation.isRunning).count
            + meshes.reduce(into: 0) { count, mesh in
                count += mesh.columns.filter(\.conversation.isRunning).count
            }
    }

    var projects: [ProjectGroup] {
        let opened = persistedOpenProjects
        let openedByID = Dictionary(uniqueKeysWithValues: opened.map { ($0.id, $0) })
        let ownedByID = Dictionary(
            persistedOwnedSessions.map { ($0.projectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sessionsByProject = Dictionary(grouping: sessions, by: { self.displayProjectID($0) })
        let chatsByProject = Dictionary(grouping: chats, by: \.projectID)
        let meshesByProject = Dictionary(grouping: meshes, by: \.projectID)
        let recentlyClosedByProject = Dictionary(
            grouping: recentlyClosedPanes,
            by: { $0.surface.projectID }
        )
        let pins = persistedPinnedIDs

        func group(for id: String) -> ProjectGroup {
            let sessions = AppModel.pinnedOrder(sessionsByProject[id] ?? [], pinned: pins)
            let projectChats = chatsByProject[id] ?? []
            let projectMeshes = meshesByProject[id] ?? []
            let recentDirectory: URL? = recentlyClosedByProject[id]?.lazy.compactMap { pane in
                if let descriptor = pane.surface.agentChatDescriptor {
                    return URL(fileURLWithPath: descriptor.workspacePath, isDirectory: true)
                }
                if let descriptor = pane.surface.meshDescriptor {
                    return URL(fileURLWithPath: descriptor.basePath, isDirectory: true)
                }
                return nil
            }.first
            let name = openedByID[id]?.name
                ?? ownedByID[id].map { ($0.cwd as NSString).lastPathComponent }
                ?? projectChats.first?.workspaceDirectory.lastPathComponent
                ?? projectMeshes.first?.baseDirectory.lastPathComponent
                ?? recentDirectory?.lastPathComponent
                ?? id
            let directory = openedByID[id].map { URL(fileURLWithPath: $0.path) }
                ?? ownedByID[id].map { URL(fileURLWithPath: $0.cwd) }
                ?? projectChats.first?.workspaceDirectory
                ?? projectMeshes.first?.baseDirectory
                ?? recentDirectory
            let terminalWorking = sessions.filter { record in
                if case .working = record.agentActivity, !record.exited { return true }
                return false
            }.count
            let chatWorking = projectChats.filter(\.conversation.isRunning).count
            let meshWorking = projectMeshes.reduce(into: 0) { count, mesh in
                count += mesh.columns.filter(\.conversation.isRunning).count
            }
            let attentionTargets = Set(
                sessions.map(\.id)
                    + projectChats.map(\.id)
                    + projectMeshes.flatMap { [$0.id] + $0.columns.map(\.id) }
            )
            let attentionCount = attentionCenter.entries.filter {
                attentionTargets.contains($0.targetID)
            }.count
            return ProjectGroup(
                id: id, name: name, directory: directory, sessions: sessions,
                colorHex: openedByID[id]?.colorHex,
                workingCount: terminalWorking + chatWorking + meshWorking,
                attentionCount: attentionCount
            )
        }

        // Opened tabs keep their persisted (user-reordered) sequence; projects
        // that only exist through live sessions/chats/Mesh or Recently Closed
        // follow, sorted by name — EXCEPT projects the user closed. Closed
        // stays closed (2026-08-06 spec §4d): a closed project's live work
        // keeps running (the close confirmation says so, and its attention
        // events still surface), but the tab returns only via reopen (⌘⇧T) or
        // Open Folder. This deliberately inverts the old rule that Recently
        // Closed work forced a project visible.
        let openedGroups = opened.map { group(for: $0.id) }
        let liveProjectIDs = Set(sessionsByProject.keys)
            .union(chatsByProject.keys)
            .union(meshesByProject.keys)
            .union(recentlyClosedByProject.keys)
        let sessionOnly = liveProjectIDs.subtracting(opened.map(\.id))
            .filter { !sessionStore.isProjectClosed($0) }
            .map(group(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return openedGroups + sessionOnly
    }

    /// Portable, account-scoped metadata for the remembered-session catalog.
    /// This allowlist deliberately cannot represent cwd, file paths, prompts,
    /// terminal bytes, environment variables, credentials, or provider tokens.
    func rememberedSessionDrafts(
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [RememberedSessionDraft] {
        let groups = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        let owned = Dictionary(uniqueKeysWithValues: persistedOwnedSessions.map { ($0.id, $0) })
        let attention = Dictionary(
            attentionCenter.entries.map { ($0.targetID, $0) },
            uniquingKeysWith: { _, newest in newest }
        )

        let terminals = sessions.map { record in
            let persisted = owned[record.id]
            let notice = attention[record.id]
            let activity: RememberedSessionActivity
            let lastActivityAt: Int64?
            if record.exited {
                activity = .ended
                lastActivityAt = notice.map { Int64($0.at.timeIntervalSince1970 * 1_000) }
            } else if notice != nil {
                activity = .needsAttention
                lastActivityAt = notice.map { Int64($0.at.timeIntervalSince1970 * 1_000) }
            } else {
                switch record.agentActivity {
                case .working:
                    activity = .working
                    lastActivityAt = now
                case let .responded(at):
                    activity = .needsAttention
                    lastActivityAt = at
                case .idle:
                    activity = .idle
                    lastActivityAt = nil
                }
            }
            return RememberedSessionDraft(
                id: record.id,
                projectID: record.projectID,
                projectName: groups[record.projectID] ?? "Kaisola project",
                title: persistedSessionAliases[record.id] ?? persisted?.title ?? record.title,
                kind: .terminal,
                agentID: persisted?.agentID,
                activity: activity,
                resumeKind: record.exited ? .metadataOnly : .livePTY,
                createdAt: persisted?.createdAt,
                lastActivityAt: lastActivityAt,
                hasLocalTranscript: record.endOffset > 0
            )
        }

        let agentChats = chats.map { chat in
            let notice = attention[chat.id]
            return RememberedSessionDraft(
                id: chat.id,
                projectID: chat.projectID,
                projectName: groups[chat.projectID] ?? chat.workspaceDirectory.lastPathComponent,
                title: chat.conversation.title,
                kind: .agentChat,
                agentID: chat.agentID,
                activity: notice != nil ? .needsAttention : (chat.conversation.isRunning ? .working : .idle),
                resumeKind: .metadataOnly,
                createdAt: nil,
                lastActivityAt: notice.map { Int64($0.at.timeIntervalSince1970 * 1_000) }
                    ?? (chat.conversation.isRunning ? now : nil),
                hasLocalTranscript: !chat.conversation.rows.isEmpty
            )
        }

        let meshRuns = meshes.map { mesh in
            let meshTargets = [mesh.id] + mesh.columns.map(\.id)
            let newestNotice = meshTargets.compactMap { attention[$0] }.max { $0.at < $1.at }
            let working = mesh.columns.contains { $0.conversation.isRunning }
            return RememberedSessionDraft(
                id: mesh.id,
                projectID: mesh.projectID,
                projectName: groups[mesh.projectID] ?? mesh.baseDirectory.lastPathComponent,
                title: mesh.title,
                kind: .mesh,
                agentID: nil,
                activity: newestNotice != nil ? .needsAttention : (working ? .working : .idle),
                resumeKind: .metadataOnly,
                createdAt: nil,
                lastActivityAt: newestNotice.map { Int64($0.at.timeIntervalSince1970 * 1_000) }
                    ?? (working ? now : nil),
                hasLocalTranscript: mesh.columns.contains { !$0.conversation.rows.isEmpty }
            )
        }
        return terminals + agentChats + meshRuns
    }

    /// The nearby Companion uses the same portable allowlist as account sync,
    /// but a running session must not manufacture a fresh activity timestamp
    /// on every terminal byte. Status and broker stream heads carry the live
    /// change; response/completion clocks remain factual.
    func companionProjectionDrafts(
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [RememberedSessionDraft] {
        rememberedSessionDrafts(now: now).map { draft in
            RememberedSessionDraft(
                id: draft.id,
                projectID: draft.projectID,
                projectName: draft.projectName,
                title: draft.title,
                kind: draft.kind,
                agentID: draft.agentID,
                activity: draft.activity,
                resumeKind: draft.resumeKind,
                createdAt: draft.createdAt,
                lastActivityAt: draft.activity == .working ? nil : draft.lastActivityAt,
                hasLocalTranscript: draft.hasLocalTranscript
            )
        }
    }

    /// A stream head is safe routing metadata, not transcript content. The
    /// phone can request a bounded broker page later without duplicating the
    /// PTY spool in AppModel or the initial projects snapshot.
    func companionTerminalStreams() -> [String: CompanionTerminalStreamHead] {
        Dictionary(uniqueKeysWithValues: sessions.compactMap { terminal in
            guard let epoch = terminal.streamEpoch, !epoch.isEmpty else { return nil }
            return (terminal.id, CompanionTerminalStreamHead(
                streamEpoch: epoch,
                endOffset: terminal.endOffset
            ))
        })
    }

    /// Refresh the small persisted navigation snapshot at explicit mutation or
    /// inventory boundaries — never during SwiftUI view evaluation.
    func refreshPersistedNavigationState(publish: Bool = true) {
        let navigation = sessionStore.navigationSnapshot()
        persistedOpenProjects = navigation.projects
        persistedOwnedSessions = navigation.sessions
        persistedSessionAliases = navigation.sessionAliases
        reloadPersistedPins()
        if publish { objectWillChange.send() }
    }

    func chats(in projectID: String) -> [AcpChatHandle] {
        chats.filter { $0.projectID == projectID }
    }

    func meshes(in projectID: String) -> [MeshSession] {
        meshes.filter { $0.projectID == projectID }
    }

    func recentlyClosedSurfaces(in projectID: String) -> [RecentlyClosedSurface] {
        recentlyClosedPanes.compactMap { pane in
            guard pane.isRecentlyClosed, pane.surface.projectID == projectID else { return nil }
            if let descriptor = pane.surface.agentChatDescriptor {
                return RecentlyClosedSurface(
                    id: descriptor.id,
                    projectID: descriptor.projectID,
                    title: descriptor.title ?? "Agent Chat",
                    kind: .chat,
                    closedAt: pane.closedAt ?? 0
                )
            }
            if let descriptor = pane.surface.meshDescriptor {
                return RecentlyClosedSurface(
                    id: descriptor.id,
                    projectID: descriptor.projectID,
                    title: descriptor.title,
                    kind: .mesh,
                    closedAt: pane.closedAt ?? 0
                )
            }
            return nil
        }.sorted { lhs, rhs in
            if lhs.closedAt == rhs.closedAt { return lhs.id < rhs.id }
            return lhs.closedAt > rhs.closedAt
        }
    }

    // MARK: - Unified session cards

    func paneLayout(for projectID: String?) -> SessionPaneLayout {
        unifiedSessionCards.layout(for: projectID)
    }

    func isSurfaceVisible(_ id: String) -> Bool {
        guard let projectID = projectID(forSurface: id) else { return false }
        return unifiedSessionCards.contains(id, in: projectID)
    }

    /// Window-aware notification routing asks each model before mutating it.
    /// Terminal inventories can be shared across windows, while chats and Mesh
    /// are window-local, so the delegate prefers a visible owner first.
    func containsAttentionTarget(_ id: String) -> Bool {
        sessions.contains(where: { $0.id == id })
            || chats.contains(where: { $0.id == id })
            || meshes.contains(where: { mesh in
                mesh.id == id || mesh.columns.contains(where: { $0.id == id })
            })
    }

    /// Normal navigation focuses a card already in the dock; a hidden card
    /// replaces only the primary slot. Explicit "open beside" is separate.
    private func focusPane(_ id: String, projectID: String) {
        unifiedSessionCards.focus(id, in: projectID)
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    /// Opens a card from a direct UI action without making the click wait for
    /// the broker snapshot. The pane is published synchronously; terminal
    /// subscription continues in the background and fills the visible card.
    func revealSurfaceBeside(_ id: String) {
        guard prepareSurfaceBeside(id) else { return }
        Task { [weak self] in
            await self?.subscribeSplit(id)
        }
    }

    func openSurfaceBeside(_ id: String) async {
        guard prepareSurfaceBeside(id) else { return }
        await subscribeSplit(id)
    }

    /// Returns whether the newly visible card needs a secondary terminal
    /// observer. Keeping this mutation synchronous makes the sidebar control
    /// feel immediate even when the broker must restore a large scrollback.
    private func prepareSurfaceBeside(_ id: String) -> Bool {
        guard let projectID = projectID(forSurface: id) else { return false }
        let isTerminal = sessions.contains(where: { $0.id == id })
        if isTerminal {
            splitIntentTokens[id] = UUID()
        }
        unifiedSessionCards.revealBeside(id, in: projectID)
        focusSurfaceFields(id)
        requestSurfaceKeyboardFocus(id)
        // Opening a card beside the current one is a visit, exactly like
        // selecting it, so the inbox entry it was carrying must not survive.
        acknowledgeAttention(forSurface: id)
        scheduleWorkspaceStateSave(projectID: projectID)
        // Publish the layout intent before subscribing. `subscribeSplit`
        // deliberately rejects a result for a card that is no longer visible,
        // so doing this in the opposite order makes a fresh card cancel itself.
        return isTerminal
            && id != selectedSessionID
            && splitDocuments[id] == nil
    }

    func placeSurface(_ id: String, relativeTo targetID: String, edge: SessionPaneLayout.Edge) {
        guard let projectID = projectID(forSurface: targetID),
              self.projectID(forSurface: id) == projectID else { return }
        unifiedSessionCards.place(id, relativeTo: targetID, edge: edge, in: projectID)
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    func resizePaneColumns(projectID: String, boundary: Int, delta: Double, minimumWeight: Double) {
        unifiedSessionCards.resizeColumns(
            in: projectID,
            boundary: boundary,
            delta: delta,
            minimumWeight: minimumWeight
        )
    }

    func resizePaneRows(
        projectID: String,
        columnID: String,
        boundary: Int,
        delta: Double,
        minimumWeight: Double
    ) {
        unifiedSessionCards.resizeRows(
            in: projectID,
            columnID: columnID,
            boundary: boundary,
            delta: delta,
            minimumWeight: minimumWeight
        )
    }

    func finishPaneResize(projectID: String) {
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    func resetPaneColumns(projectID: String) {
        unifiedSessionCards.resetColumns(in: projectID)
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    func resetPaneRows(projectID: String, columnID: String) {
        unifiedSessionCards.resetRows(in: projectID, columnID: columnID)
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    func toggleMaximizeSurface(_ id: String) {
        unifiedSessionCards.toggleMaximize(id)
    }

    func minimizeSurface(_ id: String) async {
        guard let projectID = projectID(forSurface: id),
              paneLayouts[projectID] != nil else { return }
        if sessions.contains(where: { $0.id == id }) {
            splitIntentTokens[id] = UUID()
        }
        guard let layout = unifiedSessionCards.remove(id, from: projectID) else { return }
        if sessions.contains(where: { $0.id == id }), id != selectedSessionID {
            await unsubscribeSplit(id)
        }
        if selectedChatID == id { selectedChatID = nil }
        if selectedMeshID == id { selectedMeshID = nil }
        if selectedSessionID == id {
            if let replacement = layout.sessionIDs.first(where: { candidate in
                sessions.contains(where: { $0.id == candidate })
            }) {
                await focusTerminalSurface(replacement)
            } else {
                await select(nil)
                if let focusedPaneID { focusSurfaceFields(focusedPaneID) }
            }
        }
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    private func projectID(forSurface id: String) -> String? {
        sessions.first(where: { $0.id == id }).map { displayProjectID($0) }
            ?? chats.first(where: { $0.id == id })?.projectID
            ?? meshes.first(where: { $0.id == id })?.projectID
    }

    /// The project a terminal is *shown* in: the adoption overlay's answer,
    /// falling back to the broker's real project. Presentation-only — see
    /// `sessionAdoptions`.
    func displayProjectID(_ record: BrokerTerminalRecord) -> String {
        sessionAdoptions[record.id] ?? record.projectID
    }

    /// Show a terminal in another open project — or return it home when
    /// `projectID` is its real project. The broker keeps believing the
    /// terminal lives where it always did (its identity encodes that); only
    /// what the user *sees* moves: sidebar grouping, pane layouts, and the
    /// adopting project's persisted workspace state, which records the pane
    /// under its own id so restoration keeps it.
    func moveTerminal(_ terminalID: String, toProject projectID: String) {
        guard let record = sessions.first(where: { $0.id == terminalID }) else { return }
        let store = adoptionStore
        let previousDisplay = displayProjectID(record)
        guard previousDisplay != projectID else { return }
        if projectID == record.projectID {
            store.clear(terminalID: terminalID)
            sessionAdoptions.removeValue(forKey: terminalID)
        } else {
            guard store.adopt(terminalID: terminalID, into: projectID) else {
                ToastCenter.shared.show(
                    "Too many moved terminals. Return one home first.",
                    style: .error
                )
                return
            }
            sessionAdoptions[terminalID] = projectID
        }
        unifiedSessionCards.move(terminalID, from: previousDisplay, to: projectID)
        if let project = projects.first(where: { $0.id == projectID }) {
            selectedProjectID = project.id
            selectedProjectName = project.name
        }
        focusPane(terminalID, projectID: projectID)
        scheduleWorkspaceStateSave(projectID: previousDisplay)
        scheduleWorkspaceStateSave(projectID: projectID)
        let destination = projects.first(where: { $0.id == projectID })?.name ?? "that project"
        ToastCenter.shared.show(
            projectID == record.projectID
                ? "Returned to \(destination)."
                : "Moved to \(destination). The terminal keeps running exactly where it was.",
            style: .success
        )
    }

    /// Retire a surface's needs-you state because the user just visited it. A
    /// terminal that is showing a broker completion is *acknowledged* rather
    /// than merely cleared, so a relaunch cannot resurrect that same
    /// completion; every other surface just drops its inbox entries.
    private func acknowledgeAttention(forSurface id: String) {
        if case let .responded(completedAt) = sessions.first(where: { $0.id == id })?.agentActivity {
            attentionCenter.acknowledgeSessionResponse(targetID: id, completedAt: completedAt)
        } else {
            attentionCenter.clear(targetID: id)
        }
    }

    private func focusSurfaceFields(_ id: String) {
        if chats.contains(where: { $0.id == id }) {
            selectedChatID = id
            selectedMeshID = nil
        } else if meshes.contains(where: { $0.id == id }) {
            selectedMeshID = id
            selectedChatID = nil
        } else if sessions.contains(where: { $0.id == id }) {
            selectedChatID = nil
            selectedMeshID = nil
        }
    }

    /// Publish a fresh request even when the same pane is selected twice. Chat
    /// and Mesh consume the generation through SwiftUI `FocusState`; terminals
    /// keep their AppKit first-responder bridge.
    private func requestSurfaceKeyboardFocus(_ id: String) {
        unifiedSessionCards.requestKeyboardFocus(for: id)
        if sessions.contains(where: { $0.id == id }) {
            TerminalKeyboardFocus.moveFirstResponder(toSessionID: id)
        }
    }

    func focusSurface(_ id: String) async {
        if sessions.contains(where: { $0.id == id }) {
            await focusTerminalSurface(id)
            requestSurfaceKeyboardFocus(id)
        } else if chats.contains(where: { $0.id == id }) {
            selectChat(id)
        } else if meshes.contains(where: { $0.id == id }) {
            selectMesh(id)
        }
    }

    /// AppKit moved keyboard focus into a surface (a click into its terminal).
    /// Route it through the same promotion the pane header performs so the two
    /// entry points cannot drift apart; the guard makes repeat clicks free.
    func focusSurfaceFromKeyboard(_ id: String) {
        guard focusedPaneID != id, isSurfaceVisible(id) else { return }
        Task { await focusSurface(id) }
    }

    /// Move pane focus to the next or previous visible surface in the active
    /// project (View > Focus, Control-Command-Left/Right).
    func cyclePaneFocus(forward: Bool) {
        guard let projectID = selectedProjectID,
              let layout = paneLayouts[projectID],
              let target = PaneFocusCycle.target(
                  after: focusedPaneID,
                  in: layout.sessionIDs,
                  forward: forward
              ) else { return }
        Task { await focusSurface(target) }
    }

    /// Whether a keyboard focus move has anywhere to go, so the menu items can
    /// disable themselves instead of looking broken.
    var canCyclePaneFocus: Bool {
        guard let projectID = selectedProjectID else { return false }
        return (paneLayouts[projectID]?.sessionIDs.count ?? 0) > 1
    }

    /// Promote a visible secondary terminal without dropping the old primary
    /// from the live dock. The old primary is re-subscribed as a secondary only
    /// when its card is still present in the user's layout.
    private func focusTerminalSurface(_ id: String) async {
        guard let record = sessions.first(where: { $0.id == id }) else { return }
        // Primary and secondary observers share one owner-scoped broker slot.
        // Publish the primary-role epoch before any unsubscribe can suspend so
        // a stale split cleanup knows it must repair the winning primary.
        splitIntentTokens[id] = UUID()
        let previousID = selectedSessionID
        let previousProjectID = previousID.flatMap { projectID(forSurface: $0) }
        // Preserve the visible split snapshot before changing its broker role.
        // The unified card resolves this retained document while unsubscribe /
        // subscribe work is in flight, so focusing B in an A+B layout never
        // produces an empty frame or reconstructs B's SwiftTerm view.
        if let splitDocument = splitDocuments[id] {
            retainTerminalSurfaceDocument(splitDocument)
        }
        // Also cancels an in-flight secondary subscribe, even before a split
        // document has arrived. Selection then installs the primary observer.
        await unsubscribeSplit(id)
        await select(id)
        if let previousID,
           previousID != id,
           previousProjectID == record.projectID,
           paneLayouts[record.projectID]?.contains(previousID) == true,
           splitDocuments[previousID] == nil {
            await subscribeSplit(previousID)
        }
        focusPane(id, projectID: record.projectID)
    }

    /// Switch the top-level workspace context by stable id, then restore a real
    /// surface inside it. A project click is therefore an action, not a label
    /// highlight that leaves another project's terminal visible underneath.
    func activateProject(id: String?) {
        guard let id, let project = projects.first(where: { $0.id == id }) else {
            selectedProjectID = nil
            selectedProjectName = nil
            Task { try? await workspaceStateStore.setSelectedProjectID(nil) }
            return
        }
        selectedProjectID = project.id
        selectedProjectName = project.name
        Task { try? await workspaceStateStore.setSelectedProjectID(project.id) }

        // A broker terminal can finish between the last workspace snapshot and
        // this project click. Remove only ids that have no live terminal, chat,
        // or Mesh backing before the grid renders them; otherwise the persisted
        // geometry becomes a large, inert "Session unavailable" card.
        reconcilePaneLayoutWithAvailableSurfaces(for: project.id, persist: true)

        let visibleIDs = Set(paneLayouts[project.id]?.sessionIDs ?? [])
        let selectedChatBelongsHere = selectedChatID.map { selected in
            visibleIDs.contains(selected)
                && chats.first(where: { $0.id == selected })?.projectID == project.id
        } ?? false
        let selectedMeshBelongsHere = selectedMeshID.map { selected in
            visibleIDs.contains(selected)
                && meshes.first(where: { $0.id == selected })?.projectID == project.id
        } ?? false
        let selectedTerminalBelongsHere = selectedSessionID.map { selected in
            visibleIDs.contains(selected)
                && sessions.first(where: { $0.id == selected }).map { self.displayProjectID($0) } == project.id
        } ?? false
        guard !selectedChatBelongsHere, !selectedMeshBelongsHere, !selectedTerminalBelongsHere else { return }

        if let paneID = paneLayouts[project.id]?.sessionIDs.first,
           projectID(forSurface: paneID) == project.id {
            if chats.contains(where: { $0.id == paneID }) {
                selectChat(paneID)
            } else if meshes.contains(where: { $0.id == paneID }) {
                selectMesh(paneID)
            } else {
                Task { await focusSurface(paneID) }
            }
            return
        }

        if let terminal = project.sessions.first(where: { !$0.exited }) ?? project.sessions.first {
            Task { await select(terminal.id) }
        } else if let chat = chats(in: project.id).first {
            selectChat(chat.id)
        } else if let mesh = meshes(in: project.id).first {
            selectMesh(mesh.id)
        } else {
            Task { await select(nil) }
        }
    }

    /// Reconcile persisted pane geometry against the authoritative live
    /// surfaces for one project. Missing broker terminals are removed from the
    /// visible layout only; NativeSessionStore's ownership registry remains
    /// untouched so a terminal belonging to a draining broker is never claimed
    /// or destroyed by this UI repair.
    @discardableResult
    private func reconcilePaneLayoutWithAvailableSurfaces(
        for projectID: String,
        persist: Bool
    ) -> Bool {
        // Dormant terminals stay: their PTYs died with the broker, but the
        // panes are resurrection targets, not garbage.
        let available = Set(
            sessions.lazy.filter { self.displayProjectID($0) == projectID }.map(\.id)
        ).union(chats(in: projectID).map(\.id))
            .union(meshes(in: projectID).map(\.id))
            .union(dormantTerminalIDs(in: projectID))
        guard unifiedSessionCards.reconcile(
            projectID,
            availableSurfaceIDs: available
        ) else { return false }
        if persist { scheduleWorkspaceStateSave(projectID: projectID) }
        return true
    }

    private func reconcileAllPaneLayoutsWithAvailableSurfaces() {
        for projectID in Array(paneLayouts.keys) {
            reconcilePaneLayoutWithAvailableSurfaces(for: projectID, persist: true)
        }
        // The broker inventory that triggered this reconcile is authoritative
        // about which terminals still exist, so tokens for the others are
        // ordinarily dead weight the window would otherwise keep forever.
        //
        // "Ordinarily" is doing real work here. A token is also the fence a
        // *suspended* split operation re-reads when it wakes: `unsubscribeSplit`
        // captures it, awaits the cursor write, then compares. Pruning purely on
        // the inventory let a tick during that await nil the token, so the
        // comparison read "superseded", the early return skipped the teardown,
        // and the card's document plus its slot in `splitOrder` stayed occupied
        // until the next reconnect. In-flight subscribes and retained split
        // documents outlive the inventory, so they keep their token alive.
        splitIntentTokens = SurfaceBookkeeping.pruned(
            splitIntentTokens,
            keeping: Set(sessions.map(\.id))
                .union(pendingSplitSubscriptions.keys)
                .union(splitDocuments.keys)
        )
    }

    /// Name-based compatibility for saved-window state and older callers.
    func activateProject(named name: String?) {
        guard let name else { activateProject(id: nil); return }
        if let project = projects.first(where: { $0.name == name }) {
            activateProject(id: project.id)
        } else {
            selectedProjectID = nil
            selectedProjectName = name
        }
    }

    func setProjectColor(id: String, colorHex: String?) {
        sessionStore.setProjectColor(id: id, colorHex: colorHex)
        refreshPersistedNavigationState()
    }

    func fileTabs(for projectID: String?) -> [FileWorkbenchTab] {
        guard let projectID else { return [] }
        return fileTabsByProject[projectID] ?? []
    }

    /// Single-click opens one replaceable preview tab. Kept tabs are never
    /// displaced; pinning (or opening with `pinned`) promotes the document into
    /// the durable ordered deck.
    func openFilePreview(
        _ url: URL,
        line: Int? = nil,
        pinned: Bool = false,
        workspaceHint: URL? = nil
    ) {
        let normalized = url.standardizedFileURL
        var resolvedContext = fileProjectContext(for: normalized)
        if resolvedContext == nil,
           let workspaceHint,
           let inferredRoot = Self.inferredProjectRoot(
               for: normalized,
               workspaceHint: workspaceHint
           ) {
            openProject(directory: inferredRoot)
            resolvedContext = fileProjectContext(for: normalized)
        }
        guard let context = resolvedContext else {
            // File links from an observed terminal may not have a known local
            // project root. Retain the safe legacy preview behavior for them.
            previewedFileLine = line
            previewedFileURL = normalized
            browserCardURL = nil
            return
        }
        if selectedProjectID != context.projectID {
            // A file link/palette result from another already-open project must
            // move the whole workspace context with it. Rendering that URL
            // under the previous project's asset root breaks relative links
            // and can make the editor's rollback cross project boundaries.
            activateProject(id: context.projectID)
        }
        recentlyClosedFileTabsByProject[context.projectID]?.removeAll {
            $0.url.standardizedFileURL == normalized
        }
        var tabs = fileTabsByProject[context.projectID] ?? []
        let alreadyOpen = tabs.contains { $0.url.standardizedFileURL == normalized }
        if !alreadyOpen,
           tabs.count >= NativeWorkspaceStateStore.maximumFileTabsPerProject,
           !tabs.contains(where: { !$0.isPinned }) {
            ToastCenter.shared.show(
                "Keep fewer than \(NativeWorkspaceStateStore.maximumFileTabsPerProject) documents open.",
                style: .info
            )
            return
        }
        beginFileNavigation(projectID: context.projectID, target: normalized)
        if let index = tabs.firstIndex(where: { $0.url.standardizedFileURL == normalized }) {
            tabs[index].isPinned = tabs[index].isPinned || pinned
            if let line { tabs[index].line = line }
        } else {
            let tab = FileWorkbenchTab(url: normalized, isPinned: pinned, line: line)
            if !pinned, let transient = tabs.firstIndex(where: { !$0.isPinned }) {
                tabs[transient] = tab
            } else {
                if tabs.count >= NativeWorkspaceStateStore.maximumFileTabsPerProject {
                    guard let transient = tabs.firstIndex(where: { !$0.isPinned }) else { return }
                    tabs.remove(at: transient)
                }
                tabs.append(tab)
            }
        }
        fileTabsByProject[context.projectID] = tabs
        selectedFilePathByProject[context.projectID] = normalized.path
        previewedFileLine = line
        previewedFileURL = normalized
        browserCardURL = nil
    }

    private func recordAgentFileActivity(
        _ activity: AcpFileActivity,
        surfaceID: String,
        projectID: String,
        workspaceRoot: URL
    ) -> Bool {
        guard let fileURL = WorkspaceAgentFileFollowPolicy.resolve(
            path: activity.path,
            workspaceRoot: workspaceRoot
        ) else { return false }
        agentFileActivitySequence &+= 1
        latestAgentFileActivity = WorkspaceAgentFileActivity(
            sequence: agentFileActivitySequence,
            projectID: projectID,
            surfaceID: surfaceID,
            fileURL: fileURL
        )
        return true
    }

    func selectFileTab(_ url: URL) {
        guard let context = fileProjectContext(for: url),
              let tab = fileTabsByProject[context.projectID]?.first(where: {
                  $0.url.standardizedFileURL == url.standardizedFileURL
              }) else { return }
        beginFileNavigation(projectID: context.projectID, target: tab.url)
        selectedFilePathByProject[context.projectID] = tab.url.path
        previewedFileURL = tab.url
        previewedFileLine = tab.line
        browserCardURL = nil
    }

    /// Move through the selected project's ordered editor deck without
    /// exposing terminal input to arrow-key escape sequences. The deck wraps,
    /// matching the direct previous/next-editor commands in desktop IDEs.
    @discardableResult
    func selectAdjacentFileTab(direction: Int) -> Bool {
        guard direction != 0,
              let projectID = selectedProjectID,
              let tabs = fileTabsByProject[projectID],
              tabs.count > 1 else { return false }
        let selectedPath = selectedFilePathByProject[projectID]
            ?? previewedFileURL?.standardizedFileURL.path
        guard let currentIndex = tabs.firstIndex(where: {
            $0.url.standardizedFileURL.path == selectedPath
        }) else { return false }
        let step = direction > 0 ? 1 : -1
        let nextIndex = (currentIndex + step + tabs.count) % tabs.count
        selectFileTab(tabs[nextIndex].url)
        return true
    }

    private func beginFileNavigation(projectID: String, target: URL) {
        guard previewedFileURL?.standardizedFileURL != target.standardizedFileURL,
              fileNavigationRollbacks[projectID] == nil else { return }
        fileNavigationRollbacks[projectID] = FileNavigationRollback(
            tabs: fileTabsByProject[projectID] ?? [],
            selectedPath: selectedFilePathByProject[projectID],
            visibleURL: previewedFileURL,
            visibleLine: previewedFileLine
        )
    }

    func commitFileNavigation(_ url: URL) {
        guard let context = fileProjectContext(for: url),
              selectedFilePathByProject[context.projectID] == url.standardizedFileURL.path else { return }
        fileNavigationRollbacks[context.projectID] = nil
        scheduleWorkspaceStateSave(projectID: context.projectID)
    }

    func cancelFileNavigation(restoring fallback: URL) {
        guard let context = fileProjectContext(for: fallback),
              let rollback = fileNavigationRollbacks.removeValue(forKey: context.projectID) else {
            // No pending model navigation means the view is already the source
            // of truth. Restore only inside the selected project and never
            // create another rollback while handling Cancel.
            guard let context = fileProjectContext(for: fallback),
                  selectedProjectID == context.projectID,
                  let tab = fileTabsByProject[context.projectID]?.first(where: {
                      $0.url.standardizedFileURL == fallback.standardizedFileURL
                  }) else { return }
            selectedFilePathByProject[context.projectID] = tab.url.path
            previewedFileURL = tab.url
            previewedFileLine = tab.line
            return
        }
        fileTabsByProject[context.projectID] = rollback.tabs
        selectedFilePathByProject[context.projectID] = rollback.selectedPath
        previewedFileURL = rollback.visibleURL ?? fallback.standardizedFileURL
        previewedFileLine = rollback.visibleLine
    }

    func setFileTabPinned(_ url: URL, pinned: Bool) {
        guard let context = fileProjectContext(for: url),
              var tabs = fileTabsByProject[context.projectID],
              let index = tabs.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
            return
        }
        tabs[index].isPinned = pinned
        if !pinned {
            for other in tabs.indices where other != index && !tabs[other].isPinned {
                tabs[other].isPinned = true
            }
        }
        fileTabsByProject[context.projectID] = tabs
        scheduleWorkspaceStateSave(projectID: context.projectID)
    }

    func closeFileTab(_ url: URL) {
        guard let context = fileProjectContext(for: url),
              var tabs = fileTabsByProject[context.projectID],
              let index = tabs.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else {
            return
        }
        let closedTab = tabs[index]
        let closingSelected = selectedFilePathByProject[context.projectID] == closedTab.url.path
        var recentlyClosed = recentlyClosedFileTabsByProject[context.projectID] ?? []
        recentlyClosed.removeAll {
            $0.url.standardizedFileURL == closedTab.url.standardizedFileURL
        }
        recentlyClosed.append(closedTab)
        if recentlyClosed.count > Self.maximumRecentlyClosedFileTabs {
            recentlyClosed.removeFirst(recentlyClosed.count - Self.maximumRecentlyClosedFileTabs)
        }
        recentlyClosedFileTabsByProject[context.projectID] = recentlyClosed
        tabs.remove(at: index)
        fileTabsByProject[context.projectID] = tabs
        if closingSelected {
            let neighbor = tabs.indices.contains(index) ? tabs[index] : tabs.last
            selectedFilePathByProject[context.projectID] = neighbor?.url.path
            if selectedProjectID == context.projectID {
                previewedFileURL = neighbor?.url
                previewedFileLine = neighbor?.line
            }
        }
        scheduleWorkspaceStateSave(projectID: context.projectID)
    }

    var canReopenClosedFileTab: Bool {
        guard let projectID = selectedProjectID,
              let root = projects.first(where: { $0.id == projectID })?.directory else { return false }
        let openURLs = Set((fileTabsByProject[projectID] ?? []).map { $0.url.standardizedFileURL })
        return (recentlyClosedFileTabsByProject[projectID] ?? []).reversed().contains { tab in
            let url = tab.url.standardizedFileURL
            return Self.isWithinWorkspace(url, workspace: root)
                && FileManager.default.fileExists(atPath: url.path)
                && !openURLs.contains(url)
        }
    }

    /// Reopen the newest still-valid editor in the active project. Stale or
    /// already-open entries are consumed, and the restored editor is kept open
    /// so it cannot immediately displace another transient preview.
    @discardableResult
    func reopenClosedFileTab() -> Bool {
        guard let projectID = selectedProjectID,
              let root = projects.first(where: { $0.id == projectID })?.directory else { return false }
        var recentlyClosed = recentlyClosedFileTabsByProject[projectID] ?? []
        let openURLs = Set((fileTabsByProject[projectID] ?? []).map { $0.url.standardizedFileURL })
        while let tab = recentlyClosed.popLast() {
            let url = tab.url.standardizedFileURL
            guard Self.isWithinWorkspace(url, workspace: root),
                  FileManager.default.fileExists(atPath: url.path),
                  !openURLs.contains(url) else { continue }
            recentlyClosedFileTabsByProject[projectID] = recentlyClosed
            openFilePreview(url, line: tab.line, pinned: true)
            return previewedFileURL?.standardizedFileURL == url
        }
        recentlyClosedFileTabsByProject[projectID] = []
        return false
    }

    func closeFilePreview() {
        guard let previewedFileURL,
              fileProjectContext(for: previewedFileURL) != nil else {
            self.previewedFileURL = nil
            previewedFileLine = nil
            return
        }
        closeFileTab(previewedFileURL)
    }

    /// Rebase every open-document reference after a workspace file or folder
    /// rename. The filesystem operation happens first; this method then makes
    /// the in-memory deck and its durable snapshot agree atomically.
    func reconcileWorkspaceFileMove(from source: URL, to destination: URL) {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard let context = fileProjectContext(for: source),
              Self.isWithinWorkspace(destination, workspace: context.root) else { return }

        func moved(_ url: URL?) -> URL? {
            guard let url else { return nil }
            return WorkspaceFileOperations.replacingPrefix(
                of: url,
                from: source,
                to: destination
            ) ?? url.standardizedFileURL
        }

        fileTabsByProject[context.projectID] = (fileTabsByProject[context.projectID] ?? []).map { tab in
            FileWorkbenchTab(
                url: moved(tab.url) ?? tab.url,
                isPinned: tab.isPinned,
                line: tab.line
            )
        }
        recentlyClosedFileTabsByProject[context.projectID] = (
            recentlyClosedFileTabsByProject[context.projectID] ?? []
        ).map { tab in
            FileWorkbenchTab(
                url: moved(tab.url) ?? tab.url,
                isPinned: tab.isPinned,
                line: tab.line
            )
        }
        if let selected = selectedFilePathByProject[context.projectID] {
            selectedFilePathByProject[context.projectID] = moved(URL(fileURLWithPath: selected))?.path
        }
        if let rollback = fileNavigationRollbacks[context.projectID] {
            fileNavigationRollbacks[context.projectID] = FileNavigationRollback(
                tabs: rollback.tabs.map { tab in
                    FileWorkbenchTab(
                        url: moved(tab.url) ?? tab.url,
                        isPinned: tab.isPinned,
                        line: tab.line
                    )
                },
                selectedPath: rollback.selectedPath.flatMap {
                    moved(URL(fileURLWithPath: $0))?.path
                },
                visibleURL: moved(rollback.visibleURL),
                visibleLine: rollback.visibleLine
            )
        }
        previewedFileURL = moved(previewedFileURL)
        lastPreviewedFileURL = moved(lastPreviewedFileURL)
        scheduleWorkspaceStateSave(projectID: context.projectID)
    }

    /// Remove documents beneath a file/folder that has been moved to Trash.
    /// The nearest surviving tab becomes active, mirroring ordinary tab close.
    @discardableResult
    func reconcileWorkspaceFileRemoval(_ removedItem: URL) -> WorkspaceFileRemovalSnapshot? {
        let removedItem = removedItem.standardizedFileURL
        guard let context = fileProjectContext(for: removedItem) else { return nil }
        let previousTabs = fileTabsByProject[context.projectID] ?? []
        let removedTabs = previousTabs.enumerated().compactMap { index, tab in
            WorkspaceFileOperations.contains(tab.url, in: removedItem)
                ? WorkspaceFileRemovalSnapshot.IndexedTab(index: index, tab: tab)
                : nil
        }
        let priorSelectedPath = selectedFilePathByProject[context.projectID]
        let priorVisibleURL = previewedFileURL
        let priorVisibleLine = previewedFileLine
        let priorLastVisibleURL = lastPreviewedFileURL
        let snapshot = WorkspaceFileRemovalSnapshot(
            projectID: context.projectID,
            removedTabs: removedTabs,
            selectedPath: priorSelectedPath.flatMap { path in
                WorkspaceFileOperations.contains(URL(fileURLWithPath: path), in: removedItem)
                    ? path
                    : nil
            },
            visibleURL: priorVisibleURL.flatMap {
                WorkspaceFileOperations.contains($0, in: removedItem) ? $0 : nil
            },
            visibleLine: priorVisibleURL.map {
                WorkspaceFileOperations.contains($0, in: removedItem)
            } == true ? priorVisibleLine : nil,
            lastVisibleURL: priorLastVisibleURL.flatMap {
                WorkspaceFileOperations.contains($0, in: removedItem) ? $0 : nil
            }
        )
        let removedSelectedIndex = previousTabs.firstIndex {
            WorkspaceFileOperations.contains($0.url, in: removedItem)
                && $0.url.path == selectedFilePathByProject[context.projectID]
        }
        let remainingTabs = previousTabs.filter {
            !WorkspaceFileOperations.contains($0.url, in: removedItem)
        }
        fileTabsByProject[context.projectID] = remainingTabs

        let selectedWasRemoved = selectedFilePathByProject[context.projectID].map {
            WorkspaceFileOperations.contains(URL(fileURLWithPath: $0), in: removedItem)
        } ?? false
        if selectedWasRemoved {
            let fallbackIndex = min(removedSelectedIndex ?? remainingTabs.count, max(remainingTabs.count - 1, 0))
            let fallback = remainingTabs.indices.contains(fallbackIndex) ? remainingTabs[fallbackIndex] : remainingTabs.last
            selectedFilePathByProject[context.projectID] = fallback?.url.path
            if selectedProjectID == context.projectID {
                previewedFileURL = fallback?.url
                previewedFileLine = fallback?.line
            }
        } else if let previewedFileURL,
                  WorkspaceFileOperations.contains(previewedFileURL, in: removedItem) {
            self.previewedFileURL = nil
            previewedFileLine = nil
        }
        if let lastPreviewedFileURL,
           WorkspaceFileOperations.contains(lastPreviewedFileURL, in: removedItem) {
            self.lastPreviewedFileURL = nil
        }
        // A rollback may contain the removed path and must never resurrect it.
        fileNavigationRollbacks[context.projectID] = nil
        scheduleWorkspaceStateSave(projectID: context.projectID)
        return snapshot
    }

    /// Merge a restored file/folder's tabs back into the current deck without
    /// discarding documents opened while the item was in Trash.
    func restoreWorkspaceFileRemoval(_ snapshot: WorkspaceFileRemovalSnapshot?) {
        guard let snapshot,
              let root = projects.first(where: { $0.id == snapshot.projectID })?.directory else { return }
        var tabs = fileTabsByProject[snapshot.projectID] ?? []
        for entry in snapshot.removedTabs.sorted(by: { $0.index < $1.index }) {
            let url = entry.tab.url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  Self.isWithinWorkspace(url, workspace: root),
                  !tabs.contains(where: { $0.url.standardizedFileURL == url }) else { continue }
            tabs.insert(entry.tab, at: min(entry.index, tabs.count))
        }
        fileTabsByProject[snapshot.projectID] = tabs

        if let selectedPath = snapshot.selectedPath,
           FileManager.default.fileExists(atPath: selectedPath),
           tabs.contains(where: { $0.url.path == selectedPath }) {
            selectedFilePathByProject[snapshot.projectID] = selectedPath
        }
        if selectedProjectID == snapshot.projectID,
           let visibleURL = snapshot.visibleURL,
           FileManager.default.fileExists(atPath: visibleURL.path) {
            previewedFileURL = visibleURL
            previewedFileLine = snapshot.visibleLine
        }
        if let lastVisibleURL = snapshot.lastVisibleURL,
           FileManager.default.fileExists(atPath: lastVisibleURL.path) {
            lastPreviewedFileURL = lastVisibleURL
        }
        fileNavigationRollbacks[snapshot.projectID] = nil
        scheduleWorkspaceStateSave(projectID: snapshot.projectID)
    }

    func registerWorkspaceMoveUndo(
        _ move: WorkspaceFileOperations.Move,
        workspaceRoot: URL,
        undoManager: UndoManager?
    ) {
        let actionName = move.source.deletingLastPathComponent().standardizedFileURL
            == move.destination.deletingLastPathComponent().standardizedFileURL
            ? "Rename"
            : "Move"
        registerWorkspaceMoveAction(
            from: move.destination,
            to: move.source,
            workspaceRoot: workspaceRoot,
            undoManager: undoManager,
            actionName: actionName
        )
    }

    func registerWorkspaceTrashUndo(
        _ move: WorkspaceFileOperations.TrashMove,
        removalSnapshot: WorkspaceFileRemovalSnapshot?,
        workspaceRoot: URL,
        undoManager: UndoManager?
    ) {
        let transaction = WorkspaceTrashUndoTransaction(
            original: move.original,
            root: workspaceRoot,
            actionName: "Move to Trash",
            move: move,
            removalSnapshot: removalSnapshot
        )
        registerWorkspaceRestoreAction(transaction, undoManager: undoManager)
    }

    func registerWorkspaceCreationUndo(
        _ created: WorkspaceFileOperations.CreatedItem,
        workspaceRoot: URL,
        undoManager: UndoManager?
    ) {
        let actionName = created.kind == .file ? "Create File" : "Create Folder"
        let transaction = WorkspaceTrashUndoTransaction(
            original: created.url,
            root: workspaceRoot,
            actionName: actionName
        )
        registerWorkspaceTrashAction(transaction, undoManager: undoManager)
    }

    private func registerWorkspaceMoveAction(
        from source: URL,
        to destination: URL,
        workspaceRoot: URL,
        undoManager: UndoManager?,
        actionName: String
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            guard let undoManager else { return }
            MainActor.assumeIsolated {
                model.performWorkspaceMoveAction(
                    from: source,
                    to: destination,
                    workspaceRoot: workspaceRoot,
                    undoManager: undoManager,
                    actionName: actionName
                )
            }
        }
        undoManager.setActionName(actionName)
    }

    private func performWorkspaceMoveAction(
        from source: URL,
        to destination: URL,
        workspaceRoot: URL,
        undoManager: UndoManager,
        actionName: String
    ) {
        registerWorkspaceMoveAction(
            from: destination,
            to: source,
            workspaceRoot: workspaceRoot,
            undoManager: undoManager,
            actionName: actionName
        )
        guard prepareWorkspaceFileMutation(source) else { return }
        Task {
            do {
                let move = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.move(
                        item: source,
                        to: destination,
                        workspaceRoot: workspaceRoot
                    )
                }.value
                reconcileWorkspaceFileMove(from: move.source, to: move.destination)
                ProjectFileIndex.shared.invalidate(
                    root: workspaceRoot,
                    changedPaths: [move.source, move.destination],
                    requiresFullRefresh: false
                )
                let message = actionName == "Rename"
                    ? "Renamed to \(destination.lastPathComponent)"
                    : "Moved \(destination.lastPathComponent)"
                ToastCenter.shared.show(message, style: .success)
            } catch {
                showWorkspaceMutationError(error, action: actionName.lowercased())
            }
        }
    }

    private func registerWorkspaceTrashAction(
        _ transaction: WorkspaceTrashUndoTransaction,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            guard let undoManager else { return }
            MainActor.assumeIsolated {
                model.performWorkspaceTrashAction(transaction, undoManager: undoManager)
            }
        }
        undoManager.setActionName(transaction.actionName)
    }

    private func performWorkspaceTrashAction(
        _ transaction: WorkspaceTrashUndoTransaction,
        undoManager: UndoManager
    ) {
        registerWorkspaceRestoreAction(transaction, undoManager: undoManager)
        guard !transaction.isBusy, prepareWorkspaceFileMutation(transaction.original) else { return }
        transaction.isBusy = true
        let original = transaction.original
        let root = transaction.root
        Task {
            defer { transaction.isBusy = false }
            do {
                let move = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.moveToTrash(
                        item: original,
                        workspaceRoot: root
                    )
                }.value
                transaction.move = move
                transaction.removalSnapshot = reconcileWorkspaceFileRemoval(transaction.original)
                ProjectFileIndex.shared.invalidate(root: root)
                ToastCenter.shared.show("Moved \(transaction.original.lastPathComponent) to Trash", style: .success)
            } catch {
                showWorkspaceMutationError(error, action: "move to Trash")
            }
        }
    }

    private func registerWorkspaceRestoreAction(
        _ transaction: WorkspaceTrashUndoTransaction,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            guard let undoManager else { return }
            MainActor.assumeIsolated {
                model.performWorkspaceRestoreAction(transaction, undoManager: undoManager)
            }
        }
        undoManager.setActionName(transaction.actionName)
    }

    private func performWorkspaceRestoreAction(
        _ transaction: WorkspaceTrashUndoTransaction,
        undoManager: UndoManager
    ) {
        registerWorkspaceTrashAction(transaction, undoManager: undoManager)
        guard !transaction.isBusy, let move = transaction.move else { return }
        transaction.isBusy = true
        let root = transaction.root
        Task {
            defer { transaction.isBusy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.restoreFromTrash(move, workspaceRoot: root)
                }.value
                restoreWorkspaceFileRemoval(transaction.removalSnapshot)
                ProjectFileIndex.shared.invalidate(root: root)
                ToastCenter.shared.show("Restored \(transaction.original.lastPathComponent)", style: .success)
            } catch {
                showWorkspaceMutationError(error, action: "restore")
            }
        }
    }

    private func prepareWorkspaceFileMutation(_ item: URL) -> Bool {
        let request = WorkspaceFileMutationBarrierRequest(item: item)
        NotificationCenter.default.post(name: .kaisolaPrepareWorkspaceFileMutation, object: request)
        guard request.mayProceed else {
            ToastCenter.shared.show(
                "Resolve the unsaved changes in \(item.lastPathComponent) before changing it.",
                style: .error
            )
            return false
        }
        return true
    }

    private func showWorkspaceMutationError(_ error: Error, action: String) {
        ToastCenter.shared.show(
            WorkspaceFileOperations.userFacingDescription(for: error, action: action),
            style: .error,
            duration: 5
        )
    }

    func hideFilePreview() {
        previewedFileURL = nil
        previewedFileLine = nil
    }

    func openBrowserCard(_ url: URL) {
        hideFilePreview()
        selectedMeshID = nil
        browserCardURL = url
    }

    /// Returns whether a prior file could be restored. The caller opens the
    /// Files rail when there is no prior selection, making the control useful
    /// from a completely fresh workspace too.
    @discardableResult
    func toggleFilePreview() -> Bool {
        if previewedFileURL != nil {
            hideFilePreview()
            return true
        }
        let selectedTab = selectedProjectID.flatMap { projectID in
            let selected = selectedFilePathByProject[projectID]
            return fileTabsByProject[projectID]?.first(where: { $0.url.path == selected })
        }
        let candidate = selectedTab?.url ?? lastPreviewedFileURL
        guard let candidate,
              FileManager.default.fileExists(atPath: candidate.path),
              let root = currentProjectDirectory,
              Self.isWithinWorkspace(candidate, workspace: root) else {
            return false
        }
        openFilePreview(candidate, line: selectedTab?.line, pinned: selectedTab?.isPinned ?? false)
        return true
    }

    private func fileProjectContext(for url: URL) -> (projectID: String, root: URL)? {
        if let selectedProjectID,
           let root = projects.first(where: { $0.id == selectedProjectID })?.directory,
           Self.isWithinWorkspace(url, workspace: root) {
            return (selectedProjectID, root)
        }
        guard let project = projects.compactMap({ project -> (ProjectGroup, URL)? in
            guard let root = project.directory,
                  Self.isWithinWorkspace(url, workspace: root) else { return nil }
            return (project, root)
        }).max(by: { $0.1.path.count < $1.1.path.count }) else { return nil }
        return (project.0.id, project.1)
    }

    private func restoreSelectedFilePreview(for projectID: String) {
        guard let selected = selectedFilePathByProject[projectID],
              let tab = fileTabsByProject[projectID]?.first(where: { $0.url.path == selected }) else {
            return
        }
        previewedFileURL = tab.url
        previewedFileLine = tab.line
    }

    private static func isWithinWorkspace(_ url: URL, workspace: URL) -> Bool {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// A user-clicked terminal citation can point into a repository that has no
    /// open project tab yet. Prefer its nearest Git root; otherwise use the
    /// terminal working directory when it contains the file, then the immediate
    /// parent. This gives the preview and Files rail one coherent workspace
    /// without granting meaning to an unclicked path printed by terminal output.
    private static func inferredProjectRoot(for file: URL, workspaceHint: URL) -> URL? {
        var isDirectory: ObjCBool = false
        let normalizedFile = file.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: normalizedFile.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }

        let parent = normalizedFile.deletingLastPathComponent()
        var ancestor = parent
        while true {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                return ancestor
            }
            let next = ancestor.deletingLastPathComponent()
            guard next.path != ancestor.path else { break }
            ancestor = next
        }

        var hintIsDirectory: ObjCBool = false
        let normalizedHint = workspaceHint.standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: normalizedHint.path, isDirectory: &hintIsDirectory),
           hintIsDirectory.boolValue,
           isWithinWorkspace(normalizedFile, workspace: normalizedHint) {
            return normalizedHint
        }
        return parent
    }

    private static func relativePath(for url: URL, workspace: URL) -> String? {
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.hasPrefix(root + "/") else { return nil }
        let relative = String(candidate.dropFirst(root.count + 1))
        guard !relative.isEmpty else { return nil }
        return relative
    }

    func moveProject(id: String, delta: Int) {
        sessionStore.moveProject(id: id, delta: delta)
        refreshPersistedNavigationState()
    }

    func moveProject(id: String, toIndex: Int) {
        sessionStore.moveProject(id: id, toIndex: toIndex)
        refreshPersistedNavigationState()
    }

    func relocateProject(id: String, to directory: URL) {
        let oldRoot = projects.first(where: { $0.id == id })?.directory
        let oldTabs = fileTabsByProject[id] ?? []
        let oldSelected = selectedFilePathByProject[id]
        let deferredState = deferredFileWorkspaceStates[id]
        let restorableTabs: [NativeRestorableFileTabState] = {
            guard let oldRoot, !oldTabs.isEmpty else { return deferredState?.fileTabs ?? [] }
            return oldTabs.compactMap { tab in
                guard let relative = Self.relativePath(for: tab.url, workspace: oldRoot) else { return nil }
                return NativeRestorableFileTabState(
                    relativePath: relative,
                    isPinned: tab.isPinned,
                    line: tab.line
                )
            }
        }()
        let restorableSelection: String? = {
            guard let oldRoot, let oldSelected else { return deferredState?.selectedFilePath }
            return Self.relativePath(for: URL(fileURLWithPath: oldSelected), workspace: oldRoot)
        }()
        if let relocated = sessionStore.relocateProject(id: id, toDirectory: directory.path) {
            refreshPersistedNavigationState(publish: false)
            fileTabsByProject[id] = nil
            selectedFilePathByProject[id] = nil
            deferredFileWorkspaceStates[id] = nil
            if !restorableTabs.isEmpty {
                restoreFileTabs(from: NativeProjectWorkspaceState(
                    projectID: relocated.id,
                    fileTabs: restorableTabs,
                    selectedFilePath: restorableSelection
                ))
            }
            Task { try? await workspaceStateStore.removeProjectState(projectID: id) }
            scheduleWorkspaceStateSave(projectID: relocated.id)
            selectedProjectID = relocated.id
            selectedProjectName = relocated.name
        }
        objectWillChange.send()
    }

    var recentFolders: [String] { sessionStore.recentFolders() }

    /// Remove a launch-history suggestion only. Open projects, files, and Git
    /// worktrees remain untouched.
    func removeRecentFolder(_ path: String) {
        sessionStore.removeRecentFolder(path)
        objectWillChange.send()
    }

    func isOwned(_ terminalID: String) -> Bool {
        ownedTerminalIDs.contains(terminalID)
    }

    func isTerminalInputDegraded(_ terminalID: String) -> Bool {
        terminalInputDegradedIDs.contains(terminalID)
    }

    func isTerminalInputRecovering(_ terminalID: String) -> Bool {
        terminalInputRecoveringIDs.contains(terminalID)
    }

    // MARK: - Project tabs

    /// Open a folder as a project tab (persists even with no sessions).
    func openProject(directory: URL) {
        let project = sessionStore.openProject(directory: directory.path)
        refreshPersistedNavigationState(publish: false)
        let deferredFileState = deferredFileWorkspaceStates.removeValue(forKey: project.id)
        selectedProjectID = project.id
        selectedProjectName = project.name
        if let deferredFileState {
            restoreFileTabs(from: deferredFileState)
            restoreSelectedFilePreview(for: project.id)
            scheduleWorkspaceStateSave(projectID: project.id)
        }
        objectWillChange.send()
    }

    func renameProject(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionStore.renameProject(id: id, name: trimmed)
        refreshPersistedNavigationState(publish: false)
        if selectedProjectID == id { selectedProjectName = trimmed }
        objectWillChange.send()
    }

    /// Close a project tab. Its live sessions keep running on the broker; this
    /// just removes the tab from the persisted list.
    func closeProject(id: String) {
        deferredFileWorkspaceStates[id] = workspaceSnapshot(projectID: id)
            .flatMap(fileOnlyWorkspaceState(from:))
        fileTabsByProject[id] = nil
        selectedFilePathByProject[id] = nil
        fileNavigationRollbacks[id] = nil
        workspaceSaveTasks[id]?.cancel()
        workspaceSaveTasks[id] = nil
        sessionStore.closeProject(id: id)
        refreshPersistedNavigationState(publish: false)
        if recentlyClosedPanes.contains(where: { $0.surface.projectID == id }) {
            // Closing the project tab must not cancel the only pending write
            // for a just-closed Chat or Mesh. The project can leave the opened
            // tab list while its Recently Closed recovery state stays durable.
            scheduleWorkspaceStateSave(projectID: id)
        }
        if selectedProjectID == id {
            let fallback = projects.first { $0.id != id }
            selectedProjectID = fallback?.id
            selectedProjectName = fallback?.name
        }
        objectWillChange.send()
    }

    /// Restore the most recently closed project tab (⌘⇧T) and select it.
    func reopenLastClosedProject() {
        if let restored = sessionStore.reopenLastClosedProject() {
            refreshPersistedNavigationState(publish: false)
            selectedProjectID = restored.id
            selectedProjectName = restored.name
            if let state = deferredFileWorkspaceStates.removeValue(forKey: restored.id) {
                restoreFileTabs(from: state)
                restoreSelectedFilePreview(for: restored.id)
                scheduleWorkspaceStateSave(projectID: restored.id)
            }
        }
        objectWillChange.send()
    }

    var hasClosedProjects: Bool { !sessionStore.closedProjects().isEmpty }

    /// The working directory of an owned session (for the Git panel). Observed
    /// Electron terminals have no known local directory here.
    func directory(for terminalID: String) -> URL? {
        persistedOwnedSessions.first { $0.id == terminalID }.map { URL(fileURLWithPath: $0.cwd) }
    }

    /// The directory of the project the user is currently working in, used to
    /// default new terminals/agents/chats to the active project instead of
    /// forcing a folder picker every time (matching the Electron workflow).
    /// Nil only when there's genuinely no project context to infer.
    var currentProjectDirectory: URL? {
        if let id = selectedProjectID,
           let project = projects.first(where: { $0.id == id }),
           let directory = project.directory {
            return directory
        }
        if let name = selectedProjectName,
           let project = projects.first(where: { $0.name == name }),
           let directory = project.directory {
            return directory
        }
        if let sessionID = selectedSessionID, let directory = directory(for: sessionID) {
            return directory
        }
        // With a single project open, that's unambiguously the context.
        let all = projects
        if all.count == 1 { return all.first?.directory }
        return nil
    }

    // MARK: - Durable workspace restoration

    private func scheduleWorkspaceStateSave(projectID: String) {
        guard !isRestoringWorkspaceState else { return }
        workspaceSaveTasks[projectID]?.cancel()
        workspaceSaveTasks[projectID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            // A newly generated chat's durable incarnation is queued before
            // appendChat. Never persist its restorable descriptor ahead of
            // that first identity write.
            await self.transcriptPersistenceTask?.value
            guard !Task.isCancelled else { return }
            let snapshot = self.workspaceSnapshot(projectID: projectID)
            if let snapshot {
                try? await self.workspaceStateStore.saveProjectState(snapshot, makeSelected: false)
            } else {
                try? await self.workspaceStateStore.removeProjectState(projectID: projectID)
            }
        }
    }

    private func persistWorkspaceStateImmediately(projectID: String) async {
        workspaceSaveTasks[projectID]?.cancel()
        workspaceSaveTasks[projectID] = nil
        await transcriptPersistenceTask?.value
        if let snapshot = workspaceSnapshot(projectID: projectID) {
            try? await workspaceStateStore.saveProjectState(snapshot, makeSelected: false)
        } else {
            try? await workspaceStateStore.removeProjectState(projectID: projectID)
        }
    }

    /// Test-only window onto the private snapshot builder, so the adoption
    /// overlay's persistence contract is provable without a relaunch.
    /// Test-only layout injection for close/quit races.
    func setPaneLayoutForTesting(_ layout: SessionPaneLayout, projectID: String) {
        unifiedSessionCards.install(layout, for: projectID)
    }

    /// Test-only dormant marking (production sets this in restoreOwnedSessions).
    func markDormantForTesting(_ terminalID: String) {
        dormantTerminalIDs.insert(terminalID)
    }

    func workspaceSnapshotForTesting(projectID: String) -> NativeProjectWorkspaceState? {
        workspaceSnapshot(projectID: projectID)
    }

    private func workspaceSnapshot(projectID: String) -> NativeProjectWorkspaceState? {
        let layout = paneLayouts[projectID] ?? SessionPaneLayout()
        var panes: [NativeRestorablePaneState] = []
        var seen = Set<String>()

        for terminalID in layout.sessionIDs {
            if let terminal = sessions.first(where: { $0.id == terminalID }),
               displayProjectID(terminal) == projectID {
                guard seen.insert(terminalID).inserted else { continue }
                panes.append(NativeRestorablePaneState(
                    id: terminalID,
                    surface: NativeRestorableSurfaceState(
                        kind: .terminal,
                        id: terminalID,
                        projectID: projectID,
                        title: sessionTitle(for: terminal)
                    )
                ))
            } else if dormantTerminalIDs.contains(terminalID),
                      let stored = persistedOwnedSessions.first(where: { $0.id == terminalID }),
                      stored.projectID == projectID {
                // A dormant terminal is not in live inventory, but its pane is
                // a resurrection target — dropping it here is how panes used
                // to be erased forever on the first save after a reboot.
                guard seen.insert(terminalID).inserted else { continue }
                panes.append(NativeRestorablePaneState(
                    id: terminalID,
                    surface: NativeRestorableSurfaceState(
                        kind: .terminal,
                        id: terminalID,
                        projectID: projectID,
                        title: stored.title
                    )
                ))
            }
        }

        // A hidden chat remains a restorable sidebar session; closing it is the
        // explicit destructive action that removes transcript and descriptor.
        for chat in chats(in: projectID)
        where !pendingNewTranscriptChatIDs.contains(chat.id)
            && !failedNewTranscriptChatIDs.contains(chat.id)
            && seen.insert(chat.id).inserted {
            let descriptor = NativeRestorableAgentChatDescriptor(
                id: chat.id,
                projectID: projectID,
                agentID: chat.agentID,
                workspacePath: chat.workspaceDirectory.path,
                acpSessionID: chat.conversation.providerSessionID,
                accountBinding: chat.accountBinding,
                title: chat.conversation.title,
                queuedPrompts: chat.conversation.queued.map(\.text),
                modelOverride: chat.modelOverride,
                runProfile: chat.runProfile
            )
            panes.append(NativeRestorablePaneState(
                id: chat.id,
                surface: NativeRestorableSurfaceState(agentChat: descriptor),
                isMinimized: !layout.contains(chat.id)
            ))
        }

        // Hidden Mesh sessions are durable just like hidden chats. Their
        // manifest retains exact worktree/branch/base-OID identity so window
        // close and updates cannot silently discard or orphan agent work.
        for mesh in meshes(in: projectID) where seen.insert(mesh.id).inserted {
            panes.append(NativeRestorablePaneState(
                id: mesh.id,
                surface: NativeRestorableSurfaceState(mesh: mesh.restorationDescriptor),
                isMinimized: !layout.contains(mesh.id)
            ))
        }

        // Recently Closed entries share this archive with live panes but never
        // participate in its layout. Keeping them here lets the existing Mesh
        // manifest merge protect recoverable work across multiple windows.
        for pane in recentlyClosedPanes
        where pane.surface.projectID == projectID && seen.insert(pane.id).inserted {
            panes.append(NativeRestorablePaneState(
                id: pane.id,
                surface: pane.surface,
                sizeWeight: pane.sizeWeight,
                isMinimized: true,
                isRecentlyClosed: true,
                closedAt: pane.closedAt
            ))
        }

        let restorableFileTabs: [NativeRestorableFileTabState] = {
            guard let root = projects.first(where: { $0.id == projectID })?.directory else { return [] }
            return (fileTabsByProject[projectID] ?? []).compactMap { tab in
                guard let relativePath = Self.relativePath(for: tab.url, workspace: root) else { return nil }
                return NativeRestorableFileTabState(
                    relativePath: relativePath,
                    isPinned: tab.isPinned,
                    line: tab.line
                )
            }
        }()
        let selectedFilePath: String? = selectedFilePathByProject[projectID].flatMap { selected in
            guard let root = projects.first(where: { $0.id == projectID })?.directory else { return nil }
            return Self.relativePath(for: URL(fileURLWithPath: selected), workspace: root)
        }
        guard !panes.isEmpty || !layout.isEmpty || !restorableFileTabs.isEmpty else { return nil }
        let focused = focusedPaneID.flatMap { id in
            panes.contains(where: { $0.id == id && !$0.isMinimized }) ? id : nil
        }
        return NativeProjectWorkspaceState(
            projectID: projectID,
            layout: layout,
            arrangement: layout.columns.count > 1 ? .grid : .rows,
            panes: panes,
            focusedPaneID: focused,
            fileTabs: restorableFileTabs,
            selectedFilePath: selectedFilePath
        )
    }

    private func recentlyClosedPane(id: String) -> NativeRestorablePaneState? {
        recentlyClosedPanes.first { $0.id == id && $0.isRecentlyClosed }
    }

    private func storeRecentlyClosedPane(_ pane: NativeRestorablePaneState) {
        guard pane.isRecentlyClosed else { return }
        recentlyClosedPanes.removeAll { $0.id == pane.id }
        recentlyClosedPanes.append(pane)
    }

    private func nextRecentlyClosedTimestamp() -> Int64 {
        let wallClock = Int64(Date().timeIntervalSince1970 * 1_000)
        let newest = recentlyClosedPanes.compactMap(\.closedAt).max() ?? -1
        return max(wallClock, newest + 1)
    }

    @discardableResult
    private func removeRecentlyClosedPane(id: String) -> NativeRestorablePaneState? {
        guard let index = recentlyClosedPanes.firstIndex(where: { $0.id == id }) else { return nil }
        return recentlyClosedPanes.remove(at: index)
    }

    private func removeAllRecentlyClosedPanes(id: String) {
        recentlyClosedPanes.removeAll { $0.id == id }
    }

    private func updateRecentlyClosedMeshDescriptor(_ descriptor: NativeRestorableMeshDescriptor) {
        guard let index = recentlyClosedPanes.firstIndex(where: {
            $0.id == descriptor.id && $0.isRecentlyClosed
        }) else { return }
        let existing = recentlyClosedPanes[index]
        recentlyClosedPanes[index] = NativeRestorablePaneState(
            id: descriptor.id,
            surface: NativeRestorableSurfaceState(mesh: descriptor),
            sizeWeight: existing.sizeWeight,
            isMinimized: true,
            isRecentlyClosed: true,
            closedAt: existing.closedAt
        )
    }

    private func durableRecentlyClosedPaneExists(_ pane: NativeRestorablePaneState) async throws -> Bool {
        await workspaceSaveTasks[pane.surface.projectID]?.value
        let state = try await workspaceStateStore.projectState(for: pane.surface.projectID)
        return state?.panes.contains(where: {
            $0.id == pane.id
                && $0.isRecentlyClosed
                && $0.surface.kind == pane.surface.kind
        }) == true
    }

    private func persistWorkspaceStateNow() async {
        for task in workspaceSaveTasks.values { task.cancel() }
        workspaceSaveTasks.removeAll()
        await transcriptPersistenceTask?.value
        let explicitlyOpenProjectIDs = Set(persistedOpenProjects.map(\.id))
        var projectIDs = Set(paneLayouts.keys)
        projectIDs.formUnion(chats.map(\.projectID))
        projectIDs.formUnion(meshes.map(\.projectID))
        projectIDs.formUnion(recentlyClosedPanes.map { $0.surface.projectID })
        projectIDs.formUnion(fileTabsByProject.keys)
        projectIDs.formUnion(explicitlyOpenProjectIDs)
        var statesByProject = deferredFileWorkspaceStates
        for projectID in projectIDs {
            if var state = workspaceSnapshot(projectID: projectID) {
                if !explicitlyOpenProjectIDs.contains(projectID),
                   let deferredFiles = deferredFileWorkspaceStates[projectID] {
                    // Closing a project does not terminate its broker/chat
                    // surfaces. Their live pane snapshot must not overwrite the
                    // separately deferred file deck during teardown.
                    state.fileTabs = deferredFiles.fileTabs
                    state.selectedFilePath = deferredFiles.selectedFilePath
                    state.updatedAt = max(state.updatedAt, deferredFiles.updatedAt)
                }
                statesByProject[projectID] = state
            } else if explicitlyOpenProjectIDs.contains(projectID) {
                // A currently open project with no live panes or file tabs is
                // an explicit tombstone. Do not let a previously deferred deck
                // survive teardown and reappear on the next launch.
                statesByProject[projectID] = nil
            }
        }
        let states = statesByProject.values.sorted { $0.projectID < $1.projectID }
        try? await workspaceStateStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: selectedProjectID,
                projects: states
            )
        )
        flushTerminalDraftPersistence()
        await draftPersistenceTask?.value
        await flushTranscriptPersistence()
        await usageCenter.flushPersistence()
    }

    func enqueueTranscriptSave(
        _ rows: [AcpTranscriptRow],
        startOrdinal: Int64 = 0,
        chatID: String
    ) {
        guard !explicitlyClosedChatIDs.contains(chatID) else { return }
        let previous = transcriptPersistenceTask
        let transcriptStore = transcriptStore
        transcriptPersistenceTask = Task {
            await previous?.value
            await transcriptStore.scheduleSave(
                rows,
                for: chatID,
                startOrdinal: startOrdinal
            )
        }
    }

    private func enqueueTranscriptDraft(_ draft: String, chatID: String) {
        guard !explicitlyClosedChatIDs.contains(chatID) else { return }
        let previous = transcriptPersistenceTask
        let transcriptStore = transcriptStore
        transcriptPersistenceTask = Task {
            await previous?.value
            await transcriptStore.scheduleDraft(draft, for: chatID)
        }
    }

    private func enqueueTranscriptAttachments(
        _ attachments: [AcpAttachment],
        chatID: String
    ) {
        guard !explicitlyClosedChatIDs.contains(chatID) else { return }
        let previous = transcriptPersistenceTask
        let transcriptStore = transcriptStore
        transcriptPersistenceTask = Task {
            await previous?.value
            await transcriptStore.scheduleAttachments(attachments, for: chatID)
        }
    }

    private func enqueueTranscriptSessionID(_ sessionID: String?, chatID: String) {
        guard !explicitlyClosedChatIDs.contains(chatID) else { return }
        let previous = transcriptPersistenceTask
        let transcriptStore = transcriptStore
        transcriptPersistenceTask = Task {
            await previous?.value
            await transcriptStore.scheduleSessionID(sessionID, for: chatID)
        }
    }

    private func enqueueNewTranscriptChatIncarnation(chatID: String) {
        pendingNewTranscriptChatIDs.insert(chatID)
        failedNewTranscriptChatIDs.remove(chatID)
        let previous = transcriptPersistenceTask
        let transcriptStore = transcriptStore
        transcriptPersistenceTask = Task { [weak self] in
            await previous?.value
            let began = await transcriptStore.beginNewChatID(chatID)
            guard let self else { return }
            self.pendingNewTranscriptChatIDs.remove(chatID)
            if !began {
                self.failedNewTranscriptChatIDs.insert(chatID)
                ToastCenter.shared.show(
                    "The chat opened, but its saved identity could not be created.",
                    style: .error
                )
            }
        }
    }

    /// Queue the durable transcript deletion behind the writes already in
    /// flight. The returned task carries the committed outcome, so a caller
    /// standing in front of a permanent-delete confirmation can wait for it
    /// rather than announce a deletion the store never finished.
    @discardableResult
    func enqueueTranscriptRemoval(
        chatID: String,
        verifiedDescriptorPruning: AcpTranscriptStore.TombstoneSnapshot? = nil
    ) -> Task<AcpTranscriptStore.Removal, Never> {
        explicitlyClosedChatIDs.insert(chatID)
        let previous = transcriptPersistenceTask
        let transcriptStore = transcriptStore
        let usageCenter = usageCenter
        let removal = Task { () -> AcpTranscriptStore.Removal in
            await previous?.value
            // Usage and transcript writes use separate coalescing queues during
            // normal streaming. On explicit close, drain usage first and make
            // the full transcript deletion the final actor operation.
            await usageCenter.flushPersistence()
            return await transcriptStore.remove(
                chatID: chatID,
                verifiedDescriptorPruning: verifiedDescriptorPruning
            )
        }
        transcriptPersistenceTask = Task { _ = await removal.value }
        return removal
    }

    /// Enqueue every member before any outcome is awaited. A failure for one
    /// Mesh column must not leave the remaining column transcripts unattempted.
    func enqueueTranscriptRemovals(
        chatIDs: [String]
    ) -> [Task<AcpTranscriptStore.Removal, Never>] {
        chatIDs.map { enqueueTranscriptRemoval(chatID: $0) }
    }

    /// Wait for queued transcript deletions and report the first that did not
    /// commit, so a caller can replace its success message with the truth.
    private func firstTranscriptRemovalFailure(
        _ removals: [Task<AcpTranscriptStore.Removal, Never>]
    ) async -> String? {
        for removal in removals {
            if let message = await removal.value.failureMessage { return message }
        }
        return nil
    }

    func flushTranscriptPersistence() async {
        await transcriptPersistenceTask?.value
        await transcriptStore.flush()
    }

    private func applyTranscriptPersistenceHealth(
        _ update: AcpTranscriptStore.PersistenceHealthUpdate
    ) {
        chats.first(where: { $0.id == update.chatID })?
            .conversation.applyTranscriptPersistenceHealth(update.health)
    }

    private func retryTranscriptPersistence(chatID: String) {
        let transcriptStore = transcriptStore
        Task { await transcriptStore.retryPersistence(chatID: chatID) }
    }

    /// Chats whose unreadable history has already been reported. One notice
    /// per chat per launch: restoration, a Recently Closed reopen, and an
    /// account or model switch can all read the same damaged transcript.
    private var reportedUnreadableTranscriptIDs: Set<String> = []

    /// Read a chat's stored tail. A chat with nothing saved and a chat whose
    /// history is damaged or locked no longer look alike here: the second
    /// surfaces the store's recovery guidance and still returns nil, because
    /// the store refuses writes for it. The surface stays, and the history we
    /// could not read is never replaced by the empty one this read produced.
    private func restoredTranscript(
        for chatID: String,
        tailLimit: Int = AcpConversation.defaultVisibleLimit
    ) async -> AcpTranscriptStore.Restoration? {
        let outcome = await transcriptStore.restoration(for: chatID, tailLimit: tailLimit)
        if let failure = outcome.failure, reportedUnreadableTranscriptIDs.insert(chatID).inserted {
            ToastCenter.shared.show(failure.guidance, style: .error, duration: 8)
        }
        return outcome.restoration
    }

    private func wireMeshPersistence(
        _ mesh: MeshSession,
        recentlyClosed: Bool = false,
        creatingNewColumns: Bool = false
    ) {
        let projectID = mesh.projectID
        mesh.onDescriptorChanged = { [weak self, weak mesh] in
            if recentlyClosed, let mesh {
                self?.updateRecentlyClosedMeshDescriptor(mesh.restorationDescriptor)
            }
            self?.scheduleWorkspaceStateSave(projectID: projectID)
        }
        mesh.persistDescriptor = { [weak self, weak mesh] in
            guard let self, let mesh else {
                throw CancellationError()
            }
            if creatingNewColumns {
                let desiredIDs = Set(mesh.durableColumnIDs)
                let establishedIDs = self.provisionedTranscriptIDsByMeshID[mesh.id, default: []]
                for chatID in desiredIDs.subtracting(establishedIDs).sorted() {
                    guard await self.transcriptStore.beginNewChatID(chatID) else {
                        throw NativeWorkspaceStateStore.StoreError.criticalDescriptorNotPersisted
                    }
                }
                for chatID in establishedIDs.subtracting(desiredIDs).sorted() {
                    guard await self.transcriptStore.abandonNewChatID(chatID) else {
                        throw NativeWorkspaceStateStore.StoreError.criticalDescriptorNotPersisted
                    }
                }
                self.provisionedTranscriptIDsByMeshID[mesh.id] = desiredIDs
            }
            if recentlyClosed {
                self.updateRecentlyClosedMeshDescriptor(mesh.restorationDescriptor)
            }
            guard let snapshot = self.workspaceSnapshot(projectID: projectID) else {
                throw CancellationError()
            }
            try await self.workspaceStateStore.saveProjectState(snapshot, makeSelected: false)
            let persisted = try await self.workspaceStateStore.projectState(for: projectID)
            guard persisted?.panes.contains(where: {
                $0.surface.meshDescriptor?.id == mesh.id
                    && (!recentlyClosed || $0.isRecentlyClosed)
            }) == true else {
                throw NativeWorkspaceStateStore.StoreError.criticalDescriptorNotPersisted
            }
        }
        mesh.onTranscriptChanged = { [weak self] columnID, rows, startOrdinal in
            self?.enqueueTranscriptSave(
                rows,
                startOrdinal: startOrdinal,
                chatID: columnID
            )
        }
        let pageStore = transcriptStore
        mesh.loadEarlierTranscript = { columnID, beforeOrdinal, limit in
            await pageStore.page(
                for: columnID,
                beforeOrdinal: beforeOrdinal,
                limit: limit
            )
        }
        mesh.onColumnDraftChanged = { [weak self] columnID, draft in
            self?.enqueueTranscriptDraft(draft, chatID: columnID)
        }
        mesh.onColumnAttachmentsChanged = { [weak self] columnID, attachments in
            self?.enqueueTranscriptAttachments(attachments, chatID: columnID)
        }
        mesh.onColumnSessionIDChanged = { [weak self] columnID, sessionID in
            self?.enqueueTranscriptSessionID(sessionID, chatID: columnID)
        }
        mesh.onFileActivity = { [weak self, weak mesh] _, activity in
            guard let self, let mesh else { return false }
            return self.recordAgentFileActivity(
                activity,
                surfaceID: mesh.id,
                projectID: projectID,
                workspaceRoot: mesh.baseDirectory
            )
        }
        mesh.onDraftChanged = { [weak self, weak mesh] text in
            guard let self, let mesh else { return }
            self.enqueueDraftSave(
                text,
                stableKey: "mesh|\(mesh.id)",
                projectID: projectID,
                agentID: "mesh",
                workspacePath: mesh.baseDirectory.path
            )
        }
    }

    private func enqueueDraftSave(
        _ text: String,
        chatID: String,
        projectID: String,
        agentID: String,
        workspacePath: String
    ) {
        guard !explicitlyClosedChatIDs.contains(chatID) else { return }
        enqueueTranscriptDraft(text, chatID: chatID)
        enqueueDraftSave(
            text,
            stableKey: "chat|\(chatID)",
            projectID: projectID,
            agentID: agentID,
            workspacePath: workspacePath
        )
    }

    private func enqueueDraftSave(
        _ text: String,
        stableKey: String,
        projectID: String,
        agentID: String,
        workspacePath: String
    ) {
        let previous = draftPersistenceTask
        let workspaceStateStore = workspaceStateStore
        draftPersistenceTask = Task {
            await previous?.value
            try? await workspaceStateStore.saveDraft(
                text,
                stableKey: stableKey,
                projectID: projectID,
                agentID: agentID,
                workspacePath: workspacePath
            )
        }
    }

    @discardableResult
    private func enqueueDraftRemoval(chatID: String) -> Task<Void, Never> {
        enqueueDraftRemoval(stableKey: "chat|\(chatID)")
    }

    @discardableResult
    private func enqueueDraftRemoval(stableKey: String) -> Task<Void, Never> {
        let previous = draftPersistenceTask
        let workspaceStateStore = workspaceStateStore
        let removalTask = Task {
            await previous?.value
            try? await workspaceStateStore.removeDraft(stableKey: stableKey)
        }
        draftPersistenceTask = removalTask
        return removalTask
    }

    /// The durable deletion intent has already committed before this runs.
    /// Serialize the workspace removal behind older saves, and synchronously
    /// clear AcpConversation's current and migrated UserDefaults copies so no
    /// superseded location can restore plaintext on relaunch.
    private func completeChatExternalCleanup(
        chatID: String,
        tombstone: AcpTranscriptStore.TombstoneSnapshot
    ) async -> AcpTranscriptStore.Removal {
        let cleanup = ChatDraftDefaultsCleanupContext(
            current: chatDraftDefaults,
            migrated: migratedChatDraftDefaults
        )
        let defaultsKeys = AcpConversation.persistedDraftDefaultsKeys(for: chatID)
            + AcpConversation.persistedBooleanConfigDefaultsKeys(for: chatID)
        return await transcriptStore.completeExternalCleanup(
            tombstone,
            performExternalCleanup: {
                try cleanup.erase(keys: defaultsKeys)
            }
        )
    }

    /// Mesh columns use the same transcript/defaults stores as standalone
    /// chats, so their exact receipts complete through the same synchronous,
    /// non-reentrant plaintext boundary. Enqueue every physical deletion
    /// first, then attempt every cleanup even when one column reports failure.
    private func completeMeshColumnDeletion(
        _ tombstones: [AcpTranscriptStore.TombstoneSnapshot]
    ) async -> String? {
        let ordered = tombstones.sorted {
            $0.chatID == $1.chatID
                ? $0.generation < $1.generation
                : $0.chatID < $1.chatID
        }
        let removals = ordered.map { tombstone in
            (
                tombstone,
                enqueueTranscriptRemoval(
                    chatID: tombstone.chatID,
                    verifiedDescriptorPruning: tombstone
                )
            )
        }
        var firstFailure: String?
        for (tombstone, removalTask) in removals {
            let removal = await removalTask.value
            guard removal.isRemoved else {
                if firstFailure == nil { firstFailure = removal.failureMessage }
                continue
            }
            usageCenter.remove(chatID: tombstone.chatID)
            let cleanup = await completeChatExternalCleanup(
                chatID: tombstone.chatID,
                tombstone: tombstone
            )
            if firstFailure == nil { firstFailure = cleanup.failureMessage }
        }
        return firstFailure
    }

    private func fenceDestroyedMeshPersistence(_ mesh: MeshSession) {
        mesh.onDescriptorChanged = nil
        mesh.persistDescriptor = nil
        mesh.onTranscriptChanged = nil
        mesh.loadEarlierTranscript = nil
        mesh.onColumnDraftChanged = nil
        mesh.onColumnAttachmentsChanged = nil
        mesh.onColumnSessionIDChanged = nil
        mesh.onFileActivity = nil
        mesh.onDraftChanged = nil
    }

    /// A safe Mesh destroy empties its live manifest before transcript cleanup.
    /// Union the live ids with the archive-owned deletion bridge so a retry of
    /// that already-destroyed surface still tombstones the original columns.
    private func meshDeletionColumnIDs(
        meshID: String,
        projectID: String,
        liveColumnIDs: [String]
    ) async -> [String] {
        await workspaceSaveTasks[projectID]?.value
        let persisted = try? await workspaceStateStore.projectState(for: projectID)
        let bridged = persisted?.panes.first {
            $0.id == meshID && $0.surface.kind == .mesh
        }?.surface.meshDescriptor?.deletionColumnIDs ?? []
        return Array(Set(liveColumnIDs + bridged)).sorted()
    }

    /// Await the serialized draft queue so the durable store reflects every
    /// save and removal already enqueued. `teardown` and the restore paths wait
    /// on the task directly; this is the same wait for callers outside them.
    func flushDraftPersistence() async {
        await draftPersistenceTask?.value
    }

    private static func terminalDraftStableKey(_ terminalID: String) -> String {
        "terminal|\(terminalID)"
    }

    private func restoreTerminalDraftTrackers() async {
        for session in persistedOwnedSessions
        where session.agentID != nil && terminalDraftTrackers[session.id] == nil {
            let key = Self.terminalDraftStableKey(session.id)
            let saved: String? = try? await workspaceStateStore.draft(for: key)
            if let saved, !saved.isEmpty {
                terminalDraftTrackers[session.id] = TerminalAgentDraftTracker(text: saved)
            }
        }
    }

    private func terminalDraftContext(
        for terminalID: String
    ) -> (projectID: String, agentID: String, workspacePath: String)? {
        guard let stored = persistedOwnedSessions.first(where: { $0.id == terminalID }),
              let agentID = stored.agentID
                ?? AgentRegistry.profile(displayName: detectedAgentNamesByTerminalID[terminalID])?.id else {
            return nil
        }
        return (stored.projectID, agentID, stored.cwd)
    }

    private func scheduleTerminalDraftPersistence(_ terminalID: String) {
        terminalDraftDebounceTasks[terminalID]?.cancel()
        terminalDraftDebounceTasks[terminalID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.terminalDraftDebounceTasks[terminalID] = nil
            self.persistTerminalDraftNow(terminalID)
        }
    }

    private func persistTerminalDraftNow(_ terminalID: String) {
        guard let tracker = terminalDraftTrackers[terminalID],
              let context = terminalDraftContext(for: terminalID) else { return }
        enqueueDraftSave(
            tracker.text,
            stableKey: Self.terminalDraftStableKey(terminalID),
            projectID: context.projectID,
            agentID: context.agentID,
            workspacePath: context.workspacePath
        )
    }

    private func flushTerminalDraftPersistence() {
        for task in terminalDraftDebounceTasks.values { task.cancel() }
        terminalDraftDebounceTasks.removeAll()
        for terminalID in terminalDraftTrackers.keys {
            persistTerminalDraftNow(terminalID)
        }
    }

    private func armTerminalDraftRestore(
        _ seed: TerminalDraftResumeSeed,
        terminalID: String
    ) {
        guard NativePreviewSettings.shared.restoreCLIDrafts,
              !seed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        terminalDraftRestoreTasks[terminalID]?.cancel()
        pendingTerminalDraftRestores[terminalID] = seed
        terminalLastOutputAt[terminalID] = Date()
        terminalDraftRestoreTasks[terminalID] = Task { @MainActor [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self,
                      self.pendingTerminalDraftRestores[terminalID] == seed else { return }
                let now = Date()
                let lastOutput = self.terminalLastOutputAt[terminalID] ?? startedAt
                let decision = TerminalDraftRestorePolicy.decision(
                    startedAt: startedAt,
                    lastOutputAt: lastOutput,
                    now: now
                )
                if decision == .expire {
                    self.pendingTerminalDraftRestores[terminalID] = nil
                    self.terminalDraftRestoreTasks[terminalID] = nil
                    return
                }
                guard decision == .restore,
                      self.controlAvailable,
                      self.isOwned(terminalID),
                      let record = self.sessions.first(where: { $0.id == terminalID && !$0.exited }) else {
                    continue
                }
                do {
                    try await self.controlClient.write(
                        projectID: record.projectID,
                        terminalID: terminalID,
                        data: TerminalAgentDraftTracker.retypePayload(for: seed.text)
                    )
                    guard self.pendingTerminalDraftRestores[terminalID] == seed else { return }
                    self.pendingTerminalDraftRestores[terminalID] = nil
                    self.terminalDraftRestoreTasks[terminalID] = nil
                    ToastCenter.shared.show("Restored unsent CLI draft", style: .info)
                    return
                } catch {
                    // A broker reconnect can race the quiet prompt. Retain the
                    // bounded candidate and retry until the 30-second deadline.
                }
            }
        }
    }

    /// The degraded-state explanation for a workspace archive this build could
    /// not restore. Durable for the window's lifetime: it clears only when a
    /// restore actually succeeds, never merely because the banner was closed.
    @Published private(set) var workspaceRestorationNotice: WorkspaceRestorationNotice?

    /// Resolve the environment overlay at the process-launch boundary. Missing
    /// storage intentionally permits app defaults; every unsafe present-file
    /// state raises the recovery surface and returns nil.
    private func projectAccountOverlay(forProject projectID: String) -> [String: String]? {
        let previousIssue = projectAccountRecoveryCenter.issue
        switch projectAccountRecoveryCenter.launchOverlay(
            app: NativePreviewSettings.shared.agentEnvironmentOverlay,
            forProject: projectID
        ) {
        case .success(let overlay):
            return overlay
        case .failure(let issue):
            let isNew = previousIssue != issue
            if isNew { ToastCenter.shared.show(issue.summary, style: .error, duration: 6) }
            return nil
        }
    }

    /// Re-read after the user repairs or replaces the account file. The launch
    /// that was refused stays refused; success makes an explicit retry safe.
    func retryProjectAccountRecovery() {
        if projectAccountRecoveryCenter.retry() {
            ToastCenter.shared.show("Project accounts are readable again", style: .success)
        } else if let issue = projectAccountRecoveryCenter.issue {
            ToastCenter.shared.show(issue.summary, style: .error, duration: 6)
        }
    }

    func revealProjectAccountRecovery() {
        guard let url = projectAccountRecoveryCenter.issue?.revealURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Explicitly discard the active mapping only after the store has secured
    /// the original bytes as a preserved copy (or can move the unreadable file
    /// itself there atomically).
    func resetProjectAccountsAfterFailure() {
        do {
            let preserved = try projectAccountRecoveryCenter.resetAfterFailure()
            ToastCenter.shared.show(
                "Reset project account overrides; kept \(preserved.lastPathComponent)",
                style: .success,
                duration: 6
            )
        } catch {
            retryProjectAccountRecovery()
            ToastCenter.shared.show(error.localizedDescription, style: .error, duration: 6)
        }
    }

    func restoreWorkspaceStateIfNeeded() async {
        guard !restoredWorkspaceState else { return }
        restoredWorkspaceState = true
        isRestoringWorkspaceState = true
        for task in workspaceSaveTasks.values { task.cancel() }
        workspaceSaveTasks.removeAll()
        defer { isRestoringWorkspaceState = false }

        // Capture deletion generations before the full archive read. A member
        // that is absent from that later complete archive represents a crash
        // after descriptor pruning but before receipt release; it can be
        // reclaimed without guessing from a partial/window-owned snapshot.
        let tombstonesBeforeArchive = await transcriptStore.tombstoneSnapshots()
        let restoration: NativeWorkspaceRestorationState
        do {
            restoration = try await workspaceStateStore.restorationState()
            workspaceRestorationNotice = nil
        } catch {
            await raiseWorkspaceRestorationNotice(for: error)
            return
        }
        await afterWorkspaceRestorationRead?()
        // Closed projects sit out of restoration entirely (§4d): their
        // archived state stays on disk for ⌘⇧T reopen, but no chats, meshes,
        // layouts, or Recently Closed rows materialize for them at launch.
        let restorableProjects = restoration.projects.filter {
            !sessionStore.isProjectClosed($0.projectID)
        }
        // A crash can land after the transcript tombstone but before the
        // workspace descriptor is removed. Prune every descriptor while its
        // tombstone still proves deletion intent; reclaiming tombstones first
        // would turn that stale descriptor back into an apparently live chat.
        var blockedRestoredChatIDs = Set<String>()
        var blockedRestoredMeshIDs = Set<String>()
        // Deletion also applies to projects that are currently closed. Their
        // archived panes are not restored today, but leaving a stale
        // descriptor there would revive it when the project is reopened.
        var descriptorProjectsByChatID: [String: Set<String>] = [:]
        var restorableTranscriptIDs = Set<String>()
        var meshIDsByTranscriptID: [String: Set<String>] = [:]
        var durableTranscriptIDsByMeshID: [String: Set<String>] = [:]
        for projectState in restoration.projects {
            for pane in projectState.panes {
                if let descriptor = pane.surface.agentChatDescriptor {
                    descriptorProjectsByChatID[descriptor.id, default: []].insert(
                        projectState.projectID
                    )
                    restorableTranscriptIDs.insert(descriptor.id)
                }
                if let descriptor = pane.surface.meshDescriptor {
                    let durableColumnIDs = Set(
                        descriptor.columns.map(\.id) + descriptor.deletionColumnIDs
                    )
                    durableTranscriptIDsByMeshID[descriptor.id, default: []].formUnion(
                        durableColumnIDs
                    )
                    for column in descriptor.columns {
                        restorableTranscriptIDs.insert(column.id)
                    }
                    for columnID in durableColumnIDs {
                        meshIDsByTranscriptID[columnID, default: []].insert(descriptor.id)
                    }
                }
            }
        }
        let liveTranscriptIDs = Set(chats.map(\.id)).union(
            meshes.flatMap(\.durableColumnIDs)
        )
        var verifiedDescriptorPruning = Set<AcpTranscriptStore.TombstoneSnapshot>()

        // v0.1.121 and earlier could crash between sequential Mesh-column
        // tombstones. A receipt for any archived member therefore owns the
        // complete durable descriptor, including deletion-bridge ids and any
        // duplicate/overlapping Mesh descriptors captured by this full scan.
        // Bind the connected set in one SQLite transaction before removing a
        // single archive row. A failed probe or batch leaves the whole set
        // descriptor-blocked and retryable; the generic per-chat path below
        // must not turn the partial receipt into authority to erase the Mesh.
        let preArchiveTombstoneIDs = Set(
            (tombstonesBeforeArchive ?? []).map(\.chatID)
        )
        var pendingLegacyMeshIDs = Set(preArchiveTombstoneIDs.flatMap {
            meshIDsByTranscriptID[$0, default: []]
        })
        var legacyHandledMeshIDs = Set<String>()
        var legacyHandledTranscriptIDs = Set<String>()
        while let seedMeshID = pendingLegacyMeshIDs.sorted().first {
            var componentMeshIDs = Set<String>()
            var componentTranscriptIDs = Set<String>()
            var frontier = [seedMeshID]
            while let meshID = frontier.popLast() {
                guard componentMeshIDs.insert(meshID).inserted else { continue }
                let columnIDs = durableTranscriptIDsByMeshID[meshID, default: []]
                componentTranscriptIDs.formUnion(columnIDs)
                for columnID in columnIDs {
                    for linkedMeshID in meshIDsByTranscriptID[columnID, default: []]
                    where !componentMeshIDs.contains(linkedMeshID) {
                        frontier.append(linkedMeshID)
                    }
                }
            }
            pendingLegacyMeshIDs.subtract(componentMeshIDs)
            legacyHandledMeshIDs.formUnion(componentMeshIDs)
            legacyHandledTranscriptIDs.formUnion(componentTranscriptIDs)
            blockedRestoredMeshIDs.formUnion(componentMeshIDs)

            let orderedColumnIDs = componentTranscriptIDs.sorted()
            guard !orderedColumnIDs.isEmpty,
                  componentTranscriptIDs.isDisjoint(with: liveTranscriptIDs) else {
                continue
            }
            var probeFailed = false
            for columnID in orderedColumnIDs {
                if case .unknown = await transcriptStore.tombstoneSnapshot(chatID: columnID) {
                    probeFailed = true
                }
            }
            guard !probeFailed else { continue }
            let batch = await transcriptStore.tombstone(chatIDs: orderedColumnIDs)
            guard case let .recorded(receipts) = batch else { continue }
            do {
                // Mesh descriptors/layout/focus and Mesh drafts leave first,
                // archive-wide. Re-read the latest archive for every column
                // afterward so standalone duplicates, column drafts, and a
                // Mesh inserted by a sibling window after our snapshot are all
                // gone before any exact receipt is released.
                for meshID in componentMeshIDs.sorted() {
                    _ = try await workspaceStateStore.removeMeshStateEverywhere(
                        meshID: meshID
                    )
                }
                for columnID in orderedColumnIDs {
                    _ = try await workspaceStateStore.removeTranscriptStateEverywhere(
                        chatID: columnID
                    )
                }
                verifiedDescriptorPruning.formUnion(receipts)
            } catch {
                // The all-column receipts stay descriptor-blocked. Even if an
                // earlier archive replacement committed, the next complete
                // scan can safely resume without resurrecting any member.
            }
        }

        // Mesh destruction deliberately persists its exact column ids before
        // Git cleanup can empty the ordinary manifest. If the app crashed
        // after that safe lifecycle boundary but before SQLite tombstoning,
        // establish the whole batch now and continue through the same exact
        // archive/defaults reconciliation as an uninterrupted delete.
        var preparedMeshDeletionColumns: [String: Set<String>] = [:]
        for project in restoration.projects {
            for pane in project.panes {
                guard let descriptor = pane.surface.meshDescriptor,
                      descriptor.lifecycle == .pendingDeletion,
                      descriptor.columns.isEmpty,
                      !descriptor.deletionColumnIDs.isEmpty else { continue }
                preparedMeshDeletionColumns[descriptor.id, default: []].formUnion(
                    descriptor.deletionColumnIDs
                )
            }
        }
        for meshID in preparedMeshDeletionColumns.keys.sorted() {
            guard !legacyHandledMeshIDs.contains(meshID) else { continue }
            let columnIDs = Array(preparedMeshDeletionColumns[meshID, default: []]).sorted()
            blockedRestoredMeshIDs.insert(meshID)
            var existingReceipts: [AcpTranscriptStore.TombstoneSnapshot] = []
            var probeFailed = false
            for columnID in columnIDs {
                switch await transcriptStore.tombstoneSnapshot(chatID: columnID) {
                case let .present(receipt): existingReceipts.append(receipt)
                case .absent: break
                case .unknown: probeFailed = true
                }
            }
            guard !probeFailed else { continue }
            let receipts: [AcpTranscriptStore.TombstoneSnapshot]
            if existingReceipts.count == columnIDs.count {
                receipts = existingReceipts
            } else {
                let result = await transcriptStore.tombstone(chatIDs: columnIDs)
                guard case let .recorded(recorded) = result else { continue }
                receipts = recorded
            }
            do {
                _ = try await workspaceStateStore.removeMeshStateEverywhere(meshID: meshID)
                verifiedDescriptorPruning.formUnion(receipts)
            } catch {
                // Every receipt remains descriptor-blocked and the prepared
                // marker remains retryable in the latest archive.
            }
        }

        // Only a receipt captured before the archive read may authorize
        // descriptor pruning/reclamation. A deletion created later belongs to
        // the next complete scan, even if its identifier happens to match.
        for tombstone in (tombstonesBeforeArchive ?? []).sorted(by: {
            $0.chatID == $1.chatID
                ? $0.generation < $1.generation
                : $0.chatID < $1.chatID
        }) {
            let chatID = tombstone.chatID
            if !descriptorProjectsByChatID[chatID, default: []].isEmpty {
                // This receipt existed before the archive read, so every
                // matching descriptor in that captured value was already
                // deleted. Even if another window prunes the descriptor and
                // exact-vacuums the receipt before our later probe, this stale
                // in-memory archive is never allowed to materialize it.
                blockedRestoredChatIDs.insert(chatID)
            }
            blockedRestoredMeshIDs.formUnion(meshIDsByTranscriptID[chatID, default: []])
            guard !legacyHandledTranscriptIDs.contains(chatID) else { continue }
            guard !liveTranscriptIDs.contains(chatID) else { continue }
            do {
                // Authorize against the latest complete archive, not the stale
                // project-id set derived from `restoration`: a sibling window
                // may have inserted another duplicate after that snapshot.
                _ = try await workspaceStateStore.removeAgentChatStateEverywhere(
                    chatID: chatID
                )
                _ = try await workspaceStateStore.removeTranscriptStateEverywhere(
                    chatID: chatID
                )
                // An already-absent descriptor is meaningful: the complete
                // archive proves a prior crash landed after descriptor removal
                // but before this exact receipt was released.
                verifiedDescriptorPruning.insert(tombstone)
            } catch {
                // Keep this exact receipt descriptor-blocked for a later launch.
            }
        }

        // Probe every archived descriptor separately so tombstones committed
        // during/after the initial snapshot still suppress materialization.
        // Those newer receipts remain blocked for the next full archive scan.
        for chatID in descriptorProjectsByChatID.keys.sorted() {
            switch await transcriptStore.tombstoneSnapshot(chatID: chatID) {
            case .present:
                blockedRestoredChatIDs.insert(chatID)
            case .unknown:
                blockedRestoredChatIDs.insert(chatID)
                // A failed probe is not evidence that deletion never
                // happened. Keep both stores untouched and try next time.
            case .absent:
                continue
            }
        }
        // Before the first watermark compaction, grandfather legacy workspace
        // descriptors (including legitimately empty chats that have no SQLite
        // payload). Once compaction has happened, this API fails closed for an
        // unknown id; restore never invokes the new-chat incarnation path.
        for chatID in restorableTranscriptIDs.sorted()
        where !blockedRestoredChatIDs.contains(chatID) {
            guard await transcriptStore.establishRestorableChatID(chatID) else {
                blockedRestoredChatIDs.insert(chatID)
                blockedRestoredMeshIDs.formUnion(meshIDsByTranscriptID[chatID, default: []])
                continue
            }
        }
        for chatID in blockedRestoredChatIDs {
            blockedRestoredMeshIDs.formUnion(meshIDsByTranscriptID[chatID, default: []])
        }
        recentlyClosedPanes = restorableProjects.flatMap { project in
            project.panes.filter { pane in
                guard pane.isRecentlyClosed else { return false }
                if let descriptor = pane.surface.agentChatDescriptor {
                    return !blockedRestoredChatIDs.contains(descriptor.id)
                }
                if let descriptor = pane.surface.meshDescriptor {
                    return !blockedRestoredMeshIDs.contains(descriptor.id)
                }
                return true
            }
        }

        for projectState in restorableProjects {
            for pane in projectState.panes {
                guard !pane.isRecentlyClosed,
                      let descriptor = pane.surface.agentChatDescriptor,
                      !blockedRestoredChatIDs.contains(descriptor.id),
                      chats.contains(where: { $0.id == descriptor.id }) == false else { continue }
                guard let agent = AgentRegistry.profile(id: descriptor.agentID) else { continue }
                let directory = URL(fileURLWithPath: descriptor.workspacePath, isDirectory: true)
                    .standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let transcript = await restoredTranscript(for: descriptor.id)
                let legacyDraft = try? await workspaceStateStore.draft(for: "chat|\(descriptor.id)")
                let draft = transcript?.draft ?? legacyDraft
                await beforeRestoredChatMaterialization?(descriptor.id)
                // The archive-wide probe above is only a snapshot. Re-check
                // after every restoration await and immediately before the
                // synchronous append boundary, so a deletion committed by a
                // different window cannot materialize a writable chat here.
                switch await transcriptStore.tombstoneSnapshot(chatID: descriptor.id) {
                case .unknown:
                    blockedRestoredChatIDs.insert(descriptor.id)
                    continue
                case .present(let tombstone):
                    blockedRestoredChatIDs.insert(descriptor.id)
                    do {
                        _ = try await workspaceStateStore.removeAgentChatStateEverywhere(
                            chatID: descriptor.id
                        )
                    } catch {
                        // Keep the exact receipt blocked. The stale descriptor
                        // and transcript will be retried on the next healthy
                        // full archive scan, but neither is restored now.
                        continue
                    }
                    let removal = await enqueueTranscriptRemoval(
                        chatID: descriptor.id,
                        verifiedDescriptorPruning: tombstone
                    ).value
                    if removal.isRemoved {
                        usageCenter.remove(chatID: descriptor.id)
                        _ = await completeChatExternalCleanup(
                            chatID: descriptor.id,
                            tombstone: tombstone
                        )
                    }
                    continue
                case .absent:
                    break
                }
                guard appendChat(
                    id: descriptor.id,
                    agent: agent,
                    directory: directory,
                    title: descriptor.title
                        ?? "\(agent.name) · \(directory.lastPathComponent)",
                    resumeSessionID: descriptor.acpSessionID ?? transcript?.sessionID,
                    accountBinding: descriptor.accountBinding,
                    modelOverride: descriptor.modelOverride,
                    runProfile: descriptor.runProfile ?? .write,
                    requiresAccountResolution: true,
                    initialTranscript: transcript,
                    initialDraft: draft,
                    initialQueuedPrompts: descriptor.queuedPrompts
                ) != nil else { continue }
                // Legacy migration is a write. It is deliberately after the
                // final deletion authorization and synchronous append, never
                // between the final probe and materialization.
                if transcript?.draft == nil, let legacyDraft, !legacyDraft.isEmpty {
                    await transcriptStore.scheduleDraft(legacyDraft, for: descriptor.id)
                }
            }

            for pane in projectState.panes {
                guard !pane.isRecentlyClosed,
                      let descriptor = pane.surface.meshDescriptor,
                      !blockedRestoredMeshIDs.contains(descriptor.id),
                      meshes.contains(where: { $0.id == descriptor.id }) == false,
                      NativeSessionStore.projectID(forDirectory: descriptor.basePath) == descriptor.projectID else {
                    continue
                }
                var finalColumnReceipts: [AcpTranscriptStore.TombstoneSnapshot] = []
                var finalColumnProbeFailed = false
                for column in descriptor.columns {
                    switch await transcriptStore.tombstoneSnapshot(chatID: column.id) {
                    case let .present(receipt): finalColumnReceipts.append(receipt)
                    case .absent: break
                    case .unknown: finalColumnProbeFailed = true
                    }
                }
                if finalColumnProbeFailed || !finalColumnReceipts.isEmpty {
                    blockedRestoredMeshIDs.insert(descriptor.id)
                    // Batch deletion is all-or-nothing. A partial receipt set
                    // is not authority to erase the rest of a Mesh; retain its
                    // descriptor and every receipt fail-closed for diagnosis.
                    guard !finalColumnProbeFailed,
                          finalColumnReceipts.count == descriptor.columns.count else {
                        continue
                    }
                    do {
                        for receipt in finalColumnReceipts {
                            _ = try await workspaceStateStore.removeAgentChatStateEverywhere(
                                chatID: receipt.chatID
                            )
                            _ = try await workspaceStateStore.removeTranscriptStateEverywhere(
                                chatID: receipt.chatID
                            )
                        }
                    } catch {
                        continue
                    }
                    _ = await completeMeshColumnDeletion(finalColumnReceipts)
                    continue
                }
                if Self.claimedRestoredMeshIDs.contains(descriptor.id) {
                    deferredMeshPanesByProject[descriptor.projectID, default: []].append(pane)
                    continue
                }
                let directory = URL(fileURLWithPath: descriptor.basePath, isDirectory: true)
                    .standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    deferredMeshPanesByProject[descriptor.projectID, default: []].append(pane)
                    continue
                }
                guard let projectOverlay = projectAccountOverlay(
                    forProject: descriptor.projectID
                ) else {
                    deferredMeshPanesByProject[descriptor.projectID, default: []].append(pane)
                    continue
                }
                let environment = ProcessInfo.processInfo.environment
                    .merging(projectOverlay) { _, custom in custom }

                Self.claimedRestoredMeshIDs.insert(descriptor.id)
                deferredMeshPanesByProject[descriptor.projectID]?.removeAll { $0.id == descriptor.id }
                let draft = (try? await workspaceStateStore.draft(for: "mesh|\(descriptor.id)")) ?? ""
                let mesh = MeshSession(
                    id: descriptor.id,
                    baseDirectory: directory,
                    mode: descriptor.mode,
                    purpose: descriptor.purpose,
                    title: descriptor.title,
                    lifecycle: descriptor.lifecycle,
                    initialDraft: draft,
                    initialStagedPrompts: descriptor.stagedPrompts,
                    usageCenter: usageCenter
                )
                wireMeshPersistence(mesh)
                surfaceObservers[mesh.id] = mesh.objectWillChange.sink { [weak self] _ in
                    self?.scheduleSurfaceSummaryCheck()
                }
                meshes.append(mesh)

                var states: [MeshSession.RestoredColumnState] = []
                for column in descriptor.columns {
                    let transcript = await restoredTranscript(for: column.id)
                    states.append(MeshSession.RestoredColumnState(
                        descriptor: column,
                        rows: transcript?.page.rows ?? [],
                        rowStartOrdinal: transcript?.page.startOrdinal ?? 0,
                        earlierRowCount: transcript?.page.earlierRowCount ?? 0,
                        totalRowCount: transcript?.page.totalRowCount ?? 0,
                        initialDraft: transcript?.draft,
                        initialAttachments: transcript?.attachments ?? [],
                        persistedSessionID: transcript?.sessionID,
                        usage: transcript?.usage
                    ))
                }
                let restoreCompletion = await meshLifecycleCoordinator.restore(
                    mesh,
                    states: states,
                    agents: AgentRegistry.all,
                    environment: environment
                )
                guard restoreCompletion == .completed else {
                    meshes.removeAll { $0.id == mesh.id }
                    Self.claimedRestoredMeshIDs.remove(mesh.id)
                    surfaceObservers.removeValue(forKey: mesh.id)?.cancel()
                    meshLifecycleCoordinator.forget(meshID: mesh.id)
                    continue
                }
                if mesh.lifecycle == .pendingDeletion,
                   mesh.restorationDescriptor.columns.isEmpty {
                    let columnIDs = Array(Set(
                        descriptor.deletionColumnIDs + descriptor.columns.map(\.id)
                    )).sorted()
                    do {
                        let tombstones: [AcpTranscriptStore.TombstoneSnapshot]
                        if columnIDs.isEmpty {
                            tombstones = []
                        } else {
                            let result = await transcriptStore.tombstone(chatIDs: columnIDs)
                            guard case let .recorded(recorded) = result else {
                                throw NativeWorkspaceStateStore.StoreError
                                    .criticalDescriptorNotPersisted
                            }
                            tombstones = recorded
                        }
                        fenceDestroyedMeshPersistence(mesh)
                        _ = try await workspaceStateStore.removeMeshStateEverywhere(
                            meshID: mesh.id
                        )
                        meshes.removeAll { $0.id == mesh.id }
                        Self.claimedRestoredMeshIDs.remove(mesh.id)
                        surfaceObservers.removeValue(forKey: mesh.id)?.cancel()
                        meshLifecycleCoordinator.forget(meshID: mesh.id)
                        await persistWorkspaceStateImmediately(projectID: descriptor.projectID)
                        provisionedTranscriptIDsByMeshID.removeValue(forKey: mesh.id)
                        _ = await completeMeshColumnDeletion(tombstones)
                    } catch {
                        // Keep the empty pending-deletion recovery surface. A
                        // later explicit retry can complete its tombstone;
                        // ordinary snapshots must never resurrect it as active.
                    }
                }
            }

            var layout = projectState.layout
            for blockedChatID in blockedRestoredChatIDs {
                layout.remove(blockedChatID)
            }
            for blockedMeshID in blockedRestoredMeshIDs {
                layout.remove(blockedMeshID)
            }
            if connectionState.isConnected {
                // Dormant terminals (persisted records the broker no longer
                // holds — a reboot killed their PTYs) stay in the layout so a
                // later resurrection revives the same pane instead of the next
                // state save erasing it forever.
                let available = Set(
                    sessions.lazy.filter { $0.projectID == projectState.projectID }.map(\.id)
                ).union(chats(in: projectState.projectID).map(\.id))
                    .union(meshes(in: projectState.projectID).map(\.id))
                    .union(dormantTerminalIDs(in: projectState.projectID))
                layout.normalize(availableSessionIDs: available)
            } else {
                layout.normalize()
            }
            unifiedSessionCards.install(layout, for: projectState.projectID)
            restoreFileTabs(from: projectState)
        }

        for tombstone in verifiedDescriptorPruning.sorted(by: {
            $0.chatID == $1.chatID
                ? $0.generation < $1.generation
                : $0.chatID < $1.chatID
        }) {
            // Resume every boundary independently: transcript deletion can have
            // committed before a crash while the exact receipt still retains
            // the external-plaintext fence for this launch to finish.
            let removal = await enqueueTranscriptRemoval(
                chatID: tombstone.chatID,
                verifiedDescriptorPruning: tombstone
            ).value
            guard removal.isRemoved else { continue }
            usageCenter.remove(chatID: tombstone.chatID)
            _ = await completeChatExternalCleanup(
                chatID: tombstone.chatID,
                tombstone: tombstone
            )
        }

        if let projectID = restoration.selectedProjectID,
           let project = projects.first(where: { $0.id == projectID }) {
            selectedProjectID = project.id
            selectedProjectName = project.name
            if let state = restoration.projects.first(where: { $0.projectID == projectID }),
               let focused = state.focusedPaneID,
               unifiedSessionCards.restoreFocus(focused, in: projectID) {
                if chats.contains(where: { $0.id == focused }) {
                    selectedChatID = focused
                    selectedMeshID = nil
                } else if meshes.contains(where: { $0.id == focused }) {
                    selectedMeshID = focused
                    selectedChatID = nil
                } else if sessions.contains(where: { $0.id == focused }) {
                    await focusTerminalSurface(focused)
                }
            }
            restoreSelectedFilePreview(for: projectID)
        }
    }

    /// Turn a fail-closed restoration error into something the user can see and
    /// act on.
    ///
    /// Undecodable bytes are moved aside first, because that is what makes the
    /// rest of the session work: without it every subsequent save throws
    /// against the same protected file and the window silently stops
    /// persisting. An archive from a newer Kaisola is left exactly where it is
    /// — it is that version's state, not damage — and the notice says so.
    private func raiseWorkspaceRestorationNotice(for error: Error) async {
        let kind = WorkspaceRestorationNotice.Kind(storeError: error)
        var disposition = WorkspaceRestorationNotice.ArchiveDisposition.protectedInPlace
        if kind.allowsPreservingAside {
            // Opening several windows at once puts every one of them through
            // this path against the same damaged archive, and only the first
            // finds anything left to move. "Nothing to preserve" is that race
            // resolving in a sibling's favour, not a failed rescue: the bytes
            // are safe and this window's saves are unblocked exactly as if it
            // had done the move itself.
            switch try? await workspaceStateStore.preserveUnreadableArchive() {
            case .movedAside(let url):
                disposition = .movedAside(url)
            case .nothingToPreserve:
                disposition = .alreadyPreservedByAnotherWindow
            case nil:
                disposition = .protectedInPlace
            }
        }
        let notice = WorkspaceRestorationNotice(
            kind: kind,
            archiveURL: workspaceStateStore.archiveURL,
            disposition: disposition
        ).continuing(workspaceRestorationNotice)
        workspaceRestorationNotice = notice
        ToastCenter.shared.show(notice.summary, style: .error, duration: 6)
    }

    /// Read the archive again after the user has repaired or replaced it. A
    /// success clears the notice and restores normally; a failure updates the
    /// same notice with the new reason and a higher retry count.
    func retryWorkspaceRestoration() async {
        guard let previous = workspaceRestorationNotice else { return }
        workspaceRestorationNotice?.beginRetry()
        await workspaceStateStore.invalidateCache()
        restoredWorkspaceState = false
        await restoreWorkspaceStateIfNeeded()
        guard workspaceRestorationNotice == nil else { return }
        // A retry that lands on the empty archive written after the damaged one
        // was moved aside restored nothing, and this toast is the only place
        // that would say otherwise. A retry that found real state — the user
        // repaired or replaced the file — genuinely did restore their layout.
        let readEmptyArchive: Bool
        if previous.kind == .corruptArchive,
           !previous.savesBlocked,
           let restored = try? await workspaceStateStore.restorationState() {
            readEmptyArchive = restored.projects.isEmpty && restored.selectedProjectID == nil
        } else {
            readEmptyArchive = false
        }
        ToastCenter.shared.show(
            readEmptyArchive
                ? "Started a fresh layout — your damaged copy is kept beside it"
                : "Restored your saved window layout",
            style: .success
        )
    }

    /// Hide the banner without forgetting the problem: the compact indicator
    /// stays until a restore succeeds.
    func dismissWorkspaceRestorationBanner() {
        workspaceRestorationNotice?.dismissBanner()
    }

    func presentWorkspaceRestorationBanner() {
        workspaceRestorationNotice?.presentBanner()
    }

    func revealWorkspaceRestorationArchive() {
        guard let url = workspaceRestorationNotice?.revealURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func restoreFileTabs(from state: NativeProjectWorkspaceState) {
        guard let root = projects.first(where: { $0.id == state.projectID })?.directory else {
            deferredFileWorkspaceStates[state.projectID] = fileOnlyWorkspaceState(from: state)
            return
        }
        var rootIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            deferredFileWorkspaceStates[state.projectID] = fileOnlyWorkspaceState(from: state)
            return
        }
        deferredFileWorkspaceStates[state.projectID] = nil
        var tabs: [FileWorkbenchTab] = []
        var seen = Set<String>()
        for stored in state.fileTabs {
            let candidate = root.appendingPathComponent(stored.relativePath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard Self.isWithinWorkspace(candidate, workspace: root),
                  FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  seen.insert(candidate.path).inserted else { continue }
            tabs.append(FileWorkbenchTab(
                url: candidate,
                isPinned: stored.isPinned,
                line: stored.line
            ))
        }
        guard !tabs.isEmpty else {
            fileTabsByProject[state.projectID] = nil
            selectedFilePathByProject[state.projectID] = nil
            return
        }
        fileTabsByProject[state.projectID] = tabs
        let selected = state.selectedFilePath.flatMap { relative in
            root.appendingPathComponent(relative).standardizedFileURL.path
        }
        selectedFilePathByProject[state.projectID] = tabs.contains(where: { $0.url.path == selected })
            ? selected
            : tabs.last?.url.path
    }

    /// Deferred entries exist only to bridge a file deck across a temporarily
    /// unavailable project root. Pane and chat restoration remains live state;
    /// carrying it inside this cache can resurrect stale sessions when the
    /// folder is later reopened.
    private func fileOnlyWorkspaceState(
        from state: NativeProjectWorkspaceState
    ) -> NativeProjectWorkspaceState? {
        guard !state.fileTabs.isEmpty else { return nil }
        return NativeProjectWorkspaceState(
            projectID: state.projectID,
            fileTabs: state.fileTabs,
            selectedFilePath: state.selectedFilePath,
            updatedAt: state.updatedAt
        )
    }

    // MARK: - ACP chats

    /// Open a new ACP chat with the given agent in a directory. The adapter is
    /// spawned as a child of this app. The provider session id, visible
    /// transcript, layout, and draft are persisted so a capable adapter can
    /// resume after restart; a stale provider id falls back to a fresh session.
    /// `initialDraft` carries an unsent message into the new chat. It exists for
    /// the composer's agent switch: an ACP session is bound to one adapter
    /// process, so choosing a different agent opens a second chat rather than
    /// moving this one, and the sentence the user was mid-way through typing
    /// has to survive that. The source chat keeps its own copy — a navigation
    /// action must never be the reason typed text disappears.
    func openChat(
        _ agent: AgentProfile,
        inDirectory directory: URL,
        accountProfile: UsageAccountProfile? = nil,
        initialDraft: String? = nil,
        runProfile: AcpRunProfile? = nil
    ) {
        let project = sessionStore.openProject(directory: directory.path)
        refreshPersistedNavigationState(publish: false)
        selectedProjectID = project.id
        selectedProjectName = project.name
        // The staleness nudge fires at the one moment instructions start
        // mattering, once per project per run, and stays informational.
        if !Self.staleInstructionNudgesShown.contains(project.id),
           let nudge = InstructionFileStaleness.nudge(forProjectAt: directory) {
            Self.staleInstructionNudgesShown.insert(project.id)
            ToastCenter.shared.show(nudge, style: .info, duration: 6)
        }
        let chatID = "chat-\(UUID().uuidString.lowercased())"
        guard let projectOverlay = projectAccountOverlay(forProject: project.id) else { return }
        let effectiveAccountEnvironment = ProcessInfo.processInfo.environment
            .merging(projectOverlay) { _, configured in configured }
        // Custom agents bind by their *declared* credentials (review finding
        // 3): a declared provider resolves through the identical rules the
        // built-ins use, and a declared `.none` opens the chat with no
        // account binding and no resumable provider identity.
        let accountBinding: SessionAccountBinding?
        if let provider = SessionAccountBinding.declaredProvider(forAgentID: agent.id) {
            guard let resolved = SessionAccountBinding.resolve(
                provider: provider,
                profile: accountProfile,
                fallbackEnvironment: effectiveAccountEnvironment
            ) else {
                ToastCenter.shared.show("That account does not match \(agent.name).", style: .error)
                return
            }
            accountBinding = resolved
        } else {
            accountBinding = nil
        }
        // Say it before the first turn fails rather than after. Advisory only:
        // starting on a spent account stays allowed, because the reading can be
        // stale and the call is not Kaisola's to make.
        if let accountBinding,
           let warning = SessionAccountBinding.headroomWarning(
               for: accountBinding,
               readings: UsageCenter.shared.planUsage
           ) {
            ToastCenter.shared.show(warning, style: .info, duration: 5)
        }
        let runProfile = runProfile ?? AcpRunProfileStore().defaultProfile
        // This is the sole product call that establishes a new incarnation,
        // immediately after generating a fresh UUID and before the descriptor
        // can enter the workspace archive. Restore/reconnect paths only verify
        // an already durable incarnation.
        enqueueNewTranscriptChatIncarnation(chatID: chatID)
        guard appendChat(
            id: chatID,
            agent: agent,
            directory: directory,
            title: "\(agent.name) · \((directory.path as NSString).lastPathComponent)",
            resumeSessionID: nil,
            accountBinding: accountBinding,
            modelOverride: runProfile.modelID,
            runProfile: runProfile,
            initialTranscript: nil,
            initialDraft: initialDraft,
            initialQueuedPrompts: []
        ) != nil else { return }
        focusPane(chatID, projectID: project.id)
        focusSurfaceFields(chatID)
        scheduleWorkspaceStateSave(projectID: project.id)
    }

    @discardableResult
    private func appendChat(
        id chatID: String,
        agent: AgentProfile,
        directory: URL,
        title: String,
        resumeSessionID: String?,
        accountBinding: SessionAccountBinding?,
        modelOverride: String? = nil,
        runProfile: AcpRunProfile = .write,
        accountAccess: ChatAccountAccess? = nil,
        requiresAccountResolution: Bool = false,
        initialTranscript: AcpTranscriptStore.Restoration?,
        initialDraft: String?,
        initialQueuedPrompts: [String]
    ) -> AcpChatHandle? {
        guard chats.contains(where: { $0.id == chatID }) == false else { return nil }
        explicitlyClosedChatIDs.remove(chatID)
        // The declared-credentials contract is enforced HERE, not only at
        // openChat: every path into a chat — new, workspace restore, Recently
        // Closed, account and model switches — funnels through this method,
        // so a persisted binding that no longer matches the roster's current
        // declaration is dropped, and its resumable identity with it
        // (adversarial review, finding 3). A declared `.none` never carries a
        // binding at all.
        let declaredProvider = SessionAccountBinding.declaredProvider(forAgentID: agent.id)
        let accountBinding: SessionAccountBinding? = {
            guard let declaredProvider else { return nil }
            guard let normalized = accountBinding?.normalized,
                  normalized.provider == declaredProvider else { return nil }
            return normalized
        }()
        let projectID = NativeSessionStore.projectID(forDirectory: directory.path)
        var runProfileSnapshot = runProfile
        runProfileSnapshot.modelID = modelOverride ?? runProfile.modelID
        let mcp = McpConfigStore(workspace: directory).servers()
        guard let projectOverlay = projectAccountOverlay(forProject: projectID) else { return nil }
        let baseEnvironment = ProcessInfo.processInfo.environment
            .merging(projectOverlay) { _, custom in custom }
        var environment = SessionAccountBinding.applying(accountBinding, to: baseEnvironment)
        environment = SessionModelOverride.applying(runProfileSnapshot.modelID, agentID: agent.id, to: environment)
        // The host marker — see the terminal spawn's twin assignment.
        environment["KAISOLA"] = "1"
        environment["KAISOLA_SESSION_ID"] = chatID
        guard let adapter = AcpAdapter.forAgent(agent.id, environment: environment) else { return nil }
        // Legacy descriptors have no immutable account context. Starting a new
        // provider thread preserves the visible transcript without risking a
        // resume under credentials that differ from the original continuation.
        let safeResumeSessionID = accountBinding?.normalized == nil ? nil : resumeSessionID
        let providerContext = AcpProviderLaunchContext(
            providerName: declaredProvider?.displayName ?? agent.name,
            accountLabel: accountBinding?.label ?? "Default account",
            defaultSettingsSectionID: declaredProvider == nil ? "agents" : "accounts"
        )
        let conversation = AcpConversation(
            title: title,
            command: adapter.command,
            arguments: adapter.arguments,
            containment: adapter.containment,
            environment: environment,
            cwd: directory.path,
            transcriptAgentID: agent.id,
            transcriptAgentName: agent.name,
            transcriptModelID: modelOverride,
            providerContext: providerContext,
            mcpServers: McpConfigStore.jsonValues(mcp),
            runProfile: runProfileSnapshot,
            sensitiveGlobs: NativePreviewSettings.shared.sensitiveGlobs,
            draftKey: chatID,
            resumeSessionID: safeResumeSessionID,
            initialRows: initialTranscript?.page.rows ?? [],
            initialRowStartOrdinal: initialTranscript?.page.startOrdinal ?? 0,
            initialEarlierRowCount: initialTranscript?.page.earlierRowCount ?? 0,
            initialTotalRowCount: initialTranscript?.page.totalRowCount ?? 0,
            initialRetentionStatus: initialTranscript?.retentionStatus ?? .empty,
            initialDraft: initialDraft,
            initialAttachments: initialTranscript?.attachments ?? [],
            initialUsage: initialTranscript?.usage.map {
                AcpUsage(
                    used: $0.latestUsed,
                    max: $0.latestMax,
                    costAmount: $0.costAmount,
                    costCurrency: $0.costCurrency
                )
            },
            initialQueuedPrompts: initialQueuedPrompts
        )
        usageCenter.register(chatID: chatID, sourceID: usageSourceID)
        if let initialUsage = initialTranscript?.usage {
            usageCenter.restore(chatID: chatID, snapshot: initialUsage)
        }
        // Fan this chat's live context usage into the session-wide UsageCenter.
        var chatUsageObservers = Set<AnyCancellable>()
        conversation.$usage
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self, weak conversation] usage in
                guard let self, let conversation else { return }
                self.usageCenter.record(
                    chatID: chatID, title: conversation.title, agentID: agent.id,
                    usage: usage.used, max: usage.max,
                    costAmount: usage.costAmount,
                    costCurrency: usage.costCurrency
                )
            }
            .store(in: &chatUsageObservers)
        conversation.$isRunning
            .scan((false, false)) { ($0.1, $1) }
            .filter { $0.0 && !$0.1 }
            .sink { [weak self] _ in
                guard let self else { return }
                self.usageCenter.recordTurn(chatID: chatID)
            }
            .store(in: &chatUsageObservers)
        usageObservers[chatID] = chatUsageObservers
        // Completed turns remain visible at project level until visited. A
        // permission already visible in the focused chat does not need a
        // duplicate attention entry.
        conversation.onAttention = { [weak self, weak conversation] kind, detail in
            guard let self, let conversation else { return }
            let appActive = NSApp?.isActive ?? true
            if kind != .turnCompleted, self.selectedChatID == chatID, appActive { return }
            self.attentionCenter.notify(
                kind: kind,
                targetID: chatID,
                title: conversation.title,
                detail: detail
            )
        }
        conversation.onTranscriptChanged = { [weak self] rows, startOrdinal in
            self?.enqueueTranscriptSave(
                rows,
                startOrdinal: startOrdinal,
                chatID: chatID
            )
        }
        conversation.onRetryTranscriptPersistence = { [weak self] in
            self?.retryTranscriptPersistence(chatID: chatID)
        }
        let exportStore = transcriptStore
        conversation.onExportTranscriptMarkdown = { request, destination in
            try await exportStore.exportMarkdown(
                for: chatID,
                request: request,
                to: destination
            )
        }
        let healthStore = transcriptStore
        Task { [weak conversation] in
            let health = await healthStore.persistenceHealth(for: chatID)
            conversation?.applyTranscriptPersistenceHealth(health)
        }
        let pageStore = transcriptStore
        conversation.loadEarlierRows = { beforeOrdinal, limit in
            await pageStore.page(
                for: chatID,
                beforeOrdinal: beforeOrdinal,
                limit: limit
            )
        }
        conversation.onFileActivity = { [weak self] activity in
            self?.recordAgentFileActivity(
                activity,
                surfaceID: chatID,
                projectID: projectID,
                workspaceRoot: directory
            ) ?? false
        }
        conversation.onDraftChanged = { [weak self] text in
            self?.enqueueDraftSave(
                text,
                chatID: chatID,
                projectID: projectID,
                agentID: agent.id,
                workspacePath: directory.path
            )
        }
        conversation.onAttachmentsChanged = { [weak self] attachments in
            self?.enqueueTranscriptAttachments(attachments, chatID: chatID)
        }
        conversation.onProviderSessionID = { [weak self] sessionID in
            self?.enqueueTranscriptSessionID(sessionID, chatID: chatID)
            self?.scheduleWorkspaceStateSave(projectID: projectID)
        }
        conversation.onQueueChanged = { [weak self] _ in
            self?.scheduleWorkspaceStateSave(projectID: projectID)
        }
        conversation.onConfirmedModelFallback = { [weak self, weak conversation] actualModelID in
            guard let self, let conversation,
                  let index = self.chats.firstIndex(where: { $0.id == chatID }),
                  self.chats[index].conversation === conversation else { return }
            let existing = self.chats[index]
            self.chats[index] = existing.replacingModelOverride(with: actualModelID)
            self.scheduleWorkspaceStateSave(projectID: projectID)
        }
        let accountAccess = accountAccess ?? ChatAccountAccess(
            binding: accountBinding,
            requiresResolution: requiresAccountResolution
        )
        let handle = AcpChatHandle(
            id: chatID,
            agentID: agent.id,
            workspaceDirectory: directory,
            accountBinding: accountBinding,
            modelOverride: runProfileSnapshot.modelID,
            runProfile: runProfileSnapshot,
            accountAccess: accountAccess,
            conversation: conversation
        )
        accountAccess.onResumeInvalidationRequired = { [weak self] in
            self?.scheduleChatResumeInvalidation(chatID)
        }
        chats.append(handle)
        surfaceObservers[chatID] = conversation.objectWillChange.sink { [weak self] _ in
            self?.scheduleSurfaceSummaryCheck()
        }
        reconcileChatAccountAvailability(for: handle)
        if requiresAccountResolution, accountAccess.phase == .resolving {
            usageCenter.refreshPlanUsage(workspace: directory, force: false)
        }
        return handle
    }

    /// Ordinary close moves a chat into the durable Recently Closed archive.
    /// Its adapter stops, but transcript, draft, usage, and continuation
    /// identity remain available to Restore and Undo Last Close.
    @discardableResult
    func closeChat(_ chatID: String) -> Bool {
        let closingChat = chats.first(where: { $0.id == chatID })
        guard let closingChat else { return false }
        let projectID = closingChat.projectID
        let closedChatCount = recentlyClosedPanes.lazy.filter {
            $0.surface.projectID == projectID
                && $0.isRecentlyClosed
                && $0.surface.kind == .agentChat
        }.count
        guard closedChatCount < NativeWorkspaceStateStore.maximumRecentlyClosedChatsPerProject else {
            ToastCenter.shared.show(
                "Recently Closed is full. Permanently delete an older chat before closing another.",
                style: .error,
                duration: 5
            )
            return false
        }

        let sizeWeight = workspaceSnapshot(projectID: projectID)?.panes
            .first(where: { $0.id == chatID })?.sizeWeight ?? 1
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: closingChat.id,
            projectID: projectID,
            agentID: closingChat.agentID,
            workspacePath: closingChat.workspaceDirectory.path,
            acpSessionID: closingChat.conversation.providerSessionID,
            accountBinding: closingChat.accountBinding,
            title: closingChat.conversation.title,
            queuedPrompts: closingChat.conversation.queued.map(\.text),
            modelOverride: closingChat.modelOverride,
            runProfile: closingChat.runProfile
        )
        storeRecentlyClosedPane(NativeRestorablePaneState(
            id: chatID,
            surface: NativeRestorableSurfaceState(agentChat: descriptor),
            sizeWeight: sizeWeight,
            isMinimized: true,
            isRecentlyClosed: true,
            closedAt: nextRecentlyClosedTimestamp()
        ))

        chatShutdownTasks.start(chatID) { [weak self] in
            if let finalDraft = await closingChat.conversation.stop() {
                self?.enqueueDraftSave(
                    finalDraft,
                    chatID: chatID,
                    projectID: projectID,
                    agentID: closingChat.agentID,
                    workspacePath: closingChat.workspaceDirectory.path
                )
            }
        }
        closingChat.conversation.onFileActivity = nil
        chats.removeAll { $0.id == chatID }
        usageObservers.removeValue(forKey: chatID)?.forEach { $0.cancel() }
        usageCenter.unregister(
            chatID: chatID,
            sourceID: usageSourceID,
            forgetWhenLast: false
        )
        surfaceObservers.removeValue(forKey: chatID)?.cancel()
        attentionCenter.clear(targetID: chatID)
        if selectedChatID == chatID { selectedChatID = nil }
        unifiedSessionCards.remove(chatID, from: projectID)
        scheduleWorkspaceStateSave(projectID: projectID)
        ToastCenter.shared.show("Moved chat to Recently Closed", style: .success)
        return true
    }

    /// The explicit permanent-delete boundary for a live chat.
    @discardableResult
    func deleteChat(_ chatID: String) async -> AcpTranscriptStore.Removal {
        let closingChat = chats.first(where: { $0.id == chatID })
        // Tombstone FIRST (§4e): the durable record of intent that every
        // later phase — and every other window sharing the database —
        // converges on, even across a crash. A failed write aborts the
        // delete instead of reporting success. If the app dies before this
        // lands, the delete simply didn't happen — never half-happened.
        let tombstoneResult = await transcriptStore.tombstone(chatID: chatID)
        guard case let .recorded(tombstone) = tombstoneResult else {
            guard case let .failed(error) = tombstoneResult else {
                return .failed(.database("transcript deletion intent was not recorded"))
            }
            ToastCenter.shared.show(
                "Couldn't delete the chat: \(error.message)",
                style: .error
            )
            return .failed(error)
        }
        // Fence every callback synchronously before the next await. A draft
        // already queued before the tombstone is drained below; anything that
        // arrives afterward is refused by `enqueueDraftSave(chatID:)`.
        explicitlyClosedChatIDs.insert(chatID)
        if let closingChat {
            closingChat.conversation.onTranscriptChanged = nil
            closingChat.conversation.onFileActivity = nil
            closingChat.conversation.onDraftChanged = nil
            closingChat.conversation.onQueueChanged = nil
            // The composer outlives this call by a frame or two. Taking the
            // draft key away with the text stops a late `saveDraft` from
            // writing the deleted plaintext back into defaults.
            closingChat.conversation.forgetPersistentDraft()
            chatShutdownTasks.start(chatID) {
                _ = await closingChat.conversation.stop()
            }
        }
        // The archive-wide removal is the durable proof that workspace
        // plaintext is gone. Let every older queued save finish first so none
        // can land after that proof and outlive the exact cleanup receipt.
        await draftPersistenceTask?.value
        var descriptorRemovalFailure: String?
        var descriptorPruningReceipt: AcpTranscriptStore.TombstoneSnapshot?
        do {
            _ = try await workspaceStateStore.removeAgentChatStateEverywhere(
                chatID: chatID
            )
            descriptorPruningReceipt = tombstone
        } catch {
            // Transcript tombstoning is already durable, so restoration stays
            // fail-closed if any duplicate descriptor cannot be removed. Keep
            // the exact receipt blocked for launch-time recovery.
            descriptorRemovalFailure = error.localizedDescription
        }
        chats.removeAll { $0.id == chatID }
        usageObservers.removeValue(forKey: chatID)?.forEach { $0.cancel() }
        let forgetDurableChat = usageCenter.unregister(
            chatID: chatID,
            sourceID: usageSourceID,
            forgetWhenLast: true
        )
        surfaceObservers.removeValue(forKey: chatID)?.cancel()
        attentionCenter.clear(targetID: chatID)
        if selectedChatID == chatID { selectedChatID = nil }
        if let projectID = closingChat?.projectID {
            unifiedSessionCards.remove(chatID, from: projectID)
        }
        // Unconditional (§4e): the user deleted the chat, so its transcript
        // goes — the old forgetDurableChat gate could leave tombstoned
        // content on disk forever when usage bookkeeping said "shared".
        _ = forgetDurableChat
        // If catalog pruning failed, transcript erasure must retain its
        // tombstone atomically. Otherwise remove() could erase the chat row
        // and reclaim the only fence that keeps this stale descriptor from
        // restoring on the next launch.
        let removalResult = await enqueueTranscriptRemoval(
            chatID: chatID,
            verifiedDescriptorPruning: descriptorPruningReceipt
        ).value
        // The workspace archive must reflect the deletion durably NOW, not
        // after a 220 ms debounce a crash can beat (§4e).
        // The descriptor was removed synchronously above. Do not route this
        // through the ordinary merge-preserving snapshot path: another window
        // may legitimately omit this chat, while only this explicit store
        // operation is allowed to prove deletion intent.
        // The tombstone already keeps the chat closed, but a DELETE that never
        // committed left its bytes on disk. Say that instead of letting the
        // silent close read as a finished permanent delete.
        if let failure = removalResult.failureMessage {
            ToastCenter.shared.show(
                "The chat is closed, but its transcript could not be erased from disk: \(failure)",
                style: .error
            )
            return removalResult
        }
        if let descriptorRemovalFailure {
            // The transcript tombstone is durable and every callback capable
            // of submitting new chat work was fenced before the surface was
            // removed above. Report the incomplete catalog cleanup without
            // leaving a writable UI attached to a tombstoned transcript.
            ToastCenter.shared.show(
                "The chat is closed, but its workspace descriptor could not be erased: \(descriptorRemovalFailure)",
                style: .error
            )
            return .failed(.database(descriptorRemovalFailure))
        }
        let cleanupResult = await completeChatExternalCleanup(
            chatID: chatID,
            tombstone: tombstone
        )
        if let failure = cleanupResult.failureMessage {
            ToastCenter.shared.show(
                "The chat is closed, but its saved draft cleanup is incomplete: \(failure)",
                style: .error
            )
            return cleanupResult
        }
        return .removed
    }

    /// Keep restored chat startup and live-account invalidation on the same
    /// local truth used by Usage settings. Published readings cover logout;
    /// the account-list notification covers removal and successful sign-in.
    private func observeChatAccountAvailability() {
        usageCenter.$planUsage
            .combineLatest(usageCenter.$isRefreshingPlanUsage)
            .sink { [weak self] readings, isRefreshing in
                guard let self else { return }
                self.reconcileChatAccountAvailability(
                    profiles: self.usageAccountStore.profiles(),
                    readings: readings,
                    isRefreshing: isRefreshing
                )
            }
            .store(in: &chatAccountObservers)
        NotificationCenter.default.publisher(for: .kaisolaUsageAccountsChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                // An add/remove/sign-in changes the credential fingerprint.
                // Do not let the preceding context's cached success unlock a
                // continuation before the forced probe returns.
                self.reconcileChatAccountAvailability(
                    profiles: self.usageAccountStore.profiles(),
                    readings: [],
                    isRefreshing: true
                )
                self.usageCenter.refreshPlanUsage(
                    workspace: self.currentProjectDirectory,
                    force: true
                )
            }
            .store(in: &chatAccountObservers)
    }

    private func reconcileChatAccountAvailability(
        profiles: [UsageAccountProfile]? = nil,
        readings: [UsageCenter.ProviderPlanUsage]? = nil,
        isRefreshing: Bool? = nil,
        now: Date = Date()
    ) {
        let profiles = profiles ?? usageAccountStore.profiles()
        let readings = readings ?? usageCenter.planUsage
        let isRefreshing = isRefreshing ?? usageCenter.isRefreshingPlanUsage
        for chat in chats {
            reconcileChatAccountAvailability(
                for: chat,
                profiles: profiles,
                readings: readings,
                isRefreshing: isRefreshing,
                now: now
            )
        }
    }

    private func reconcileChatAccountAvailability(
        for chat: AcpChatHandle,
        profiles: [UsageAccountProfile]? = nil,
        readings: [UsageCenter.ProviderPlanUsage]? = nil,
        isRefreshing: Bool? = nil,
        now: Date = Date()
    ) {
        let transition = chat.accountAccess.reconcile(.init(
            profiles: profiles ?? usageAccountStore.profiles(),
            readings: readings ?? usageCenter.planUsage,
            isRefreshing: isRefreshing ?? usageCenter.isRefreshingPlanUsage,
            now: now
        ))
        if transition == .requiresResumeInvalidation {
            scheduleChatResumeInvalidation(chat.id)
        }
    }

    /// Coalesced to one pass per runloop turn, for two reasons.
    ///
    /// `objectWillChange` fires *before* the property changes, so reading a
    /// conversation inside its own sink returns the previous value. Deferring
    /// the read to the next turn is what makes the comparison meaningful.
    ///
    /// It also collapses a burst: a streaming turn publishes rows and
    /// contentVersion for every chunk, and several conversations can stream at
    /// once. One comparison per turn answers all of them.
    private func scheduleSurfaceSummaryCheck() {
        guard !surfaceSummaryCheckScheduled else { return }
        surfaceSummaryCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.surfaceSummaryCheckScheduled = false
            self.publishIfSurfacesChanged()
        }
    }

    /// Re-broadcast only when something the shell renders about a chat moved.
    ///
    /// The shell used to be invalidated by every conversation publish, which
    /// during a streaming turn is every chunk — and with several conversations
    /// running, several times that. Nothing outside the chat surface renders a
    /// transcript, so almost all of it announced a change no observer could see.
    private func publishIfSurfacesChanged() {
        var summaries: [String: ChatSurfaceSummary] = [:]
        summaries.reserveCapacity(chats.count)
        for chat in chats {
            let conversation = chat.conversation
            summaries[chat.id] = ChatSurfaceSummary(
                title: conversation.title,
                isRunning: conversation.isRunning,
                isConnected: conversation.isConnected,
                statusMessage: conversation.statusMessage,
                pendingPermissionCount: conversation.pendingPermissionCount,
                queuedCount: conversation.queued.count,
                hasRows: !conversation.rows.isEmpty,
                usage: conversation.usage
            )
        }
        var meshSummaries: [String: MeshSurfaceSummary] = [:]
        meshSummaries.reserveCapacity(meshes.count)
        for mesh in meshes {
            meshSummaries[mesh.id] = MeshSurfaceSummary(
                title: mesh.title,
                anyRunning: mesh.anyRunning,
                stage: mesh.stage,
                // The shell builds run targets from column worktrees, which move
                // when a column is configured rather than when one streams.
                columnTargets: mesh.columns.map { column in
                    "\(column.worktreePath ?? "")|\(column.branch ?? "")"
                }
            )
        }
        guard summaries != chatSurfaceSummaries || meshSummaries != meshSurfaceSummaries else {
            return
        }
        chatSurfaceSummaries = summaries
        meshSurfaceSummaries = meshSummaries
        objectWillChange.send()
    }

    private func scheduleChatResumeInvalidation(_ chatID: String) {
        guard chats.contains(where: { $0.id == chatID }),
              chatAccountInvalidationTasks[chatID] == nil else { return }
        chatAccountInvalidationTasks[chatID] = Task { @MainActor [weak self] in
            await self?.invalidateChatResumeIdentity(chatID)
            self?.chatAccountInvalidationTasks[chatID] = nil
        }
    }

    /// Replace only the adapter-bearing handle, with no provider resume id.
    /// The stable chat id, pane, selection, transcript, draft, attachments and
    /// queued follow-ups survive; the stopped process cannot become a zombie.
    private func invalidateChatResumeIdentity(_ chatID: String) async {
        guard let chat = chats.first(where: { $0.id == chatID }),
              let agent = AgentRegistry.profile(id: chat.agentID) else { return }
        let finalDraft = await chat.conversation.stop()
        if let finalDraft {
            enqueueDraftSave(
                finalDraft,
                chatID: chatID,
                projectID: chat.projectID,
                agentID: chat.agentID,
                workspacePath: chat.workspaceDirectory.path
            )
        }
        await flushTranscriptPersistence()
        let transcript = await restoredTranscript(for: chatID)
        guard let live = chats.first(where: { $0.id == chatID }),
              live.conversation === chat.conversation else { return }

        let queued = chat.conversation.queued.map(\.text)
        chats.removeAll { $0.id == chatID }
        usageObservers.removeValue(forKey: chatID)?.forEach { $0.cancel() }
        usageCenter.unregister(chatID: chatID, sourceID: usageSourceID, forgetWhenLast: false)
        surfaceObservers.removeValue(forKey: chatID)?.cancel()
        enqueueTranscriptSessionID(nil, chatID: chatID)
        guard appendChat(
            id: chatID,
            agent: agent,
            directory: chat.workspaceDirectory,
            title: chat.conversation.title,
            resumeSessionID: nil,
            accountBinding: chat.accountBinding,
            modelOverride: chat.modelOverride,
            runProfile: chat.runProfile,
            accountAccess: chat.accountAccess,
            initialTranscript: transcript,
            initialDraft: finalDraft ?? transcript?.draft,
            initialQueuedPrompts: queued
        ) != nil else { return }
        scheduleWorkspaceStateSave(projectID: chat.projectID)
    }

    /// Profile used by the recovery card's direct Sign In sheet. If the user
    /// had removed the registry entry, this explicit action re-registers the
    /// exact immutable id/path before authentication begins.
    func accountSignInProfile(for chatID: String) -> UsageAccountProfile? {
        guard let chat = chats.first(where: { $0.id == chatID }),
              let binding = chat.accountBinding,
              let accountID = binding.accountID else { return nil }
        let requested = UsageAccountProfile(
            id: accountID,
            provider: binding.provider,
            label: binding.label,
            directory: binding.configDirectory
        )
        let profile = usageAccountStore.profiles().first(where: {
            guard $0.id == accountID, $0.provider == binding.provider else { return false }
            return SessionAccountBinding.resolve(
                provider: $0.provider,
                profile: $0,
                fallbackEnvironment: [:]
            )?.continuationKey == binding.continuationKey
        }) ?? usageAccountStore.restore(requested)
        guard let profile else { return nil }
        chat.accountAccess.beginRecovery()
        NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
        return profile
    }

    /// Explicitly confirms the non-destructive path advertised by the blocked
    /// state. This never removes the pane or transcript; it only makes sure the
    /// adapter is stopped and the latest debounced draft is durable.
    func preserveBlockedChat(_ chatID: String) async {
        if let task = chatAccountInvalidationTasks[chatID] { await task.value }
        guard let chat = chats.first(where: { $0.id == chatID }) else { return }
        if let finalDraft = await chat.conversation.stop() {
            enqueueDraftSave(
                finalDraft,
                chatID: chatID,
                projectID: chat.projectID,
                agentID: chat.agentID,
                workspacePath: chat.workspaceDirectory.path
            )
            await draftPersistenceTask?.value
        }
        ToastCenter.shared.show("Transcript and draft kept. No agent is running.", style: .success)
    }

    /// Stop the adapter without deleting the surface, transcript, or draft.
    /// The conversation can be restarted in place, so ordinary run control no
    /// longer has to go through the destructive close path.
    func stopChat(_ chatID: String) {
        guard let chat = chats.first(where: { $0.id == chatID }) else { return }
        Task { _ = await chat.conversation.stop() }
    }

    /// Move a live chat to a different provider account, mid-conversation
    /// included — "should be able to change subscription login in an mcp/acp
    /// agent chat and during if possible".
    ///
    /// The transcript, draft, and queued prompts survive; the provider thread
    /// does not. Resuming a continuation under different credentials is never
    /// safe (the same rule `appendChat`'s `safeResumeSessionID` enforces at
    /// restore), so the switch stops the running adapter, lets persistence
    /// drain, and restarts the same chat surface under the new binding with a
    /// fresh provider session. Switching during a turn cuts that turn — which
    /// is what asking to switch *now* means — and the queue then flushes into
    /// the new session.
    func switchChatAccount(_ chatID: String, to profile: UsageAccountProfile?) async {
        if let task = chatAccountInvalidationTasks[chatID] { await task.value }
        guard let chat = chats.first(where: { $0.id == chatID }),
              let agent = AgentRegistry.profile(id: chat.agentID) else { return }
        let projectID = chat.projectID
        guard let overlay = projectAccountOverlay(forProject: projectID) else { return }
        guard let binding = SessionAccountBinding.resolve(
            agentID: chat.agentID,
            profile: profile,
            fallbackEnvironment: ProcessInfo.processInfo.environment
                .merging(overlay) { _, configured in configured }
        ) else {
            ToastCenter.shared.show("That account does not match \(agent.name).", style: .error)
            return
        }
        if let current = chat.accountBinding?.normalized,
           current.continuationKey == binding.continuationKey {
            ToastCenter.shared.show("This chat is already using \(binding.label).", style: .info)
            return
        }
        if let warning = SessionAccountBinding.headroomWarning(
            for: binding,
            readings: UsageCenter.shared.planUsage
        ) {
            ToastCenter.shared.show(warning, style: .info, duration: 5)
        }
        let directory = chat.workspaceDirectory
        let title = chat.conversation.title
        let queued = chat.conversation.queued.map(\.text)
        let requiresAccountResolution = !chat.accountAccess.allowsAdapterStart
        // Stop the adapter and let every buffered row and the draft reach the
        // store before the transcript is read back for the new handle.
        let finalDraft = await chat.conversation.stop()
        await flushTranscriptPersistence()
        let transcript = await restoredTranscript(for: chatID)
        // Re-check after the awaits: a concurrent close, delete, or second
        // switch may have replaced or removed the handle this call captured.
        guard let live = chats.first(where: { $0.id == chatID }),
              live.conversation === chat.conversation else { return }
        // The surface stays: same id, same pane, same selection. Only the
        // handle and its process are replaced, with no await between removal
        // and re-append, so no frame renders a missing session.
        chats.removeAll { $0.id == chatID }
        usageObservers.removeValue(forKey: chatID)?.forEach { $0.cancel() }
        usageCenter.unregister(chatID: chatID, sourceID: usageSourceID, forgetWhenLast: false)
        surfaceObservers.removeValue(forKey: chatID)?.cancel()
        guard appendChat(
            id: chatID,
            agent: agent,
            directory: directory,
            title: title,
            resumeSessionID: nil,
            accountBinding: binding,
            modelOverride: chat.modelOverride,
            runProfile: chat.runProfile,
            requiresAccountResolution: requiresAccountResolution,
            initialTranscript: transcript,
            initialDraft: finalDraft ?? transcript?.draft,
            initialQueuedPrompts: queued
        ) != nil else {
            ToastCenter.shared.show(
                "The chat adapter is unavailable, so the account was not switched.",
                style: .error
            )
            return
        }
        scheduleWorkspaceStateSave(projectID: projectID)
        ToastCenter.shared.show(
            requiresAccountResolution
                ? "Checking \(binding.label) before starting. The transcript stays."
                : "Switched to \(binding.label). Fresh provider session; the transcript stays.",
            style: requiresAccountResolution ? .info : .success
        )
    }

    /// Move a live chat to a different model — the account switch's twin, with
    /// one important difference: the credentials do not change, so the
    /// provider thread is a legitimate resume candidate and the conversation's
    /// context survives wherever the adapter honors resume. `nil` returns the
    /// chat to the app-default model.
    func switchChatModel(_ chatID: String, to model: String?) async {
        guard let chat = chats.first(where: { $0.id == chatID }),
              let agent = AgentRegistry.profile(id: chat.agentID) else { return }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (trimmed?.isEmpty == false) ? trimmed : nil
        guard target != chat.modelOverride else {
            ToastCenter.shared.show(
                "This chat is already on \(target ?? "the default model").",
                style: .info
            )
            return
        }
        let projectID = chat.projectID
        let directory = chat.workspaceDirectory
        let title = chat.conversation.title
        let queued = chat.conversation.queued.map(\.text)
        let resumeSessionID = chat.conversation.providerSessionID
        let finalDraft = await chat.conversation.stop()
        await flushTranscriptPersistence()
        let transcript = await restoredTranscript(for: chatID)
        guard let live = chats.first(where: { $0.id == chatID }),
              live.conversation === chat.conversation else { return }
        chats.removeAll { $0.id == chatID }
        usageObservers.removeValue(forKey: chatID)?.forEach { $0.cancel() }
        usageCenter.unregister(chatID: chatID, sourceID: usageSourceID, forgetWhenLast: false)
        surfaceObservers.removeValue(forKey: chatID)?.cancel()
        guard appendChat(
            id: chatID,
            agent: agent,
            directory: directory,
            title: title,
            resumeSessionID: resumeSessionID ?? transcript?.sessionID,
            accountBinding: chat.accountBinding,
            modelOverride: target,
            runProfile: chat.runProfile,
            initialTranscript: transcript,
            initialDraft: finalDraft ?? transcript?.draft,
            initialQueuedPrompts: queued
        ) != nil else {
            ToastCenter.shared.show(
                "The chat adapter is unavailable, so the model was not switched.",
                style: .error
            )
            return
        }
        scheduleWorkspaceStateSave(projectID: projectID)
        ToastCenter.shared.show(
            "Switched to \(target ?? "the default model").",
            style: .success
        )
    }

    /// Rebuild the adapter on a new immutable run-profile snapshot. ACP binds
    /// client capabilities and MCP servers during initialize/session-new, so a
    /// live process can never be safely widened or narrowed in place.
    func switchChatRunProfile(_ chatID: String, to profileID: String) async {
        guard let chat = chats.first(where: { $0.id == chatID }),
              let agent = AgentRegistry.profile(id: chat.agentID),
              let profile = AcpRunProfileStore().profile(id: profileID) else {
            ToastCenter.shared.show("That run profile is no longer available.", style: .error)
            return
        }
        guard profile != chat.runProfile else {
            ToastCenter.shared.show("This chat already uses \(profile.name).", style: .info)
            return
        }
        let projectID = chat.projectID
        let queued = chat.conversation.queued.map(\.text)
        let finalDraft = await chat.conversation.stop()
        await flushTranscriptPersistence()
        let transcript = await restoredTranscript(for: chatID)
        guard let live = chats.first(where: { $0.id == chatID }),
              live.conversation === chat.conversation else { return }
        chats.removeAll { $0.id == chatID }
        usageObservers.removeValue(forKey: chatID)?.forEach { $0.cancel() }
        usageCenter.unregister(chatID: chatID, sourceID: usageSourceID, forgetWhenLast: false)
        surfaceObservers.removeValue(forKey: chatID)?.cancel()
        guard appendChat(
            id: chatID,
            agent: agent,
            directory: chat.workspaceDirectory,
            title: chat.conversation.title,
            resumeSessionID: nil,
            accountBinding: chat.accountBinding,
            modelOverride: profile.modelID,
            runProfile: profile,
            accountAccess: chat.accountAccess,
            initialTranscript: transcript,
            initialDraft: finalDraft ?? transcript?.draft,
            initialQueuedPrompts: queued
        ) != nil else {
            ToastCenter.shared.show("The chat adapter is unavailable, so the profile was not switched.", style: .error)
            return
        }
        scheduleWorkspaceStateSave(projectID: projectID)
        ToastCenter.shared.show("Switched to \(profile.name). Fresh provider session; the transcript stays.", style: .success)
    }

    func selectChat(_ chatID: String?) {
        selectedChatID = chatID
        if let chatID {
            missingSessionRecovery = nil
            if let projectID = chats.first(where: { $0.id == chatID })?.projectID,
               let project = projects.first(where: { $0.id == projectID }) {
                selectedProjectID = project.id
                selectedProjectName = project.name
                focusPane(chatID, projectID: projectID)
            }
            selectedMeshID = nil
            attentionCenter.clear(targetID: chatID)
            requestSurfaceKeyboardFocus(chatID)
        }
    }

    // MARK: - Kaisola Mesh

    enum MeshDeleteResult: Equatable {
        case closed
        case needsConfirmation(columns: Int)
        case blocked(String)
        case unavailable
    }

    enum RecentlyClosedActionResult: Equatable {
        case completed
        case needsConfirmation(columns: Int)
        case blocked(String)
        case unavailable
    }

    /// Live Mesh sessions (app-scoped, like chats).
    @Published private(set) var meshes: [MeshSession] = []
    @Published var selectedMeshID: String?
    /// AppModel owns presentation membership; this object owns lifecycle tasks,
    /// cancellation, and transition state.
    private let meshLifecycleCoordinator = MeshLifecycleCoordinator()

    /// Start a Mesh in a directory with every ACP-capable agent. `staged`
    /// runs the scout→execute pipeline; `idea` runs the read-only brainstorm.
    func openMesh(inDirectory directory: URL, staged: Bool = false, idea: Bool = false) {
        let agents = AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }
        guard !agents.isEmpty else { return }
        let project = sessionStore.openProject(directory: directory.path)
        refreshPersistedNavigationState(publish: false)
        selectedProjectID = project.id
        selectedProjectName = project.name
        guard let projectOverlay = projectAccountOverlay(forProject: project.id) else { return }
        let environment = ProcessInfo.processInfo.environment
            .merging(projectOverlay) { _, custom in custom }
        let mesh = MeshSession(
            id: "mesh-\(UUID().uuidString.lowercased())",
            baseDirectory: directory,
            mode: staged ? .staged : .flat,
            purpose: idea ? .idea : .build,
            usageCenter: usageCenter
        )
        wireMeshPersistence(mesh, creatingNewColumns: true)
        surfaceObservers[mesh.id] = mesh.objectWillChange.sink { [weak self] _ in
            self?.scheduleSurfaceSummaryCheck()
        }
        meshes.append(mesh)
        selectedMeshID = mesh.id
        selectedChatID = nil
        focusPane(mesh.id, projectID: project.id)
        scheduleWorkspaceStateSave(projectID: project.id)
        meshLifecycleCoordinator.start(mesh, agents: agents, environment: environment)
    }

    /// Close a Mesh without deleting any durable state. Running adapters stop,
    /// while transcripts, drafts, staged prompts, and worktrees move together
    /// into Recently Closed.
    func closeMesh(
        _ meshID: String,
        allowStoppingRunning: Bool = false
    ) async -> RecentlyClosedActionResult {
        guard let mesh = meshes.first(where: { $0.id == meshID }) else { return .unavailable }
        guard allowStoppingRunning || !mesh.anyRunning else {
            return .needsConfirmation(columns: 0)
        }
        let projectID = mesh.projectID
        let sizeWeight = workspaceSnapshot(projectID: projectID)?.panes
            .first(where: { $0.id == meshID })?.sizeWeight ?? 1

        mesh.onFileActivity = nil
        guard await meshLifecycleCoordinator.suspend(mesh) == .completed else {
            return .unavailable
        }
        storeRecentlyClosedPane(NativeRestorablePaneState(
            id: mesh.id,
            surface: NativeRestorableSurfaceState(mesh: mesh.restorationDescriptor),
            sizeWeight: sizeWeight,
            isMinimized: true,
            isRecentlyClosed: true,
            closedAt: nextRecentlyClosedTimestamp()
        ))
        meshes.removeAll { $0.id == meshID }
        Self.claimedRestoredMeshIDs.remove(meshID)
        surfaceObservers.removeValue(forKey: meshID)?.cancel()
        if selectedMeshID == meshID { selectedMeshID = nil }
        unifiedSessionCards.remove(meshID, from: projectID)
        meshLifecycleCoordinator.forget(meshID: meshID)
        await persistWorkspaceStateImmediately(projectID: projectID)
        ToastCenter.shared.show("Moved Mesh to Recently Closed", style: .success)
        return .completed
    }

    /// Central permanent-delete policy. UI callers first request without
    /// authorization; only the destructive confirmation retries with
    /// `allowRecoverableWork`. Window/app/update teardown never enters here.
    func requestDeleteMesh(_ meshID: String, allowRecoverableWork: Bool) async -> MeshDeleteResult {
        guard let mesh = meshes.first(where: { $0.id == meshID }) else { return .unavailable }
        let columnIDs = await meshDeletionColumnIDs(
            meshID: meshID,
            projectID: mesh.projectID,
            liveColumnIDs: mesh.durableColumnIDs
        )
        let columnConversations = mesh.columns.map(\.conversation)
        let initialAssessment = await mesh.discardAssessment()
        switch initialAssessment {
        case .safe:
            break
        case let .recoverableWork(columns) where !allowRecoverableWork:
            return .needsConfirmation(columns: columns)
        case .recoverableWork:
            break
        case let .blocked(message):
            return .blocked(message)
        }
        if !columnIDs.isEmpty {
            await workspaceSaveTasks[mesh.projectID]?.value
            do {
                try await workspaceStateStore.prepareMeshTranscriptDeletion(
                    projectID: mesh.projectID,
                    meshID: meshID,
                    columnIDs: columnIDs
                )
            } catch {
                return .blocked(
                    "The Mesh deletion receipt could not be saved, so nothing was deleted: \(error.localizedDescription)"
                )
            }
        }
        let outcome = await meshLifecycleCoordinator.destroy(
            mesh,
            allowRecoverableWork: allowRecoverableWork
        )
        guard case let .completed(result) = outcome else { return .unavailable }
        switch result {
        case .safe:
            let projectID = mesh.projectID
            for conversation in columnConversations {
                conversation.forgetPersistentDraft()
            }
            fenceDestroyedMeshPersistence(mesh)
            await draftPersistenceTask?.value
            let tombstones: [AcpTranscriptStore.TombstoneSnapshot]
            if columnIDs.isEmpty {
                tombstones = []
            } else {
                let result = await transcriptStore.tombstone(chatIDs: columnIDs)
                guard case let .recorded(recorded) = result else {
                    guard case let .failed(error) = result else {
                        return .blocked("Mesh column deletion intent could not be recorded.")
                    }
                    return .blocked(
                        "Mesh work was cleaned up, but its column deletion receipt could not be saved: \(error.message)"
                    )
                }
                tombstones = recorded
            }
            do {
                _ = try await workspaceStateStore.removeMeshStateEverywhere(meshID: meshID)
            } catch {
                return .blocked("Mesh work was cleaned up, but the close tombstone could not be saved: \(error.localizedDescription)")
            }
            meshes.removeAll { $0.id == meshID }
            Self.claimedRestoredMeshIDs.remove(meshID)
            surfaceObservers.removeValue(forKey: meshID)?.cancel()
            if selectedMeshID == meshID { selectedMeshID = nil }
            unifiedSessionCards.remove(meshID, from: projectID)
            meshLifecycleCoordinator.forget(meshID: meshID)
            await persistWorkspaceStateImmediately(projectID: projectID)
            provisionedTranscriptIDsByMeshID.removeValue(forKey: meshID)
            if let failure = await completeMeshColumnDeletion(tombstones) {
                return .blocked(
                    "Mesh work was cleaned up, but a column's saved data could not be erased: \(failure)"
                )
            }
            return .closed
        case let .recoverableWork(columns):
            return .needsConfirmation(columns: columns)
        case let .blocked(message):
            return .blocked(message)
        }
    }

    func selectMesh(_ meshID: String?) {
        selectedMeshID = meshID
        if let meshID {
            missingSessionRecovery = nil
            if let projectID = meshes.first(where: { $0.id == meshID })?.projectID,
               let project = projects.first(where: { $0.id == projectID }) {
                selectedProjectID = project.id
                selectedProjectName = project.name
                focusPane(meshID, projectID: projectID)
            }
            selectedChatID = nil
            requestSurfaceKeyboardFocus(meshID)
        }
    }

    /// Restore a specific archived surface. Closed adapters never overlap a
    /// replacement: Chat waits for its stop task, while Mesh reconstructs its
    /// exact manifest without creating new worktrees or dispatching prompts.
    private func deletedRecentlyClosedChatResult(
        surfaceID: String,
        descriptor: NativeRestorableAgentChatDescriptor
    ) async -> RecentlyClosedActionResult? {
        switch await transcriptStore.tombstoneSnapshot(chatID: descriptor.id) {
        case .absent:
            return nil
        case .unknown:
            // Hide an action we cannot safely authorize, but retain both
            // durable stores so a later healthy launch can reconcile them.
            removeAllRecentlyClosedPanes(id: surfaceID)
            return .blocked(
                "Recently Closed deletion state could not be verified. The saved entry was retained for a later retry."
            )
        case .present(let tombstone):
            removeAllRecentlyClosedPanes(id: surfaceID)
            do {
                _ = try await workspaceStateStore.removeAgentChatStateEverywhere(
                    chatID: descriptor.id
                )
            } catch {
                // The exact tombstone remains descriptor-blocked. This window
                // must not expose restore, and the durable row stays available
                // for the next reconciliation attempt.
                return .blocked(
                    "The deleted chat could not be removed from Recently Closed: \(error.localizedDescription)"
                )
            }
            // Finish through the same serialized exact-receipt transaction as
            // an active delete. Unlike vacuum alone, remove() clears a pending
            // migration queued by this actor before releasing the fence.
            let removal = await enqueueTranscriptRemoval(
                chatID: descriptor.id,
                verifiedDescriptorPruning: tombstone
            ).value
            guard removal.isRemoved else {
                return .blocked(
                    "The deleted chat transcript could not be erased: "
                        + (removal.failureMessage ?? "the deletion receipt changed")
                )
            }
            usageCenter.remove(chatID: descriptor.id)
            let cleanup = await completeChatExternalCleanup(
                chatID: descriptor.id,
                tombstone: tombstone
            )
            guard cleanup.isRemoved else {
                return .blocked(
                    "The deleted chat draft cleanup could not be completed: "
                        + (cleanup.failureMessage ?? "the deletion receipt changed")
                )
            }
            return .unavailable
        }
    }

    func restoreRecentlyClosedSurface(_ surfaceID: String) async -> RecentlyClosedActionResult {
        guard let pane = recentlyClosedPane(id: surfaceID) else { return .unavailable }
        guard Self.claimedRecentlyClosedSurfaceIDs.insert(surfaceID).inserted else {
            return .blocked("Another window is already restoring or deleting this entry.")
        }
        defer { Self.claimedRecentlyClosedSurfaceIDs.remove(surfaceID) }
        do {
            guard try await durableRecentlyClosedPaneExists(pane) else {
                _ = removeRecentlyClosedPane(id: surfaceID)
                return .unavailable
            }
        } catch {
            return .blocked("Recently Closed could not be verified: \(error.localizedDescription)")
        }

        if let descriptor = pane.surface.agentChatDescriptor {
            if let deleted = await deletedRecentlyClosedChatResult(
                surfaceID: surfaceID,
                descriptor: descriptor
            ) {
                return deleted
            }
            await chatShutdownTasks.wait(for: surfaceID)
            await draftPersistenceTask?.value
            await flushTranscriptPersistence()
            guard recentlyClosedPane(id: surfaceID) != nil,
                  let agent = AgentRegistry.profile(id: descriptor.agentID) else {
                return .unavailable
            }
            let directory = URL(fileURLWithPath: descriptor.workspacePath, isDirectory: true)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .blocked("The chat's project folder is unavailable. Nothing was removed.")
            }
            let transcript = await restoredTranscript(for: descriptor.id)
            let legacyDraft = try? await workspaceStateStore.draft(for: "chat|\(descriptor.id)")
            let draft = transcript?.draft ?? legacyDraft
            await beforeRecentlyClosedLegacyDraftMigration?(descriptor.id)
            await beforeRecentlyClosedChatMaterialization?(descriptor.id)
            // Every await above is a race boundary: another window may commit
            // deletion after the initial check. Re-probe immediately before
            // appendChat is allowed to materialize a writable surface.
            if let deleted = await deletedRecentlyClosedChatResult(
                surfaceID: surfaceID,
                descriptor: descriptor
            ) {
                return deleted
            }
            guard appendChat(
                id: descriptor.id,
                agent: agent,
                directory: directory,
                title: descriptor.title ?? "\(agent.name) · \(directory.lastPathComponent)",
                resumeSessionID: descriptor.acpSessionID ?? transcript?.sessionID,
                accountBinding: descriptor.accountBinding,
                modelOverride: descriptor.modelOverride,
                runProfile: descriptor.runProfile ?? .write,
                requiresAccountResolution: true,
                initialTranscript: transcript,
                initialDraft: draft,
                initialQueuedPrompts: descriptor.queuedPrompts
            ) != nil else {
                return .blocked("The chat adapter is unavailable. The Recently Closed entry was preserved.")
            }
            // Do not enqueue the legacy migration before the final deletion
            // probe. A write that captures a just-created deletion generation
            // could otherwise outlive a vacuum and recreate the deleted row.
            if transcript?.draft == nil, let legacyDraft, !legacyDraft.isEmpty {
                await transcriptStore.scheduleDraft(legacyDraft, for: descriptor.id)
            }
            _ = removeRecentlyClosedPane(id: surfaceID)
            selectChat(surfaceID)
            await persistWorkspaceStateImmediately(projectID: descriptor.projectID)
            ToastCenter.shared.show("Restored chat", style: .success)
            return .completed
        }

        guard let descriptor = pane.surface.meshDescriptor else { return .unavailable }
        guard descriptor.lifecycle != .pendingDeletion else {
            return .blocked("This Mesh is completing a permanent deletion and cannot be restored.")
        }
        guard !Self.claimedRestoredMeshIDs.contains(surfaceID) else {
            return .blocked("This Mesh is already open in another window.")
        }
        Self.claimedRestoredMeshIDs.insert(surfaceID)
        var keepsClaim = false
        defer {
            if !keepsClaim { Self.claimedRestoredMeshIDs.remove(surfaceID) }
        }
        guard let mesh = await materializeRecentlyClosedMesh(descriptor) else {
            return .blocked("The Mesh project folder or adapter configuration is unavailable. Nothing was removed.")
        }
        _ = removeRecentlyClosedPane(id: surfaceID)
        wireMeshPersistence(mesh)
        surfaceObservers[mesh.id] = mesh.objectWillChange.sink { [weak self] _ in
            self?.scheduleSurfaceSummaryCheck()
        }
        meshes.append(mesh)
        keepsClaim = true
        selectMesh(mesh.id)
        await persistWorkspaceStateImmediately(projectID: descriptor.projectID)
        ToastCenter.shared.show("Restored Mesh", style: .success)
        return .completed
    }

    func restoreMostRecentlyClosed(in projectID: String) async -> RecentlyClosedActionResult {
        guard let newest = recentlyClosedSurfaces(in: projectID).first else { return .unavailable }
        return await restoreRecentlyClosedSurface(newest.id)
    }

    /// Permanent deletion of an archived surface. Chat records durable intent
    /// before touching the archive, exactly like active-chat deletion. Mesh
    /// uses its transactional destroy path so partial Git cleanup remains
    /// represented by a retryable manifest.
    func deleteRecentlyClosedSurface(
        _ surfaceID: String,
        allowRecoverableWork: Bool
    ) async -> RecentlyClosedActionResult {
        guard let pane = recentlyClosedPane(id: surfaceID) else { return .unavailable }
        guard Self.claimedRecentlyClosedSurfaceIDs.insert(surfaceID).inserted else {
            return .blocked("Another window is already restoring or deleting this entry.")
        }
        defer { Self.claimedRecentlyClosedSurfaceIDs.remove(surfaceID) }
        do {
            guard try await durableRecentlyClosedPaneExists(pane) else {
                _ = removeRecentlyClosedPane(id: surfaceID)
                return .unavailable
            }
        } catch {
            return .blocked("Recently Closed could not be verified: \(error.localizedDescription)")
        }
        if let descriptor = pane.surface.agentChatDescriptor {
            await chatShutdownTasks.wait(for: surfaceID)
            let tombstoneResult = await transcriptStore.tombstone(chatID: surfaceID)
            guard case let .recorded(tombstone) = tombstoneResult else {
                guard case let .failed(error) = tombstoneResult else {
                    return .blocked("The permanent-delete intent could not be recorded.")
                }
                return .blocked(
                    "The permanent-delete intent could not be recorded: \(error.message)"
                )
            }
            do {
                let removed = try await workspaceStateStore.removeAgentChatStateEverywhere(
                    chatID: surfaceID
                )
                guard removed else {
                    removeAllRecentlyClosedPanes(id: surfaceID)
                    // The descriptor was already absent. That is the same
                    // verified state a crash-recovery launch uses; this exact
                    // generation may finish physical transcript deletion.
                    explicitlyClosedChatIDs.insert(surfaceID)
                    usageCenter.remove(chatID: surfaceID)
                    let removal = await enqueueTranscriptRemoval(
                        chatID: surfaceID,
                        verifiedDescriptorPruning: tombstone
                    ).value
                    if let failure = removal.failureMessage {
                        return .blocked(
                            "The chat left Recently Closed, but its transcript could not be erased: \(failure)"
                        )
                    }
                    let cleanup = await completeChatExternalCleanup(
                        chatID: surfaceID,
                        tombstone: tombstone
                    )
                    if let failure = cleanup.failureMessage {
                        return .blocked(
                            "The chat left Recently Closed, but its saved drafts could not be erased: \(failure)"
                        )
                    }
                    return .unavailable
                }
            } catch {
                // Deletion intent is already durable. Suppress this cached
                // restore action and retain the descriptor-blocked tombstone
                // for a later launch/retry to prune safely.
                removeAllRecentlyClosedPanes(id: surfaceID)
                return .blocked(
                    "The deleted chat could not be removed from Recently Closed: \(error.localizedDescription)"
                )
            }
            removeAllRecentlyClosedPanes(id: surfaceID)
            explicitlyClosedChatIDs.insert(surfaceID)
            usageCenter.remove(chatID: surfaceID)
            let removalResult = await enqueueTranscriptRemoval(
                chatID: surfaceID,
                verifiedDescriptorPruning: tombstone
            ).value
            await persistWorkspaceStateImmediately(projectID: descriptor.projectID)
            // "Permanently deleted" is only true once the DELETE commits.
            if let failure = removalResult.failureMessage {
                return .blocked(
                    "The chat left Recently Closed, but its transcript could not be erased: \(failure)"
                )
            }
            let cleanup = await completeChatExternalCleanup(
                chatID: surfaceID,
                tombstone: tombstone
            )
            if let failure = cleanup.failureMessage {
                return .blocked(
                    "The chat left Recently Closed, but its saved drafts could not be erased: \(failure)"
                )
            }
            ToastCenter.shared.show("Permanently deleted chat", style: .success)
            return .completed
        }

        guard let descriptor = pane.surface.meshDescriptor else { return .unavailable }
        guard !Self.claimedRestoredMeshIDs.contains(surfaceID) else {
            return .blocked("This Mesh is open in another window and cannot be deleted here.")
        }
        Self.claimedRestoredMeshIDs.insert(surfaceID)
        defer { Self.claimedRestoredMeshIDs.remove(surfaceID) }
        guard let mesh = await materializeRecentlyClosedMesh(descriptor) else {
            return .blocked("The Mesh project folder is unavailable. Its worktrees were preserved.")
        }
        let columnIDs = await meshDeletionColumnIDs(
            meshID: surfaceID,
            projectID: descriptor.projectID,
            liveColumnIDs: mesh.durableColumnIDs + descriptor.deletionColumnIDs
        )
        let columnConversations = mesh.columns.map(\.conversation)
        let initialAssessment = await mesh.discardAssessment()
        switch initialAssessment {
        case .safe:
            break
        case let .recoverableWork(columns) where !allowRecoverableWork:
            return .needsConfirmation(columns: columns)
        case .recoverableWork:
            break
        case let .blocked(message):
            return .blocked(message)
        }
        if !columnIDs.isEmpty {
            await workspaceSaveTasks[descriptor.projectID]?.value
            do {
                try await workspaceStateStore.prepareMeshTranscriptDeletion(
                    projectID: descriptor.projectID,
                    meshID: surfaceID,
                    columnIDs: columnIDs
                )
            } catch {
                return .blocked(
                    "The Mesh deletion receipt could not be saved, so nothing was deleted: \(error.localizedDescription)"
                )
            }
        }
        let outcome = await meshLifecycleCoordinator.destroy(
            mesh,
            allowRecoverableWork: allowRecoverableWork
        )
        guard case let .completed(result) = outcome else { return .unavailable }
        switch result {
        case .safe:
            for conversation in columnConversations {
                conversation.forgetPersistentDraft()
            }
            fenceDestroyedMeshPersistence(mesh)
            await draftPersistenceTask?.value
            let tombstones: [AcpTranscriptStore.TombstoneSnapshot]
            if columnIDs.isEmpty {
                tombstones = []
            } else {
                let result = await transcriptStore.tombstone(chatIDs: columnIDs)
                guard case let .recorded(recorded) = result else {
                    guard case let .failed(error) = result else {
                        return .blocked("Mesh column deletion intent could not be recorded.")
                    }
                    return .blocked(
                        "Mesh work was cleaned up, but its column deletion receipt could not be saved: \(error.message)"
                    )
                }
                tombstones = recorded
            }
            do {
                _ = try await workspaceStateStore.removeMeshStateEverywhere(meshID: surfaceID)
            } catch {
                return .blocked("Mesh work was cleaned up, but the delete tombstone could not be saved: \(error.localizedDescription)")
            }
            _ = removeRecentlyClosedPane(id: surfaceID)
            meshLifecycleCoordinator.forget(meshID: surfaceID)
            await persistWorkspaceStateImmediately(projectID: descriptor.projectID)
            provisionedTranscriptIDsByMeshID.removeValue(forKey: surfaceID)
            if let failure = await completeMeshColumnDeletion(tombstones) {
                return .blocked(
                    "Mesh work was cleaned up, but a column's saved data could not be erased: \(failure)"
                )
            }
            ToastCenter.shared.show("Permanently deleted Mesh", style: .success)
            return .completed
        case let .recoverableWork(columns):
            return .needsConfirmation(columns: columns)
        case let .blocked(message):
            return .blocked(message)
        }
    }

    private func materializeRecentlyClosedMesh(
        _ descriptor: NativeRestorableMeshDescriptor
    ) async -> MeshSession? {
        guard NativeSessionStore.projectID(forDirectory: descriptor.basePath) == descriptor.projectID else {
            return nil
        }
        let directory = URL(fileURLWithPath: descriptor.basePath, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        await draftPersistenceTask?.value
        await flushTranscriptPersistence()
        let draft = (try? await workspaceStateStore.draft(for: "mesh|\(descriptor.id)")) ?? ""
        let mesh = MeshSession(
            id: descriptor.id,
            baseDirectory: directory,
            mode: descriptor.mode,
            purpose: descriptor.purpose,
            title: descriptor.title,
            lifecycle: descriptor.lifecycle,
            initialDraft: draft,
            initialStagedPrompts: descriptor.stagedPrompts,
            usageCenter: usageCenter
        )
        wireMeshPersistence(mesh, recentlyClosed: true)
        var states: [MeshSession.RestoredColumnState] = []
        for column in descriptor.columns {
            let transcript = await restoredTranscript(for: column.id)
            states.append(MeshSession.RestoredColumnState(
                descriptor: column,
                rows: transcript?.page.rows ?? [],
                rowStartOrdinal: transcript?.page.startOrdinal ?? 0,
                earlierRowCount: transcript?.page.earlierRowCount ?? 0,
                totalRowCount: transcript?.page.totalRowCount ?? 0,
                initialDraft: transcript?.draft,
                initialAttachments: transcript?.attachments ?? [],
                persistedSessionID: transcript?.sessionID,
                usage: transcript?.usage
            ))
        }
        guard let projectOverlay = projectAccountOverlay(forProject: descriptor.projectID) else {
            return nil
        }
        let environment = ProcessInfo.processInfo.environment
            .merging(projectOverlay) { _, custom in custom }
        let completion = await meshLifecycleCoordinator.restore(
            mesh,
            states: states,
            agents: AgentRegistry.all,
            environment: environment
        )
        guard completion == .completed else {
            meshLifecycleCoordinator.forget(meshID: descriptor.id)
            return nil
        }
        return mesh
    }

    /// Full window teardown: stop every app-scoped process, persist its state,
    /// and drop broker connections. Mesh Git worktrees deliberately remain
    /// registered; only an explicit, safety-checked permanent Delete may destroy them.
    func teardown() async {
        for task in chatAccountInvalidationTasks.values { await task.value }
        chatAccountInvalidationTasks.removeAll()
        // Save the user's restorable truth before asking any adapter or mesh to
        // stop. A provider shutdown can stall, but a bounded application quit
        // must still retain the latest file deck, cursor, drafts, transcripts,
        // usage, and session layout that were available at quit time.
        flushPendingTerminalOutputs()
        await persistCurrentCursor()
        await persistWorkspaceStateNow()
        for chat in chats {
            if let finalDraft = await chat.conversation.stop() {
                enqueueDraftSave(
                    finalDraft,
                    chatID: chat.id,
                    projectID: chat.projectID,
                    agentID: chat.agentID,
                    workspacePath: chat.workspaceDirectory.path
                )
            }
            usageCenter.unregister(
                chatID: chat.id,
                sourceID: usageSourceID,
                forgetWhenLast: false
            )
        }
        await chatShutdownTasks.drain()
        for observers in usageObservers.values { observers.forEach { $0.cancel() } }
        usageObservers.removeAll()
        await draftPersistenceTask?.value
        await persistWorkspaceStateNow()
        meshLifecycleCoordinator.cancelAll()
        for mesh in meshes {
            _ = await meshLifecycleCoordinator.suspend(mesh)
        }
        // `suspend` updates lifecycle and can fence a worktree provision that
        // was already in flight. Flush that final safe manifest before the
        // window model releases its claim. Stopped chats deliberately remain
        // in `chats` through this last snapshot: their transcript rows live in
        // SQLite, but this descriptor is the only durable route back to them
        // after a relaunch or app update.
        await persistWorkspaceStateNow()
        chats.removeAll()
        for mesh in meshes {
            Self.claimedRestoredMeshIDs.remove(mesh.id)
            meshLifecycleCoordinator.forget(meshID: mesh.id)
        }
        meshes.removeAll()
        surfaceObservers.removeAll()
        splitIntentTokens.removeAll()
        await disconnect()
    }

    /// Where an inbox entry's target lives now, resolved at render time —
    /// `AttentionCenter.Entry` deliberately carries no project, so the inbox
    /// asks the live surfaces instead of trusting a snapshot that could name
    /// a project the session has since left.
    func attentionContext(for targetID: String) -> (projectName: String?, exists: Bool) {
        func name(_ projectID: String) -> String? {
            projects.first(where: { $0.id == projectID })?.name
        }
        if let chat = chats.first(where: { $0.id == targetID }) {
            return (name(chat.projectID), true)
        }
        if let terminal = sessions.first(where: { $0.id == targetID }) {
            return (name(displayProjectID(terminal)), true)
        }
        if let mesh = meshes.first(where: { mesh in
            mesh.id == targetID || mesh.columns.contains(where: { $0.id == targetID })
        }) {
            return (name(mesh.projectID), true)
        }
        return (nil, false)
    }

    /// Jump from an inbox entry to its surface (chat or terminal session).
    func jumpToAttentionTarget(_ targetID: String) {
        if chats.contains(where: { $0.id == targetID }) {
            attentionCenter.clear(targetID: targetID)
            selectChat(targetID)
        } else if sessions.contains(where: { $0.id == targetID }) {
            attentionCenter.clear(targetID: targetID)
            Task { await select(targetID) }
        } else if let mesh = meshes.first(where: { mesh in
            mesh.id == targetID || mesh.columns.contains(where: { $0.id == targetID })
        }) {
            attentionCenter.clear(targetID: targetID)
            selectMesh(mesh.id)
        } else {
            attentionCenter.clear(targetID: targetID)
            ToastCenter.shared.show("That session is no longer open", style: .info)
        }
    }

    /// Deterministic, broker-free state for the hosted visual-inspection job.
    /// It is reachable only through the explicit app launch environment used
    /// by `.github/workflows/native-visual.yml`; normal app launches never call
    /// it and still derive every session from the real broker.
    static let visualFixtureBrokerGenerationID = "visual-fixture-generation"

    func loadVisualFixture(workspace: URL, includeSplit: Bool = false) {
        usesVisualFixtureTransport = true
        let root = workspace.standardizedFileURL
        let project = sessionStore.openProject(directory: root.path)
        sessionStore.setProjectColor(id: project.id, colorHex: "7C5CFC")
        // The one fixture with *nothing mounted*: a project, a connected
        // shell, and an empty canvas — the state the idle glass backdrop and
        // the empty-state card exist for (see `WorkspaceBackdropView.idle`).
        // Every other surface seeds sessions, so without this the idle canvas
        // is unreachable under the deterministic harness.
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "empty-workspace" {
            refreshPersistedNavigationState(publish: false)
            controlAvailable = true
            connectionState = .connected(
                version: "visual fixture", pid: 4_200, serverEnforcedObserver: true
            )
            selectedProjectID = project.id
            selectedProjectName = project.name
            return
        }
        let secondaryURL = root.appendingPathComponent("native/KaisolaMac", isDirectory: true)
        if FileManager.default.fileExists(atPath: secondaryURL.path) {
            let secondary = sessionStore.openProject(directory: secondaryURL.path)
            sessionStore.setProjectColor(id: secondary.id, colorHex: "4BA3C7")
        }

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let fixtures = [
            NativeOwnedSession(
                id: "visual-terminal",
                projectID: project.id,
                cwd: root.path,
                title: root.lastPathComponent,
                createdAt: now
            ),
            NativeOwnedSession(
                id: "visual-codex",
                projectID: project.id,
                cwd: root.path,
                title: "Codex · \(root.lastPathComponent)",
                createdAt: now + 1,
                agentID: "codex"
            ),
        ]
        fixtures.forEach(sessionStore.upsert)
        refreshPersistedNavigationState(publish: false)

        let visualSurface = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"]
        sessions = [
            BrokerTerminalRecord(
                id: fixtures[0].id,
                projectID: project.id,
                pid: 4_201,
                exited: false,
                streamEpoch: "visual-shell",
                endOffset: 0,
                diskBytes: visualSurface == "terminal-transcript" ? 2 * 1_024 * 1_024 * 1_024 : 0,
                brokerGenerationID: Self.visualFixtureBrokerGenerationID,
                agentActivity: .idle
            ),
            BrokerTerminalRecord(
                id: fixtures[1].id,
                projectID: project.id,
                pid: 4_202,
                exited: false,
                streamEpoch: "visual-codex",
                endOffset: 0,
                brokerGenerationID: Self.visualFixtureBrokerGenerationID,
                agentActivity: .working
            ),
        ]
        ownedTerminalIDs = Set(fixtures.map(\.id))
        controlAvailable = true
        connectionState = .connected(version: "visual fixture", pid: 4_200, serverEnforcedObserver: true)
        selectedProjectID = project.id
        selectedProjectName = project.name
        selectedSession = sessions[0]
        selectedSessionID = sessions[0].id

        let requestedResourceBytes = visualSurface == "terminal-ownership-flap"
            ? TerminalDocument.maximumRetainedBytes
            : ProcessInfo.processInfo.environment[
                "KAISOLA_NATIVE_RESOURCE_SCROLLBACK_BYTES"
            ].flatMap(Int.init)
        let resourceScrollback: TerminalScrollback?
        if visualSurface != "terminal-transcript",
           visualSurface != "terminal-semantic",
           visualSurface != "terminal-scroll-output",
           visualSurface != "terminal-continuous-scroll",
           let requestedResourceBytes,
           requestedResourceBytes > 0 {
            let targetBytes = min(requestedResourceBytes, TerminalDocument.maximumRetainedBytes)
            if visualSurface == "terminal-ownership-flap" {
                resourceScrollback = VisualTerminalOwnershipFlapFixture.scrollback(
                    targetBytes: targetBytes
                )
            } else {
                resourceScrollback = VisualTerminalResourceFixture.scrollback(
                    targetBytes: targetBytes
                )
            }
        } else {
            resourceScrollback = nil
        }
        let output: String
        if visualSurface == "terminal-transcript" {
            output = VisualTerminalTranscriptFixture.output
        } else if visualSurface == "terminal-semantic" {
            let mark: (String) -> String = { "\u{1B}]133;\($0)\u{7}" }
            output = mark("A")
                + "michael@kaisola Kaisola % " + mark("B")
                + "swift test" + mark("C") + "\r\n"
                + "Building for debugging...\r\n"
                + "Test Suite 'KaisolaTests' passed at 08:18.\r\n"
                + mark("D;0") + mark("A")
                + "michael@kaisola Kaisola % " + mark("B")
                + "git status --short" + mark("C") + "\r\n"
                + " M NativeTerminalSurface.swift\r\n"
                + mark("D;1") + mark("A")
                + "michael@kaisola Kaisola % " + mark("B")
        } else if visualSurface == "terminal-scroll-output" {
            output = VisualTerminalStreamingFixture.initialOutput
        } else if visualSurface == "terminal-continuous-scroll" {
            output = VisualTerminalContinuousScrollFixture.initialOutput
        } else if resourceScrollback != nil {
            output = ""
        } else {
            output = [
                "Last login: Thu Jul 23 17:42:08 on ttys001",
                "michael@kaisola Kaisola % git status --short",
                " M native/KaisolaMac/Kaisola/Features/Sessions/RootShellView.swift",
                "michael@kaisola Kaisola % ",
            ].joined(separator: "\r\n")
        }
        let retainedScrollback = resourceScrollback ?? TerminalScrollback(output)
        let byteCount = Int64(retainedScrollback.byteCount)
        let document = TerminalDocument(
            sessionID: sessions[0].id,
            scrollback: retainedScrollback,
            cursor: TerminalCursor(streamEpoch: "visual-shell", offset: byteCount),
            truncated: false,
            exited: false,
            errorMessage: nil
        )
        terminalDocument = document
        terminalSurfaceDocuments = [sessions[0].id: document]
        terminalSurfaceOrder = [sessions[0].id]
        terminalSurfaceFeeds.removeAll()
        publishTerminalSurfaceDocument(document)
        splitDocuments.removeAll()
        splitOrder.removeAll()
        unifiedSessionCards.install(
            SessionPaneLayout(sessionID: sessions[0].id),
            for: project.id
        )
        unifiedSessionCards.focusPresentation(on: sessions[0].id)

        if includeSplit {
            let splitOutput = [
                "› Make terminal agent output easier to scan.",
                "",
                "• I kept the CLI's own hierarchy and high-contrast ANSI roles.",
                "",
                "  - User turns keep the CLI's native prompt treatment.",
                "  - Agent replies remain on the plain terminal canvas.",
                "  - Links such as \u{1B}[36mhttps://kaisola.app\u{1B}[0m remain clickable.",
                "",
                "────────────────────────────────────────",
                "› Ask Codex anything…",
            ].joined(separator: "\r\n")
            splitDocuments[sessions[1].id] = TerminalDocument(
                sessionID: sessions[1].id,
                output: splitOutput,
                cursor: TerminalCursor(
                    streamEpoch: "visual-codex",
                    offset: Int64(splitOutput.utf8.count)
                ),
                truncated: false,
                exited: false,
                errorMessage: nil
            )
            publishTerminalSurfaceDocument(splitDocuments[sessions[1].id]!)
            splitOrder = [sessions[1].id]
            unifiedSessionCards.add(sessions[1].id, to: project.id)
        }
    }

    /// Broker-free ownership transition used by hosted visual QA and unit
    /// fixtures. Production models never set `usesVisualFixtureTransport`, so
    /// this cannot alter a live controller or terminal.
    @discardableResult
    func setVisualFixtureTerminalOwnership(
        _ owned: Bool,
        terminalID: String = "visual-terminal"
    ) -> Bool {
        guard usesVisualFixtureTransport,
              sessions.contains(where: { $0.id == terminalID && !$0.exited }) else {
            return false
        }
        if owned {
            ownedTerminalIDs.insert(terminalID)
        } else {
            if invalidateTerminalInput(for: terminalID) {
                reportDiscardedTerminalInput(for: [terminalID])
            }
            ownedTerminalIDs.remove(terminalID)
        }
        return true
    }

    /// Read-only proof seam for the ownership-epoch tests. Draft state is
    /// intentionally observable only as parsed composer text, never as queued
    /// packet contents.
    func terminalDraftTextForTesting(_ terminalID: String) -> String? {
        terminalDraftTrackers[terminalID]?.text
    }

    /// Feed the broker-free streaming fixture through the same 16 ms output
    /// batcher used by live PTYs. This is callable only from the declared
    /// hosted surface, so production sessions can never synthesize output.
    @discardableResult
    func enqueueVisualTerminalStreamingPacket(_ index: Int) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              let visualSurface = environment["KAISOLA_NATIVE_VISUAL_SURFACE"],
              ["terminal-scroll-output", "terminal-continuous-scroll"].contains(visualSurface),
              VisualTerminalStreamingFixture.packetIndices.contains(index),
              let terminal = sessions.first,
              terminal.id == terminalDocument.sessionID,
              let cursor = terminalDocument.cursor else { return false }
        let data = visualSurface == "terminal-continuous-scroll"
            ? VisualTerminalContinuousScrollFixture.packet(index: index)
            : VisualTerminalStreamingFixture.packet(index: index)
        let startOffset = pendingTerminalOutput[terminal.id]?.endOffset ?? cursor.offset
        enqueueTerminalOutput(
            projectID: terminal.projectID,
            terminalID: terminal.id,
            epoch: cursor.streamEpoch,
            startOffset: startOffset,
            endOffset: startOffset + Int64(data.utf8.count),
            data: data
        )
        return true
    }

    /// Finish a hosted burst synchronously before its evidence gate reads the
    /// document cursor. Ordinary live output still drains on the frame timer.
    func finishVisualTerminalStreamingBurst() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              let visualSurface = environment["KAISOLA_NATIVE_VISUAL_SURFACE"],
              ["terminal-scroll-output", "terminal-continuous-scroll"].contains(visualSurface) else {
            return
        }
        flushPendingTerminalOutputs()
    }

    /// Switch the hosted terminal fixture from the green live-work badge to a
    /// durable orange completion badge. The fixture AttentionCenter is
    /// process-local, so this never writes the user's inbox or posts a system
    /// notification.
    func loadVisualCompletedAttentionFixture() {
        guard let index = sessions.firstIndex(where: { $0.id == "visual-codex" }) else { return }
        sessions[index].agentActivity = .responded(at: Int64(Date().timeIntervalSince1970 * 1_000))
        attentionCenter.notify(
            kind: .sessionResponded,
            targetID: sessions[index].id,
            title: sessionTitle(for: sessions[index]),
            detail: "Codex finished"
        )
    }

    /// `agentCount` drives the 2/3/4-column visual fixtures; the deck the Mesh
    /// picks for that many columns is a function of the window width the
    /// fixture declares.
    func loadVisualMeshFixture(workspace: URL, agentCount: Int = 3) {
        let mesh = MeshSession(baseDirectory: workspace.standardizedFileURL)
        mesh.loadVisualFixture(
            agents: Array(AgentRegistry.builtIns.prefix(max(1, agentCount)))
        )
        surfaceObservers[mesh.id] = mesh.objectWillChange.sink { [weak self] _ in
            self?.scheduleSurfaceSummaryCheck()
        }
        meshes = [mesh]
        selectedSessionID = nil
        unifiedSessionCards.install(
            SessionPaneLayout(sessionID: mesh.id),
            for: mesh.projectID
        )
        selectMesh(mesh.id)
    }

    func loadVisualMixedSessionFixture(workspace: URL, includePermission: Bool = false) {
        let root = workspace.standardizedFileURL
        guard let project = projects.first(where: { $0.directory?.standardizedFileURL == root }),
              let agent = AgentRegistry.profile(id: "codex"),
              let chat = appendChat(
                id: "visual-chat",
                agent: agent,
                directory: root,
                title: "Codex · \(root.lastPathComponent)",
                resumeSessionID: nil,
                accountBinding: SessionAccountBinding.resolve(
                    agentID: agent.id,
                    profile: nil,
                    fallbackEnvironment: ProcessInfo.processInfo.environment
                ),
                initialTranscript: nil,
                initialDraft: "",
                initialQueuedPrompts: []
              ) else { return }
        chat.conversation.loadVisualFixture(includePermission: includePermission)
        unifiedSessionCards.add(chat.id, to: project.id)
        selectChat(chat.id)
    }

    func reload() async {
        // Hosted visual fixtures are deliberately broker-free. Even an
        // accidental menu command or future fixture interaction must not turn
        // their otherwise inert live clients into a real broker connection.
        guard !usesVisualFixtureTransport else { return }
        flushPendingTerminalOutputs()
        hasStarted = true
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await persistCurrentCursor()
        await clearSplits()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionState = .looking
        connectedBrokerFeatures = []
        await client.disconnect()
        selectedSession = nil

        let connected = await connect(generation: generation, reconnectAttempt: nil)
        await restoreWorkspaceStateIfNeeded()
        await restoreTerminalDraftTrackers()
        if connected {
            await restoreVisibleSecondarySubscriptions(
                expectedConnectionGeneration: generation
            )
        }
        if !connected {
            scheduleReconnect(attempt: 0, generation: generation)
        }
    }

    /// Called when the app returns to the foreground. An existing healthy
    /// observer is left alone; an offline one resumes its bounded retry loop.
    func resumeIfNeeded() {
        guard hasStarted,
              shouldReconnect,
              case .unavailable = connectionState else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        scheduleReconnect(attempt: 0, generation: connectionGeneration, immediate: true)
    }

    /// Sleep can invalidate a Unix socket without promptly waking a blocked
    /// read. Reopening the observer is safe and retains the in-memory cursor.
    func recoverAfterWake() async {
        guard hasStarted, shouldReconnect else { return }
        await reload()
    }

    /// Resolve an explicit new-window target only after the destination model
    /// has its own current inventory. Absence and connection failure become a
    /// durable recovery card instead of being flattened into `select(nil)`.
    func openPopOutTarget(_ sessionID: String) async {
        let target = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            missingSessionRecovery = MissingSessionRecovery(
                sessionID: sessionID,
                message: "Kaisola could not identify the terminal to open."
            )
            return
        }
        guard connectionState.isConnected else {
            missingSessionRecovery = MissingSessionRecovery(
                sessionID: target,
                message: "Kaisola could not connect to that terminal. It may still be running; try again after the connection recovers."
            )
            return
        }

        await refreshInventory()
        guard sessions.contains(where: { $0.id == target }) else {
            missingSessionRecovery = MissingSessionRecovery(
                sessionID: target,
                message: "That terminal is no longer available. It may have ended or been closed in another window."
            )
            return
        }

        missingSessionRecovery = nil
        await select(target)
        if selectedSessionID != target {
            missingSessionRecovery = MissingSessionRecovery(
                sessionID: target,
                message: "Kaisola found the terminal but could not open it in this window."
            )
        }
    }

    func retryMissingSession() async {
        guard let missingSessionRecovery else { return }
        if !connectionState.isConnected { await reload() }
        await openPopOutTarget(missingSessionRecovery.sessionID)
    }

    func dismissMissingSessionRecovery() {
        missingSessionRecovery = nil
    }

    func select(_ id: String?) async {
        // Preserve every byte that arrived before this interaction boundary;
        // the document below is the snapshot persisted and retained on leave.
        flushPendingTerminalOutputs()
        terminalSelectionGeneration &+= 1
        let selectionGeneration = terminalSelectionGeneration
        // Snapshot the surface we are leaving once, at the interaction
        // boundary. Streaming output continues to publish only through
        // `terminalDocument`; copying every packet into the retained deck
        // causes needless whole-shell invalidations.
        let previousSession = selectedSession
        let previousDocument = terminalDocument
        if let currentSessionID = previousDocument.sessionID {
            terminalSurfaceDocuments[currentSessionID] = previousDocument
        }

        let next = id.flatMap { requested in sessions.first(where: { $0.id == requested }) }
        if let next {
            // Direct selection paths (restore, project activation, commands)
            // are primary-role intents too, not only split-card promotion.
            splitIntentTokens[next.id] = UUID()
        }

        // Publish the complete visible selection before the first suspension.
        // Cursor persistence and broker unsubscribe can take hundreds of
        // milliseconds; waiting for them here made the old terminal briefly
        // reappear whenever a chat/Mesh/CLI tab was selected.
        if let next {
            missingSessionRecovery = nil
            let retainedDocument = terminalSurfaceDocuments[next.id]
                ?? (previousDocument.sessionID == next.id
                    ? previousDocument
                    : .loading(sessionID: next.id))
            selectedSession = next
            selectedSessionID = next.id
            if let project = projects.first(where: { $0.id == next.projectID }) {
                selectedProjectID = project.id
                selectedProjectName = project.name
            }
            focusPane(next.id, projectID: next.projectID)
            selectedChatID = nil
            selectedMeshID = nil
            browserCardURL = nil
            sessionStore.recordSelectedSession(next.id)
            if case let .responded(completedAt) = next.agentActivity {
                attentionCenter.acknowledgeSessionResponse(
                    targetID: next.id,
                    completedAt: completedAt
                )
            } else {
                attentionCenter.clear(targetID: next.id)
            }
            publishPrimaryDocument(retainedDocument, touch: true)
        } else {
            selectedSession = nil
            selectedSessionID = nil
            selectedChatID = nil
            selectedMeshID = nil
            browserCardURL = nil
            terminalDocument = .empty
        }

        cursorSaveTask?.cancel()
        cursorSaveTask = nil
        await persist(previousDocument, for: previousSession)
        guard selectionGeneration == terminalSelectionGeneration else { return }

        if let previousSession,
           previousSession.id != next?.id,
           connectionState.isConnected {
            try? await client.unsubscribe(from: previousSession, ownerID: observerOwnerID)
            guard selectionGeneration == terminalSelectionGeneration else { return }
        }

        guard let next else { return }
        let retainedDocument = terminalSurfaceDocuments[next.id]
            ?? .loading(sessionID: next.id)
        guard connectionState.isConnected else {
            return
        }

        let resumeCursor = retainedDocument.cursor
        let priorPersistedCursor: TerminalCursor?
        if let scope = cursorScope(for: next) {
            priorPersistedCursor = try? await cursorStore.cursor(for: scope)
        } else {
            priorPersistedCursor = nil
        }
        guard selectionGeneration == terminalSelectionGeneration else { return }

        do {
            let result = try await client.subscribe(
                to: next,
                ownerID: observerOwnerID,
                cursor: resumeCursor
            )
            guard selectionGeneration == terminalSelectionGeneration else { return }
            var document = retainedDocument.applying(result, sessionID: next.id)
            // A cold launch asks for the full retained snapshot instead of
            // skipping bytes merely because a disk cursor exists. The cursor
            // still proves whether history disappeared while the UI was away.
            if resumeCursor == nil,
               let priorPersistedCursor,
               case let .snapshot(snapshot, _) = result,
               (priorPersistedCursor.streamEpoch != snapshot.streamEpoch
                   || priorPersistedCursor.offset < snapshot.startOffset
                   || priorPersistedCursor.offset > snapshot.endOffset) {
                document.truncated = true
            }
            publishPrimaryDocument(document)
            await persistCurrentCursor()
        } catch {
            guard selectionGeneration == terminalSelectionGeneration else { return }
            publishPrimaryDocument(.failure(sessionID: next.id, message: error.kaisolaSafeDescription))
        }
    }

    /// Freeze a cursor for the opt-in transcript viewer. The viewer pages the
    /// broker spool as it existed at open time, while the live terminal keeps
    /// streaming independently. This avoids replaying old ANSI/TUI commands
    /// into SwiftTerm or moving the user's interactive viewport.
    func terminalTranscriptContext(for terminalID: String) -> TerminalTranscriptContext? {
        guard let terminal = sessions.first(where: { $0.id == terminalID }) else { return nil }
        let document: TerminalDocument?
        if terminalDocument.sessionID == terminalID {
            document = terminalDocument
        } else if let split = splitDocuments[terminalID] {
            document = split
        } else {
            document = terminalSurfaceDocuments[terminalID]
        }
        let liveCursor = document?.cursor
        let streamEpoch = liveCursor?.streamEpoch ?? terminal.streamEpoch
        let endOffset = liveCursor?.offset ?? terminal.endOffset
        guard let streamEpoch, !streamEpoch.isEmpty, endOffset >= 0 else { return nil }
        let fallbackOutput: String
        let fallbackStartOffset: Int64
        let fallbackTruncated: Bool
        if let document,
           document.cursor?.streamEpoch == streamEpoch,
           document.cursor?.offset == endOffset {
            fallbackOutput = document.output
            fallbackStartOffset = max(0, endOffset - Int64(fallbackOutput.utf8.count))
            fallbackTruncated = document.truncated || fallbackStartOffset > 0
        } else {
            fallbackOutput = ""
            fallbackStartOffset = endOffset
            fallbackTruncated = endOffset > 0
        }
        return TerminalTranscriptContext(
            id: terminalID,
            title: sessionTitle(for: terminal),
            streamEpoch: streamEpoch,
            endOffset: endOffset,
            diskBytes: terminal.diskBytes,
            fallbackOutput: fallbackOutput,
            fallbackStartOffset: fallbackStartOffset,
            fallbackTruncated: fallbackTruncated,
            brokerSupportsHistory: connectedBrokerFeatures.contains(BrokerWire.terminalHistoryFeature),
            columns: terminal.columns ?? 160,
            rows: terminal.rows ?? 60
        )
    }

    func terminalHistoryPage(
        context: TerminalTranscriptContext,
        beforeOffset: Int64,
        maxBytes: Int = 512 * 1_024
    ) async throws -> TerminalHistoryPage {
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
           ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "terminal-transcript" {
            return try VisualTerminalTranscriptFixture.page(
                streamEpoch: context.streamEpoch,
                beforeOffset: beforeOffset,
                maxBytes: maxBytes
            )
        }
        if !context.brokerSupportsHistory {
            return try Self.retainedTranscriptPage(
                context: context,
                beforeOffset: beforeOffset,
                maxBytes: maxBytes
            )
        }
        guard connectionState.isConnected,
              let terminal = sessions.first(where: { $0.id == context.id }) else {
            throw BrokerClientError.notConnected
        }
        return try await client.historyPage(
            for: terminal,
            ownerID: observerOwnerID,
            streamEpoch: context.streamEpoch,
            beforeOffset: beforeOffset,
            maxBytes: maxBytes
        )
    }

    /// Compatibility paging for an already-running broker that predates the
    /// additive terminal.history request. The context freezes the document at
    /// sheet-open time, so concurrent terminal output cannot move page bounds
    /// or make scrolling jump. New brokers never enter this lane.
    nonisolated static func retainedTranscriptPage(
        context: TerminalTranscriptContext,
        beforeOffset: Int64,
        maxBytes: Int
    ) throws -> TerminalHistoryPage {
        guard !context.brokerSupportsHistory,
              maxBytes > 0,
              beforeOffset >= context.fallbackStartOffset,
              beforeOffset <= context.endOffset else {
            throw BrokerClientError.malformedResponse
        }

        let relativeEnd = beforeOffset - context.fallbackStartOffset
        guard relativeEnd <= Int64(context.fallbackOutput.utf8.count),
              let relativeEndInt = Int(exactly: relativeEnd) else {
            throw BrokerClientError.malformedResponse
        }
        let utf8 = context.fallbackOutput.utf8
        let byteEnd = utf8.index(utf8.startIndex, offsetBy: relativeEndInt)
        guard let stringEnd = byteEnd.samePosition(in: context.fallbackOutput) else {
            throw BrokerClientError.malformedResponse
        }

        let proposedStart = max(0, relativeEndInt - maxBytes)
        var adjustedStart = proposedStart
        var byteStart = utf8.index(utf8.startIndex, offsetBy: proposedStart)
        while byteStart < byteEnd,
              byteStart.samePosition(in: context.fallbackOutput) == nil {
            byteStart = utf8.index(after: byteStart)
            adjustedStart += 1
        }
        guard let stringStart = byteStart.samePosition(in: context.fallbackOutput) else {
            throw BrokerClientError.malformedResponse
        }

        let output = String(context.fallbackOutput[stringStart..<stringEnd])
        let startOffset = context.fallbackStartOffset + Int64(adjustedStart)
        guard Int64(output.utf8.count) == beforeOffset - startOffset else {
            throw BrokerClientError.malformedResponse
        }
        return TerminalHistoryPage(
            streamEpoch: context.streamEpoch,
            output: output,
            startOffset: startOffset,
            endOffset: beforeOffset,
            hasMore: startOffset > context.fallbackStartOffset,
            truncated: context.fallbackTruncated
        )
    }

    /// Publish the current primary document and synchronize the bounded surface
    /// deck used by `RootShellView`. LRU order changes only on selection, never
    /// for every output packet, keeping high-volume terminal streaming cheap.
    private func publishPrimaryDocument(_ document: TerminalDocument, touch: Bool = false) {
        terminalDocument = document
        retainTerminalSurfaceDocument(document, touch: touch)
    }

    /// Return the stable observable lane prepared before a terminal card enters
    /// the SwiftUI graph. View evaluation stays read-only and never allocates or
    /// mutates model state from inside `body`.
    func terminalSurfaceFeed(for terminalID: String) -> TerminalSurfaceFeed? {
        terminalSurfaceFeeds[terminalID]
    }

    /// Publish bytes only to the matching terminal card. A hidden terminal has
    /// no feed and therefore incurs no SwiftUI work; its document remains in
    /// the model until the ordinary selection boundary snapshots it.
    private func publishTerminalSurfaceDocument(_ document: TerminalDocument) {
        guard let sessionID = document.sessionID else { return }
        if let feed = terminalSurfaceFeeds[sessionID] {
            feed.replace(with: document)
        } else {
            terminalSurfaceFeeds[sessionID] = TerminalSurfaceFeed(document: document)
        }
    }

    /// Keep a document in the bounded terminal deck without making it primary.
    /// Reconnect uses this for every visible secondary before dropping dead
    /// socket subscriptions, so SwiftTerm keeps rendering the last good frame
    /// until the replacement snapshot arrives.
    private func retainTerminalSurfaceDocument(_ document: TerminalDocument, touch: Bool = false) {
        guard let sessionID = document.sessionID else { return }
        publishTerminalSurfaceDocument(document)
        terminalSurfaceDocuments[sessionID] = document
        if touch || !terminalSurfaceOrder.contains(sessionID) {
            terminalSurfaceOrder.removeAll { $0 == sessionID }
            terminalSurfaceOrder.append(sessionID)
        }
        let evictions = Self.retainedSurfaceEvictions(
            order: terminalSurfaceOrder,
            byteCount: { [terminalSurfaceDocuments] id in
                terminalSurfaceDocuments[id]?.scrollback.byteCount ?? 0
            },
            protected: mountedTerminalSurfaceIDs
        )
        guard !evictions.isEmpty else { return }
        let evicted = Set(evictions)
        terminalSurfaceOrder.removeAll { evicted.contains($0) }
        for id in evicted {
            terminalSurfaceDocuments.removeValue(forKey: id)
            terminalSurfaceFeeds.removeValue(forKey: id)
        }
    }

    /// Surfaces that are on screen right now. A terminal card renders only
    /// while its feed exists, so evicting one of these would replace live
    /// output with a spinner — a worse outcome than the memory it reclaims.
    /// In-flight split subscriptions are included because their card is already
    /// mounted and rendering from the retained document until the snapshot
    /// lands. The active project's whole pane layout is unioned in too:
    /// `focusTerminalSurface` unsubscribes the outgoing primary before
    /// re-subscribing it as a split, and during that window it lives in none
    /// of the sets above even though its card is still mounted in the layout.
    private var mountedTerminalSurfaceIDs: Set<String> {
        Self.protectedSurfaceIDs(
            splitDocumentIDs: splitDocuments.keys,
            pendingSplitSubscriptionIDs: pendingSplitSubscriptions.keys,
            selectedSessionID: selectedSessionID,
            primarySessionID: terminalDocument.sessionID,
            activePaneLayoutSessionIDs: selectedProjectID.flatMap { paneLayouts[$0]?.sessionIDs } ?? []
        )
    }

    /// Pure form of `mountedTerminalSurfaceIDs`, so the eviction-protection
    /// policy can be exercised without an `AppModel` instance. Kept in sync by
    /// construction: the property above is a thin call site, not a second copy
    /// of this union.
    nonisolated static func protectedSurfaceIDs(
        splitDocumentIDs: some Sequence<String>,
        pendingSplitSubscriptionIDs: some Sequence<String>,
        selectedSessionID: String?,
        primarySessionID: String?,
        activePaneLayoutSessionIDs: some Sequence<String>
    ) -> Set<String> {
        var ids = Set(splitDocumentIDs)
        ids.formUnion(pendingSplitSubscriptionIDs)
        if let selectedSessionID { ids.insert(selectedSessionID) }
        if let primarySessionID { ids.insert(primarySessionID) }
        ids.formUnion(activePaneLayoutSessionIDs)
        return ids
    }

    /// Which retained documents to drop, least-recently-used first, so the deck
    /// obeys both its document count and its byte budget.
    ///
    /// Pure so the policy can be exercised without a broker: the caller owns
    /// the storage, this decides only the order and the stopping point. The
    /// most recent entry is never evicted — it is the document being published.
    nonisolated static func retainedSurfaceEvictions(
        order: [String],
        byteCount: (String) -> Int,
        protected: Set<String>,
        maximumSurfaces: Int = AppModel.maximumRetainedTerminalSurfaces,
        maximumBytes: Int = AppModel.maximumRetainedTerminalBytes
    ) -> [String] {
        var survivors = order
        var retainedBytes = survivors.reduce(into: 0) { $0 += byteCount($1) }
        var evictions: [String] = []
        var index = 0

        while index < survivors.count - 1 {
            let overCount = survivors.count > maximumSurfaces
            let overBudget = retainedBytes > maximumBytes
            guard overCount || overBudget else { break }
            let candidate = survivors[index]
            guard !protected.contains(candidate) else {
                index += 1
                continue
            }
            survivors.remove(at: index)
            retainedBytes -= byteCount(candidate)
            evictions.append(candidate)
        }
        return evictions
    }

    // MARK: - Native terminal ownership (Phase 2)

    /// Creates a plain shell the native app owns in the given directory.
    @discardableResult
    func createTerminal(inDirectory directory: URL) async -> String? {
        await createOwnedSession(inDirectory: directory, agent: nil)
    }

    /// Launches a one-click agent session: an owned terminal that boots the
    /// agent's CLI in the chosen directory, exactly like Electron's prepared
    /// terminal agents.
    func createAgentSession(
        _ agent: AgentProfile,
        inDirectory directory: URL,
        accountProfile: UsageAccountProfile? = nil
    ) async {
        await createOwnedSession(
            inDirectory: directory,
            agent: agent,
            accountProfile: accountProfile
        )
    }

    /// Registers a durable owned session and selects it. The PTY lives on the
    /// broker, so it survives this app quitting, updating, or crashing exactly
    /// like Electron's do. An agent session boots its CLI via a login shell so
    /// the user's PATH and CLI config apply.
    /// Returns the created terminal's id on success, nil on failure — so a
    /// caller (e.g. a Quick Action) can target exactly the shell it spawned
    /// rather than racing the shared `selectedSessionID`.
    @discardableResult
    private func createOwnedSession(
        inDirectory directory: URL,
        agent: AgentProfile?,
        accountProfile: UsageAccountProfile? = nil,
        lockedAccountBinding: SessionAccountBinding? = nil,
        resumeAgent: Bool = false,
        titleOverride: String? = nil,
        draftRestoreSeed: TerminalDraftResumeSeed? = nil,
        terminalIDOverride: String? = nil,
        restore: Bool = false,
        select: Bool = true,
        environmentBinding: SessionAccountBinding? = nil
    ) async -> String? {
        guard controlAvailable, connectionState.isConnected else {
            // Never fail silently: say WHY sessions can't be created here.
            publishPrimaryDocument(.failure(
                sessionID: "create-unavailable",
                message: connectionState.isConnected
                    ? "This terminal service is view-only right now, so new terminals are disabled. Chats and Mesh still work — they don't need it."
                    : "Kaisola isn't connected to saved terminal sessions, so new terminals are disabled. Chats and Mesh still work without that connection."
            ))
            return nil
        }
        let cwd = directory.path
        let projectID = NativeSessionStore.projectID(forDirectory: cwd)
        let terminalID = terminalIDOverride
            ?? NativeSessionStore.terminalID(projectID: projectID)
        let userShell = NativeTerminalLaunchEnvironment.resolvedShell(
            environment: ProcessInfo.processInfo.environment
        )
        let shell = NativeSemanticShellIntegration.launchShell(
            userShell: userShell,
            enabled: NativePreviewSettings.shared.semanticShellIntegration
        ) ?? userShell
        // Account isolation (custom CLAUDE_CONFIG_DIR / CODEX_HOME) rides in
        // as exported variables ahead of the CLI. Per-project overrides win
        // over the app-wide setting, key by key.
        guard var overlay = projectAccountOverlay(forProject: projectID) else { return nil }
        let accountBinding: SessionAccountBinding?
        if let agent, SessionAccountBinding.provider(forAgentID: agent.id) != nil {
            if let lockedAccountBinding {
                guard lockedAccountBinding.normalized?.provider
                    == SessionAccountBinding.provider(forAgentID: agent.id) else {
                    ToastCenter.shared.show("The saved account does not match \(agent.name).", style: .error)
                    return nil
                }
                accountBinding = lockedAccountBinding.normalized
            } else {
                guard let resolved = SessionAccountBinding.resolve(
                    agentID: agent.id,
                    profile: accountProfile,
                    fallbackEnvironment: ProcessInfo.processInfo.environment
                        .merging(overlay) { _, configured in configured }
                ) else {
                    ToastCenter.shared.show("That account does not match \(agent.name).", style: .error)
                    return nil
                }
                accountBinding = resolved
            }
            overlay = SessionAccountBinding.applying(accountBinding, to: overlay)
        } else if let environmentBinding = environmentBinding?.normalized {
            // A resurrected agent terminal boots as a plain shell (the resume
            // chip is the launch gate), but its saved account environment
            // must already be in place — otherwise the chip's resume command
            // would run under the default account, the exact hazard the chip
            // guards against.
            accountBinding = environmentBinding
            overlay = SessionAccountBinding.applying(environmentBinding, to: overlay)
        } else {
            accountBinding = nil
        }
        // The host marker, same convention as Cursor's CURSOR_AGENT: shell
        // profiles and CLIs can detect they are running inside Kaisola (and
        // which session) to suppress pagers, heavy prompt themes, or anything
        // else that fights inline capture.
        overlay["KAISOLA"] = "1"
        overlay["KAISOLA_SESSION_ID"] = terminalID
        // The overlay can carry secrets (ANTHROPIC_API_KEY / OPENAI_API_KEY).
        // The broker's createTerminal has no env channel, so the env must reach
        // the shell through the `-c` command — but embedding `export KEY=secret`
        // there leaves the secret in the parent shell's argv, visible to every
        // `ps`/diagnostic while the agent runs. Instead write the exports to a
        // per-session 0600 file and `source` + `rm` it, so only the file PATH
        // (not the secret) is ever in argv. Falls back to inline exports if the
        // file can't be written, so a write failure never blocks a session.
        let exports = overlay
            .map { "export \($0.key)=\(Self.shellQuote($0.value)); " }
            .sorted()
            .joined()
        let prelude: String
        if overlay.isEmpty {
            prelude = ""
        } else if let envFile = Self.writeSessionEnvFile(exports: exports, terminalID: terminalID) {
            prelude = "source \(Self.shellQuote(envFile)); rm -f \(Self.shellQuote(envFile)); "
        } else {
            prelude = exports
        }
        // A GUI app may inherit PATH from an older launching process. Prefer
        // current package-manager bins after the user's login profile has run,
        // then start the interactive shell without running the login profile a
        // second time. This fixes updated CLIs being shadowed by stale copies
        // while preserving the user's ordinary interactive rc file.
        let launchPrelude = NativeTerminalLaunchEnvironment.preferredPathPrelude() + prelude
        let arguments: [String]
        if let agent, !agent.launchCommand.isEmpty {
            // -ilc runs the agent as the login shell's command so it inherits
            // the interactive environment, then hands control to the user.
            let baseCommand = resumeAgent ? (agent.resumeCommand ?? agent.launchCommand) : agent.launchCommand
            let agentCommand = agent.id == "codex"
                ? ProviderRouting.codexLaunchCommand(
                    baseCommand,
                    openAIBaseURL: NativePreviewSettings.shared.openAIBaseURL,
                    openAIModel: NativePreviewSettings.shared.openAIModel
                )
                : baseCommand
            arguments = ["-ilc", "\(launchPrelude)\(agentCommand); exec \(Self.shellQuote(shell)) -i"]
        } else if !launchPrelude.isEmpty {
            // The non-interactive login shell reads the account profile once;
            // the replacement interactive shell then reads the normal rc once.
            arguments = ["-lc", "\(launchPrelude)exec \(Self.shellQuote(shell)) -i"]
        } else {
            arguments = ["-il"]
        }
        do {
            let creation = try await controlClient.createTerminal(
                projectID: projectID,
                terminalID: terminalID,
                command: shell,
                arguments: arguments,
                cwd: cwd,
                columns: 100,
                rows: 30,
                restore: restore
            )
            let folder = (cwd as NSString).lastPathComponent
            let requestedTitle = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionTitle = requestedTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? agent.map { "\($0.name) · \(folder)" }
                ?? folder
            sessionStore.upsert(NativeOwnedSession(
                id: terminalID,
                projectID: projectID,
                cwd: cwd,
                title: sessionTitle,
                createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
                agentID: agent?.id,
                accountBinding: accountBinding
            ))
            // A restore can resolve to a COLD record: the terminal ended
            // before the broker restart, so no shell spawned — history is
            // servable, the pane shows its ended state, and the record is
            // stamped so it never becomes a resurrection candidate (§2h-1b).
            if creation.exited {
                sessionStore.stampEnded(
                    terminalID, at: Int64(Date().timeIntervalSince1970 * 1_000)
                )
                refreshPersistedNavigationState(publish: false)
                Task { [weak self] in await self?.refreshInventory() }
                return terminalID
            }
            // Ensure the session's folder is a persistent project tab — but
            // never on the resurrection path: a respawn must not re-open a
            // closed project's tab or eat its ⌘⇧T undo entry (§4c).
            if !restore {
                sessionStore.openProject(directory: cwd)
            }
            refreshPersistedNavigationState(publish: false)
            ownedTerminalIDs.insert(terminalID)
            terminalInputDegradedIDs.remove(terminalID)
            terminalInputRecoveringIDs.remove(terminalID)

            // terminal.create already returned the authoritative identity. Put
            // it in the local inventory now so selection publishes a loading
            // card immediately instead of waiting for a second broker roundtrip.
            sessions.removeAll { $0.id == terminalID }
            sessions.append(BrokerTerminalRecord(
                id: terminalID,
                projectID: projectID,
                pid: creation.pid,
                exited: false,
                streamEpoch: creation.streamEpoch,
                endOffset: 0,
                currentOwnerID: observerOwnerID
            ))
            if select {
                await self.select(terminalID)
            }
            if resumeAgent, agent?.resumeCommand != nil, let draftRestoreSeed,
               NativePreviewSettings.shared.restoreCLIDrafts {
                terminalDraftTrackers[terminalID] = TerminalAgentDraftTracker(
                    text: draftRestoreSeed.text
                )
                persistTerminalDraftNow(terminalID)
                enqueueDraftRemoval(stableKey: draftRestoreSeed.sourceStableKey)
                armTerminalDraftRestore(draftRestoreSeed, terminalID: terminalID)
            }
            Task { [weak self] in await self?.refreshInventory() }
            return terminalID
        } catch {
            publishPrimaryDocument(.failure(sessionID: terminalID, message: error.kaisolaSafeDescription))
            return nil
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Write the export prelude to a per-session mode-0600 file under Application
    /// Support so account secrets reach the broker-spawned shell without landing
    /// in its argv. Returns the file path, or nil on any failure (caller then
    /// falls back to inline exports — availability over secrecy). The shell
    /// `rm`s it immediately after sourcing; a stale file (shell never ran) is a
    /// 0600 file only the user can read.
    private static func writeSessionEnvFile(exports: String, terminalID: String) -> String? {
        let directory = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("session-env", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Sanitize the id into a filename; it is broker-generated but keep
            // the path from ever escaping the directory.
            let safeID = terminalID.replacingOccurrences(
                of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
            )
            let file = directory.appendingPathComponent("\(safeID).sh", isDirectory: false)
            try Data(exports.utf8).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path
            )
            return file.path
        } catch {
            return nil
        }
    }

    /// The agent profile a session is currently running. Prepared agent
    /// sessions carry a durable id; a plain terminal that later starts an
    /// agent CLI is resolved from the live process probe. Keeping both paths
    /// here gives existing PTYs the same navigation identity and activity semantics
    /// as newly-created agent sessions without changing or restarting them.
    func agentProfile(for terminalID: String) -> AgentProfile? {
        persistedAgentProfile(for: terminalID)
            ?? AgentRegistry.profile(displayName: detectedAgentNamesByTerminalID[terminalID])
    }

    /// Named account presentation for an app-owned agent terminal. The
    /// project/default binding stays implicit; only an explicit profile adds
    /// chrome, so the indispensable Working/Responded status remains first.
    func accountLabel(for terminalID: String) -> String? {
        guard let binding = persistedOwnedSessions
            .first(where: { $0.id == terminalID })?
            .accountBinding?.normalized,
              binding.accountID != nil else { return nil }
        return binding.label
    }

    private func persistedAgentProfile(for terminalID: String) -> AgentProfile? {
        guard let stored = persistedOwnedSessions.first(where: { $0.id == terminalID }),
              let agentID = stored.agentID else { return nil }
        return AgentRegistry.profile(id: agentID)
    }

    /// Human-readable navigation title. Broker ids are intentionally opaque;
    /// plain shells use a project-local ordinal while agent and custom names
    /// keep their persisted title.
    func sessionTitle(for record: BrokerTerminalRecord) -> String {
        Self.sessionDisplayTitle(
            for: record,
            visibleRecords: sessions,
            storedSessions: persistedOwnedSessions,
            aliases: persistedSessionAliases
        )
    }

    func sessionTitle(for terminalID: String) -> String {
        guard let record = sessions.first(where: { $0.id == terminalID }) else {
            return persistedSessionAliases[terminalID]
                ?? persistedOwnedSessions.first(where: { $0.id == terminalID })?.title
                ?? terminalID
        }
        return sessionTitle(for: record)
    }

    /// The rename field edits the persisted base title, not a generated
    /// "Terminal 2" navigation label.
    func editableSessionTitle(for terminalID: String) -> String {
        persistedSessionAliases[terminalID]
            ?? persistedOwnedSessions.first(where: { $0.id == terminalID })?.title
            ?? sessions.first(where: { $0.id == terminalID })?.title
            ?? ""
    }

    /// Editable title for any unified session card. Chat titles are included in
    /// the durable workspace descriptor; Mesh titles are live for the current
    /// run (a Mesh process itself is intentionally not resurrected after quit).
    func editableSurfaceTitle(for id: String) -> String {
        if let chat = chats.first(where: { $0.id == id }) {
            return chat.conversation.title
        }
        if let mesh = meshes.first(where: { $0.id == id }) {
            return mesh.title
        }
        return editableSessionTitle(for: id)
    }

    static func sessionDisplayTitle(
        for record: BrokerTerminalRecord,
        visibleRecords _: [BrokerTerminalRecord],
        storedSessions: [NativeOwnedSession],
        aliases: [String: String] = [:]
    ) -> String {
        if let alias = aliases[record.id], !alias.isEmpty { return alias }
        let storedByID = Dictionary(uniqueKeysWithValues: storedSessions.map { ($0.id, $0) })
        guard let stored = storedByID[record.id] else { return record.title }
        return stored.title
    }

    /// Rename any session's navigation title. Owned sessions keep their title
    /// in the owned registry; observed sessions get a local alias only, so this
    /// never broadens write authority over an Electron-owned PTY.
    func renameSession(_ terminalID: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sessions.contains(where: { $0.id == terminalID }) else { return }
        if isOwned(terminalID),
           var stored = persistedOwnedSessions.first(where: { $0.id == terminalID }) {
            stored.title = trimmed
            stored.lastAutoTitle = nil
            sessionStore.upsert(stored)
            sessionStore.setSessionAlias(nil, for: terminalID)
        } else {
            sessionStore.setSessionAlias(trimmed, for: terminalID)
        }
        refreshPersistedNavigationState()
    }

    func renameSurface(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let chat = chats.first(where: { $0.id == id }) {
            chat.conversation.title = trimmed
            usageCenter.rename(chatID: id, title: trimmed)
            scheduleWorkspaceStateSave(projectID: chat.projectID)
            return
        }
        if let mesh = meshes.first(where: { $0.id == id }) {
            mesh.title = trimmed
            return
        }
        renameSession(id, to: trimmed)
    }

    /// A live OSC title from an owned session's terminal (SwiftTerm's
    /// setTerminalTitle). Auto-names the session unless the user renamed it.
    func applyAutoTitle(_ rawTitle: String, to terminalID: String) {
        guard isOwned(terminalID),
              let stored = persistedOwnedSessions.first(where: { $0.id == terminalID }) else { return }
        let agentName = agentProfile(for: terminalID)?.name
        let folder = (stored.cwd as NSString).lastPathComponent
        let defaultTitle = agentName.map { "\($0) · \(folder)" } ?? folder
        let userRenamed = sessionStore.hasCustomTitle(
            terminalID,
            defaultTitle: defaultTitle
        )
        guard !userRenamed else { return }
        guard let auto = SessionTitleTracker.autoTitle(
            fromOSC: rawTitle,
            agentName: agentName,
            folder: folder
        ) else {
            guard stored.title != defaultTitle,
                  SessionTitleTracker.representsCreationDefault(
                    fromOSC: rawTitle,
                    folder: folder
                  ) else { return }
            sessionStore.applyAutoTitle(defaultTitle, terminalID: terminalID)
            refreshPersistedNavigationState()
            return
        }
        guard SessionTitleTracker.shouldApply(
            autoTitle: auto,
            currentTitle: stored.title,
            userRenamed: false
        ) else { return }
        sessionStore.applyAutoTitle(auto, terminalID: terminalID)
        refreshPersistedNavigationState()
    }

    private func applyProcessAutoTitle(_ processName: String?, to terminalID: String) {
        guard isOwned(terminalID),
              let stored = persistedOwnedSessions.first(where: { $0.id == terminalID }) else { return }
        // Process auto-titling must only consider the launch-time profile. A
        // live-detected CLI is exactly the case this method is meant to name.
        let agentName = persistedAgentProfile(for: terminalID)?.name
        let folder = (stored.cwd as NSString).lastPathComponent
        guard let auto = SessionTitleTracker.autoTitle(
            fromProcess: processName,
            agentName: agentName,
            folder: folder
        ) else { return }
        let defaultTitle = agentName.map { "\($0) · \(folder)" } ?? folder
        guard SessionTitleTracker.shouldApply(
            autoTitle: auto,
            currentTitle: stored.title,
            userRenamed: sessionStore.hasCustomTitle(terminalID, defaultTitle: defaultTitle)
        ) else { return }
        sessionStore.applyAutoTitle(auto, terminalID: terminalID)
        refreshPersistedNavigationState()
    }

    /// Keyboard bytes from an owned session's surface. Ownership is re-checked
    /// here so no UI wiring mistake can ever write to an observed terminal. For
    /// an agent session, a submitted line (carriage return) opens an agent
    /// turn; the broker's quiet timer settles it back to idle.
    func sendInput(_ data: String, to terminalID: String) {
        guard let record = sessions.first(where: { $0.id == terminalID }) else { return }
        // Every caller wires this from an owned surface, so reaching it
        // unowned means ownership flapped underneath a still-mounted view
        // (teardown, mid-restore). Say so — silently eating the bytes is
        // indistinguishable from broken typing (2026-08-07 incident).
        guard isOwned(terminalID) else {
            reportTerminalInputFailure(terminalID)
            return
        }
        guard !isTerminalInputDegraded(terminalID) else {
            reportTerminalInputFailure(terminalID, scopedToTerminal: true)
            return
        }
        let projectID = record.projectID
        let opensAgentTurn = (
            agentProfile(for: terminalID) != nil
                || detectedAgentNamesByTerminalID[terminalID] != nil
        ) && data.contains("\r")
        guard controlAvailable else {
            reportTerminalInputFailure(terminalID)
            return
        }
        let inputGeneration = terminalInputGenerations[terminalID, default: 0]
        let chunks = Self.terminalWriteChunks(data)
        let pasteGeneration: UInt64?
        if chunks.count > 1 {
            let generation: UInt64
            if let current = terminalPasteGenerationByTerminalID[terminalID] {
                generation = current
            } else {
                nextTerminalPasteGeneration &+= 1
                generation = nextTerminalPasteGeneration
                terminalPasteGenerationByTerminalID[terminalID] = generation
            }
            pasteGeneration = generation
            let current = terminalPasteProgressByTerminalID[terminalID]
                ?? TerminalPasteProgress(sentBytes: 0, totalBytes: 0)
            terminalPasteProgressByTerminalID[terminalID] = TerminalPasteProgress(
                sentBytes: current.sentBytes,
                totalBytes: current.totalBytes + chunks.reduce(0) { $0 + $1.utf8.count }
            )
        } else {
            pasteGeneration = nil
        }
        terminalInputQueues[terminalID, default: []].append(contentsOf:
            chunks.enumerated().map { index, chunk in
                PendingTerminalInput(
                    projectID: projectID,
                    data: chunk,
                    opensAgentTurn: opensAgentTurn && index == chunks.count - 1,
                    generation: inputGeneration,
                    pasteGeneration: pasteGeneration,
                    byteCount: chunk.utf8.count
                )
            }
        )
        guard terminalInputDrainTasks[terminalID] == nil else { return }
        terminalInputDrainTasks[terminalID] = Task { [weak self] in
            await self?.drainTerminalInputQueue(
                terminalID,
                generation: inputGeneration
            )
        }
    }

    /// Revalidate only the affected terminal on the still-live controller
    /// lane. A full reload would tear down observer subscriptions and briefly
    /// interrupt every unrelated terminal, recreating the blast radius this
    /// recovery state is designed to avoid.
    func recoverTerminalInput(_ terminalID: String) async {
        guard isTerminalInputDegraded(terminalID),
              !isTerminalInputRecovering(terminalID),
              controlAvailable,
              isOwned(terminalID),
              let record = sessions.first(where: { $0.id == terminalID && !$0.exited }) else {
            return
        }
        let recoveryGeneration = connectionGeneration
        terminalInputRecoveringIDs.insert(terminalID)
        defer { terminalInputRecoveringIDs.remove(terminalID) }
        do {
            // Control requests are ordered on one socket. A successful attach
            // therefore proves the broker has moved past the ambiguous write
            // without replaying its bytes or disturbing observer streams.
            try await controlClient.attach(
                projectID: record.projectID,
                terminalID: terminalID
            )
            guard recoveryGeneration == connectionGeneration,
                  controlAvailable,
                  isOwned(terminalID),
                  sessions.contains(where: { $0.id == terminalID && !$0.exited }) else {
                return
            }
            terminalInputDegradedIDs.remove(terminalID)
            terminalInputFailureNoticeAt.removeValue(forKey: terminalID)
            ToastCenter.shared.show("Terminal input restored.", style: .success)
        } catch {
            guard recoveryGeneration == connectionGeneration, controlAvailable else { return }
            if Self.isControllerConnectionFailure(error) {
                reportTerminalInputFailure(terminalID)
                controlAvailable = false
                ownedTerminalIDs = []
                terminalInputDegradedIDs.removeAll()
                terminalInputRecoveringIDs.removeAll()
                connectionLost(error, generation: recoveryGeneration)
            } else {
                terminalInputFailureNoticeAt.removeValue(forKey: terminalID)
                reportTerminalInputFailure(terminalID, scopedToTerminal: true)
            }
        }
    }

    /// One consumer per PTY makes keyboard bytes FIFO by construction. The
    /// previous fire-and-forget Task per key depended on actor scheduling order
    /// and swallowed every mutation error.
    private func drainTerminalInputQueue(
        _ terminalID: String,
        generation: UInt64
    ) async {
        defer {
            if terminalInputGenerations[terminalID, default: 0] == generation {
                terminalInputDrainTasks[terminalID] = nil
            }
        }
        while !Task.isCancelled,
              terminalInputGenerations[terminalID, default: 0] == generation,
              controlAvailable,
              isOwned(terminalID),
              var queue = terminalInputQueues[terminalID],
              !queue.isEmpty {
            let packet = queue.removeFirst()
            terminalInputQueues[terminalID] = queue
            guard packet.generation == generation else { continue }
            let writeGeneration = connectionGeneration
            do {
                try await controlClient.write(
                    projectID: packet.projectID,
                    terminalID: terminalID,
                    data: packet.data
                )
                // Composer persistence is an acknowledgement receipt, not an
                // optimistic key log. A packet discarded while queued, or an
                // ambiguous late success from a revoked generation, must never
                // become a future automatic draft retype.
                guard terminalInputGenerations[terminalID, default: 0] == generation,
                      controlAvailable,
                      isOwned(terminalID) else { return }
                trackTerminalDraftInput(packet.data, terminalID: terminalID)
                acknowledgeTerminalPaste(packet, terminalID: terminalID)
                if packet.opensAgentTurn {
                    // Deliberately not part of the write's error path: a
                    // refused turn signal is an activity-tracking failure, not
                    // a broken connection, so it must not drop queued bytes.
                    await signalAgentTurn(
                        busy: true,
                        projectID: packet.projectID,
                        terminalID: terminalID
                    )
                }
            } catch {
                // An invalidated generation may finish its cancelled transport
                // await after a fresh owner has already queued input. It must
                // not erase that new queue or tear down the replacement lane.
                guard terminalInputGenerations[terminalID, default: 0] == generation else {
                    return
                }
                guard !Task.isCancelled,
                      writeGeneration == connectionGeneration,
                      controlAvailable else { return }
                if Self.isControllerConnectionFailure(error) {
                    reportTerminalInputFailure(terminalID)
                    invalidateAllTerminalInput()
                    controlAvailable = false
                    ownedTerminalIDs = []
                    terminalInputDegradedIDs.removeAll()
                    terminalInputRecoveringIDs.removeAll()
                    connectionLost(error, generation: writeGeneration)
                } else {
                    // Never retry an ambiguous terminal.write. Request IDs are
                    // correlation-only, so a timeout may mean the bytes were
                    // applied and only the response was lost. Retrying could
                    // duplicate text, Return, or Ctrl-C.
                    invalidateTerminalInput(for: terminalID)
                    terminalInputDegradedIDs.insert(terminalID)
                    reportTerminalInputFailure(terminalID, scopedToTerminal: true)
                }
                return
            }
        }
        if terminalInputGenerations[terminalID, default: 0] == generation,
           terminalInputQueues[terminalID]?.isEmpty == true {
            terminalInputQueues.removeValue(forKey: terminalID)
        }
    }

    /// The broker enforces this same cap immediately before node-pty. Split on
    /// Unicode-scalar boundaries keep every chunk a valid String. A bracketed
    /// paste closes and reopens around each body chunk so cancellation between
    /// acknowledgements cannot strand the receiving TUI in paste mode; the
    /// concatenated body remains byte-exact.
    nonisolated static func terminalWriteChunks(_ data: String) -> [String] {
        guard data.utf8.count > terminalWritePayloadByteLimit else { return [data] }
        let bracketedPasteOpening = "\u{1B}[200~"
        let bracketedPasteClosing = "\u{1B}[201~"
        if data.hasPrefix(bracketedPasteOpening),
           data.hasSuffix(bracketedPasteClosing) {
            let body = String(
                data.dropFirst(bracketedPasteOpening.count)
                    .dropLast(bracketedPasteClosing.count)
            )
            let bodyLimit = terminalWritePayloadByteLimit
                - bracketedPasteOpening.utf8.count
                - bracketedPasteClosing.utf8.count
            return terminalWriteScalarChunks(body, maximumBytes: bodyLimit).map {
                bracketedPasteOpening + $0 + bracketedPasteClosing
            }
        }
        return terminalWriteScalarChunks(
            data,
            maximumBytes: terminalWritePayloadByteLimit
        )
    }

    nonisolated private static func terminalWriteScalarChunks(
        _ data: String,
        maximumBytes: Int
    ) -> [String] {
        var chunks: [String] = []
        chunks.reserveCapacity((data.utf8.count / maximumBytes) + 1)
        var current = ""
        var currentBytes = 0
        for scalar in data.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            if currentBytes + scalarBytes > maximumBytes,
               !current.isEmpty {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            current.unicodeScalars.append(scalar)
            currentBytes += scalarBytes
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    func terminalPasteProgress(for terminalID: String) -> TerminalPasteProgress? {
        terminalPasteProgressByTerminalID[terminalID]
    }

    /// Cancel only chunks the controller has not started. The current write has
    /// an ambiguous outcome until its reply arrives and must never be aborted
    /// or replayed; ordinary keyboard packets queued behind the paste survive.
    func cancelTerminalPaste(for terminalID: String) {
        guard let pasteGeneration = terminalPasteGenerationByTerminalID.removeValue(
            forKey: terminalID
        ) else { return }
        terminalPasteProgressByTerminalID.removeValue(forKey: terminalID)
        terminalInputQueues[terminalID]?.removeAll {
            $0.pasteGeneration == pasteGeneration
        }
        ToastCenter.shared.show(
            "Paste cancelled; a chunk already being sent may still finish.",
            style: .info,
            duration: 4
        )
    }

    private func acknowledgeTerminalPaste(
        _ packet: PendingTerminalInput,
        terminalID: String
    ) {
        guard let pasteGeneration = packet.pasteGeneration,
              terminalPasteGenerationByTerminalID[terminalID] == pasteGeneration,
              let progress = terminalPasteProgressByTerminalID[terminalID] else { return }
        let sentBytes = min(progress.totalBytes, progress.sentBytes + packet.byteCount)
        if sentBytes == progress.totalBytes {
            terminalPasteGenerationByTerminalID.removeValue(forKey: terminalID)
            terminalPasteProgressByTerminalID.removeValue(forKey: terminalID)
        } else {
            terminalPasteProgressByTerminalID[terminalID] = TerminalPasteProgress(
                sentBytes: sentBytes,
                totalBytes: progress.totalBytes
            )
        }
    }

    /// Tells the broker a turn opened or closed and only then moves local
    /// activity state. The broker replies `{ok:false}` for a record it no
    /// longer holds; treating that as success is what let the app protect a
    /// turn the broker had already written off as idle.
    private func signalAgentTurn(
        busy: Bool,
        projectID: String,
        terminalID: String
    ) async {
        do {
            try await controlClient.setAgentTurn(
                projectID: projectID,
                terminalID: terminalID,
                busy: busy
            )
            if busy {
                acknowledgedAgentTurnTerminalIDs.insert(terminalID)
            } else {
                acknowledgedAgentTurnTerminalIDs.remove(terminalID)
            }
            if agentTurnSignalFailureTerminalIDs.remove(terminalID) != nil {
                agentTurnSignalFailureNoticeAt.removeValue(forKey: terminalID)
            }
        } catch {
            acknowledgedAgentTurnTerminalIDs.remove(terminalID)
            agentTurnSignalFailureTerminalIDs.insert(terminalID)
            reportAgentTurnSignalFailure(terminalID)
        }
    }

    /// Terminals whose open agent turn the broker confirmed and has not yet
    /// reported finished. Only positive acknowledgements land here.
    var openAgentTurnTerminalIDs: Set<String> {
        guard !acknowledgedAgentTurnTerminalIDs.isEmpty else { return [] }
        let live = Set(sessions.lazy.filter { !$0.exited }.map(\.id))
        return acknowledgedAgentTurnTerminalIDs.intersection(live)
    }

    /// Terminals the app believes are mid-turn while the broker does not.
    /// Rows that already left the live inventory clear themselves: a terminal
    /// the broker no longer holds cannot be cut over underneath anything.
    var unprotectedAgentTurnTerminalIDs: Set<String> {
        guard !agentTurnSignalFailureTerminalIDs.isEmpty else { return [] }
        let live = Set(sessions.lazy.filter { !$0.exited }.map(\.id))
        return agentTurnSignalFailureTerminalIDs.intersection(live)
    }

    /// The native half of the terminal-continuity update gate. While a live
    /// terminal's activity is unsignalled the broker would read it as idle and
    /// accept a rolling cutover, so the app stops asking for one.
    var brokerUpdateGateBlockedDetail: String? {
        let blocked = unprotectedAgentTurnTerminalIDs
        guard !blocked.isEmpty else { return nil }
        let subject = blocked.count == 1
            ? "1 terminal's agent activity"
            : "\(blocked.count) terminals' agent activity"
        return "Terminal-continuity updates are paused: \(subject) could not be reported to the "
            + "background service, which would read those sessions as idle."
    }

    private func reportAgentTurnSignalFailure(_ terminalID: String) {
        let now = Date()
        if let last = agentTurnSignalFailureNoticeAt[terminalID],
           now.timeIntervalSince(last) < 2 { return }
        agentTurnSignalFailureNoticeAt[terminalID] = now
        ToastCenter.shared.show(
            "Agent activity could not be reported; terminal-continuity updates are paused",
            style: .error,
            duration: 6
        )
    }

    /// Cancel and forget bytes accepted under the terminal's previous owner
    /// capability. Generation fencing also keeps an old task's `defer` or
    /// transport error from clearing a new drain installed after reattachment.
    @discardableResult
    private func invalidateTerminalInput(for terminalID: String) -> Bool {
        let discardedQueuedInput = terminalInputQueues[terminalID]?.isEmpty == false
        terminalInputGenerations[terminalID, default: 0] &+= 1
        terminalInputDrainTasks.removeValue(forKey: terminalID)?.cancel()
        terminalInputQueues.removeValue(forKey: terminalID)
        terminalPasteGenerationByTerminalID.removeValue(forKey: terminalID)
        terminalPasteProgressByTerminalID.removeValue(forKey: terminalID)
        return discardedQueuedInput
    }

    private func invalidateAllTerminalInput(notifyIfDiscarded: Bool = false) {
        let terminalIDs = Set(terminalInputQueues.keys)
            .union(terminalInputDrainTasks.keys)
            .union(ownedTerminalIDs)
        var terminalsWithDiscardedInput: Set<String> = []
        for terminalID in terminalIDs {
            if invalidateTerminalInput(for: terminalID) {
                terminalsWithDiscardedInput.insert(terminalID)
            }
        }
        if notifyIfDiscarded, !terminalsWithDiscardedInput.isEmpty {
            reportDiscardedTerminalInput(for: terminalsWithDiscardedInput)
        }
    }

    private func reportDiscardedTerminalInput(for terminalIDs: Set<String>) {
        let message: String
        if terminalIDs.count == 1, let terminalID = terminalIDs.first {
            let safeTitle = SessionTitleTracker.sanitize(
                terminalInputNoticeTitle(for: terminalID)
            )
                ?? "This terminal"
            message = safeTitle + Self.terminalInputDiscardNoticeSuffix
        } else {
            message = Self.terminalInputDiscardAggregateNotice
        }
        let now = Date()
        for terminalID in terminalIDs {
            // A stale surface callback often follows the ownership callback in
            // the same run-loop turn. The discard notice already explains its
            // fate, so suppress the generic recovery toast for that echo only.
            terminalInputFailureNoticeAt[terminalID] = now
        }
        ToastCenter.shared.show(
            message,
            style: .error,
            duration: 6
        )
    }

    /// Match the terminal identity shown in the project rail. A plain shell's
    /// stored title is normally just its project folder, which is ambiguous as
    /// soon as that project has two terminals; the rail resolves that collision
    /// with a project-local ordinal (and process name when available).
    private func terminalInputNoticeTitle(for terminalID: String) -> String {
        guard let project = projects.first(where: { project in
            project.sessions.contains(where: { $0.id == terminalID })
        }),
              let ordinal = project.sessions.firstIndex(where: { $0.id == terminalID }),
              let record = project.sessions.first(where: { $0.id == terminalID }) else {
            return sessionTitle(for: terminalID)
        }
        return QuietRailTitle.displayTitle(
            rawTitle: sessionTitle(for: record),
            projectName: project.name,
            processName: meta(for: terminalID)?.processName,
            ordinal: ordinal + 1
        )
    }

    private nonisolated static func isControllerConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? BrokerClientError else { return false }
        switch error {
        case .notConnected,
             .connectionClosed,
             .authenticationRejected,
             .protocolMismatch,
             .securityEpochMismatch,
             .implementationMismatch,
             .identityChanged,
             .observeFeatureMissing,
             .connectionTimedOut,
             .socketFailure,
             .socketPathTooLong:
            return true
        case .frameRejected,
             .malformedResponse,
             .requestTimedOut,
             .terminalCapacityExceeded,
             .requestFailed:
            return false
        }
    }

    private func reportTerminalInputFailure(
        _ terminalID: String,
        scopedToTerminal: Bool = false
    ) {
        let now = Date()
        if let last = terminalInputFailureNoticeAt[terminalID],
           now.timeIntervalSince(last) < 2 { return }
        terminalInputFailureNoticeAt[terminalID] = now
        ToastCenter.shared.show(
            scopedToTerminal
                ? "Input paused for this terminal; the last write could not be confirmed. Other sessions remain connected."
                : "Terminal connection is recovering; input was not sent",
            style: .error,
            duration: 4
        )
    }

    private func trackTerminalDraftInput(_ data: String, terminalID: String) {
        var cancelledPendingRestore = false
        if pendingTerminalDraftRestores[terminalID] != nil {
            // Terminal-generated query replies are intentionally non-interactive
            // in the tracker. A printable key, navigation key, submit, or clear
            // means the user has taken over this fresh composer, so never race
            // their input with a delayed automatic retype.
            var probe = TerminalAgentDraftTracker()
            if probe.apply(data).userInteracted {
                terminalDraftRestoreTasks.removeValue(forKey: terminalID)?.cancel()
                pendingTerminalDraftRestores.removeValue(forKey: terminalID)
                terminalDraftTrackers[terminalID] = TerminalAgentDraftTracker()
                cancelledPendingRestore = true
            }
        }
        if terminalDraftContext(for: terminalID) != nil {
            var tracker = terminalDraftTrackers[terminalID] ?? TerminalAgentDraftTracker()
            let effect = tracker.apply(data)
            terminalDraftTrackers[terminalID] = tracker
            if effect.textChanged || cancelledPendingRestore {
                scheduleTerminalDraftPersistence(terminalID)
            }
        }
    }

    func resizeTerminal(_ terminalID: String, columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        desiredTerminalGeometry[terminalID] = DesktopTerminalGeometry(
            columns: columns,
            rows: rows
        )
        scheduleDesiredTerminalResize(terminalID)
    }

    private func scheduleDesiredTerminalResize(
        _ terminalID: String,
        force: Bool = false
    ) {
        guard controlAvailable, isOwned(terminalID),
              !companionControlledTerminalIDs.contains(terminalID),
              let record = sessions.first(where: { $0.id == terminalID }),
              let geometry = desiredTerminalGeometry[terminalID] else { return }
        let projectID = record.projectID
        let sizeKey = geometry.key
        guard force
            || lastTerminalSize[terminalID] != sizeKey
            || terminalResizeTasks[terminalID] != nil else { return }
        let generation = (terminalResizeGeneration[terminalID] ?? 0) + 1
        terminalResizeGeneration[terminalID] = generation
        terminalResizeTasks[terminalID]?.cancel()
        terminalResizeTasks[terminalID] = Task { [weak self] in
            // AppKit emits a burst of transient dimensions during live resize,
            // minimize, zoom, and equal-grid relayout. Send only the settled
            // latest size so stale async requests cannot arrive out of order and
            // make SwiftTerm reflow against yesterday's width.
            if !force {
                try? await Task.sleep(nanoseconds: Self.terminalResizeDebounceNanoseconds)
            }
            guard !Task.isCancelled, let self,
                  self.terminalResizeGeneration[terminalID] == generation,
                  self.desiredTerminalGeometry[terminalID] == geometry,
                  self.controlAvailable,
                  self.isOwned(terminalID),
                  !self.companionControlledTerminalIDs.contains(terminalID) else { return }
            do {
                try await self.controlClient.resize(
                    projectID: projectID,
                    terminalID: terminalID,
                    columns: geometry.columns,
                    rows: geometry.rows
                )
                guard self.terminalResizeGeneration[terminalID] == generation else { return }
                self.lastTerminalSize[terminalID] = sizeKey
                self.terminalResizeTasks[terminalID] = nil
            } catch {
                guard self.terminalResizeGeneration[terminalID] == generation else { return }
                self.terminalResizeTasks[terminalID] = nil
            }
        }
    }

    /// Companion never receives this AppModel's full controller. These four
    /// entry points re-check both durable ownership and the broker's exact
    /// current controller instance before forwarding a leased operation.
    func companionTerminalAvailability(
        for terminal: BrokerTerminalRecord
    ) -> CompanionTerminalControlAvailability? {
        guard let current = companionControlledTerminal(matching: terminal) else { return nil }
        return CompanionTerminalControlAvailability(
            geometry: CompanionTerminalGeometry(columns: current.columns, rows: current.rows)
        )
    }

    func setCompanionControlActive(
        _ active: Bool,
        for terminal: BrokerTerminalRecord
    ) async throws {
        try await controlClient.setControlLease(
            projectID: terminal.projectID,
            terminalID: terminal.id,
            active: active
        )
        applyCompanionControlState(active, for: terminal)
    }

    func setCompanionControlFixtureActive(
        _ active: Bool,
        for terminal: BrokerTerminalRecord
    ) {
        applyCompanionControlState(active, for: terminal)
    }

    private func applyCompanionControlState(
        _ active: Bool,
        for terminal: BrokerTerminalRecord
    ) {
        if active {
            companionControlledTerminalIDs.insert(terminal.id)
            terminalResizeTasks.removeValue(forKey: terminal.id)?.cancel()
            terminalResizeGeneration[terminal.id, default: 0] += 1
        } else {
            companionControlledTerminalIDs.remove(terminal.id)
            scheduleDesiredTerminalResize(terminal.id, force: true)
        }
    }

    func companionWrite(_ data: String, to terminal: BrokerTerminalRecord) async throws {
        guard let current = companionControlledTerminal(matching: terminal) else {
            throw CompanionTerminalControlAdapterError.unavailable
        }
        trackTerminalDraftInput(data, terminalID: current.id)
        try await controlClient.write(
            projectID: current.projectID,
            terminalID: current.id,
            data: data
        )
        let opensAgentTurn = (
            agentProfile(for: current.id) != nil
                || detectedAgentNamesByTerminalID[current.id] != nil
        ) && data.contains("\r")
        if opensAgentTurn {
            await signalAgentTurn(
                busy: true,
                projectID: current.projectID,
                terminalID: current.id
            )
        }
    }

    func companionResize(
        _ geometry: CompanionTerminalGeometry,
        terminal: BrokerTerminalRecord
    ) async throws {
        guard let current = companionControlledTerminal(matching: terminal) else {
            throw CompanionTerminalControlAdapterError.unavailable
        }
        // Fence a pending AppKit resize before applying remote geometry. The
        // desktop view can request its dimensions again after the lease restores
        // the captured original size.
        terminalResizeTasks.removeValue(forKey: current.id)?.cancel()
        terminalResizeGeneration[current.id, default: 0] += 1
        try await controlClient.resize(
            projectID: current.projectID,
            terminalID: current.id,
            columns: geometry.columns,
            rows: geometry.rows
        )
        lastTerminalSize[current.id] = "\(geometry.columns)x\(geometry.rows)"
    }

    func companionInterrupt(_ terminal: BrokerTerminalRecord) async throws {
        guard let current = companionControlledTerminal(matching: terminal) else {
            throw CompanionTerminalControlAdapterError.unavailable
        }
        // Ctrl-C through the already-sealed write operation is exactly what
        // the broker's terminal.signal route does. Keeping it here avoids
        // widening BrokerControlServing just for Companion.
        trackTerminalDraftInput("\u{3}", terminalID: current.id)
        try await controlClient.write(
            projectID: current.projectID,
            terminalID: current.id,
            data: "\u{3}"
        )
    }

    private func companionControlledTerminal(
        matching terminal: BrokerTerminalRecord
    ) -> BrokerTerminalRecord? {
        guard controlAvailable,
              isOwned(terminal.id),
              !controlClient.connectionInstanceID.isEmpty,
              let current = sessions.first(where: {
                  $0.id == terminal.id
                      && $0.projectID == terminal.projectID
                      && !$0.exited
              }),
              current.currentOwnerInstanceID == controlClient.connectionInstanceID else {
            return nil
        }
        return current
    }

    /// Ends an owned session for good: the PTY dies and the registry entry is
    /// removed. (App quit is different — quitting detaches and the shell keeps
    /// running on the broker.)
    /// Closing is user intent (2026-08-06 spec §4a): everything that decides
    /// whether the terminal can ever come back happens HERE, synchronously —
    /// the store commit (record removed, tombstone added, release queued) and
    /// the pane removal. A ⌘Q in the same runloop turn, a dead broker, or a
    /// respawn already in flight all see the truth. Broker cleanup is
    /// best-effort behind it via `drainPendingReleases()`.
    func commitClose(_ terminalID: String, recordUndo: Bool = true) {
        terminalDraftDebounceTasks.removeValue(forKey: terminalID)?.cancel()
        persistTerminalDraftNow(terminalID)
        let brokerGenerationID = sessions.first { $0.id == terminalID }?.brokerGenerationID
        sessionStore.commitCloseTerminal(
            terminalID,
            recordUndo: recordUndo,
            brokerGenerationID: brokerGenerationID
        )
        refreshPersistedNavigationState(publish: false)
        dormantTerminalIDs.remove(terminalID)
        terminalResizeTasks.removeValue(forKey: terminalID)?.cancel()
        terminalResizeGeneration.removeValue(forKey: terminalID)
        desiredTerminalGeometry.removeValue(forKey: terminalID)
        lastTerminalSize.removeValue(forKey: terminalID)
        invalidateTerminalInput(for: terminalID)
        terminalInputFailureNoticeAt.removeValue(forKey: terminalID)
        terminalInputDegradedIDs.remove(terminalID)
        terminalInputRecoveringIDs.remove(terminalID)
        ownedTerminalIDs.remove(terminalID)
        companionControlledTerminalIDs.remove(terminalID)
        terminalSurfaceDocuments.removeValue(forKey: terminalID)
        terminalSurfaceOrder.removeAll { $0 == terminalID }
        terminalSurfaceFeeds.removeValue(forKey: terminalID)
        terminalDraftRestoreTasks.removeValue(forKey: terminalID)?.cancel()
        pendingTerminalDraftRestores.removeValue(forKey: terminalID)
        terminalLastOutputAt.removeValue(forKey: terminalID)
        terminalDraftTrackers.removeValue(forKey: terminalID)
        pendingAgentResume.removeValue(forKey: terminalID)
        sessions.removeAll { $0.id == terminalID }
        // Drop the parked SwiftTerm buffer too; this terminal cannot come back.
        TerminalSurfaceCache.shared.evict(sessionID: terminalID)
        for projectID in Array(paneLayouts.keys) {
            _ = reconcilePaneLayoutWithAvailableSurfaces(for: projectID, persist: true)
        }
        if selectedSessionID == terminalID {
            selectedSessionID = nil
            // Async surface teardown (empty document publish) — pure UI, so
            // it may follow the synchronous state commit.
            Task { [weak self] in await self?.select(nil) }
        }
        unifiedSessionCards.clearFocus(ifMatching: terminalID)
    }

    /// Live work that would keep running out of sight if this project closed:
    /// unexited terminals, running chats, running mesh columns.
    func runningWorkCount(inProject projectID: String) -> Int {
        let terminals = sessions.filter {
            displayProjectID($0) == projectID && !$0.exited
        }.count
        let runningChats = chats(in: projectID).filter(\.conversation.isRunning).count
        let runningColumns = meshes(in: projectID).reduce(into: 0) { count, mesh in
            count += mesh.columns.filter(\.conversation.isRunning).count
        }
        return terminals + runningChats + runningColumns
    }

    /// Whether a close affordance applies: any terminal with a persisted
    /// record (live, exited, dormant, or unavailable) can be closed.
    func canClose(_ terminalID: String) -> Bool {
        sessionStore.owns(terminalID: terminalID) || dormantTerminalIDs.contains(terminalID)
    }

    /// Dormant ids scoped to one project — a dormant terminal must hold a
    /// pane open only in its own project's layout.
    private func dormantTerminalIDs(in projectID: String) -> Set<String> {
        let byID = Dictionary(
            persistedOwnedSessions.map { ($0.id, $0.projectID) },
            uniquingKeysWith: { first, _ in first }
        )
        return dormantTerminalIDs.filter { byID[$0] == projectID }
    }

    /// Owed broker releases, drained after every close and every connect.
    /// Idempotent: an absent terminal acknowledges the release too.
    func drainPendingReleases() async {
        guard controlAvailable else { return }
        for pending in sessionStore.pendingReleaseList() {
            do {
                // The broker acknowledges release idempotently — an absent
                // terminal succeeds — so success is the ONLY ack. An error
                // (network blip, generation rollover) keeps the entry queued
                // for the next drain; acking on failure was how a closed
                // terminal's still-alive PTY could be re-adopted later.
                // Every returned disposition is terminal: either the broker
                // acknowledged the idempotent release, the terminal is absent
                // from every validated inventory, or its captured generation
                // has retired. Only a thrown transport/identity error retries.
                _ = try await controlClient.release(
                    projectID: pending.projectID,
                    terminalID: pending.id,
                    brokerGenerationID: pending.brokerGenerationID
                )
                sessionStore.acknowledgeRelease(id: pending.id)
            } catch {
                continue
            }
        }
        await refreshInventory()
    }

    /// Compatibility shim for existing async call sites; the commit itself is
    /// synchronous per §4a.
    func endSession(_ terminalID: String) async {
        commitClose(terminalID)
        await drainPendingReleases()
        await select(selectedSessionID)
    }

    /// Recreate the most recently ended session (⌘⌥T). Provider CLIs with a
    /// documented continuation command reopen their most recent conversation
    /// in the same locked account/workspace; other agents start fresh. The old
    /// PTY is gone, so the broker always creates a new terminal identity.
    func reopenLastClosedSession() async {
        guard let closed = sessionStore.popClosedSession() else { return }
        if await recreateSession(from: closed) == nil {
            // A transient broker/account failure must not consume the user's
            // only reopen affordance or strand its private draft.
            sessionStore.pushClosedSession(closed)
        }
    }

    /// Whether an exact ended card can be recreated right now. Observed panes
    /// remain read-only, and a disconnected/legacy broker keeps the action
    /// visible but disabled instead of pretending a new PTY was started.
    func canReopenEndedSession(_ terminalID: String) -> Bool {
        controlAvailable
            && connectionState.isConnected
            && !reopeningTerminalIDs.contains(terminalID)
            && sessions.contains(where: { $0.id == terminalID && $0.exited })
            && isOwned(terminalID)
            && persistedOwnedSessions.contains(where: { $0.id == terminalID })
    }

    /// Recreate the terminal represented by one ended pane, then put the new
    /// broker identity back into that pane's exact split position. The ended
    /// record remains available in the sidebar for transcript inspection.
    func reopenEndedSession(_ terminalID: String) async {
        guard canReopenEndedSession(terminalID),
              let record = sessions.first(where: { $0.id == terminalID && $0.exited }),
              let stored = persistedOwnedSessions.first(where: { $0.id == terminalID }) else {
            return
        }
        let originalLayout = paneLayouts[record.projectID]
        reopeningTerminalIDs.insert(terminalID)
        defer { reopeningTerminalIDs.remove(terminalID) }

        let closed = ClosedSession(
            cwd: stored.cwd,
            agentID: stored.agentID,
            title: stored.title,
            accountBinding: stored.accountBinding,
            sourceTerminalID: terminalID
        )
        guard let createdID = await recreateSession(from: closed) else { return }
        // The create suspended; another window may have closed the old id
        // (tombstoned it) meanwhile. Its close already reconciled the layout,
        // so swap against the CURRENT layout, never the pre-await snapshot —
        // overwriting with the stale copy was a lost-update.
        if sessionStore.isTerminalTombstoned(terminalID) {
            unifiedSessionCards.focusPresentation(on: createdID)
            scheduleWorkspaceStateSave(projectID: record.projectID)
            return
        }
        if unifiedSessionCards.replace(
            terminalID,
            with: createdID,
            in: record.projectID,
            fallback: originalLayout
        ) {
            scheduleWorkspaceStateSave(projectID: record.projectID)
        }
        // The replacement owns the pane now; the old record must not linger
        // as a permanent resurrection candidate (§4b). Runs after the layout
        // swap so the reconcile inside commitClose sees the new id, not a
        // hole. No undo entry: the user asked for a replacement, not a close.
        commitClose(terminalID, recordUndo: false)
        Task { [weak self] in await self?.drainPendingReleases() }
    }

    private func recreateSession(from closed: ClosedSession) async -> String? {
        let directory = URL(fileURLWithPath: closed.cwd)
        let agent = closed.agentID.flatMap { AgentRegistry.profile(id: $0) }
        await draftPersistenceTask?.value
        var draftSeed: TerminalDraftResumeSeed?
        if NativePreviewSettings.shared.restoreCLIDrafts,
           agent?.resumeCommand != nil,
           let sourceTerminalID = closed.sourceTerminalID {
            let sourceStableKey = Self.terminalDraftStableKey(sourceTerminalID)
            let restoredDraft: String? = try? await workspaceStateStore.draft(for: sourceStableKey)
            if let restoredDraft, !restoredDraft.isEmpty {
                draftSeed = TerminalDraftResumeSeed(
                    text: restoredDraft,
                    sourceStableKey: sourceStableKey
                )
            }
        }
        return await createOwnedSession(
            inDirectory: directory,
            agent: agent,
            lockedAccountBinding: closed.accountBinding,
            resumeAgent: agent?.resumeCommand != nil,
            titleOverride: closed.title,
            draftRestoreSeed: draftSeed
        )
    }

    var hasClosedSessions: Bool { !sessionStore.closedSessions().isEmpty }

    /// Refresh the session list from the broker without disturbing streams.
    /// The `list()` rows carry agent busy/completed fields, so this keeps every
    /// row's agent status current, not just the subscribed one.
    func refreshInventory() async {
        refreshPersistedNavigationState(publish: false)
        guard connectionState.isConnected else { return }
        do {
            let status = try await client.inventory()
            consecutiveInventoryFailures = 0
            // `@Published` fires on every assignment regardless of equality, and
            // this runs on a 2.5s timer for the life of the app — assigning
            // unconditionally rebuilt the entire shell every tick even when the
            // broker reported no change at all.
            // Tombstoned ids never re-enter the visible inventory: a poll
            // tick landing between commitClose and the broker release must
            // not flicker the closed terminal back into the tab strip.
            let visibleTerminals = status.terminals.filter {
                !sessionStore.isTerminalTombstoned($0.id)
            }
            if visibleTerminals != sessions {
                notifyInventoryCompletions(previous: sessions, next: visibleTerminals)
                sessions = visibleTerminals
                reconcileAllPaneLayoutsWithAvailableSurfaces()
                syncTrackedWorkingDirectories()
                stampEndedFromInventory(visibleTerminals)
            }
            await retryUnownedAttaches()
            let emptyDrains = await client.detachEmptyDrainingGenerations()
            if !emptyDrains.isEmpty {
                await controlClient.detachGenerations(emptyDrains)
                brokerRollbackCandidates.removeAll { emptyDrains.contains($0.id) }
            }
            var retirementDiagnostics: [BrokerRetirementDiagnostic] = []
            if let activeBrokerUpgradeMonitor {
                let monitorGeneration = connectionGeneration
                // A refused agent-turn signal leaves the broker reading a
                // working terminal as idle. Hold the cutover gate shut until
                // every active turn is protected, while still publishing the
                // current generation's bounded retirement diagnostics below.
                if unprotectedAgentTurnTerminalIDs.isEmpty {
                    let next = await activeBrokerUpgradeMonitor.attemptUpgradeIfNeeded()
                    guard monitorGeneration == connectionGeneration,
                          connectionState.isConnected else { return }
                    if next != brokerUpgradeState { brokerUpgradeState = next }
                    if case let .current(contentDigest) = next,
                       activeBrokerTopology?.current.id != contentDigest {
                        // The coordinator atomically changed the registry.
                        // Reopen both lanes against the new topology before
                        // allowing a create; retained IDs route to drains.
                        connectionLost(
                            BrokerClientError.identityChanged,
                            generation: connectionGeneration
                        )
                        return
                    }
                }
                retirementDiagnostics = await activeBrokerUpgradeMonitor
                    .retirementDiagnostics()
                guard monitorGeneration == connectionGeneration,
                      connectionState.isConnected else { return }
            }
            let topologyGeneration = connectionGeneration
            if let provider = activeBrokerTopologyProvider {
                let latest = await provider.generationTopology()
                guard topologyGeneration == connectionGeneration,
                      connectionState.isConnected else { return }
                guard let latest else {
                    connectionLost(
                        BrokerClientError.identityChanged,
                        generation: topologyGeneration
                    )
                    return
                }
                if latest != activeBrokerTopology {
                    connectionLost(
                        BrokerClientError.identityChanged,
                        generation: topologyGeneration
                    )
                    return
                }
            }
            if let activeBrokerTopology {
                let nextDetail = BrokerGenerationDiagnostics.detail(
                    appVersion: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "Dev",
                    topology: activeBrokerTopology,
                    retirementDiagnostics: retirementDiagnostics
                )
                if nextDetail != brokerGenerationDetail {
                    brokerGenerationDetail = nextDetail
                }
            }
        } catch {
            consecutiveInventoryFailures += 1
            if consecutiveInventoryFailures >= 3 {
                consecutiveInventoryFailures = 0
                connectionLost(error, generation: connectionGeneration)
                return
            }
        }
        refreshBranches()
        refreshMeta()
    }

    func rollbackBrokerGeneration(_ generationID: String) async {
        guard brokerRollbackCandidates.contains(where: { $0.id == generationID }),
              let controller = activeBrokerRollbackController else {
            ToastCenter.shared.show(
                BrokerRollbackError.targetUnavailable.localizedDescription,
                style: .error
            )
            return
        }
        do {
            let selected = try await controller.rollback(toGenerationID: generationID)
            ToastCenter.shared.show(
                "Using terminal continuity \(selected.version). Running terminals were preserved.",
                style: .success
            )
            brokerRollbackCandidates = []
            connectionLost(
                BrokerClientError.identityChanged,
                generation: connectionGeneration
            )
        } catch {
            ToastCenter.shared.show(
                (error as? BrokerRollbackError)?.localizedDescription
                    ?? "Terminal-continuity rollback could not be completed safely.",
                style: .error,
                duration: 6
            )
        }
    }

    /// Process-name + listening-port meta per owned native session, refreshed
    /// on a TTL so the inventory tick stays cheap.
    @Published private(set) var metaByTerminalID: [String: TerminalMeta] = [:]
    private var detectedAgentNamesByTerminalID: [String: String] = [:]
    private var lastMetaScan = Date.distantPast
    private var metaScanTask: Task<Void, Never>?

    func meta(for terminalID: String) -> TerminalMeta? { metaByTerminalID[terminalID] }

    private func refreshMeta() {
        guard metaScanTask == nil,
              Date().timeIntervalSince(lastMetaScan) > 5 else { return }
        lastMetaScan = Date()
        let owned: [(String, Int32)] = sessions.compactMap {
            guard ownedTerminalIDs.contains($0.id), !$0.exited, let pid = $0.pid else { return nil }
            return ($0.id, pid)
        }
        metaScanTask = Task.detached(priority: .utility) { [weak self] in
            let byPID = TerminalMetaService.collect(pids: owned.map { $0.1 })
            var out: [String: TerminalMeta] = [:]
            for (id, pid) in owned { out[id] = byPID[pid] ?? .empty }
            let collected = out
            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.metaScanTask = nil }
                // Guarded because this runs every 5s whether or not the process
                // table moved, and an unguarded assignment to a @Published
                // property republishes the whole model — invalidating every view
                // that observes it — to say nothing changed. The inventory tick
                // below already compares before assigning; this is the same rule.
                if self.metaByTerminalID != collected {
                    self.metaByTerminalID = collected
                }
                self.detectedAgentNamesByTerminalID = self.detectedAgentNamesByTerminalID.filter {
                    collected[$0.key] != nil
                }
                for (terminalID, meta) in collected {
                    if let name = SessionTitleTracker.agentDisplayName(forProcess: meta.processName) {
                        self.detectedAgentNamesByTerminalID[terminalID] = name
                    }
                    self.applyProcessAutoTitle(meta.processName, to: terminalID)
                }
            }
        }
    }

    /// Git branch per owned-session folder (session-row meta), refreshed on a
    /// TTL so the inventory tick doesn't spawn a git process per 2.5s.
    @Published private(set) var branchesByCwd: [String: String] = [:]
    private var lastBranchScan = Date.distantPast
    private var branchScanTask: Task<Void, Never>?

    func branch(for terminalID: String) -> String? {
        guard let cwd = persistedOwnedSessions.first(where: { $0.id == terminalID })?.cwd else { return nil }
        return branchesByCwd[cwd]
    }

    private func refreshBranches() {
        guard branchScanTask == nil,
              Date().timeIntervalSince(lastBranchScan) > 10 else { return }
        lastBranchScan = Date()
        let cwds = Set(persistedOwnedSessions.map(\.cwd))
        guard !cwds.isEmpty else { return }
        branchScanTask = Task.detached(priority: .utility) { [weak self] in
            var result: [String: String] = [:]
            for cwd in cwds {
                guard !Task.isCancelled else { break }
                if let branch = TerminalMetaService.gitBranch(
                    at: URL(fileURLWithPath: cwd, isDirectory: true)
                ) {
                    result[cwd] = branch
                }
            }
            let branches = result
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Same guard as the process-table scan: this fires every 10s and
                // a branch rarely changes between two of them, so an unguarded
                // write spends a full-model invalidation announcing that nothing
                // moved.
                if self.branchesByCwd != branches {
                    self.branchesByCwd = branches
                }
                self.branchScanTask = nil
            }
        }
    }

    /// A light periodic refresh so agent working/idle state stays current on
    /// every row while the app is connected. The subscribed session also gets
    /// immediate activity events; this covers the rest.
    private func startInventoryRefresh(generation: Int) {
        inventoryRefreshTask?.cancel()
        let sleeper = sleep
        inventoryRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleeper(2_500_000_000) } catch { return }
                guard let self, generation == self.connectionGeneration else { return }
                await self.refreshInventory()
            }
        }
    }

    /// After the observer connects, bring up the controller lane and re-own
    /// the terminals this app created in earlier runs. Registry entries from a
    /// different still-draining broker are retained; an authenticated broker
    /// owner capability can repair records lost during a profile switch.
    private func restoreOwnedSessions(
        topology: BrokerGenerationTopology,
        generation: Int
    ) async {
        invalidateAllTerminalInput(notifyIfDiscarded: true)
        controlAvailable = false
        ownedTerminalIDs = []
        terminalInputDegradedIDs = []
        terminalInputRecoveringIDs = []
        await controlClient.setDisconnectHandler { [weak self] error in
            Task { @MainActor in
                guard let self, self.controlAvailable else { return }
                self.invalidateAllTerminalInput(notifyIfDiscarded: true)
                self.controlAvailable = false
                self.ownedTerminalIDs = []
                self.terminalInputDegradedIDs.removeAll()
                self.terminalInputRecoveringIDs.removeAll()
                for task in self.terminalResizeTasks.values { task.cancel() }
                self.terminalResizeTasks.removeAll()
                // The observer socket may still be streaming, but a full
                // generation reconnect is the safest ownership reattach: it
                // re-probes identity, restores both lanes, and never touches
                // the detached broker's PTYs.
                self.connectionLost(error, generation: generation)
            }
        }
        do {
            try await controlClient.connect(to: topology, ownerID: sessionStore.ownerID())
        } catch {
            // Observation continues against brokers that refuse control.
            return
        }
        guard generation == connectionGeneration,
              connectionState.isConnected else {
            await controlClient.disconnect()
            connectionLost(BrokerClientError.identityChanged, generation: generation)
            return
        }
        if let provider = activeBrokerTopologyProvider {
            guard let latest = await provider.generationTopology(),
                  generation == connectionGeneration,
                  connectionState.isConnected,
                  latest == topology else {
                await controlClient.disconnect()
                connectionLost(BrokerClientError.identityChanged, generation: generation)
                return
            }
        }
        controlAvailable = true
        sessionStore.recoverOwnedSessions(from: sessions)
        refreshPersistedNavigationState(publish: false)
        var owned: Set<String> = []
        var dormant: Set<String> = []
        var attachRefusals = 0
        for stored in persistedOwnedSessions {
            guard let record = sessions.first(where: { $0.id == stored.id }) else {
                // This record may belong to the other broker in a dual-broker
                // drain. Absence from the current inventory is not deletion —
                // the pane goes dormant, survives layout normalization, and is
                // a resurrection candidate once the upgrade state is settled.
                dormant.insert(stored.id)
                continue
            }
            if record.exited {
                owned.insert(stored.id)
                continue
            }
            do {
                try await controlClient.attach(projectID: stored.projectID, terminalID: stored.id)
                owned.insert(stored.id)
            } catch {
                // Another controller holds it; leave it observed — but never
                // silently: a read-only terminal looks exactly like "typing
                // is broken" (2026-08-07 phantom-owner incident, where stale
                // ownership on a draining broker left every terminal mute
                // with no explanation).
                attachRefusals += 1
            }
        }
        ownedTerminalIDs = owned
        dormantTerminalIDs = dormant
        if attachRefusals > 0 {
            ToastCenter.shared.show(
                attachRefusals == 1
                    ? "1 terminal is read-only — another window or a stale connection holds its input. Reload to retry."
                    : "\(attachRefusals) terminals are read-only — another window or a stale connection holds their input. Reload to retry.",
                style: .error
            )
        }
        // Layout may have reported its real size while inventory was visible
        // but before ownership finished restoring. Those callbacks are retained
        // above; ownership publication is the level-triggered flush point.
        for terminalID in owned {
            scheduleDesiredTerminalResize(terminalID, force: true)
        }
        // Owed releases from closes that happened while disconnected drain
        // FIRST, so a resurrection sweep can never race a queued close.
        Task { [weak self] in
            await self?.drainPendingReleases()
            // Resurrection is scheduled HERE — not only from reload() — so a
            // broker that dies and reconnects mid-session also gets its lost
            // terminals back. Detached: never blocks restore or reconnect.
            await self?.resurrectDormantTerminals()
        }
    }

    /// The broker's tracked cwd (refreshed as shells `cd` around) flows back
    /// into the app's persisted records, so a resurrection after the NEXT
    /// reboot reopens where the shell actually was, not where it started.
    /// Inventory is the durable exit evidence (§4b): exit events only reach
    /// current observers, but every refresh lists exited rows, so a terminal
    /// that ended while the app was away is still remembered as ended — and
    /// never resurrected.
    private func stampEndedFromInventory(_ records: [BrokerTerminalRecord]) {
        var changed = false
        for record in records where record.exited {
            guard let stored = persistedOwnedSessions.first(where: { $0.id == record.id }),
                  stored.endedAt == nil else { continue }
            sessionStore.stampEnded(record.id, at: Int64(Date().timeIntervalSince1970 * 1_000))
            changed = true
        }
        if changed { refreshPersistedNavigationState(publish: false) }
    }

    private func syncTrackedWorkingDirectories() {
        var changed = false
        for record in sessions {
            guard let cwd = record.cwd, !cwd.isEmpty,
                  !sessionStore.isTerminalTombstoned(record.id),
                  let stored = persistedOwnedSessions.first(where: { $0.id == record.id }),
                  stored.cwd != cwd else { continue }
            var updated = NativeOwnedSession(
                id: stored.id,
                projectID: stored.projectID,
                cwd: cwd,
                title: stored.title,
                createdAt: stored.createdAt,
                agentID: stored.agentID,
                accountBinding: stored.accountBinding
            )
            updated.lastAutoTitle = stored.lastAutoTitle
            sessionStore.upsert(updated)
            changed = true
        }
        if changed { refreshPersistedNavigationState(publish: false) }
    }

    /// Respawns every dormant terminal at its recorded working directory,
    /// automatically for plain shells; a terminal that was running an agent
    /// CLI comes back as a shell plus a resume chip (never auto-run — usage
    /// cost and account binding are the user's call). Runs after the restored
    /// UI is up; failures leave the pane dormant for the next attempt.
    func resurrectDormantTerminals() async {
        guard controlAvailable, !dormantTerminalIDs.isEmpty else { return }
        // One sweep at a time: reload, reconnect, and launch can all schedule
        // this, and two overlapping sweeps could double-spawn the same id.
        guard !resurrectionSweepInFlight else { return }
        resurrectionSweepInFlight = true
        defer { resurrectionSweepInFlight = false }
        let records = persistedOwnedSessions.filter { dormantTerminalIDs.contains($0.id) }
        for stored in records {
            // An in-flight broker upgrade means a draining generation may
            // still own these PTYs; respawning now could fork them. Checked
            // per iteration — each spawn is a suspension point during which
            // an upgrade can start — and a pane loses nothing by staying
            // dormant until the next settled reconnect.
            switch brokerUpgradeState {
            case .unknown, .current: break
            default: return
            }
            guard controlAvailable, dormantTerminalIDs.contains(stored.id) else { continue }
            // Closed-stays-closed (§4b/§4c): never respawn a terminal the
            // user closed, one whose process ended, or one whose project is
            // closed.
            guard !sessionStore.isTerminalTombstoned(stored.id),
                  stored.endedAt == nil,
                  !sessionStore.isProjectClosed(stored.projectID) else {
                dormantTerminalIDs.remove(stored.id)
                continue
            }
            // Freshest inventory wins: a drain handoff may have surfaced the
            // terminal since restore marked it dormant.
            guard !sessions.contains(where: { $0.id == stored.id }) else {
                dormantTerminalIDs.remove(stored.id)
                continue
            }
            // A vanished directory keeps the pane dormant rather than
            // respawning under a different project identity.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: stored.cwd, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let created = await createOwnedSession(
                inDirectory: URL(fileURLWithPath: stored.cwd),
                agent: nil,
                titleOverride: stored.title,
                terminalIDOverride: stored.id,
                restore: true,
                select: false,
                environmentBinding: stored.agentID != nil ? stored.accountBinding : nil
            )
            // The spawn suspended; the user (or another window) may have
            // closed this id meanwhile. A create that landed for a tombstoned
            // id gets a compensating release immediately — the store already
            // refused the upsert, so the PTY would otherwise leak untracked.
            if sessionStore.isTerminalTombstoned(stored.id) {
                try? await controlClient.release(
                    projectID: stored.projectID, terminalID: stored.id
                )
                dormantTerminalIDs.remove(stored.id)
                continue
            }
            guard created == stored.id else { continue }
            dormantTerminalIDs.remove(stored.id)
            // A restore can resolve to a COLD record (the terminal had ended
            // before the reboot): the fresh store record carries endedAt, and
            // upserting the stale pre-await snapshot would erase that
            // evidence and offer a resume chip into a dead session.
            let fresh = sessionStore.sessions().first { $0.id == stored.id }
            if fresh?.endedAt != nil { continue }
            if let agentID = stored.agentID {
                // The plain-shell spawn overwrote the stored record; put the
                // agent identity and account binding back so the chip (and a
                // later resurrection) still know what this terminal was.
                sessionStore.upsert(stored)
                refreshPersistedNavigationState(publish: false)
                if ResumeChipEligibility.shouldShow(
                    agentID: agentID,
                    accountBindingResolves: stored.accountBinding == nil
                        || stored.accountBinding?.normalized != nil
                ) {
                    pendingAgentResume[stored.id] = agentID
                }
            }
        }
    }

    /// Chip action: boot the agent's resume command in the resurrected shell.
    func runPendingAgentResume(for terminalID: String) async {
        guard let agentID = pendingAgentResume.removeValue(forKey: terminalID),
              let command = AgentRegistry.all.first(where: { $0.id == agentID })?.resumeCommand,
              let stored = persistedOwnedSessions.first(where: { $0.id == terminalID }) else {
            pendingAgentResume.removeValue(forKey: terminalID)
            return
        }
        try? await controlClient.write(
            projectID: stored.projectID,
            terminalID: terminalID,
            data: command + "\n"
        )
    }

    /// Chip dismissal without resuming.
    func dismissPendingAgentResume(for terminalID: String) {
        pendingAgentResume.removeValue(forKey: terminalID)
    }

    /// Ownership self-heal: a session this install owns on record but could
    /// not attach (a stale owner on a draining broker, another window mid-
    /// handoff) is retried on the inventory cadence, throttled to every 10s.
    /// The moment the blocker releases — as in the 2026-08-07 incident —
    /// input comes back on its own instead of waiting for a manual reload.
    private func retryUnownedAttaches() async {
        guard controlAvailable else { return }
        let unowned = persistedOwnedSessions.filter { stored in
            !ownedTerminalIDs.contains(stored.id)
                && !dormantTerminalIDs.contains(stored.id)
                && stored.endedAt == nil
                && sessions.contains { $0.id == stored.id && !$0.exited }
        }
        guard !unowned.isEmpty else { return }
        if let last = lastAttachRetryAt, Date().timeIntervalSince(last) < 10 { return }
        lastAttachRetryAt = Date()
        var regained = 0
        for stored in unowned {
            do {
                try await controlClient.attach(projectID: stored.projectID, terminalID: stored.id)
                ownedTerminalIDs.insert(stored.id)
                scheduleDesiredTerminalResize(stored.id, force: true)
                regained += 1
            } catch {
                continue
            }
        }
        if regained > 0 {
            ToastCenter.shared.show(
                regained == 1
                    ? "Terminal input restored."
                    : "Input restored for \(regained) terminals.",
                style: .success
            )
        }
    }

    /// App-quit path: detach so owned shells keep running on the broker, then
    /// drop the controller connection.
    func releaseOwnedSessionsForQuit() async {
        // Seal and forget interactive intent before the first suspension. A
        // direct quit call must not leave a drain alive while owners detach.
        invalidateAllTerminalInput()
        guard controlAvailable else { return }
        for stored in persistedOwnedSessions where ownedTerminalIDs.contains(stored.id) {
            try? await controlClient.detachOwner(projectID: stored.projectID, terminalID: stored.id)
        }
        await controlClient.setDisconnectHandler(nil)
        await controlClient.disconnect()
        controlAvailable = false
    }

    func disconnect() async {
        flushPendingTerminalOutputs()
        shouldReconnect = false
        for task in terminalDraftRestoreTasks.values { task.cancel() }
        terminalDraftRestoreTasks.removeAll()
        pendingTerminalDraftRestores.removeAll()
        terminalLastOutputAt.removeAll()
        connectionGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        inventoryRefreshTask?.cancel()
        inventoryRefreshTask = nil
        consecutiveInventoryFailures = 0
        branchScanTask?.cancel()
        branchScanTask = nil
        for task in terminalResizeTasks.values { task.cancel() }
        terminalResizeTasks.removeAll()
        terminalResizeGeneration.removeAll()
        lastTerminalSize.removeAll()
        invalidateAllTerminalInput()
        terminalInputFailureNoticeAt.removeAll()
        terminalInputDegradedIDs.removeAll()
        terminalInputRecoveringIDs.removeAll()
        cursorSaveTask?.cancel()
        cursorSaveTask = nil
        await controlClient.setDisconnectHandler(nil)
        await persistCurrentCursor()
        await clearSplits()
        if usesVisualFixtureTransport {
            controlAvailable = false
            connectedBrokerFeatures = []
            connectionState = .unavailable("Visual fixture complete")
            return
        }
        await releaseOwnedSessionsForQuit()
        if let selectedSession, connectionState.isConnected {
            try? await client.unsubscribe(from: selectedSession, ownerID: observerOwnerID)
        }
        await client.disconnect()
        connectedBrokerFeatures = []
        activeBrokerTopology = nil
        activeBrokerTopologyProvider = nil
        activeBrokerUpgradeMonitor = nil
        activeBrokerRollbackController = nil
        brokerUpgradeState = .unknown
        brokerGenerationDetail = AppModel.brokerGenerationsUninspected
        brokerRollbackCandidates = []
    }

    private func resolvedGenerationTopology(
        for info: BrokerInfo,
        provider: (any BrokerGenerationTopologyProviding)?
    ) async throws -> BrokerGenerationTopology {
        guard let provider else { return .single(info) }
        guard let topology = await provider.generationTopology() else {
            throw BrokerClientError.identityChanged
        }
        return topology
    }

    private func connect(generation: Int, reconnectAttempt: Int?) async -> Bool {
        guard generation == connectionGeneration, shouldReconnect else { return false }
        // Retrying from a settled offline state stays silent: flipping to
        // "Reconnecting" every backoff cycle strobes the UI forever against a
        // broker that will keep refusing (for example one that predates
        // terminal observation). The state only moves when the outcome does.
        let silentRetry: Bool
        if case .unavailable = connectionState, reconnectAttempt != nil {
            silentRetry = true
        } else {
            silentRetry = false
        }
        if !silentRetry {
            connectionState = reconnectAttempt.map { .reconnecting(attempt: $0 + 1) } ?? .connecting
        }

        do {
            // The disconnect handler stays DISARMED until a connection is fully
            // established: an aborted probe handshake (e.g. Electron's broker
            // failing the feature check) must never fire connectionLost against
            // the connection the fallback goes on to establish.
            await client.setDisconnectHandler(nil)
            await client.setEventHandler { [weak self] event in
                Task { @MainActor in self?.consume(event) }
            }
            var info: BrokerInfo
            var topology: BrokerGenerationTopology
            var hello: BrokerHello
            do {
                activeBrokerUpgradeMonitor = brokerPreparer as? any BrokerUpgradeMonitoring
                activeBrokerTopologyProvider = brokerPreparer as? any BrokerGenerationTopologyProviding
                activeBrokerRollbackController = brokerPreparer as? any BrokerGenerationRollbackServing
                info = try await brokerPreparer.prepare()
                topology = try await resolvedGenerationTopology(
                    for: info,
                    provider: activeBrokerTopologyProvider
                )
                activeBrokerIdentity = info.persistenceIdentity
                activeBrokerTopology = topology
                hello = try await client.connect(to: topology)
                usingSeparateBroker = false
            } catch BrokerClientError.observeFeatureMissing where fallbackPreparer != nil {
                // Electron's broker is alive but predates the features this app
                // needs. Leave it (and every session on it) untouched and run
                // the app's OWN broker under its separate profile instead.
                guard let fallbackPreparer else { throw BrokerClientError.observeFeatureMissing }
                // The failed hello leaves the client attached to the old
                // socket; reset it before dialing the separate broker.
                await client.disconnect()
                activeBrokerUpgradeMonitor = fallbackPreparer as? any BrokerUpgradeMonitoring
                activeBrokerTopologyProvider = fallbackPreparer as? any BrokerGenerationTopologyProviding
                activeBrokerRollbackController = fallbackPreparer as? any BrokerGenerationRollbackServing
                info = try await fallbackPreparer.prepare()
                topology = try await resolvedGenerationTopology(
                    for: info,
                    provider: activeBrokerTopologyProvider
                )
                activeBrokerIdentity = info.persistenceIdentity
                activeBrokerTopology = topology
                hello = try await client.connect(to: topology)
                usingSeparateBroker = true
            }
            let status = try await client.inventory()
            guard generation == connectionGeneration, shouldReconnect else { return false }
            await client.setDisconnectHandler { [weak self] error in
                Task { @MainActor in self?.connectionLost(error, generation: generation) }
            }

            let visibleTerminals = status.terminals.filter {
                !sessionStore.isTerminalTombstoned($0.id)
            }
            notifyInventoryCompletions(previous: sessions, next: visibleTerminals)
            sessions = visibleTerminals
            connectedBrokerFeatures = hello.features
            let connectedUpgradeState = await activeBrokerUpgradeMonitor?.upgradeState() ?? .unknown
            guard generation == connectionGeneration, shouldReconnect else { return false }
            let retirementDiagnostics = await activeBrokerUpgradeMonitor?
                .retirementDiagnostics() ?? []
            guard generation == connectionGeneration, shouldReconnect else { return false }
            brokerUpgradeState = connectedUpgradeState
            brokerGenerationDetail = BrokerGenerationDiagnostics.detail(
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "Dev",
                topology: topology,
                retirementDiagnostics: retirementDiagnostics
            )
            brokerRollbackCandidates = await activeBrokerRollbackController?
                .rollbackCandidates() ?? []
            await client.preserveDrainingGenerations(Set(
                brokerRollbackCandidates.lazy
                    .filter(\.retainedForExplicitSelection)
                    .map(\.id)
            ))
            if restoredWorkspaceState {
                // A reconnect inventory is authoritative before any old split
                // subscription is restored. Prune finished ids in the same
                // main-actor turn so the UI never flashes a dead placeholder.
                reconcileAllPaneLayoutsWithAvailableSurfaces()
            }
            // The topology can be revoked while the observer hello, inventory,
            // diagnostics, and rollback probes suspend. Re-prove the exact
            // route immediately before publishing a connected state or
            // restoring the controller lane. A provider that withholds
            // authority must never leave a successfully dialed but stale route
            // eligible for terminal.create.
            let postDialTopology = try await resolvedGenerationTopology(
                for: info,
                provider: activeBrokerTopologyProvider
            )
            guard generation == connectionGeneration,
                  shouldReconnect,
                  postDialTopology == topology else {
                throw BrokerClientError.identityChanged
            }
            connectionState = .connected(
                version: hello.version + (usingSeparateBroker ? " · Kaisola-only continuity" : ""),
                pid: hello.pid,
                serverEnforcedObserver: hello.serverEnforcedObserver
            )
            await restoreOwnedSessions(topology: topology, generation: generation)
            let emptyDrains = await client.detachEmptyDrainingGenerations()
            if !emptyDrains.isEmpty {
                await controlClient.detachGenerations(emptyDrains)
                brokerRollbackCandidates.removeAll { emptyDrains.contains($0.id) }
            }
            startInventoryRefresh(generation: generation)
            // Prefer the in-memory selection, then the persisted one from the
            // last run (whole-app persistence), then the first session.
            let preferredID = selectedSessionID.flatMap { selected in
                sessions.contains(where: { $0.id == selected }) ? selected : nil
            } ?? sessionStore.lastSelectedSessionID().flatMap { stored in
                sessions.contains(where: { $0.id == stored }) ? stored : nil
            } ?? sessions.first?.id
            recoverInventoryCompletionAttention(
                from: status.terminals,
                selectedSessionID: preferredID
            )
            selectedSession = nil
            if let preferredID {
                selectedSessionID = preferredID
                await select(preferredID)
            } else {
                selectedSessionID = nil
                terminalDocument = .empty
            }
            // Initial launch restores its disk layout after connect(). Every
            // later successful reconnect already has that layout in memory and
            // must re-establish all visible secondaries, not only the primary.
            if restoredWorkspaceState {
                await restoreVisibleSecondarySubscriptions(
                    expectedConnectionGeneration: generation
                )
            }
            return true
        } catch {
            guard generation == connectionGeneration, shouldReconnect else { return false }
            connectedBrokerFeatures = []
            activeBrokerTopology = nil
            activeBrokerTopologyProvider = nil
            activeBrokerRollbackController = nil
            brokerRollbackCandidates = []
            let description = error.kaisolaSafeDescription
            if case let .unavailable(existing) = connectionState, existing == description {
                // identical settled state — no churn for observers
            } else {
                connectionState = .unavailable(description)
            }
            return false
        }
    }

    private func scheduleReconnect(attempt: Int, generation: Int, immediate: Bool = false) {
        guard generation == connectionGeneration,
              shouldReconnect,
              reconnectTask == nil else { return }
        let delay = immediate ? 0 : reconnectBackoff.delayNanoseconds(
            forAttempt: attempt,
            jitterUnit: jitter()
        )
        let sleeper = sleep
        reconnectTask = Task { [weak self] in
            do {
                if delay > 0 { try await sleeper(delay) }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runReconnectAttempt(attempt, generation: generation)
        }
    }

    private func runReconnectAttempt(_ attempt: Int, generation: Int) async {
        reconnectTask = nil
        guard generation == connectionGeneration, shouldReconnect else { return }
        await client.disconnect()
        selectedSession = nil
        if !(await connect(generation: generation, reconnectAttempt: attempt)) {
            scheduleReconnect(attempt: attempt + 1, generation: generation)
        }
    }

    /// Observer frames carry the broker's routing identity, and only a frame
    /// that matches this observer *and* the project the terminal is actually
    /// filed under may act on local state. Project identity comes from the
    /// authoritative inventory, plus the selected row so a frame that lands
    /// between a local create and the next poll is still accepted. A frame for
    /// a terminal this app does not know has no legitimate local target.
    private func isAuthenticObserverEvent(_ event: BrokerEvent) -> Bool {
        guard event.ownerID == observerOwnerID else { return false }
        guard let knownProjectID = sessions.first(where: { $0.id == event.terminalID })?.projectID
            ?? (selectedSession?.id == event.terminalID ? selectedSession?.projectID : nil)
        else { return false }
        return knownProjectID == event.projectID
    }

    private func consume(_ event: BrokerEvent) {
        // Authenticate before anything else: activity used to be applied ahead
        // of the owner check, so a misrouted or forged frame could move another
        // owner's busy/completed state and its needs-you badge. Owner and
        // project identity are now settled before the first side effect.
        guard isAuthenticObserverEvent(event) else { return }

        // Agent activity updates the session's row even if it is the selected
        // one; it is scoped to the subscribed terminal like every other event.
        if case let .activity(busy, completedAt) = event.kind {
            applyActivity(busy: busy, completedAt: completedAt, to: event.terminalID)
        }

        if case let .output(epoch, startOffset, endOffset, data) = event.kind {
            if pendingTerminalDraftRestores[event.terminalID] != nil {
                terminalLastOutputAt[event.terminalID] = Date()
            }
            enqueueTerminalOutput(
                projectID: event.projectID,
                terminalID: event.terminalID,
                epoch: epoch,
                startOffset: startOffset,
                endOffset: endOffset,
                data: data
            )
            return
        }

        // Exit and gap events are ordered after all prior output on the broker
        // socket. Drain this terminal first so cursor persistence and recovery
        // observe the same order.
        flushPendingTerminalOutput(for: event.terminalID)

        // Split panes get the same event handling as the primary document.
        if splitDocuments[event.terminalID] != nil, event.terminalID != selectedSession?.id {
            switch event.kind {
            case .output:
                break
            case .snapshotRequired:
                Task { await resubscribeSplit(event.terminalID) }
            case .exit:
                splitDocuments[event.terminalID]?.exited = true
                if let document = splitDocuments[event.terminalID] {
                    publishTerminalSurfaceDocument(document)
                }
            case .activity:
                break
            }
            return
        }

        guard event.projectID == selectedSession?.projectID,
              event.terminalID == selectedSession?.id else { return }

        switch event.kind {
        case .output:
            break
        case .snapshotRequired:
            Task { await select(selectedSessionID) }
        case .exit:
            terminalDocument.exited = true
            publishTerminalSurfaceDocument(terminalDocument)
            queueCursorPersistence()
            // A dead shell has nothing to resume into; without this, a
            // resurrected shell that exits immediately renders the resume
            // chip and the "Session ended" banner stacked on each other.
            pendingAgentResume.removeValue(forKey: event.terminalID)
            // Exit evidence (§4b): an ended terminal is never resurrected.
            sessionStore.stampEnded(
                event.terminalID,
                at: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            refreshPersistedNavigationState(publish: false)
        case .activity:
            break
        }
    }

    private func enqueueTerminalOutput(
        projectID: String,
        terminalID: String,
        epoch: String,
        startOffset: Int64,
        endOffset: Int64,
        data: String
    ) {
        guard splitDocuments[terminalID] != nil || terminalID == selectedSession?.id else { return }
        guard let next = TerminalOutputBatch(
            projectID: projectID,
            terminalID: terminalID,
            epoch: epoch,
            startOffset: startOffset,
            endOffset: endOffset,
            data: data
        ) else {
            recoverTerminalOutputGap(terminalID)
            return
        }

        if var pending = pendingTerminalOutput[terminalID] {
            if pending.projectID == projectID,
               pending.append(epoch: epoch, startOffset: startOffset, endOffset: endOffset, data: data) {
                pendingTerminalOutput[terminalID] = pending
                return
            }
            // A discontinuity cannot overtake an already valid prefix. Apply
            // the prefix now, then let the ordinary document cursor decide
            // whether this packet is contiguous or needs a fresh snapshot.
            flushPendingTerminalOutput(for: terminalID)
        }

        pendingTerminalOutput[terminalID] = next
        if !pendingTerminalOutputOrder.contains(terminalID) {
            pendingTerminalOutputOrder.append(terminalID)
        }
        scheduleTerminalOutputFlush()
    }

    /// One coalescer in the path, not two.
    ///
    /// This window was written when the broker broadcast observer output once
    /// per pty chunk, so batching here was the only thing standing between an
    /// agent redraw and a hundred main-thread passes a second. A broker that
    /// batches on its own frame window has already done that merging, and a
    /// second window stacked on top spends up to another frame of latency
    /// merging what now usually arrives as a single batch.
    ///
    /// Against a broker without the capability the window stays exactly as it
    /// was, because there it is still the only coalescer in the path. The merge
    /// and gap-recovery logic in `drainPendingTerminalOutputs` runs either way;
    /// only the wait is conditional.
    private func scheduleTerminalOutputFlush() {
        guard terminalOutputFlushTask == nil else { return }
        if connectedBrokerFeatures.contains(BrokerWire.terminalObserverCoalescingFeature) {
            drainPendingTerminalOutputs()
            return
        }
        terminalOutputFlushGeneration &+= 1
        let generation = terminalOutputFlushGeneration
        terminalOutputFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.terminalOutputFrameNanoseconds)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  generation == self.terminalOutputFlushGeneration else { return }
            self.terminalOutputFlushTask = nil
            self.drainPendingTerminalOutputs()
        }
    }

    private func flushPendingTerminalOutputs() {
        terminalOutputFlushGeneration &+= 1
        terminalOutputFlushTask?.cancel()
        terminalOutputFlushTask = nil
        drainPendingTerminalOutputs()
    }

    private func drainPendingTerminalOutputs() {
        let batches = pendingTerminalOutput
        let order = pendingTerminalOutputOrder
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        pendingTerminalOutputOrder.removeAll(keepingCapacity: true)
        for terminalID in order {
            if let batch = batches[terminalID] { applyTerminalOutput(batch) }
        }
    }

    private func flushPendingTerminalOutput(for terminalID: String) {
        guard let batch = pendingTerminalOutput.removeValue(forKey: terminalID) else { return }
        pendingTerminalOutputOrder.removeAll { $0 == terminalID }
        applyTerminalOutput(batch)
    }

    private func applyTerminalOutput(_ batch: TerminalOutputBatch) {
        if splitDocuments[batch.terminalID] != nil,
           batch.terminalID != selectedSession?.id {
            if splitDocuments[batch.terminalID]?.append(
                epoch: batch.epoch,
                startOffset: batch.startOffset,
                endOffset: batch.endOffset,
                data: batch.data
            ) != true {
                recoverTerminalOutputGap(batch.terminalID)
            } else if let document = splitDocuments[batch.terminalID] {
                publishTerminalSurfaceDocument(document)
            }
            return
        }

        guard batch.projectID == selectedSession?.projectID,
              batch.terminalID == selectedSession?.id else { return }
        guard terminalDocument.append(
            epoch: batch.epoch,
            startOffset: batch.startOffset,
            endOffset: batch.endOffset,
            data: batch.data
        ) else {
            recoverTerminalOutputGap(batch.terminalID)
            return
        }
        publishTerminalSurfaceDocument(terminalDocument)
        queueCursorPersistence()
    }

    private func recoverTerminalOutputGap(_ terminalID: String) {
        if splitDocuments[terminalID] != nil, terminalID != selectedSession?.id {
            Task { await resubscribeSplit(terminalID) }
        } else if terminalID == selectedSession?.id {
            Task { await select(selectedSessionID) }
        }
    }

    // MARK: - Split panes (multiple sessions open at once)

    /// Additional open sessions, each with its own live subscription and
    /// document, rendered beside the primary pane. Order = pane order.
    /// Like the primary document, live split bytes publish through per-card
    /// feeds. `splitOrder` remains the structural publisher for card topology.
    private(set) var splitDocuments: [String: TerminalDocument] = [:]
    @Published private(set) var splitOrder: [String] = []
    static let maxSplitPanes = 3

    /// Open a session in a split pane beside the primary one.
    func openInSplit(_ terminalID: String) async {
        await openSurfaceBeside(terminalID)
    }

    private func subscribeSplit(_ terminalID: String) async {
        guard connectionState.isConnected,
              splitDocuments[terminalID] == nil,
              pendingSplitSubscriptions[terminalID] == nil,
              terminalID != selectedSessionID,
              splitOrder.count < SessionPaneLayout.maximumPaneCount - 1,
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        let connection = connectionGeneration
        let intent = splitIntentTokens[terminalID] ?? UUID()
        splitIntentTokens[terminalID] = intent
        let token = UUID()
        pendingSplitSubscriptions[terminalID] = token
        do {
            let result = try await client.subscribe(to: record, ownerID: observerOwnerID, cursor: nil)
            guard pendingSplitSubscriptions[terminalID] == token else {
                await cleanUpStaleSplitSubscription(
                    terminalID,
                    record: record,
                    subscriptionConnectionGeneration: connection
                )
                return
            }
            pendingSplitSubscriptions[terminalID] = nil
            guard connection == connectionGeneration,
                  splitIntentTokens[terminalID] == intent,
                  connectionState.isConnected,
                  selectedSessionID != terminalID,
                  isSurfaceVisible(terminalID),
                  sessions.contains(where: { $0.id == terminalID && !$0.exited }) else {
                await cleanUpStaleSplitSubscription(
                    terminalID,
                    record: record,
                    subscriptionConnectionGeneration: connection
                )
                return
            }
            splitDocuments[terminalID] = TerminalDocument.empty.applying(result, sessionID: terminalID)
            retainTerminalSurfaceDocument(splitDocuments[terminalID]!)
            if !splitOrder.contains(terminalID) { splitOrder.append(terminalID) }
        } catch {
            guard pendingSplitSubscriptions[terminalID] == token else { return }
            pendingSplitSubscriptions[terminalID] = nil
            guard connection == connectionGeneration,
                  splitIntentTokens[terminalID] == intent,
                  selectedSessionID != terminalID,
                  isSurfaceVisible(terminalID) else { return }
            // Preserve a last-good frame when one exists. A first-time failure
            // gets an explicit card-local error instead of an infinite spinner;
            // the next broker reconnect retries the visible intent.
            if let retained = terminalSurfaceDocuments[terminalID] {
                splitDocuments[terminalID] = retained
                if !splitOrder.contains(terminalID) { splitOrder.append(terminalID) }
            } else {
                let failure = TerminalDocument.failure(
                    sessionID: terminalID,
                    message: error.kaisolaSafeDescription
                )
                splitDocuments[terminalID] = failure
                retainTerminalSurfaceDocument(failure)
                if !splitOrder.contains(terminalID) { splitOrder.append(terminalID) }
            }
        }
    }

    /// Recreate every visible terminal subscription in layout order. This is
    /// deliberately scoped to the active project/window: hidden project layouts
    /// remain durable metadata but do not consume broker observers or renderers.
    private func restoreVisibleSecondarySubscriptions(
        expectedConnectionGeneration: Int
    ) async {
        guard expectedConnectionGeneration == connectionGeneration,
              connectionState.isConnected,
              let selectedProjectID,
              let layout = paneLayouts[selectedProjectID] else { return }
        var seen = Set<String>()
        let terminalIDs = layout.sessionIDs.filter { id in
            guard seen.insert(id).inserted,
                  id != selectedSessionID,
                  sessions.contains(where: { $0.id == id && !$0.exited }) else { return false }
            return true
        }
        for terminalID in terminalIDs {
            guard expectedConnectionGeneration == connectionGeneration,
                  connectionState.isConnected else { return }
            await subscribeSplit(terminalID)
        }
    }

    /// A late successful subscribe can belong to a card the user already hid.
    /// Unsubscribe only when it is unquestionably still the same live socket
    /// and there is no primary/new-secondary intent; otherwise touching the
    /// owner-scoped subscription could tear down the valid replacement.
    private func cleanUpStaleSplitSubscription(
        _ terminalID: String,
        record: BrokerTerminalRecord,
        subscriptionConnectionGeneration: Int
    ) async {
        let cleanupIntent = splitIntentTokens[terminalID]
        guard subscriptionConnectionGeneration == connectionGeneration,
              connectionState.isConnected,
              selectedSessionID != terminalID,
              pendingSplitSubscriptions[terminalID] == nil,
              !isSurfaceVisible(terminalID) else { return }
        try? await client.unsubscribe(from: record, ownerID: observerOwnerID)
        guard subscriptionConnectionGeneration == connectionGeneration else { return }
        if splitIntentTokens[terminalID] != cleanupIntent {
            // A newer primary/secondary role raced the owner-scoped
            // unsubscribe. It may have successfully subscribed while this
            // stale cleanup was suspended, so establish the winning role again
            // only after the destructive unsubscribe has completed.
            pendingSplitSubscriptions[terminalID] = nil
            splitDocuments[terminalID] = nil
            splitOrder.removeAll { $0 == terminalID }
            if selectedSessionID == terminalID {
                splitIntentTokens[terminalID] = UUID()
                await select(terminalID)
            } else if isSurfaceVisible(terminalID) {
                await subscribeSplit(terminalID)
            }
        }
    }

    /// Close a split pane; its session keeps running on the broker.
    func closeSplit(_ terminalID: String) async {
        // The card action is a minimize: publish the hidden intent before any
        // cursor/broker await so a concurrent reopen cannot be removed by the
        // stale completion.
        await minimizeSurface(terminalID)
    }

    private func unsubscribeSplit(_ terminalID: String) async {
        let intent = splitIntentTokens[terminalID] ?? UUID()
        splitIntentTokens[terminalID] = intent
        let connection = connectionGeneration
        // Invalidate a blocked in-flight result even when no document has
        // arrived yet. The late-result fence performs the safe cleanup.
        pendingSplitSubscriptions[terminalID] = nil
        guard splitDocuments[terminalID] != nil else {
            splitOrder.removeAll { $0 == terminalID }
            return
        }
        await persistSplitCursor(terminalID)
        guard splitIntentTokens[terminalID] == intent,
              connection == connectionGeneration else { return }
        if connectionState.isConnected,
           let record = sessions.first(where: { $0.id == terminalID }) {
            try? await client.unsubscribe(from: record, ownerID: observerOwnerID)
        }
        guard connection == connectionGeneration else { return }
        if splitIntentTokens[terminalID] != intent {
            // A reopen landed while the broker unsubscribe was suspended. The
            // old owner observer is now gone; replace it in-order rather than
            // letting the stale completion blank the newly visible card.
            splitDocuments[terminalID] = nil
            splitOrder.removeAll { $0 == terminalID }
            if selectedSessionID != terminalID, isSurfaceVisible(terminalID) {
                await subscribeSplit(terminalID)
            }
            return
        }
        splitDocuments[terminalID] = nil
        splitOrder.removeAll { $0 == terminalID }
    }

    /// Promote a split to the primary pane (tab click): the split subscription
    /// closes with its cursor persisted, then the normal select path resumes
    /// from that cursor — continuous scrollback, one subscription per terminal.
    func promoteSplit(_ terminalID: String) async {
        guard splitDocuments[terminalID] != nil else { return }
        await focusTerminalSurface(terminalID)
    }

    /// Drop every split (connection loss / reload), persisting cursors.
    private func clearSplits(expectedConnectionGeneration: Int? = nil) async {
        if let expectedConnectionGeneration,
           expectedConnectionGeneration != connectionGeneration { return }
        let documents = splitDocuments.values
        for document in documents { retainTerminalSurfaceDocument(document) }
        pendingSplitSubscriptions.removeAll()
        for id in splitOrder { await persistSplitCursor(id) }
        if let expectedConnectionGeneration,
           expectedConnectionGeneration != connectionGeneration { return }
        splitDocuments.removeAll()
        splitOrder.removeAll()
    }

    private func resubscribeSplit(_ terminalID: String) async {
        guard splitDocuments[terminalID] != nil,
              pendingSplitSubscriptions[terminalID] == nil,
              selectedSessionID != terminalID,
              isSurfaceVisible(terminalID),
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        let connection = connectionGeneration
        let intent = splitIntentTokens[terminalID] ?? UUID()
        splitIntentTokens[terminalID] = intent
        let token = UUID()
        pendingSplitSubscriptions[terminalID] = token
        do {
            let result = try await client.subscribe(to: record, ownerID: observerOwnerID, cursor: nil)
            guard pendingSplitSubscriptions[terminalID] == token else {
                await cleanUpStaleSplitSubscription(
                    terminalID,
                    record: record,
                    subscriptionConnectionGeneration: connection
                )
                return
            }
            pendingSplitSubscriptions[terminalID] = nil
            guard connection == connectionGeneration,
                  splitIntentTokens[terminalID] == intent,
                  connectionState.isConnected,
                  selectedSessionID != terminalID,
                  isSurfaceVisible(terminalID) else {
                await cleanUpStaleSplitSubscription(
                    terminalID,
                    record: record,
                    subscriptionConnectionGeneration: connection
                )
                return
            }
            splitDocuments[terminalID] = TerminalDocument.empty.applying(result, sessionID: terminalID)
            retainTerminalSurfaceDocument(splitDocuments[terminalID]!)
        } catch {
            guard pendingSplitSubscriptions[terminalID] == token else { return }
            pendingSplitSubscriptions[terminalID] = nil
        }
    }

    private func persistSplitCursor(_ terminalID: String) async {
        guard let document = splitDocuments[terminalID],
              let record = sessions.first(where: { $0.id == terminalID }),
              let scope = cursorScope(for: record),
              let cursor = document.cursor else { return }
        try? await cursorStore.save(cursor, for: scope)
    }

    private func applyActivity(busy: Bool, completedAt: Int64?, to terminalID: String) {
        // The broker is authoritative for when a turn ends, so its idle edge
        // retires the local acknowledgement the app opened the turn with.
        if !busy { acknowledgedAgentTurnTerminalIDs.remove(terminalID) }
        guard let index = sessions.firstIndex(where: { $0.id == terminalID }) else { return }
        let wasWorking = { if case .working = sessions[index].agentActivity { return true }; return false }()
        let activity: AgentActivity = if busy {
            .working
        } else if let completedAt {
            .responded(at: completedAt)
        } else {
            .idle
        }
        if case let .responded(at: completedAt) = activity, wasWorking {
            // A completed terminal remains a needs-you moment until visited,
            // even if it finished in the currently visible project. Keyed on the
            // working edge, not on the assignment, so the guard below cannot
            // swallow it.
            let detectedCLI = detectedAgentNamesByTerminalID[terminalID]
            attentionCenter.notifySessionResponded(
                targetID: terminalID,
                title: sessionTitle(for: sessions[index]),
                detail: detectedCLI.map { "\($0) finished" } ?? "Agent responded",
                completedAt: completedAt
            )
        }
        // Writing one element of a @Published array republishes the array, and
        // this runs on the live broker activity stream, where a busy agent flaps
        // between the same two states repeatedly. Every one of those wrote a
        // full-model invalidation to announce the value it already held.
        guard sessions[index].agentActivity != activity else { return }
        sessions[index].agentActivity = activity
    }

    /// Inventory and observer events share one broker socket but can be
    /// delivered in either order. If the periodic inventory wins the race, it
    /// must raise the same durable needs-you entry as the activity event; the
    /// later event then sees `.responded` and cannot duplicate it.
    private func notifyInventoryCompletions(
        previous: [BrokerTerminalRecord],
        next: [BrokerTerminalRecord]
    ) {
        for record in Self.inventoryCompletionTransitions(previous: previous, next: next) {
            let detectedCLI = detectedAgentNamesByTerminalID[record.id]
            guard case let .responded(completedAt) = record.agentActivity else { continue }
            attentionCenter.notifySessionResponded(
                targetID: record.id,
                title: sessionTitle(for: record),
                detail: detectedCLI.map { "\($0) finished" } ?? "Agent responded",
                completedAt: completedAt
            )
        }
    }

    /// A replaced/relaunched app can connect after the broker has already
    /// recorded the final response, so there is no in-process working -> done
    /// edge to observe. Recover every unacknowledged completion once at the
    /// connection boundary. The automatically restored primary is already
    /// visible and therefore counts as visited; all other project rows retain
    /// their durable orange badge until selected.
    private func recoverInventoryCompletionAttention(
        from records: [BrokerTerminalRecord],
        selectedSessionID: String?
    ) {
        for record in records {
            guard case let .responded(completedAt) = record.agentActivity else { continue }
            if record.id == selectedSessionID {
                attentionCenter.acknowledgeSessionResponse(
                    targetID: record.id,
                    completedAt: completedAt
                )
                continue
            }
            let detectedCLI = detectedAgentNamesByTerminalID[record.id]
            attentionCenter.notifySessionResponded(
                targetID: record.id,
                title: sessionTitle(for: record),
                detail: detectedCLI.map { "\($0) finished" } ?? "Agent responded",
                completedAt: completedAt
            )
        }
    }

    static func inventoryCompletionTransitions(
        previous: [BrokerTerminalRecord],
        next: [BrokerTerminalRecord]
    ) -> [BrokerTerminalRecord] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return next.filter { record in
            guard case .responded = record.agentActivity,
                  let old = previousByID[record.id],
                  case .working = old.agentActivity else { return false }
            return true
        }
    }

    private func connectionLost(_ error: any Error, generation: Int) {
        guard generation == connectionGeneration, shouldReconnect else { return }
        flushPendingTerminalOutputs()
        connectedBrokerFeatures = []
        brokerRollbackCandidates = []
        activeBrokerRollbackController = nil
        connectionState = .unavailable(error.kaisolaSafeDescription)
        Task { [weak self] in
            guard let self else { return }
            // Subscriptions died with the socket. Finish retaining/persisting
            // them before reconnect starts, otherwise the old cleanup task can
            // erase the newly restored secondary documents.
            await self.clearSplits(expectedConnectionGeneration: generation)
            guard generation == self.connectionGeneration, self.shouldReconnect else { return }
            self.scheduleReconnect(attempt: 0, generation: generation)
        }
    }

    private func cursorScope(for session: BrokerTerminalRecord) -> TerminalCursorScope? {
        guard let brokerIdentity = session.brokerPersistenceIdentity ?? activeBrokerIdentity else {
            return nil
        }
        return TerminalCursorScope(
            brokerIdentity: brokerIdentity,
            projectID: session.projectID,
            terminalID: session.id
        )
    }

    private func persistCurrentCursor() async {
        cursorSaveTask?.cancel()
        cursorSaveTask = nil
        await persist(terminalDocument, for: selectedSession)
    }

    private func persist(_ document: TerminalDocument, for session: BrokerTerminalRecord?) async {
        guard let session,
              let scope = cursorScope(for: session),
              document.sessionID == session.id,
              let cursor = document.cursor else { return }
        try? await cursorStore.save(cursor, for: scope)
    }

    private func queueCursorPersistence() {
        guard let session = selectedSession,
              let scope = cursorScope(for: session),
              terminalDocument.sessionID == session.id,
              let cursor = terminalDocument.cursor else { return }
        cursorSaveTask?.cancel()
        let store = cursorStore
        cursorSaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            try? await store.save(cursor, for: scope)
        }
    }
}

/// Deterministic ASCII scrollback for broker-free physical-footprint probes.
/// The environment-gated visual fixture is the only caller; production broker
/// output never passes through this generator.
enum VisualTerminalResourceFixture {
    private static let line = String(repeating: "0123456789abcdef", count: 63) + "\r\n"

    static func output(targetBytes: Int) -> String {
        scrollback(targetBytes: targetBytes).output
    }

    static func scrollback(targetBytes: Int) -> TerminalScrollback {
        guard targetBytes > 0 else { return TerminalScrollback() }
        var result = TerminalScrollback()
        var remaining = targetBytes
        while remaining > 0 {
            let chunkBytes = min(remaining, TerminalScrollback.targetPageBytes)
            let lineBytes = line.utf8.count
            let lineCount = (chunkBytes + lineBytes - 1) / lineBytes
            var chunk = String(repeating: line, count: lineCount)
            let overflow = chunk.utf8.count - chunkBytes
            if overflow > 0 {
                let utf8 = chunk.utf8
                let byteEnd = utf8.index(utf8.startIndex, offsetBy: chunkBytes)
                if let stringEnd = byteEnd.samePosition(in: chunk) {
                    chunk.removeSubrange(stringEnd..<chunk.endIndex)
                }
            }
            result.append(chunk)
            remaining -= chunkBytes
        }
        return result
    }
}

/// Exact-size retained transcript for the broker-free ownership-flap gate. The
/// OSC 8 tail makes link/parser state part of the same mounted-view receipt.
enum VisualTerminalOwnershipFlapFixture {
    static let linkText = "FLAP-LINK"
    static let linkURL = "https://flap.test/state"
    private static let tail = "\r\n\u{1B}]8;;\(linkURL)\u{7}\(linkText)\u{1B}]8;;\u{7}\r\nready"

    static func scrollback(targetBytes: Int) -> TerminalScrollback {
        guard targetBytes >= tail.utf8.count else {
            return VisualTerminalResourceFixture.scrollback(targetBytes: targetBytes)
        }
        var result = VisualTerminalResourceFixture.scrollback(
            targetBytes: targetBytes - tail.utf8.count
        )
        result.append(tail)
        return result
    }
}

/// Deterministic retained history for the successful transcript visual and
/// accessibility fixture. It includes terminal control sequences so the sheet
/// proves it renders sanitized plain text rather than replaying terminal state.
enum VisualTerminalTranscriptFixture {
    static let output = [
        "\u{1B}[32mKaisola retained terminal history\u{1B}[0m",
        "",
        "$ git status --short",
        " M native/KaisolaMac/Kaisola/Features/Sessions/TerminalTranscriptView.swift",
        "",
        "Earlier output remains searchable without moving the live terminal.",
        "Unicode stays intact: café · 研究 · ✅",
        "https://kaisola.com/app/",
        "",
        "$ swift test",
        "All focused transcript contracts passed.",
    ].joined(separator: "\r\n") + "\r\n"

    static func page(
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) throws -> TerminalHistoryPage {
        let bytes = Data(output.utf8)
        guard streamEpoch == "visual-shell",
              beforeOffset == Int64(bytes.count),
              maxBytes >= bytes.count else {
            throw BrokerClientError.malformedResponse
        }
        return TerminalHistoryPage(
            streamEpoch: streamEpoch,
            output: output,
            startOffset: 0,
            endOffset: Int64(bytes.count),
            hasMore: false,
            truncated: false
        )
    }
}

/// A real-window race fixture for the original "viewport spazzes while output
/// arrives" report. The first frame has enough retained rows to scroll well
/// away from live output; 240 tiny packets then exercise AppModel's production
/// 16 ms coalescer while the hosted AppKit surface remains user-unpinned. Each
/// packet also carries a real Braille activity-spinner OSC title, matching the
/// repaint-heavy agent TUI that previously published AppModel changes from
/// inside SwiftUI's view-update turn, persisted each spinner frame as identity,
/// and produced visible jitter plus a runtime warning.
enum VisualTerminalStreamingFixture {
    static let historicalLineCount = 480
    static let packetIndices = 1 ... 240
    static let activityFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    static let initialOutput = (0 ..< historicalLineCount).map { index in
        String(format: "historical-anchor-%04d  retained output remains stable", index)
    }.joined(separator: "\r\n") + "\r\n"

    static func packet(index: Int) -> String {
        let frame = activityFrames[(index - 1) % activityFrames.count]
        let title = "\(frame) Kaisola"
        return "\u{1B}]0;\(title)\u{7}"
            + String(format: "streaming-frame-%04d  background output\r\n", index)
    }

    static var finalMarker: String {
        String(format: "streaming-frame-%04d", packetIndices.upperBound)
    }
}

/// Broker-free retained history for the optimized continuous-scroll fixture.
/// It carries real OSC 133 prompt marks and an OSC 8 link so the installed-app
/// receipt can prove those parser-owned features survive the fractional host
/// viewport while Claude-style repaints and Codex-style linefeeds interleave.
enum VisualTerminalContinuousScrollFixture {
    private static func mark(_ value: String) -> String { "\u{1B}]133;\(value)\u{7}" }

    static let initialOutput = mark("A")
        + "michael@kaisola Kaisola % " + mark("B")
        + "codex --continue" + mark("C") + "\r\n"
        + "Open \u{1B}]8;;https://kaisola.app\u{7}https://kaisola.app\u{1B}]8;;\u{7}\r\n"
        + (0 ..< 640).map { index in
            String(format: "continuous-anchor-%04d  retained output remains readable", index)
        }.joined(separator: "\r\n")
        + "\r\n" + mark("D;0") + mark("A")
        + "michael@kaisola Kaisola % " + mark("B")

    /// A hosted window may complete one final grid reflow after its retained
    /// transcript was replayed. Production deliberately drops row-addressed
    /// OSC marks across that reflow, so the live lane supplies a new, complete
    /// lifecycle before the fixture claims that subsequent scrolling and
    /// repaint traffic preserve semantic navigation.
    static func packet(index: Int) -> String {
        let packet = VisualTerminalStreamingFixture.packet(index: index)
        guard index == VisualTerminalStreamingFixture.packetIndices.lowerBound else {
            return packet
        }
        return "continuous-scroll-probe" + mark("C") + "\r\n"
            + packet
            + mark("D;0") + mark("A")
            + "michael@kaisola Kaisola % " + mark("B")
    }
}

/// Resolves terminal launch state independently of the app/broker lifetime.
/// Kept deterministic at its core so PATH precedence and invalid-shell fallback
/// are covered without spawning a process in unit tests.
enum NativeTerminalLaunchEnvironment {
    static let preferredBinaryDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
    ]

    static func resolvedShell(
        environment: [String: String],
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String {
        if let configured = environment["SHELL"],
           configured.hasPrefix("/"),
           isExecutable(configured) {
            return configured
        }
        if isExecutable("/bin/zsh") { return "/bin/zsh" }
        return "/bin/sh"
    }

    static func preferredPathPrelude(
        existingDirectories: [String]? = nil
    ) -> String {
        let directories = existingDirectories ?? preferredBinaryDirectories.filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !directories.isEmpty else { return "" }
        let prefix = directories.joined(separator: ":")
        return "export PATH='\(prefix)':\"$PATH\"; hash -r 2>/dev/null || true; "
    }
}

/// Installs an opt-in, app-owned shell startup shim without modifying user
/// dotfiles. The launcher is used only for newly created sessions and always
/// execs the user's resolved shell; disabling the setting returns immediately
/// to the ordinary direct-shell path.
enum NativeSemanticShellIntegration {
    struct Installation: Equatable, Sendable {
        let launcher: URL
        let startupDirectory: URL
    }

    static func launchShell(
        userShell: String,
        enabled: Bool,
        directory: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("semantic-shell", isDirectory: true)
    ) -> String? {
        guard enabled else { return nil }
        switch URL(fileURLWithPath: userShell).lastPathComponent {
        case "zsh":
            return try? installZsh(userShell: userShell, directory: directory).launcher.path
        case "bash":
            return try? installBash(userShell: userShell, directory: directory).launcher.path
        case "fish":
            return try? installFish(userShell: userShell, directory: directory).launcher.path
        default:
            return nil
        }
    }

    static func installZsh(userShell: String, directory: URL) throws -> Installation {
        guard URL(fileURLWithPath: userShell).lastPathComponent == "zsh" else {
            throw CocoaError(.featureUnsupported)
        }
        let fileManager = FileManager.default
        let startupDirectory = directory.appendingPathComponent("zdot", isDirectory: true)
        try preparePrivateDirectory(directory, createParents: true, fileManager: fileManager)
        try preparePrivateDirectory(startupDirectory, createParents: false, fileManager: fileManager)

        let launcher = directory.appendingPathComponent("kaisola-zsh", isDirectory: false)
        let launcherScript = """
        #!/bin/sh
        if [ -z "${KAISOLA_USER_ZDOTDIR+x}" ]; then
          export KAISOLA_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"
        fi
        export KAISOLA_INTEGRATION_ZDOTDIR=\(shellQuote(startupDirectory.path))
        export ZDOTDIR="$KAISOLA_INTEGRATION_ZDOTDIR"
        exec \(shellQuote(userShell)) "$@"
        """

        let zshenv = """
        typeset -g __kaisola_wrapper_zdotdir="$ZDOTDIR"
        typeset -g __kaisola_user_zdotdir="${KAISOLA_USER_ZDOTDIR:-$HOME}"
        if [[ -r "$__kaisola_user_zdotdir/.zshenv" ]]; then
          ZDOTDIR="$__kaisola_user_zdotdir"
          builtin source "$ZDOTDIR/.zshenv"
          __kaisola_user_zdotdir="${ZDOTDIR:-$__kaisola_user_zdotdir}"
          typeset -gx KAISOLA_USER_ZDOTDIR="$__kaisola_user_zdotdir"
        fi
        ZDOTDIR="$__kaisola_wrapper_zdotdir"
        """

        let zprofile = sourceUserStartupFile(".zprofile", restoreWrapper: true)
        let zshrc = sourceUserStartupFile(".zshrc", restoreWrapper: false) + """

        builtin source "$__kaisola_wrapper_zdotdir/kaisola-integration.zsh"
        ZDOTDIR="$__kaisola_user_zdotdir"
        """
        let integration = #"""
        if [[ -z "${KAISOLA_SEMANTIC_MARKS_ACTIVE:-}" ]]; then
          typeset -g KAISOLA_SEMANTIC_MARKS_ACTIVE=1
          builtin autoload -Uz add-zsh-hook
          typeset -gi __kaisola_semantic_state=0
          typeset -g __kaisola_mark_a=$'%{\e]133;A\a%}'
          typeset -g __kaisola_mark_a_secondary=$'%{\e]133;A;k=s\a%}'
          typeset -g __kaisola_mark_b=$'%{\e]133;B\a%}'

          __kaisola_strip_semantic_prompt_marks() {
            PS1=${PS1//$'%{\e]133;A\a%}'}
            PS1=${PS1//$'%{\e]133;B\a%}'}
            PS2=${PS2//$'%{\e]133;A;k=s\a%}'}
            PS2=${PS2//$'%{\e]133;B\a%}'}
          }

          __kaisola_semantic_precmd() {
            builtin local command_status=$?
            if (( __kaisola_semantic_state == 1 )); then
              builtin printf '\e]133;D;%d\a' "$command_status"
            fi
            __kaisola_strip_semantic_prompt_marks
            if [[ -o prompt_percent ]]; then
              PS1="${__kaisola_mark_a}${PS1}${__kaisola_mark_b}"
              PS2="${__kaisola_mark_a_secondary}${PS2}"
              (( __kaisola_semantic_state = 2 ))
            fi
          }

          __kaisola_semantic_preexec() {
            __kaisola_strip_semantic_prompt_marks
            builtin printf '\e]133;C\a'
            (( __kaisola_semantic_state = 1 ))
          }

          add-zsh-hook precmd __kaisola_semantic_precmd
          add-zsh-hook preexec __kaisola_semantic_preexec
        fi
        """#

        try write(launcherScript, to: launcher, permissions: 0o700)
        try write(zshenv, to: startupDirectory.appendingPathComponent(".zshenv"), permissions: 0o600)
        try write(zprofile, to: startupDirectory.appendingPathComponent(".zprofile"), permissions: 0o600)
        try write(zshrc, to: startupDirectory.appendingPathComponent(".zshrc"), permissions: 0o600)
        try write(
            integration,
            to: startupDirectory.appendingPathComponent("kaisola-integration.zsh"),
            permissions: 0o600
        )
        return Installation(launcher: launcher, startupDirectory: startupDirectory)
    }

    /// Bash only honors `--rcfile` for an interactive non-login shell. Kaisola's
    /// broker intentionally launches `-il`, `-ilc`, and `-lc`, so the private
    /// launcher removes only the login flag and the app-owned startup file
    /// reproduces Bash's documented login order before installing the hooks.
    /// User startup files stay read-only and the one-shot BASH_ENV does not leak
    /// into programs launched from the terminal.
    static func installBash(userShell: String, directory: URL) throws -> Installation {
        guard URL(fileURLWithPath: userShell).lastPathComponent == "bash" else {
            throw CocoaError(.featureUnsupported)
        }
        let fileManager = FileManager.default
        let startupDirectory = directory.appendingPathComponent("bash", isDirectory: true)
        try preparePrivateDirectory(directory, createParents: true, fileManager: fileManager)
        try preparePrivateDirectory(startupDirectory, createParents: false, fileManager: fileManager)

        let launcher = directory.appendingPathComponent("kaisola-bash", isDirectory: false)
        let startupFile = startupDirectory.appendingPathComponent(
            "kaisola-bashrc",
            isDirectory: false
        )
        let launcherScript = """
        #!/bin/sh
        case "${1:-}" in
          -ilc|-lic|-icl|-ilc*)
            export KAISOLA_BASH_LOGIN=1
            shift
            set -- -ic "$@"
            ;;
          -lc|-cl)
            export KAISOLA_BASH_LOGIN=1
            shift
            set -- -c "$@"
            ;;
          -il|-li)
            export KAISOLA_BASH_LOGIN=1
            shift
            set -- -i "$@"
            ;;
          -l|--login)
            export KAISOLA_BASH_LOGIN=1
            shift
            ;;
        esac
        export BASH_ENV=\(shellQuote(startupFile.path))
        exec \(shellQuote(userShell)) --noprofile --rcfile \(shellQuote(startupFile.path)) "$@"
        """
        let integration = #"""
        if [[ -z "${KAISOLA_BASH_STARTUP_ACTIVE:-}" ]]; then
          KAISOLA_BASH_STARTUP_ACTIVE=1
          if [[ "${KAISOLA_BASH_LOGIN:-0}" == 1 ]]; then
            [[ -r /etc/profile ]] && builtin source /etc/profile
            for __kaisola_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
              if [[ -r "$__kaisola_profile" ]]; then
                builtin source "$__kaisola_profile"
                break
              fi
            done
            builtin unset __kaisola_profile
          elif [[ -r "$HOME/.bashrc" ]]; then
            builtin source "$HOME/.bashrc"
          fi
        fi
        builtin unset KAISOLA_BASH_LOGIN BASH_ENV

        if [[ -z "${KAISOLA_SEMANTIC_MARKS_ACTIVE:-}" ]]; then
          KAISOLA_SEMANTIC_MARKS_ACTIVE=1
          __kaisola_semantic_seen_prompt=0
          __kaisola_semantic_ps0_initialized=0
          __kaisola_semantic_custom_ps0=
          __kaisola_semantic_custom_ps1=
          __kaisola_semantic_custom_ps2=
          declare -a __kaisola_semantic_original_prompt_commands=()
          __kaisola_semantic_prompt_declaration="$(builtin declare -p PROMPT_COMMAND 2>/dev/null || true)"
          if [[ "$__kaisola_semantic_prompt_declaration" == "declare -a"* ]]; then
            __kaisola_semantic_original_prompt_commands=("${PROMPT_COMMAND[@]}")
          elif [[ -n "${PROMPT_COMMAND:-}" ]]; then
            __kaisola_semantic_original_prompt_commands=("$PROMPT_COMMAND")
          fi
          builtin unset __kaisola_semantic_prompt_declaration

          __kaisola_semantic_restore_status() {
            builtin return "$1"
          }

          __kaisola_semantic_update_prompts() {
            if (( __kaisola_semantic_ps0_initialized == 0 )) \
                || [[ "$PS0" != "$__kaisola_semantic_custom_ps0" ]]; then
              __kaisola_semantic_custom_ps0='\[\e]133;C\a\]'"$PS0"
              PS0="$__kaisola_semantic_custom_ps0"
              __kaisola_semantic_ps0_initialized=1
            fi
            if [[ "$PS1" != "$__kaisola_semantic_custom_ps1" ]]; then
              __kaisola_semantic_custom_ps1='\[\e]133;A\a\]'"$PS1"'\[\e]133;B\a\]'
              PS1="$__kaisola_semantic_custom_ps1"
            fi
            if [[ "$PS2" != "$__kaisola_semantic_custom_ps2" ]]; then
              __kaisola_semantic_custom_ps2='\[\e]133;A;k=s\a\]'"$PS2"
              PS2="$__kaisola_semantic_custom_ps2"
            fi
          }

          __kaisola_semantic_prompt_command() {
            builtin local command_status=$?
            builtin local original_command
            if (( __kaisola_semantic_seen_prompt == 1 )); then
              builtin printf '\e]133;D;%d\a' "$command_status"
            fi
            for original_command in "${__kaisola_semantic_original_prompt_commands[@]}"; do
              [[ -z "$original_command" ]] && continue
              __kaisola_semantic_restore_status "$command_status"
              builtin eval "$original_command"
            done
            __kaisola_semantic_update_prompts
            __kaisola_semantic_seen_prompt=1
          }

          PROMPT_COMMAND=__kaisola_semantic_prompt_command
        fi
        """#

        try write(launcherScript, to: launcher, permissions: 0o700)
        try write(integration, to: startupFile, permissions: 0o600)
        return Installation(launcher: launcher, startupDirectory: startupDirectory)
    }

    /// Fish evaluates `--init-command` after the user's ordinary configuration
    /// and before interactive input, so it provides an app-owned injection
    /// point without replacing or editing `config.fish`. Current Fish releases
    /// emit OSC 133 themselves; the private startup file detects that capability
    /// and returns before defining anything. The fallback is only for older Fish
    /// releases and deliberately emits lifecycle markers without command text.
    static func installFish(userShell: String, directory: URL) throws -> Installation {
        guard URL(fileURLWithPath: userShell).lastPathComponent == "fish" else {
            throw CocoaError(.featureUnsupported)
        }
        let fileManager = FileManager.default
        let startupDirectory = directory.appendingPathComponent("fish", isDirectory: true)
        try preparePrivateDirectory(directory, createParents: true, fileManager: fileManager)
        try preparePrivateDirectory(startupDirectory, createParents: false, fileManager: fileManager)

        let launcher = directory.appendingPathComponent("kaisola-fish", isDirectory: false)
        let startupFile = startupDirectory.appendingPathComponent(
            "kaisola-integration.fish",
            isDirectory: false
        )
        let launcherScript = """
        #!/bin/sh
        export KAISOLA_FISH_INTEGRATION=\(shellQuote(startupFile.path))
        exec \(shellQuote(userShell)) --init-command 'source "$KAISOLA_FISH_INTEGRATION"; set -e KAISOLA_FISH_INTEGRATION' "$@"
        """
        let integration = #"""
        status is-interactive; or return 0

        # Fish with forward-char-passive emits native OSC 133 A/B/C/D markers.
        # Do not duplicate or replace that first-party integration.
        bind --function-names | string match -q -- forward-char-passive; and return 0
        set -q KAISOLA_SEMANTIC_MARKS_ACTIVE; and return 0
        set -g KAISOLA_SEMANTIC_MARKS_ACTIVE 1

        function __kaisola_semantic_osc
            builtin printf '\e]133;%s\a' (string join ';' -- $argv)
        end

        function __kaisola_semantic_preexec --on-event fish_preexec
            __kaisola_semantic_osc C
        end

        function __kaisola_semantic_postexec --on-event fish_postexec
            set -l command_status $status
            __kaisola_semantic_osc D $command_status
        end

        # D before C is an aborted edit in the OSC 133 contract. Kaisola drops
        # that transient block, then the repainted prompt creates a fresh A/B.
        function __kaisola_semantic_cancel --on-event fish_cancel
            __kaisola_semantic_osc D
        end

        function __kaisola_semantic_posterror --on-event fish_posterror
            set -l command_status $status
            __kaisola_semantic_osc D $command_status
        end

        function __kaisola_semantic_prompt_start
            __kaisola_semantic_osc A
        end

        function __kaisola_semantic_command_start
            __kaisola_semantic_osc B
        end

        function __kaisola_semantic_has_mode_prompt
            functions fish_mode_prompt | string match -rvq '^ *(#|function |end$|$)'
        end

        function __kaisola_semantic_wrap_prompt
            if __kaisola_semantic_has_mode_prompt
                functions --copy fish_mode_prompt __kaisola_user_fish_mode_prompt
                function fish_mode_prompt
                    __kaisola_semantic_prompt_start
                    __kaisola_user_fish_mode_prompt
                end
                function fish_prompt
                    __kaisola_user_fish_prompt
                    __kaisola_semantic_command_start
                end
            else
                function fish_prompt
                    __kaisola_semantic_prompt_start
                    __kaisola_user_fish_prompt
                    __kaisola_semantic_command_start
                end
            end
        end

        # A prompt may still be autoloaded when --init-command runs. Preserve it
        # on the first fish_prompt event, after configuration has fully settled.
        function __kaisola_semantic_preserve_prompt --on-event fish_prompt
            if functions --query fish_prompt
                functions --erase __kaisola_user_fish_prompt
                functions --copy fish_prompt __kaisola_user_fish_prompt
                functions --erase __kaisola_semantic_preserve_prompt
                __kaisola_semantic_wrap_prompt
            else if functions --query __kaisola_user_fish_prompt
                functions --erase __kaisola_semantic_preserve_prompt
                __kaisola_semantic_wrap_prompt
            else
                function __kaisola_user_fish_prompt
                    echo -n (whoami)@(prompt_hostname) (prompt_pwd) '> '
                end
            end
        end

        __kaisola_semantic_preserve_prompt
        """#

        try write(launcherScript, to: launcher, permissions: 0o700)
        try write(integration, to: startupFile, permissions: 0o600)
        return Installation(launcher: launcher, startupDirectory: startupDirectory)
    }

    private static func sourceUserStartupFile(_ name: String, restoreWrapper: Bool) -> String {
        """
        typeset -g __kaisola_wrapper_zdotdir="$ZDOTDIR"
        typeset -g __kaisola_user_zdotdir="${KAISOLA_USER_ZDOTDIR:-$HOME}"
        ZDOTDIR="$__kaisola_user_zdotdir"
        if [[ -r "$ZDOTDIR/\(name)" ]]; then
          builtin source "$ZDOTDIR/\(name)"
          __kaisola_user_zdotdir="${ZDOTDIR:-$__kaisola_user_zdotdir}"
          typeset -gx KAISOLA_USER_ZDOTDIR="$__kaisola_user_zdotdir"
        fi
        \(restoreWrapper ? "ZDOTDIR=\"$__kaisola_wrapper_zdotdir\"" : "")
        """
    }

    private static func write(_ text: String, to url: URL, permissions: Int) throws {
        try rejectSymbolicLink(at: url, fileManager: .default)
        try Data(text.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private static func rejectSymbolicLink(at url: URL, fileManager: FileManager) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func preparePrivateDirectory(
        _ url: URL,
        createParents: Bool,
        fileManager: FileManager
    ) throws {
        try rejectSymbolicLink(at: url, fileManager: fileManager)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteNoPermission) }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: createParents,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Owns the cancellable operations that move a Mesh between durable lifecycle
/// states. `MeshSession` remains responsible for the worktree and adapter
/// transaction itself; this coordinator prevents stale AppModel tasks from
/// publishing a superseded transition.
@MainActor
final class MeshLifecycleCoordinator {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case restoring
        case active
        case suspending
        case suspended
        case destroying
        case destroyed
        case recoveryRequired
        case cancelled

        init(_ persisted: NativeMeshLifecycle) {
            switch persisted {
            case .provisioning:
                self = .starting
            case .active:
                self = .active
            case .suspended:
                self = .suspended
            case .pendingDeletion:
                self = .destroying
            case .recoveryRequired:
                self = .recoveryRequired
            }
        }
    }

    enum Completion: Equatable, Sendable {
        case completed
        case cancelled
    }

    enum Outcome<Value: Equatable & Sendable>: Equatable, Sendable {
        case completed(Value)
        case cancelled
    }

    private struct ActiveOperation {
        let generation: UInt64
        let cancel: @MainActor () -> Void
        let wait: @MainActor () async -> Void
    }

    private var generationCounter: UInt64 = 0
    private var operations: [String: ActiveOperation] = [:]
    private var states: [String: State] = [:]

    func state(for meshID: String) -> State {
        states[meshID] ?? .idle
    }

    func start(
        _ mesh: MeshSession,
        agents: [AgentProfile],
        environment: [String: String]
    ) {
        start(meshID: mesh.id) {
            await mesh.start(agents: agents, environment: environment)
            return State(mesh.lifecycle)
        }
    }

    func restore(
        _ mesh: MeshSession,
        states: [MeshSession.RestoredColumnState],
        agents: [AgentProfile],
        environment: [String: String]
    ) async -> Completion {
        await restore(meshID: mesh.id) {
            await mesh.restore(states: states, agents: agents, environment: environment)
            return State(mesh.lifecycle)
        }
    }

    func suspend(_ mesh: MeshSession) async -> Completion {
        await suspend(meshID: mesh.id) {
            await mesh.suspend()
            return State(mesh.lifecycle)
        }
    }

    func destroy(
        _ mesh: MeshSession,
        allowRecoverableWork: Bool
    ) async -> Outcome<MeshSession.DiscardAssessment> {
        await destroy(
            meshID: mesh.id,
            operation: {
                await mesh.destroy(allowRecoverableWork: allowRecoverableWork)
            },
            resolvedState: { result in
                result == .safe ? .destroyed : State(mesh.lifecycle)
            }
        )
    }

    /// Starts a retained operation without making AppModel own an unstructured
    /// Task. A later suspend, destroy, or explicit cancellation invalidates its
    /// generation before the underlying MeshSession is asked to stop.
    func start(
        meshID: String,
        operation: @escaping @MainActor @Sendable () async -> State
    ) {
        let (generation, task) = beginOperation(
            meshID: meshID,
            transition: .starting,
            operation: operation
        )
        Task { [weak self] in
            let finalState = await task.value
            self?.finish(meshID: meshID, generation: generation, state: finalState)
        }
    }

    func restore(
        meshID: String,
        operation: @escaping @MainActor @Sendable () async -> State
    ) async -> Completion {
        await stateTransition(meshID: meshID, transition: .restoring, operation: operation)
    }

    func suspend(
        meshID: String,
        operation: @escaping @MainActor @Sendable () async -> State
    ) async -> Completion {
        await stateTransition(meshID: meshID, transition: .suspending, operation: operation)
    }

    func destroy<Value: Equatable & Sendable>(
        meshID: String,
        operation: @escaping @MainActor @Sendable () async -> Value,
        resolvedState: @MainActor (Value) -> State
    ) async -> Outcome<Value> {
        let (generation, task) = beginOperation(
            meshID: meshID,
            transition: .destroying,
            operation: operation
        )
        let value = await task.value
        guard finish(
            meshID: meshID,
            generation: generation,
            state: resolvedState(value)
        ) else {
            return .cancelled
        }
        return .completed(value)
    }

    /// Invalidates an operation synchronously. Its work receives cooperative
    /// Task cancellation, while the generation fence prevents late completion
    /// from changing the visible lifecycle even if that work ignores it.
    func cancel(meshID: String) {
        guard states[meshID] != nil || operations[meshID] != nil else { return }
        let operation = operations.removeValue(forKey: meshID)
        operation?.cancel()
        states[meshID] = .cancelled
    }

    func cancelAll() {
        for meshID in Array(operations.keys) {
            cancel(meshID: meshID)
        }
    }

    func waitForIdle(meshID: String) async {
        while let operation = operations[meshID] {
            await operation.wait()
            if operations[meshID]?.generation == operation.generation {
                await Task.yield()
            }
        }
    }

    /// Removes bounded coordinator metadata after AppModel drops the surface.
    func forget(meshID: String) {
        operations.removeValue(forKey: meshID)?.cancel()
        states.removeValue(forKey: meshID)
    }

    private func stateTransition(
        meshID: String,
        transition: State,
        operation: @escaping @MainActor @Sendable () async -> State
    ) async -> Completion {
        let (generation, task) = beginOperation(
            meshID: meshID,
            transition: transition,
            operation: operation
        )
        let finalState = await task.value
        return finish(meshID: meshID, generation: generation, state: finalState)
            ? .completed
            : .cancelled
    }

    private func beginOperation<Value: Sendable>(
        meshID: String,
        transition: State,
        operation: @escaping @MainActor @Sendable () async -> Value
    ) -> (UInt64, Task<Value, Never>) {
        operations.removeValue(forKey: meshID)?.cancel()
        generationCounter &+= 1
        let generation = generationCounter
        states[meshID] = transition
        let task = Task { await operation() }
        operations[meshID] = ActiveOperation(
            generation: generation,
            cancel: { task.cancel() },
            wait: { _ = await task.value }
        )
        return (generation, task)
    }

    @discardableResult
    private func finish(meshID: String, generation: UInt64, state: State) -> Bool {
        guard operations[meshID]?.generation == generation else {
            return false
        }
        operations.removeValue(forKey: meshID)
        states[meshID] = state
        return true
    }
}

private extension Error {
    var kaisolaSafeDescription: String {
        if let localized = self as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "The terminal observer could not connect. Everything already running was left untouched."
    }
}
