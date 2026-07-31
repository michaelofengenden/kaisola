import AppKit
import Combine
import Foundation
import KaisolaBrokerProtocol

@MainActor
final class AppModel: ObservableObject {
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
            case .looking: "Looking for the background service"
            case .connecting: "Connecting"
            case .reconnecting: "Reconnecting"
            case .connected: "Connected"
            case .unavailable: "Offline"
            }
        }

        var detail: String? {
            switch self {
            case let .reconnecting(attempt):
                "Attempt \(attempt) · running terminals keep going in the background"
            case let .connected(version, pid, serverEnforced):
                "Background service \(version) · PID \(pid) · \(serverEnforced ? "server-enforced observer" : "local observer policy")"
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
    @Published private(set) var sessions: [BrokerTerminalRecord] = []
    @Published var selectedSessionID: String?
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
    /// each free to grow to `TerminalDocument.maximumRetainedBytes`, is 768 MiB
    /// of scrollback strings — reachable simply by touring long-lived
    /// terminals. Retained bytes are therefore bounded too, evicting
    /// least-recently-used first. 96 MiB holds a whole saturated terminal plus
    /// a comfortable deck of ordinary ones.
    nonisolated static let maximumRetainedTerminalBytes = 96 * 1_024 * 1_024
    /// Terminals this app created and may mutate. Everything else stays
    /// strictly observed no matter what the UI asks for.
    @Published private(set) var ownedTerminalIDs: Set<String> = []
    /// Whether the connected broker accepted a controller connection; older
    /// brokers stay observe-only and hide every mutation affordance.
    @Published private(set) var controlAvailable = false
    /// A phone holds the short Companion lease. Keep AppKit geometry callbacks
    /// from fighting its explicit PTY size until release restores the desktop
    /// geometry; surfaced by the session UI as a live remote-control state.
    @Published private(set) var companionControlledTerminalIDs: Set<String> = []
    /// Open ACP chat conversations, keyed by a synthetic chat id. These run
    /// independently of the broker (the adapter is a child of this app).
    @Published private(set) var chats: [AcpChatHandle] = []
    @Published var selectedChatID: String?
    /// Project-scoped card geometry shared by terminals, ACP chats, and Mesh.
    /// A column is horizontal; ids inside a column stack vertically.
    @Published private(set) var paneLayouts: [String: SessionPaneLayout] = [:]
    @Published private(set) var focusedPaneID: String?
    @Published private(set) var maximizedPaneID: String?
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
    private let usageCenter: UsageCenter
    private let attentionCenter: AttentionCenter
    private let reconnectBackoff: BrokerReconnectBackoff
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let jitter: @Sendable () -> Double
    private var selectedSession: BrokerTerminalRecord?
    private var activeBrokerIdentity: String?
    private var connectedBrokerFeatures: Set<String> = []
    private var activeBrokerUpgradeMonitor: (any BrokerUpgradeMonitoring)?
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
    }
    private var terminalInputQueues: [String: [PendingTerminalInput]] = [:]
    private var terminalInputDrainTasks: [String: Task<Void, Never>] = [:]
    private var terminalInputFailureNoticeAt: [String: Date] = [:]
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
    private let observerOwnerID = "kaisola-native"

    /// Disk-backed navigation state is cached in memory. `projects` is read by
    /// many SwiftUI branches on every streamed terminal update; decoding two
    /// JSON files repeatedly there turned normal output into main-thread I/O
    /// and was the largest source of the spinning cursor after opening folders.
    var persistedOpenProjects: [OpenProject] = []
    var persistedOwnedSessions: [NativeOwnedSession] = []
    var persistedSessionAliases: [String: String] = [:]
    var persistedPinnedIDs: Set<String> = []

    init(
        brokerPreparer: any BrokerInfoPreparing = BrokerStartupCoordinator.live(),
        fallbackPreparer: (any BrokerInfoPreparing)? = nil,
        client: any ObserveOnlyBrokerServing = ObserveOnlyBrokerClient(),
        controlClient: any BrokerControlServing = BrokerControlClient(),
        sessionStore: NativeSessionStore = NativeSessionStore(),
        cursorStore: TerminalCursorStore = TerminalCursorStore(fileURL: NativePreviewPaths.terminalCursorStore),
        workspaceStateStore: NativeWorkspaceStateStore = .live,
        transcriptStore: AcpTranscriptStore = .live,
        usageCenter: UsageCenter = .shared,
        attentionCenter: AttentionCenter = .shared,
        reconnectBackoff: BrokerReconnectBackoff = BrokerReconnectBackoff(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        jitter: @escaping @Sendable () -> Double = {
            Double.random(in: -1...1)
        }
    ) {
        self.brokerPreparer = brokerPreparer
        self.fallbackPreparer = fallbackPreparer
        self.client = client
        self.controlClient = controlClient
        self.sessionStore = sessionStore
        self.cursorStore = cursorStore
        self.workspaceStateStore = workspaceStateStore
        self.transcriptStore = transcriptStore
        self.usageCenter = usageCenter
        self.attentionCenter = attentionCenter
        self.reconnectBackoff = reconnectBackoff
        self.sleep = sleep
        self.jitter = jitter
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
        persistedPinnedIDs = SessionPinStore().pins()
    }

    /// Keeps each chat's usage observers alive only while that chat exists.
    /// Keying by id avoids retaining closed conversations and stale Usage rows.
    private var usageObservers: [String: Set<AnyCancellable>] = [:]
    private let usageSourceID = UUID().uuidString.lowercased()
    /// Serializes transcript actor enqueues so an immediate quit cannot overtake
    /// the final streaming row or an explicit chat removal.
    private var transcriptPersistenceTask: Task<Void, Never>?
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
    private var meshShutdownTasks: [String: Task<Void, Never>] = [:]
    /// A durable Mesh may be restored by only one window model at a time.
    /// Main-actor isolation makes this a process-wide claim without locks.
    private static var claimedRestoredMeshIDs: Set<String> = []
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
        let sessionsByProject = Dictionary(grouping: sessions, by: \.projectID)
        let chatsByProject = Dictionary(grouping: chats, by: \.projectID)
        let meshesByProject = Dictionary(grouping: meshes, by: \.projectID)
        let pins = persistedPinnedIDs

        func group(for id: String) -> ProjectGroup {
            let sessions = AppModel.pinnedOrder(sessionsByProject[id] ?? [], pinned: pins)
            let projectChats = chatsByProject[id] ?? []
            let projectMeshes = meshesByProject[id] ?? []
            let name = openedByID[id]?.name
                ?? ownedByID[id].map { ($0.cwd as NSString).lastPathComponent }
                ?? projectChats.first?.workspaceDirectory.lastPathComponent
                ?? projectMeshes.first?.baseDirectory.lastPathComponent
                ?? id
            let directory = openedByID[id].map { URL(fileURLWithPath: $0.path) }
                ?? ownedByID[id].map { URL(fileURLWithPath: $0.cwd) }
                ?? projectChats.first?.workspaceDirectory
                ?? projectMeshes.first?.baseDirectory
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
        // that only exist through live sessions/chats/Mesh follow, sorted by
        // name. Closing a tab therefore never orphans an active surface.
        let openedGroups = opened.map { group(for: $0.id) }
        let liveProjectIDs = Set(sessionsByProject.keys)
            .union(chatsByProject.keys)
            .union(meshesByProject.keys)
        let sessionOnly = liveProjectIDs.subtracting(opened.map(\.id))
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
        persistedPinnedIDs = SessionPinStore().pins()
        if publish { objectWillChange.send() }
    }

    func chats(in projectID: String) -> [AcpChatHandle] {
        chats.filter { $0.projectID == projectID }
    }

    func meshes(in projectID: String) -> [MeshSession] {
        meshes.filter { $0.projectID == projectID }
    }

    // MARK: - Unified session cards

    func paneLayout(for projectID: String?) -> SessionPaneLayout {
        guard let projectID else { return SessionPaneLayout() }
        return paneLayouts[projectID] ?? SessionPaneLayout()
    }

    func isSurfaceVisible(_ id: String) -> Bool {
        guard let projectID = projectID(forSurface: id) else { return false }
        return paneLayouts[projectID]?.contains(id) == true
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
        var layout = paneLayouts[projectID] ?? SessionPaneLayout()
        layout.focus(id)
        paneLayouts[projectID] = layout
        focusedPaneID = id
        maximizedPaneID = nil
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
        var layout = paneLayouts[projectID] ?? SessionPaneLayout()
        layout.add(id)
        paneLayouts[projectID] = layout
        focusedPaneID = id
        maximizedPaneID = nil
        focusSurfaceFields(id)
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
        var layout = paneLayouts[projectID] ?? SessionPaneLayout()
        layout.place(id, relativeTo: targetID, edge: edge)
        paneLayouts[projectID] = layout
        focusedPaneID = id
        maximizedPaneID = nil
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    func resizePaneColumns(projectID: String, boundary: Int, delta: Double, minimumWeight: Double) {
        guard var layout = paneLayouts[projectID] else { return }
        layout.resizeColumns(boundary: boundary, delta: delta, minimumWeight: minimumWeight)
        paneLayouts[projectID] = layout
    }

    func resizePaneRows(
        projectID: String,
        columnID: String,
        boundary: Int,
        delta: Double,
        minimumWeight: Double
    ) {
        guard var layout = paneLayouts[projectID] else { return }
        layout.resizeRows(
            columnID: columnID,
            boundary: boundary,
            delta: delta,
            minimumWeight: minimumWeight
        )
        paneLayouts[projectID] = layout
    }

    func finishPaneResize(projectID: String) {
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    func resetPaneColumns(projectID: String) {
        guard var layout = paneLayouts[projectID] else { return }
        layout.resetColumnWeights()
        paneLayouts[projectID] = layout
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    func resetPaneRows(projectID: String, columnID: String) {
        guard var layout = paneLayouts[projectID] else { return }
        layout.resetRowWeights(columnID: columnID)
        paneLayouts[projectID] = layout
        scheduleWorkspaceStateSave(projectID: projectID)
    }

    func toggleMaximizeSurface(_ id: String) {
        maximizedPaneID = maximizedPaneID == id ? nil : id
        focusedPaneID = id
    }

    func minimizeSurface(_ id: String) async {
        guard let projectID = projectID(forSurface: id), var layout = paneLayouts[projectID] else { return }
        if sessions.contains(where: { $0.id == id }) {
            splitIntentTokens[id] = UUID()
        }
        layout.remove(id)
        paneLayouts[projectID] = layout
        if sessions.contains(where: { $0.id == id }), id != selectedSessionID {
            await unsubscribeSplit(id)
        }
        if focusedPaneID == id { focusedPaneID = layout.sessionIDs.first }
        if maximizedPaneID == id { maximizedPaneID = nil }
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
        sessions.first(where: { $0.id == id })?.projectID
            ?? chats.first(where: { $0.id == id })?.projectID
            ?? meshes.first(where: { $0.id == id })?.projectID
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

    func focusSurface(_ id: String) async {
        if sessions.contains(where: { $0.id == id }) {
            await focusTerminalSurface(id)
        } else if chats.contains(where: { $0.id == id }) {
            selectChat(id)
        } else if meshes.contains(where: { $0.id == id }) {
            selectMesh(id)
        }
        // The ring and the keyboard must agree in both directions. Moving the
        // ring from a header click, the rail, or a menu command previously left
        // AppKit's first responder wherever it was, so the app showed one pane
        // as focused while typing — and VoiceOver — went to another.
        TerminalKeyboardFocus.moveFirstResponder(toSessionID: id)
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
              let target = PaneFocusCycle.terminalTarget(
                  after: focusedPaneID,
                  in: layout.sessionIDs,
                  forward: forward,
                  // Chat and Mesh panes have no FocusState hook yet, so the
                  // ring must skip straight past them (out of scope: giving
                  // them one).
                  isTerminalSurface: { id in sessions.contains(where: { $0.id == id }) }
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
        focusedPaneID = id
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
                && sessions.first(where: { $0.id == selected })?.projectID == project.id
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
        guard var layout = paneLayouts[projectID] else { return false }
        let previous = layout
        let available = Set(
            sessions.lazy.filter { $0.projectID == projectID }.map(\.id)
        ).union(chats(in: projectID).map(\.id))
            .union(meshes(in: projectID).map(\.id))
        layout.normalize(availableSessionIDs: available)
        guard layout != previous else { return false }

        let removed = Set(previous.sessionIDs).subtracting(layout.sessionIDs)
        paneLayouts[projectID] = layout
        if let focusedPaneID, removed.contains(focusedPaneID) {
            self.focusedPaneID = layout.sessionIDs.first
        }
        if let maximizedPaneID, removed.contains(maximizedPaneID) {
            self.maximizedPaneID = nil
        }
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

    func registerWorkspaceRenameUndo(
        _ move: WorkspaceFileOperations.Move,
        workspaceRoot: URL,
        undoManager: UndoManager?
    ) {
        registerWorkspaceRenameAction(
            from: move.destination,
            to: move.source,
            workspaceRoot: workspaceRoot,
            undoManager: undoManager
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

    private func registerWorkspaceRenameAction(
        from source: URL,
        to destination: URL,
        workspaceRoot: URL,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] model in
            guard let undoManager else { return }
            MainActor.assumeIsolated {
                model.performWorkspaceRenameAction(
                    from: source,
                    to: destination,
                    workspaceRoot: workspaceRoot,
                    undoManager: undoManager
                )
            }
        }
        undoManager.setActionName("Rename")
    }

    private func performWorkspaceRenameAction(
        from source: URL,
        to destination: URL,
        workspaceRoot: URL,
        undoManager: UndoManager
    ) {
        registerWorkspaceRenameAction(
            from: destination,
            to: source,
            workspaceRoot: workspaceRoot,
            undoManager: undoManager
        )
        guard prepareWorkspaceFileMutation(source) else { return }
        Task {
            do {
                let move = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.rename(
                        item: source,
                        to: destination.lastPathComponent,
                        workspaceRoot: workspaceRoot
                    )
                }.value
                reconcileWorkspaceFileMove(from: move.source, to: move.destination)
                ProjectFileIndex.shared.invalidate()
                ToastCenter.shared.show("Renamed to \(destination.lastPathComponent)", style: .success)
            } catch {
                showWorkspaceMutationError(error, action: "rename")
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
                ProjectFileIndex.shared.invalidate()
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
                ProjectFileIndex.shared.invalidate()
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

    func isOwned(_ terminalID: String) -> Bool {
        ownedTerminalIDs.contains(terminalID)
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
        if let snapshot = workspaceSnapshot(projectID: projectID) {
            try? await workspaceStateStore.saveProjectState(snapshot, makeSelected: false)
        } else {
            try? await workspaceStateStore.removeProjectState(projectID: projectID)
        }
    }

    private func workspaceSnapshot(projectID: String) -> NativeProjectWorkspaceState? {
        let layout = paneLayouts[projectID] ?? SessionPaneLayout()
        var panes: [NativeRestorablePaneState] = []
        var seen = Set<String>()

        for terminalID in layout.sessionIDs {
            guard let terminal = sessions.first(where: { $0.id == terminalID }),
                  terminal.projectID == projectID,
                  seen.insert(terminalID).inserted else { continue }
            panes.append(NativeRestorablePaneState(
                id: terminalID,
                surface: NativeRestorableSurfaceState(
                    kind: .terminal,
                    id: terminalID,
                    projectID: projectID,
                    title: sessionTitle(for: terminal)
                )
            ))
        }

        // A hidden chat remains a restorable sidebar session; closing it is the
        // explicit destructive action that removes transcript and descriptor.
        for chat in chats(in: projectID) where seen.insert(chat.id).inserted {
            let descriptor = NativeRestorableAgentChatDescriptor(
                id: chat.id,
                projectID: projectID,
                agentID: chat.agentID,
                workspacePath: chat.workspaceDirectory.path,
                acpSessionID: chat.conversation.providerSessionID,
                accountBinding: chat.accountBinding,
                title: chat.conversation.title
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

    private func persistWorkspaceStateNow() async {
        for task in workspaceSaveTasks.values { task.cancel() }
        workspaceSaveTasks.removeAll()
        let explicitlyOpenProjectIDs = Set(persistedOpenProjects.map(\.id))
        var projectIDs = Set(paneLayouts.keys)
        projectIDs.formUnion(chats.map(\.projectID))
        projectIDs.formUnion(meshes.map(\.projectID))
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

    func enqueueTranscriptSave(_ rows: [AcpTranscriptRow], chatID: String) {
        guard !explicitlyClosedChatIDs.contains(chatID) else { return }
        let previous = transcriptPersistenceTask
        let transcriptStore = transcriptStore
        transcriptPersistenceTask = Task {
            await previous?.value
            await transcriptStore.scheduleSave(rows, for: chatID)
        }
    }

    func enqueueTranscriptRemoval(chatID: String) {
        explicitlyClosedChatIDs.insert(chatID)
        let previous = transcriptPersistenceTask
        let transcriptStore = transcriptStore
        let usageCenter = usageCenter
        transcriptPersistenceTask = Task {
            await previous?.value
            // Usage and transcript writes use separate coalescing queues during
            // normal streaming. On explicit close, drain usage first and make
            // the full transcript deletion the final actor operation.
            await usageCenter.flushPersistence()
            await transcriptStore.remove(chatID: chatID)
        }
    }

    func flushTranscriptPersistence() async {
        await transcriptPersistenceTask?.value
        await transcriptStore.flush()
    }

    private func wireMeshPersistence(_ mesh: MeshSession) {
        let projectID = mesh.projectID
        mesh.onDescriptorChanged = { [weak self] in
            self?.scheduleWorkspaceStateSave(projectID: projectID)
        }
        mesh.persistDescriptor = { [weak self, weak mesh] in
            guard let self, let mesh,
                  let snapshot = self.workspaceSnapshot(projectID: projectID) else {
                throw CancellationError()
            }
            try await self.workspaceStateStore.saveProjectState(snapshot, makeSelected: false)
            let persisted = try await self.workspaceStateStore.projectState(for: projectID)
            guard persisted?.panes.contains(where: {
                $0.surface.meshDescriptor?.id == mesh.id
            }) == true else {
                throw NativeWorkspaceStateStore.StoreError.criticalDescriptorNotPersisted
            }
        }
        mesh.onTranscriptChanged = { [weak self] columnID, rows in
            self?.enqueueTranscriptSave(rows, chatID: columnID)
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

    private func enqueueDraftRemoval(chatID: String) {
        enqueueDraftRemoval(stableKey: "chat|\(chatID)")
    }

    private func enqueueDraftRemoval(stableKey: String) {
        let previous = draftPersistenceTask
        let workspaceStateStore = workspaceStateStore
        draftPersistenceTask = Task {
            await previous?.value
            try? await workspaceStateStore.removeDraft(stableKey: stableKey)
        }
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

    func restoreWorkspaceStateIfNeeded() async {
        guard !restoredWorkspaceState else { return }
        restoredWorkspaceState = true
        isRestoringWorkspaceState = true
        for task in workspaceSaveTasks.values { task.cancel() }
        workspaceSaveTasks.removeAll()
        defer { isRestoringWorkspaceState = false }

        let restoration: NativeWorkspaceRestorationState
        do {
            restoration = try await workspaceStateStore.restorationState()
            workspaceRestorationNotice = nil
        } catch {
            await raiseWorkspaceRestorationNotice(for: error)
            return
        }
        for projectState in restoration.projects {
            for pane in projectState.panes {
                guard let descriptor = pane.surface.agentChatDescriptor,
                      chats.contains(where: { $0.id == descriptor.id }) == false,
                      let agent = AgentRegistry.profile(id: descriptor.agentID) else { continue }
                let directory = URL(fileURLWithPath: descriptor.workspacePath, isDirectory: true)
                    .standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let transcript = await transcriptStore.entry(for: descriptor.id)
                let draft = try? await workspaceStateStore.draft(for: "chat|\(descriptor.id)")
                _ = appendChat(
                    id: descriptor.id,
                    agent: agent,
                    directory: directory,
                    title: descriptor.title
                        ?? "\(agent.name) · \(directory.lastPathComponent)",
                    resumeSessionID: descriptor.acpSessionID,
                    accountBinding: descriptor.accountBinding,
                    initialRows: transcript?.rows ?? [],
                    initialDraft: draft,
                    initialUsage: transcript?.usage
                )
            }

            for pane in projectState.panes {
                guard let descriptor = pane.surface.meshDescriptor,
                      meshes.contains(where: { $0.id == descriptor.id }) == false,
                      NativeSessionStore.projectID(forDirectory: descriptor.basePath) == descriptor.projectID else {
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
                    usageCenter: usageCenter
                )
                wireMeshPersistence(mesh)
                surfaceObservers[mesh.id] = mesh.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                meshes.append(mesh)

                var states: [MeshSession.RestoredColumnState] = []
                for column in descriptor.columns {
                    let transcript = await transcriptStore.entry(for: column.id)
                    states.append(MeshSession.RestoredColumnState(
                        descriptor: column,
                        rows: transcript?.rows ?? [],
                        initialDraft: nil,
                        usage: transcript?.usage
                    ))
                }
                let environment = ProcessInfo.processInfo.environment.merging(
                    ProjectAccountStore.mergedOverlay(
                        app: NativePreviewSettings.shared.agentEnvironmentOverlay,
                        project: ProjectAccountStore().override(forProject: descriptor.projectID)
                    )
                ) { _, custom in custom }
                await mesh.restore(states: states, agents: AgentRegistry.all, environment: environment)
                if mesh.lifecycle == .pendingDeletion,
                   mesh.restorationDescriptor.columns.isEmpty {
                    do {
                        try await workspaceStateStore.removeMeshState(
                            projectID: descriptor.projectID,
                            meshID: mesh.id
                        )
                        meshes.removeAll { $0.id == mesh.id }
                        Self.claimedRestoredMeshIDs.remove(mesh.id)
                        surfaceObservers.removeValue(forKey: mesh.id)?.cancel()
                        await persistWorkspaceStateImmediately(projectID: descriptor.projectID)
                    } catch {
                        // Keep the empty pending-deletion recovery surface. A
                        // later explicit retry can complete its tombstone;
                        // ordinary snapshots must never resurrect it as active.
                    }
                }
            }

            var layout = projectState.layout
            if connectionState.isConnected {
                let available = Set(
                    sessions.lazy.filter { $0.projectID == projectState.projectID }.map(\.id)
                ).union(chats(in: projectState.projectID).map(\.id))
                    .union(meshes(in: projectState.projectID).map(\.id))
                layout.normalize(availableSessionIDs: available)
            } else {
                layout.normalize()
            }
            paneLayouts[projectState.projectID] = layout
            restoreFileTabs(from: projectState)
        }

        if let projectID = restoration.selectedProjectID,
           let project = projects.first(where: { $0.id == projectID }) {
            selectedProjectID = project.id
            selectedProjectName = project.name
            if let state = restoration.projects.first(where: { $0.projectID == projectID }),
               let focused = state.focusedPaneID,
               paneLayouts[projectID]?.contains(focused) == true {
                focusedPaneID = focused
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
                : "Restored your saved workspace layout",
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
    func openChat(
        _ agent: AgentProfile,
        inDirectory directory: URL,
        accountProfile: UsageAccountProfile? = nil
    ) {
        let project = sessionStore.openProject(directory: directory.path)
        refreshPersistedNavigationState(publish: false)
        selectedProjectID = project.id
        selectedProjectName = project.name
        let chatID = "chat-\(UUID().uuidString.lowercased().prefix(8))"
        let projectOverlay = ProjectAccountStore.mergedOverlay(
            app: NativePreviewSettings.shared.agentEnvironmentOverlay,
            project: ProjectAccountStore().override(forProject: project.id)
        )
        let effectiveAccountEnvironment = ProcessInfo.processInfo.environment
            .merging(projectOverlay) { _, configured in configured }
        guard let accountBinding = SessionAccountBinding.resolve(
            agentID: agent.id,
            profile: accountProfile,
            fallbackEnvironment: effectiveAccountEnvironment
        ) else {
            ToastCenter.shared.show("That account does not match \(agent.name).", style: .error)
            return
        }
        guard appendChat(
            id: chatID,
            agent: agent,
            directory: directory,
            title: "\(agent.name) · \((directory.path as NSString).lastPathComponent)",
            resumeSessionID: nil,
            accountBinding: accountBinding,
            initialRows: [],
            initialDraft: nil,
            initialUsage: nil
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
        initialRows: [AcpTranscriptRow],
        initialDraft: String?,
        initialUsage: AcpPersistedUsage?
    ) -> AcpChatHandle? {
        guard chats.contains(where: { $0.id == chatID }) == false else { return nil }
        explicitlyClosedChatIDs.remove(chatID)
        let projectID = NativeSessionStore.projectID(forDirectory: directory.path)
        let mcp = McpConfigStore(workspace: directory).servers()
        let baseEnvironment = ProcessInfo.processInfo.environment.merging(
            ProjectAccountStore.mergedOverlay(
                app: NativePreviewSettings.shared.agentEnvironmentOverlay,
                project: ProjectAccountStore().override(forProject: projectID)
            )
        ) { _, custom in custom }
        let environment = SessionAccountBinding.applying(accountBinding, to: baseEnvironment)
        guard let adapter = AcpAdapter.forAgent(agent.id, environment: environment) else { return nil }
        // Legacy descriptors have no immutable account context. Starting a new
        // provider thread preserves the visible transcript without risking a
        // resume under credentials that differ from the original continuation.
        let safeResumeSessionID = accountBinding?.normalized == nil ? nil : resumeSessionID
        let conversation = AcpConversation(
            title: title,
            command: adapter.command,
            arguments: adapter.arguments,
            environment: environment,
            cwd: directory.path,
            mcpServers: McpConfigStore.jsonValues(mcp),
            sensitiveGlobs: NativePreviewSettings.shared.sensitiveGlobs,
            draftKey: chatID,
            resumeSessionID: safeResumeSessionID,
            initialRows: initialRows,
            initialDraft: initialDraft,
            initialUsage: initialUsage.map {
                AcpUsage(
                    used: $0.latestUsed,
                    max: $0.latestMax,
                    costAmount: $0.costAmount,
                    costCurrency: $0.costCurrency
                )
            }
        )
        usageCenter.register(chatID: chatID, sourceID: usageSourceID)
        if let initialUsage {
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
        conversation.onTranscriptChanged = { [weak self] rows in
            self?.enqueueTranscriptSave(rows, chatID: chatID)
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
        conversation.onProviderSessionID = { [weak self] _ in
            self?.scheduleWorkspaceStateSave(projectID: projectID)
        }
        let handle = AcpChatHandle(
            id: chatID,
            agentID: agent.id,
            workspaceDirectory: directory,
            accountBinding: accountBinding,
            conversation: conversation
        )
        chats.append(handle)
        surfaceObservers[chatID] = conversation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return handle
    }

    func closeChat(_ chatID: String) {
        let closingChat = chats.first(where: { $0.id == chatID })
        if let closingChat {
            // Quiesce persistence synchronously on MainActor before stop()
            // yields and lets already-buffered ACP events drain.
            explicitlyClosedChatIDs.insert(chatID)
            closingChat.conversation.onTranscriptChanged = nil
            closingChat.conversation.onDraftChanged = nil
            chatShutdownTasks.start(chatID) {
                _ = await closingChat.conversation.stop()
            }
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
            var layout = paneLayouts[projectID] ?? SessionPaneLayout()
            layout.remove(chatID)
            paneLayouts[projectID] = layout
            scheduleWorkspaceStateSave(projectID: projectID)
        }
        if forgetDurableChat { enqueueTranscriptRemoval(chatID: chatID) }
        enqueueDraftRemoval(chatID: chatID)
    }

    /// Stop the adapter without deleting the surface, transcript, or draft.
    /// The conversation can be restarted in place, so ordinary run control no
    /// longer has to go through the destructive close path.
    func stopChat(_ chatID: String) {
        guard let chat = chats.first(where: { $0.id == chatID }) else { return }
        Task { _ = await chat.conversation.stop() }
    }

    func selectChat(_ chatID: String?) {
        selectedChatID = chatID
        if let chatID {
            if let projectID = chats.first(where: { $0.id == chatID })?.projectID,
               let project = projects.first(where: { $0.id == projectID }) {
                selectedProjectID = project.id
                selectedProjectName = project.name
                focusPane(chatID, projectID: projectID)
            }
            selectedMeshID = nil
            focusedPaneID = chatID
            attentionCenter.clear(targetID: chatID)
        }
    }

    // MARK: - Kaisola Mesh

    enum MeshCloseResult: Equatable {
        case closed
        case needsConfirmation(columns: Int)
        case blocked(String)
        case unavailable
    }

    /// Live Mesh sessions (app-scoped, like chats).
    @Published private(set) var meshes: [MeshSession] = []
    @Published var selectedMeshID: String?

    /// Start a Mesh in a directory with every ACP-capable agent. `staged`
    /// runs the scout→execute pipeline; `idea` runs the read-only brainstorm.
    func openMesh(inDirectory directory: URL, staged: Bool = false, idea: Bool = false) {
        let agents = AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }
        guard !agents.isEmpty else { return }
        let project = sessionStore.openProject(directory: directory.path)
        refreshPersistedNavigationState(publish: false)
        selectedProjectID = project.id
        selectedProjectName = project.name
        let mesh = MeshSession(
            baseDirectory: directory,
            mode: staged ? .staged : .flat,
            purpose: idea ? .idea : .build,
            usageCenter: usageCenter
        )
        wireMeshPersistence(mesh)
        surfaceObservers[mesh.id] = mesh.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        meshes.append(mesh)
        selectedMeshID = mesh.id
        selectedChatID = nil
        focusPane(mesh.id, projectID: project.id)
        scheduleWorkspaceStateSave(projectID: project.id)
        let environment = ProcessInfo.processInfo.environment.merging(
            ProjectAccountStore.mergedOverlay(
                app: NativePreviewSettings.shared.agentEnvironmentOverlay,
                project: ProjectAccountStore().override(
                    forProject: NativeSessionStore.projectID(forDirectory: directory.path)
                )
            )
        ) { _, custom in custom }
        Task { await mesh.start(agents: agents, environment: environment) }
    }

    /// Central destructive-close policy. UI callers first request without
    /// authorization; only the destructive confirmation retries with
    /// `allowRecoverableWork`. Window/app/update teardown never enters here.
    func requestCloseMesh(_ meshID: String, allowRecoverableWork: Bool) async -> MeshCloseResult {
        guard let mesh = meshes.first(where: { $0.id == meshID }) else { return .unavailable }
        let columnIDs = mesh.durableColumnIDs
        let result = await mesh.destroy(allowRecoverableWork: allowRecoverableWork)
        switch result {
        case .safe:
            let projectID = mesh.projectID
            do {
                try await workspaceStateStore.removeMeshState(projectID: projectID, meshID: meshID)
            } catch {
                return .blocked("Mesh work was cleaned up, but the close tombstone could not be saved: \(error.localizedDescription)")
            }
            meshes.removeAll { $0.id == meshID }
            Self.claimedRestoredMeshIDs.remove(meshID)
            surfaceObservers.removeValue(forKey: meshID)?.cancel()
            if selectedMeshID == meshID { selectedMeshID = nil }
            var layout = paneLayouts[projectID] ?? SessionPaneLayout()
            layout.remove(meshID)
            paneLayouts[projectID] = layout
            for columnID in columnIDs { enqueueTranscriptRemoval(chatID: columnID) }
            enqueueDraftRemoval(stableKey: "mesh|\(meshID)")
            await persistWorkspaceStateImmediately(projectID: projectID)
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
            if let projectID = meshes.first(where: { $0.id == meshID })?.projectID,
               let project = projects.first(where: { $0.id == projectID }) {
                selectedProjectID = project.id
                selectedProjectName = project.name
                focusPane(meshID, projectID: projectID)
            }
            selectedChatID = nil
            focusedPaneID = meshID
        }
    }

    /// Full window teardown: stop every app-scoped process, persist its state,
    /// and drop broker connections. Mesh Git worktrees deliberately remain
    /// registered; only an explicit, safety-checked Close Mesh may destroy them.
    func teardown() async {
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
        chats.removeAll()
        for mesh in meshes {
            await mesh.suspend()
        }
        for task in meshShutdownTasks.values { await task.value }
        meshShutdownTasks.removeAll()
        // `suspend` updates lifecycle and can fence a worktree provision that
        // was already in flight. Flush that final safe manifest before the
        // window model releases its claim.
        await persistWorkspaceStateNow()
        for mesh in meshes { Self.claimedRestoredMeshIDs.remove(mesh.id) }
        meshes.removeAll()
        surfaceObservers.removeAll()
        splitIntentTokens.removeAll()
        await disconnect()
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
    func loadVisualFixture(workspace: URL, includeSplit: Bool = false) {
        usesVisualFixtureTransport = true
        let root = workspace.standardizedFileURL
        let project = sessionStore.openProject(directory: root.path)
        sessionStore.setProjectColor(id: project.id, colorHex: "7C5CFC")
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
                agentActivity: .idle
            ),
            BrokerTerminalRecord(
                id: fixtures[1].id,
                projectID: project.id,
                pid: 4_202,
                exited: false,
                streamEpoch: "visual-codex",
                endOffset: 0,
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

        let requestedResourceBytes = ProcessInfo.processInfo.environment[
            "KAISOLA_NATIVE_RESOURCE_SCROLLBACK_BYTES"
        ].flatMap(Int.init)
        let resourceScrollback: TerminalScrollback? = if visualSurface != "terminal-transcript",
                                                         visualSurface != "terminal-semantic",
                                                         visualSurface != "terminal-scroll-output",
                                                         let requestedResourceBytes,
                                                         requestedResourceBytes > 0 {
            VisualTerminalResourceFixture.scrollback(
                targetBytes: min(requestedResourceBytes, TerminalDocument.maximumRetainedBytes)
            )
        } else {
            nil
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
        paneLayouts[project.id] = SessionPaneLayout(sessionID: sessions[0].id)
        focusedPaneID = sessions[0].id

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
            paneLayouts[project.id]?.add(sessions[1].id)
        }
    }

    /// Feed the broker-free streaming fixture through the same 16 ms output
    /// batcher used by live PTYs. This is callable only from the declared
    /// hosted surface, so production sessions can never synthesize output.
    @discardableResult
    func enqueueVisualTerminalStreamingPacket(_ index: Int) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "terminal-scroll-output",
              VisualTerminalStreamingFixture.packetIndices.contains(index),
              let terminal = sessions.first,
              terminal.id == terminalDocument.sessionID,
              let cursor = terminalDocument.cursor else { return false }
        let data = VisualTerminalStreamingFixture.packet(index: index)
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
        guard ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"]
                == "terminal-scroll-output" else { return }
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

    func loadVisualMeshFixture(workspace: URL) {
        let mesh = MeshSession(baseDirectory: workspace.standardizedFileURL)
        mesh.loadVisualFixture()
        surfaceObservers[mesh.id] = mesh.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        meshes = [mesh]
        selectedMeshID = mesh.id
        selectedChatID = nil
        selectedSessionID = nil
        selectedProjectID = mesh.projectID
        selectedProjectName = projects.first(where: { $0.id == mesh.projectID })?.name
        paneLayouts[mesh.projectID] = SessionPaneLayout(sessionID: mesh.id)
        focusedPaneID = mesh.id
    }

    func loadVisualMixedSessionFixture(workspace: URL) {
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
                initialRows: [],
                initialDraft: "",
                initialUsage: nil
              ) else { return }
        chat.conversation.loadVisualFixture()
        var layout = paneLayouts[project.id] ?? SessionPaneLayout()
        layout.add(chat.id)
        paneLayouts[project.id] = layout
        selectedChatID = chat.id
        selectedMeshID = nil
        focusedPaneID = chat.id
    }

    func reload() async {
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
        draftRestoreSeed: TerminalDraftResumeSeed? = nil
    ) async -> String? {
        guard controlAvailable else {
            // Never fail silently: say WHY sessions can't be created here.
            publishPrimaryDocument(.failure(
                sessionID: "create-unavailable",
                message: connectionState.isConnected
                    ? "This terminal service is view-only right now, so new terminals are disabled. Chats and Mesh still work — they don't need it."
                    : "Kaisola isn't connected to its background terminal service, so new terminals are disabled. Chats and Mesh still work without it."
            ))
            return nil
        }
        let cwd = directory.path
        let projectID = NativeSessionStore.projectID(forDirectory: cwd)
        let terminalID = NativeSessionStore.terminalID(projectID: projectID)
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
        var overlay = ProjectAccountStore.mergedOverlay(
            app: NativePreviewSettings.shared.agentEnvironmentOverlay,
            project: ProjectAccountStore().override(forProject: projectID)
        )
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
        } else {
            accountBinding = nil
        }
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
                rows: 30
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
            // Ensure the session's folder is a persistent project tab.
            sessionStore.openProject(directory: cwd)
            refreshPersistedNavigationState(publish: false)
            ownedTerminalIDs.insert(terminalID)

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
            await select(terminalID)
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
        guard isOwned(terminalID),
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        let projectID = record.projectID
        trackTerminalDraftInput(data, terminalID: terminalID)
        let opensAgentTurn = (
            agentProfile(for: terminalID) != nil
                || detectedAgentNamesByTerminalID[terminalID] != nil
        ) && data.contains("\r")
        guard controlAvailable else {
            reportTerminalInputFailure(terminalID)
            return
        }
        terminalInputQueues[terminalID, default: []].append(PendingTerminalInput(
            projectID: projectID,
            data: data,
            opensAgentTurn: opensAgentTurn
        ))
        guard terminalInputDrainTasks[terminalID] == nil else { return }
        terminalInputDrainTasks[terminalID] = Task { [weak self] in
            await self?.drainTerminalInputQueue(terminalID)
        }
    }

    /// One consumer per PTY makes keyboard bytes FIFO by construction. The
    /// previous fire-and-forget Task per key depended on actor scheduling order
    /// and swallowed every mutation error.
    private func drainTerminalInputQueue(_ terminalID: String) async {
        defer { terminalInputDrainTasks[terminalID] = nil }
        while !Task.isCancelled,
              controlAvailable,
              isOwned(terminalID),
              var queue = terminalInputQueues[terminalID],
              !queue.isEmpty {
            let packet = queue.removeFirst()
            terminalInputQueues[terminalID] = queue
            do {
                try await controlClient.write(
                    projectID: packet.projectID,
                    terminalID: terminalID,
                    data: packet.data
                )
                if packet.opensAgentTurn {
                    try? await controlClient.setAgentTurn(
                        projectID: packet.projectID,
                        terminalID: terminalID,
                        busy: true
                    )
                }
            } catch {
                terminalInputQueues.removeValue(forKey: terminalID)
                reportTerminalInputFailure(terminalID)
                guard controlAvailable else { return }
                controlAvailable = false
                ownedTerminalIDs = []
                connectionLost(error, generation: connectionGeneration)
                return
            }
        }
        if terminalInputQueues[terminalID]?.isEmpty == true {
            terminalInputQueues.removeValue(forKey: terminalID)
        }
    }

    private func reportTerminalInputFailure(_ terminalID: String) {
        let now = Date()
        if let last = terminalInputFailureNoticeAt[terminalID],
           now.timeIntervalSince(last) < 2 { return }
        terminalInputFailureNoticeAt[terminalID] = now
        ToastCenter.shared.show(
            "Terminal connection is recovering; input was not sent",
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

    func setCompanionControlActive(_ active: Bool, for terminal: BrokerTerminalRecord) {
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
            try? await controlClient.setAgentTurn(
                projectID: current.projectID,
                terminalID: current.id,
                busy: true
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
              let controller = controlClient as? BrokerControlClient,
              let current = sessions.first(where: {
                  $0.id == terminal.id
                      && $0.projectID == terminal.projectID
                      && !$0.exited
              }),
              current.currentOwnerInstanceID == controller.connectionInstanceID else {
            return nil
        }
        return current
    }

    /// Ends an owned session for good: the PTY dies and the registry entry is
    /// removed. (App quit is different — quitting detaches and the shell keeps
    /// running on the broker.)
    func endSession(_ terminalID: String) async {
        guard isOwned(terminalID),
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        terminalDraftDebounceTasks.removeValue(forKey: terminalID)?.cancel()
        persistTerminalDraftNow(terminalID)
        await draftPersistenceTask?.value
        // Remember enough to recreate it (⌘⌥T), but do not mutate the local
        // registry unless the broker confirms the permanent close (or a
        // timeout races with a close that inventory can already prove).
        let closedSession = persistedOwnedSessions
            .first(where: { $0.id == terminalID })
            .map {
                ClosedSession(
                    cwd: $0.cwd,
                    agentID: $0.agentID,
                    title: $0.title,
                    accountBinding: $0.accountBinding,
                    sourceTerminalID: terminalID
                )
            }
        // terminal.kill leaves an exited diagnostic record behind; release is
        // the owner-gated permanent close and removes the spool + sidebar row.
        do {
            try await controlClient.release(projectID: record.projectID, terminalID: terminalID)
        } catch {
            await refreshInventory()
            guard !sessions.contains(where: { $0.id == terminalID }) else {
                ToastCenter.shared.show("Couldn't end session: \(error.kaisolaSafeDescription)", style: .error)
                return
            }
        }
        if let closedSession {
            sessionStore.pushClosedSession(closedSession)
        }
        sessionStore.remove(terminalID: terminalID)
        refreshPersistedNavigationState(publish: false)
        terminalResizeTasks.removeValue(forKey: terminalID)?.cancel()
        terminalResizeGeneration.removeValue(forKey: terminalID)
        desiredTerminalGeometry.removeValue(forKey: terminalID)
        lastTerminalSize.removeValue(forKey: terminalID)
        terminalInputDrainTasks.removeValue(forKey: terminalID)?.cancel()
        terminalInputQueues.removeValue(forKey: terminalID)
        terminalInputFailureNoticeAt.removeValue(forKey: terminalID)
        ownedTerminalIDs.remove(terminalID)
        companionControlledTerminalIDs.remove(terminalID)
        terminalSurfaceDocuments.removeValue(forKey: terminalID)
        terminalSurfaceOrder.removeAll { $0 == terminalID }
        terminalSurfaceFeeds.removeValue(forKey: terminalID)
        terminalDraftRestoreTasks.removeValue(forKey: terminalID)?.cancel()
        pendingTerminalDraftRestores.removeValue(forKey: terminalID)
        terminalLastOutputAt.removeValue(forKey: terminalID)
        terminalDraftTrackers.removeValue(forKey: terminalID)
        // Drop the parked SwiftTerm buffer too; this terminal cannot come back.
        TerminalSurfaceCache.shared.evict(sessionID: terminalID)
        if selectedSessionID == terminalID {
            selectedSessionID = nil
            await select(nil)
        }
        await refreshInventory()
    }

    /// Recreate the most recently ended session (⌘⌥T). Provider CLIs with a
    /// documented continuation command reopen their most recent conversation
    /// in the same locked account/workspace; other agents start fresh. The old
    /// PTY is gone, so the broker always creates a new terminal identity.
    func reopenLastClosedSession() async {
        guard let closed = sessionStore.popClosedSession() else { return }
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
        let created = await createOwnedSession(
            inDirectory: directory,
            agent: agent,
            lockedAccountBinding: closed.accountBinding,
            resumeAgent: agent?.resumeCommand != nil,
            titleOverride: closed.title,
            draftRestoreSeed: draftSeed
        )
        if created == nil {
            // A transient broker/account failure must not consume the user's
            // only reopen affordance or strand its private draft.
            sessionStore.pushClosedSession(closed)
        }
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
            if status.terminals != sessions {
                notifyInventoryCompletions(previous: sessions, next: status.terminals)
                sessions = status.terminals
                reconcileAllPaneLayoutsWithAvailableSurfaces()
            }
            if let activeBrokerUpgradeMonitor {
                let next = await activeBrokerUpgradeMonitor.attemptUpgradeIfNeeded()
                if next != brokerUpgradeState { brokerUpgradeState = next }
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

    /// Process-name + listening-port meta per owned native session, refreshed
    /// on a TTL so the inventory tick stays cheap.
    @Published private(set) var metaByTerminalID: [String: TerminalMeta] = [:]
    private var detectedAgentNamesByTerminalID: [String: String] = [:]
    private var lastMetaScan = Date.distantPast

    func meta(for terminalID: String) -> TerminalMeta? { metaByTerminalID[terminalID] }

    private func refreshMeta() {
        guard Date().timeIntervalSince(lastMetaScan) > 5 else { return }
        lastMetaScan = Date()
        let owned: [(String, Int32)] = sessions.compactMap {
            guard ownedTerminalIDs.contains($0.id), !$0.exited, let pid = $0.pid else { return nil }
            return ($0.id, pid)
        }
        Task.detached(priority: .utility) { [weak self] in
            var out: [String: TerminalMeta] = [:]
            for (id, pid) in owned { out[id] = TerminalMetaService.collect(pid: pid) }
            let collected = out
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.metaByTerminalID = collected
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
                self?.branchesByCwd = branches
                self?.branchScanTask = nil
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
    private func restoreOwnedSessions(info: BrokerInfo, generation: Int) async {
        controlAvailable = false
        ownedTerminalIDs = []
        await controlClient.setDisconnectHandler { [weak self] error in
            Task { @MainActor in
                guard let self, self.controlAvailable else { return }
                self.controlAvailable = false
                self.ownedTerminalIDs = []
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
            try await controlClient.connect(to: info, ownerID: sessionStore.ownerID())
        } catch {
            // Observation continues against brokers that refuse control.
            return
        }
        controlAvailable = true
        sessionStore.recoverOwnedSessions(from: sessions)
        refreshPersistedNavigationState(publish: false)
        var owned: Set<String> = []
        for stored in persistedOwnedSessions {
            guard let record = sessions.first(where: { $0.id == stored.id }) else {
                // This record may belong to the other broker in a dual-broker
                // drain. Absence from the current inventory is not deletion.
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
                // Another controller holds it; leave it observed.
            }
        }
        ownedTerminalIDs = owned
        // Layout may have reported its real size while inventory was visible
        // but before ownership finished restoring. Those callbacks are retained
        // above; ownership publication is the level-triggered flush point.
        for terminalID in owned {
            scheduleDesiredTerminalResize(terminalID, force: true)
        }
    }

    /// App-quit path: detach so owned shells keep running on the broker, then
    /// drop the controller connection.
    func releaseOwnedSessionsForQuit() async {
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
        for task in terminalInputDrainTasks.values { task.cancel() }
        terminalInputDrainTasks.removeAll()
        terminalInputQueues.removeAll()
        terminalInputFailureNoticeAt.removeAll()
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
        activeBrokerUpgradeMonitor = nil
        brokerUpgradeState = .unknown
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
            var hello: BrokerHello
            do {
                activeBrokerUpgradeMonitor = brokerPreparer as? any BrokerUpgradeMonitoring
                info = try await brokerPreparer.prepare()
                activeBrokerIdentity = info.persistenceIdentity
                hello = try await client.connect(to: info)
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
                info = try await fallbackPreparer.prepare()
                activeBrokerIdentity = info.persistenceIdentity
                hello = try await client.connect(to: info)
                usingSeparateBroker = true
            }
            let status = try await client.inventory()
            guard generation == connectionGeneration, shouldReconnect else { return false }
            await client.setDisconnectHandler { [weak self] error in
                Task { @MainActor in self?.connectionLost(error, generation: generation) }
            }

            notifyInventoryCompletions(previous: sessions, next: status.terminals)
            sessions = status.terminals
            connectedBrokerFeatures = hello.features
            brokerUpgradeState = await activeBrokerUpgradeMonitor?.upgradeState() ?? .unknown
            if restoredWorkspaceState {
                // A reconnect inventory is authoritative before any old split
                // subscription is restored. Prune finished ids in the same
                // main-actor turn so the UI never flashes a dead placeholder.
                reconcileAllPaneLayoutsWithAvailableSurfaces()
            }
            connectionState = .connected(
                version: hello.version + (usingSeparateBroker ? " · separate background service" : ""),
                pid: hello.pid,
                serverEnforcedObserver: hello.serverEnforcedObserver
            )
            await restoreOwnedSessions(info: info, generation: generation)
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

    private func consume(_ event: BrokerEvent) {
        // Agent activity updates the session's row even if it is the selected
        // one; it is scoped to the subscribed terminal like every other event.
        if case let .activity(busy, completedAt) = event.kind {
            applyActivity(busy: busy, completedAt: completedAt, to: event.terminalID)
        }
        guard event.ownerID == observerOwnerID else { return }

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

    private func scheduleTerminalOutputFlush() {
        guard terminalOutputFlushTask == nil else { return }
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
        guard let index = sessions.firstIndex(where: { $0.id == terminalID }) else { return }
        let wasWorking = { if case .working = sessions[index].agentActivity { return true }; return false }()
        if busy {
            sessions[index].agentActivity = .working
        } else if let completedAt {
            sessions[index].agentActivity = .responded(at: completedAt)
            // A completed terminal remains a needs-you moment until visited,
            // even if it finished in the currently visible project.
            if wasWorking {
                let detectedCLI = detectedAgentNamesByTerminalID[terminalID]
                attentionCenter.notifySessionResponded(
                    targetID: terminalID,
                    title: sessionTitle(for: sessions[index]),
                    detail: detectedCLI.map { "\($0) finished" } ?? "Agent responded",
                    completedAt: completedAt
                )
            }
        } else {
            sessions[index].agentActivity = .idle
        }
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
        guard let activeBrokerIdentity else { return nil }
        return TerminalCursorScope(
            brokerIdentity: activeBrokerIdentity,
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

private extension Error {
    var kaisolaSafeDescription: String {
        if let localized = self as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "The terminal observer could not connect. Everything already running was left untouched."
    }
}
