import Combine
import Darwin
import Foundation
import KaisolaCore

/// How a Mesh fans work out. `.flat` (v1 default) sends the SAME prompt to every
/// agent at once. `.staged` runs the scout → execute pipeline: one agent scouts
/// the repo read-only and writes a numbered task contract, then the rest execute
/// it in isolated worktrees. Orthogonal to `MeshPurpose`.
enum MeshMode: String, Codable, Equatable, Hashable, Sendable {
    case flat
    case staged
}

/// Why a Mesh is running. `.build` makes edits (worktrees, diffs, integrate).
/// `.idea` is a bounded read-only brainstorm — no worktrees regardless of repo,
/// one initial answer per column then a single automatic reaction pass.
enum MeshPurpose: String, Codable, Equatable, Hashable, Sendable {
    case build
    case idea
}

/// A column's role in the run. Flat build columns are `.peer`; a staged build
/// run has one `.scout` (read-only, shared base) and the rest `.executor`
/// (worktrees); an idea run's columns are all `.ideator` (read-only, shared).
enum MeshRole: String, Codable, Equatable, Hashable, Sendable {
    case peer
    case scout
    case executor
    case ideator
}

extension MeshRole {
    /// Roles that make edits get an isolated worktree; read-only roles (scout,
    /// ideator) share the base directory and never get one.
    var usesWorktree: Bool { self == .peer || self == .executor }
}

/// One Kaisola Mesh run: the same prompt fanned out to several agents, each in
/// its own ACP conversation — and, when the workspace is a git repo, each
/// editing role in an ISOLATED git worktree on a `kaisola-mesh-*` branch so
/// their edits can't collide. Columns stream independently; each can be diffed
/// against HEAD, and the human either integrates a winner's diff into the base
/// workspace or (idea mode) just reads the discussion.
@MainActor
final class MeshSession: ObservableObject, Identifiable {
    struct Column: Identifiable {
        let id: String
        let agent: AgentProfile
        let role: MeshRole
        let conversation: AcpConversation
        /// Immutable provider account context captured when this column began.
        /// Provider continuation ids are authoritative only alongside it.
        let accountBinding: SessionAccountBinding?
        /// The isolated worktree this column works in (nil = shared workspace).
        let worktreePath: String?
        let branch: String?
        let createdBaseOID: String?
    }

    /// A pure agent → role mapping, computed WITHOUT spawning anything so the
    /// assignment logic is unit-testable.
    struct RoleAssignment: Equatable, Sendable {
        let agent: AgentProfile
        let role: MeshRole
    }

    let id: String
    @Published var title: String {
        didSet { onDescriptorChanged?() }
    }
    let baseDirectory: URL
    let mode: MeshMode
    let purpose: MeshPurpose
    var projectID: String {
        NativeSessionStore.projectID(forDirectory: baseDirectory.path)
    }
    @Published private(set) var columns: [Column] = []
    /// Snapshot of the project-scoped ACP adapters and enabled MCP servers
    /// wired into this run. Exposed in the Mesh header so configuration is
    /// inspectable instead of being invisible launch state.
    @Published private(set) var configuredAgentNames: [String] = []
    @Published private(set) var configuredMCPServerNames: [String] = []
    /// Non-nil when isolation was requested but unavailable (not a repo).
    @Published private(set) var isolationNote: String?
    /// Pipeline phase for the header chip: "Scouting…"/"Executing…" (staged),
    /// "Ideating…"/"Reacting…" (idea), "Idle", or a timeout message. Meaningless
    /// for a flat build run.
    @Published private(set) var stage: String = "Idle"
    @Published private(set) var lifecycle: NativeMeshLifecycle
    @Published var draft: String {
        didSet { onDraftChanged?(draft) }
    }

    /// AppModel injects persistence without coupling Mesh to a concrete store.
    var onDescriptorChanged: (() -> Void)?
    /// Awaited at worktree transaction boundaries. AppModel writes the Mesh
    /// manifest before Git registration and immediately after adoption.
    var persistDescriptor: (() async throws -> Void)?
    var onTranscriptChanged: ((_ columnID: String, _ rows: [AcpTranscriptRow]) -> Void)?
    var onDraftChanged: ((String) -> Void)?

    private let fileManager: FileManager
    private let worktreeRoot: URL
    private let usageCenter: UsageCenter
    /// Relay each column's live conversation state through this Mesh object so
    /// parent project navigation can show accurate working activity.
    private var columnObservers = Set<AnyCancellable>()
    /// Drives the staged / idea handoff; cancelled on shutdown and restarted on
    /// each new staged/idea send.
    private var stageTask: Task<Void, Never>?
    /// Closing a Mesh can race the async repository/worktree probes in `start`.
    /// A generation guard prevents that suspended startup from resurrecting
    /// hidden columns or processes after shutdown.
    private var startupGeneration = 0
    private var isSuspended = false
    private var isDestroyed = false
    /// Column manifests written before `git worktree add`. If the app crashes
    /// between Git registration and ACP construction, restoration can still
    /// find and adopt the exact path/branch pair instead of orphaning it.
    private var provisioningColumns: [NativeRestorableMeshColumnDescriptor] = []
    private var retiredColumnIDs: Set<String> = []

    /// Transaction-boundary persistence is mandatory before any Git mutation.
    /// A missing or failed writer is treated as a safety failure, never as a
    /// successful save.
    private func persistBoundary(_ failureMessage: String) async -> Bool {
        guard let persistDescriptor else {
            isolationNote = failureMessage
            lifecycle = .recoveryRequired
            onDescriptorChanged?()
            return false
        }
        do {
            try await persistDescriptor()
            return true
        } catch {
            isolationNote = "\(failureMessage) \(error.localizedDescription)"
            lifecycle = .recoveryRequired
            onDescriptorChanged?()
            return false
        }
    }

    private func persistBestEffort() async {
        try? await persistDescriptor?()
    }

    init(
        id: String = "mesh-\(UUID().uuidString.lowercased().prefix(8))",
        baseDirectory: URL,
        mode: MeshMode = .flat,
        purpose: MeshPurpose = .build,
        title: String? = nil,
        lifecycle: NativeMeshLifecycle = .provisioning,
        initialDraft: String = "",
        worktreeRoot: URL = NativePreviewPaths.meshWorktreesDirectory,
        fileManager: FileManager = .default,
        usageCenter: UsageCenter = .shared
    ) {
        self.id = id
        self.baseDirectory = baseDirectory.standardizedFileURL
        self.mode = mode
        self.purpose = purpose
        self.title = title ?? "Mesh · \(baseDirectory.lastPathComponent)"
        self.lifecycle = lifecycle
        self.draft = initialDraft
        self.worktreeRoot = worktreeRoot.standardizedFileURL
        self.fileManager = fileManager
        self.usageCenter = usageCenter
    }

    /// Broker- and network-free columns for hosted visual QA. This is reachable
    /// only from the explicit visual-fixture launch path; production Mesh runs
    /// always go through `start` and current project ACP/MCP configuration.
    func loadVisualFixture(
        agents: [AgentProfile] = Array(AgentRegistry.builtIns.prefix(3)),
        mcpServerNames: [String] = ["filesystem", "github"]
    ) {
        configuredAgentNames = agents.map(\.name)
        configuredMCPServerNames = mcpServerNames
        columns = agents.map { agent in
            let conversation = AcpConversation(
                title: agent.name,
                command: "/usr/bin/true",
                arguments: [],
                cwd: baseDirectory.path
            )
            // MeshColumnView starts every conversation from a view task. Seed
            // the deterministic transcript *and* mark startup complete before
            // publishing the column so hosted capture never launches even the
            // benign `/usr/bin/true` adapter or races its exit callbacks.
            conversation.loadVisualFixture()
            return Column(
                id: "\(id)-visual-\(agent.id)",
                agent: agent,
                role: .peer,
                conversation: conversation,
                accountBinding: SessionAccountBinding.resolve(
                    agentID: agent.id,
                    profile: nil,
                    fallbackEnvironment: ProcessInfo.processInfo.environment
                ),
                worktreePath: nil,
                branch: nil,
                createdBaseOID: nil
            )
        }
        lifecycle = .active
    }

    /// Pure role assignment. `.idea` overrides mode — every column is a read-only
    /// ideator. Otherwise `.flat` → all peers; `.staged` → first agent scouts,
    /// the rest execute. No side effects, no spawning.
    nonisolated static func roles(for agents: [AgentProfile], mode: MeshMode, purpose: MeshPurpose = .build) -> [RoleAssignment] {
        if purpose == .idea {
            return agents.map { RoleAssignment(agent: $0, role: .ideator) }
        }
        switch mode {
        case .flat:
            return agents.map { RoleAssignment(agent: $0, role: .peer) }
        case .staged:
            return agents.enumerated().map { index, agent in
                RoleAssignment(agent: agent, role: index == 0 ? .scout : .executor)
            }
        }
    }

    /// Create a column per agent. An editing role attempts worktree isolation
    /// (and fails closed in a repo when it can't); read-only roles (scout,
    /// ideator) always share the base directory.
    func start(agents: [AgentProfile], environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard !isSuspended, !isDestroyed, columns.isEmpty else { return }
        startupGeneration &+= 1
        let generation = startupGeneration
        let service = GitService(repoRoot: baseDirectory)
        lifecycle = .provisioning
        onDescriptorChanged?()
        guard await persistBoundary("Could not save the Mesh recovery manifest — no agents were started.") else {
            return
        }
        // Publish the active project configuration immediately, before the
        // repo/isolation probe, so the Mesh opens with truthful chrome instead
        // of briefly reading “0 ACP · 0 MCP”.
        let serverConfigs = McpConfigStore(workspace: baseDirectory).servers()
        let mcp = McpConfigStore.jsonValues(serverConfigs)
        let usable = agents.filter { AcpAdapter.forAgent($0.id, environment: environment) != nil }
        configuredAgentNames = usable.map(\.name)
        configuredMCPServerNames = serverConfigs.filter(\.enabled).map(\.name)
        // A git workspace promises isolation; a plain folder never had it.
        // Distinguish the two so a worktree FAILURE in a repo fails closed
        // instead of silently fanning agents into one shared writable tree.
        enum RepositoryProbe: Sendable {
            case repository(baseOID: String)
            case plainFolder
            case failed(String)
        }
        let repoProbe = await Task.detached(priority: .userInitiated) { () -> RepositoryProbe in
            do {
                _ = try service.status()
                return .repository(baseOID: try service.headOID())
            } catch GitService.GitError.notARepository {
                return .plainFolder
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
        guard !isSuspended, !isDestroyed, startupGeneration == generation else { return }
        let baseOID: String?
        let baseIsRepo: Bool
        switch repoProbe {
        case let .repository(oid):
            baseOID = oid
            baseIsRepo = true
        case .plainFolder:
            baseOID = nil
            baseIsRepo = false
        case let .failed(message):
            baseOID = nil
            baseIsRepo = false
            isolationNote = "Could not verify repository safety — editing columns were not started. \(message)"
        }
        if baseIsRepo {
            do {
                try NativePreviewPaths.prepareMeshWorktrees(at: worktreeRoot)
            } catch {
                isolationNote = "Could not prepare durable Mesh storage — editing columns were not started."
            }
        }
        // Filtered adapter order determines role assignment (first = scout).
        for assignment in Self.roles(for: usable, mode: mode, purpose: purpose) {
            let agent = assignment.agent
            guard let accountBinding = SessionAccountBinding.resolve(
                agentID: agent.id,
                profile: nil,
                fallbackEnvironment: environment
            ) else { continue }
            let columnEnvironment = SessionAccountBinding.applying(accountBinding, to: environment)
            // Resolve adapters from the SAME environment the columns run with,
            // so a dev/test adapter override actually governs the spawn.
            guard let adapter = AcpAdapter.forAgent(agent.id, environment: columnEnvironment) else { continue }
            var worktree: String?
            var branch: String?
            var createdBaseOID: String?
            if assignment.role.usesWorktree, baseIsRepo {
                guard isolationNote == nil, let baseOID else { continue }
                let candidateBranch = "\(GitService.meshBranchPrefix)\(id.suffix(6))-\(agent.id)"
                let candidatePath = worktreeRoot
                    .appendingPathComponent("\(id)-\(agent.id)", isDirectory: true).path
                let columnID = "\(id)-\(agent.id)"
                let provisioning = NativeRestorableMeshColumnDescriptor(
                    id: columnID,
                    agentID: agent.id,
                    role: assignment.role,
                    worktreePath: candidatePath,
                    branch: candidateBranch,
                    createdBaseOID: baseOID,
                    acpSessionID: nil,
                    accountBinding: accountBinding,
                    provisioning: .provisioning,
                    workspaceKind: .worktree
                )
                provisioningColumns.append(provisioning)
                onDescriptorChanged?()
                guard await persistBoundary("Could not save the worktree manifest — provisioning stopped safely.") else {
                    return
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try service.worktreeAdd(
                            path: candidatePath,
                            branch: candidateBranch,
                            startPoint: baseOID
                        )
                    }.value
                    guard !isSuspended, !isDestroyed, startupGeneration == generation else {
                        // A lifecycle teardown never destroys recoverable work.
                        // Leave the registered pair in the durable manifest.
                        provisioningColumns = provisioningColumns.map { existing in
                            existing.id == columnID
                                ? NativeRestorableMeshColumnDescriptor(
                                    id: existing.id,
                                    agentID: existing.agentID,
                                    role: existing.role,
                                    worktreePath: existing.worktreePath,
                                    branch: existing.branch,
                                    createdBaseOID: existing.createdBaseOID,
                                    acpSessionID: existing.acpSessionID,
                                    accountBinding: existing.accountBinding,
                                    provisioning: .recoveryRequired,
                                    workspaceKind: existing.workspaceKind
                                )
                                : existing
                        }
                        lifecycle = .recoveryRequired
                        await persistBestEffort()
                        return
                    }
                    worktree = candidatePath
                    branch = candidateBranch
                    createdBaseOID = baseOID
                    provisioningColumns.removeAll { $0.id == columnID }
                } catch {
                    // Fail closed: no isolated column, no column at all.
                    provisioningColumns.removeAll { $0.id == columnID }
                    isolationNote = "Could not create a worktree for \(agent.name) — column skipped."
                    onDescriptorChanged?()
                    guard await persistBoundary("Could not save the worktree failure state — provisioning stopped safely.") else {
                        return
                    }
                    continue
                }
            } else if assignment.role.usesWorktree {
                if case .plainFolder = repoProbe {
                    isolationNote = "Not a git repo — columns share the workspace (no isolation)."
                } else {
                    // Any ambiguous Git probe fails closed. Read-only scout /
                    // ideator roles may still run, but writers never share a
                    // directory whose repository status could not be proven.
                    continue
                }
            }
            let cwd = worktree ?? baseDirectory.path
            let columnID = "\(id)-\(agent.id)"
            let conversation = makeConversation(
                columnID: columnID,
                agent: agent,
                adapter: adapter,
                environment: columnEnvironment,
                cwd: cwd,
                mcp: mcp
            )
            columns.append(Column(
                id: columnID,
                agent: agent,
                role: assignment.role,
                conversation: conversation,
                accountBinding: accountBinding,
                worktreePath: worktree,
                branch: branch,
                createdBaseOID: createdBaseOID
            ))
            onDescriptorChanged?()
            guard await persistBoundary("Could not save the attached Mesh column — agents were suspended safely.") else {
                return
            }
        }
        for column in columns {
            guard !isSuspended, !isDestroyed, startupGeneration == generation else { return }
            await column.conversation.start()
        }
        lifecycle = provisioningColumns.isEmpty ? .active : .recoveryRequired
        onDescriptorChanged?()
        _ = await persistBoundary("Could not save the active Mesh manifest — recovery remains required.")
    }

    struct RestoredColumnState: Sendable {
        let descriptor: NativeRestorableMeshColumnDescriptor
        let rows: [AcpTranscriptRow]
        let initialDraft: String?
        let usage: AcpPersistedUsage?
    }

    enum DiscardAssessment: Equatable, Sendable {
        case safe
        case recoverableWork(columns: Int)
        case blocked(String)
    }

    var restorationDescriptor: NativeRestorableMeshDescriptor {
        let live = columns.map { column in
            NativeRestorableMeshColumnDescriptor(
                id: column.id,
                agentID: column.agent.id,
                role: column.role,
                worktreePath: column.worktreePath,
                branch: column.branch,
                createdBaseOID: column.createdBaseOID,
                acpSessionID: column.conversation.providerSessionID,
                accountBinding: column.accountBinding,
                provisioning: .attached,
                workspaceKind: column.worktreePath == nil ? .base : .worktree
            )
        }
        return NativeRestorableMeshDescriptor(
            id: id,
            projectID: projectID,
            basePath: baseDirectory.path,
            title: title,
            mode: mode,
            purpose: purpose,
            lifecycle: lifecycle,
            columns: live + provisioningColumns
        )
    }

    var durableColumnIDs: [String] {
        Array(Set(columns.map(\.id) + provisioningColumns.map(\.id)).union(retiredColumnIDs)).sorted()
    }

    /// Rebuild a suspended Mesh from its manifest without creating branches or
    /// resending prompts. Each exact worktree path/branch pair is verified
    /// against Git before an ACP column is allowed to adopt it.
    func restore(
        states: [RestoredColumnState],
        agents: [AgentProfile],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        guard !isDestroyed, columns.isEmpty else { return }
        let serverConfigs = McpConfigStore(workspace: baseDirectory).servers()
        let mcp = McpConfigStore.jsonValues(serverConfigs)
        configuredMCPServerNames = serverConfigs.filter(\.enabled).map(\.name)
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let baseService = GitService(repoRoot: baseDirectory)
        var recovery: [NativeRestorableMeshColumnDescriptor] = []
        let worktreeRootIsSafe: Bool
        do {
            try NativePreviewPaths.prepareMeshWorktrees(at: worktreeRoot)
            worktreeRootIsSafe = true
        } catch {
            worktreeRootIsSafe = false
            isolationNote = "Mesh storage failed its ownership and permissions check; worktrees were preserved without launching agents."
        }

        for state in states {
            let descriptor = state.descriptor
            guard let agent = byID[descriptor.agentID] else {
                recovery.append(Self.recoveryDescriptor(descriptor))
                continue
            }
            let hadPersistedBinding = descriptor.accountBinding != nil
            let accountBinding: SessionAccountBinding
            if let persisted = descriptor.accountBinding?.normalized {
                guard SessionAccountBinding.provider(forAgentID: agent.id) == persisted.provider else {
                    recovery.append(Self.recoveryDescriptor(descriptor))
                    continue
                }
                accountBinding = persisted
            } else {
                guard let current = SessionAccountBinding.resolve(
                    agentID: agent.id,
                    profile: nil,
                    fallbackEnvironment: environment
                ) else {
                    recovery.append(Self.recoveryDescriptor(descriptor))
                    continue
                }
                accountBinding = current
            }
            let columnEnvironment = SessionAccountBinding.applying(accountBinding, to: environment)
            guard let adapter = AcpAdapter.forAgent(agent.id, environment: columnEnvironment) else {
                recovery.append(Self.recoveryDescriptor(descriptor))
                continue
            }
            var cwd = baseDirectory.path
            if descriptor.workspaceKind == .worktree {
                guard worktreeRootIsSafe,
                      let path = descriptor.worktreePath,
                      let branch = descriptor.branch,
                      descriptor.createdBaseOID != nil,
                      isOwnedWorktreePath(path, agentID: descriptor.agentID) else {
                    recovery.append(Self.recoveryDescriptor(descriptor))
                    continue
                }
                let exists = fileManager.fileExists(atPath: path)
                let registered: Bool
                let branchExists: Bool
                do {
                    registered = try baseService.isRegisteredWorktree(path: path, branch: branch)
                    branchExists = try baseService.branchExists(branch)
                } catch {
                    recovery.append(Self.recoveryDescriptor(descriptor))
                    continue
                }
                if !exists || !registered {
                    if (descriptor.provisioning == .provisioning || lifecycle == .pendingDeletion),
                       !exists, !registered, !branchExists {
                        // Crash happened before `git worktree add`; no work was
                        // ever created, so the preflight manifest is safe to clear.
                        continue
                    }
                    recovery.append(Self.recoveryDescriptor(descriptor))
                    continue
                }
                cwd = path
            }
            let conversation = makeConversation(
                columnID: descriptor.id,
                agent: agent,
                adapter: adapter,
                environment: columnEnvironment,
                cwd: cwd,
                mcp: mcp,
                // A pre-binding manifest has no proof of which credentials
                // own its provider id. Restore the transcript but start fresh.
                resumeSessionID: hadPersistedBinding ? descriptor.acpSessionID : nil,
                initialRows: state.rows,
                initialDraft: state.initialDraft,
                initialUsage: state.usage
            )
            columns.append(Column(
                id: descriptor.id,
                agent: agent,
                role: descriptor.role,
                conversation: conversation,
                accountBinding: accountBinding,
                worktreePath: descriptor.worktreePath,
                branch: descriptor.branch,
                createdBaseOID: descriptor.createdBaseOID
            ))
        }
        provisioningColumns = recovery
        configuredAgentNames = columns.map(\.agent.name)
        if !recovery.isEmpty {
            lifecycle = .recoveryRequired
        } else if lifecycle != .pendingDeletion || !columns.isEmpty {
            lifecycle = .suspended
        }
        if !recovery.isEmpty {
            isolationNote = "Some worktrees need recovery; preserved without deletion."
        }
        isSuspended = false // restored conversations start lazily when visible
        onDescriptorChanged?()
    }

    /// Stop app-owned adapters while preserving every Git path, branch,
    /// transcript, and manifest. Used for window close, quit, and update.
    func suspend() async {
        guard !isDestroyed, !isSuspended else { return }
        isSuspended = true
        startupGeneration &+= 1
        stageTask?.cancel()
        stageTask = nil
        stage = "Interrupted"
        for column in columns {
            _ = await column.conversation.stop()
        }
        lifecycle = provisioningColumns.isEmpty ? .suspended : .recoveryRequired
        onDescriptorChanged?()
        await persistBestEffort()
    }

    /// Inventory uncommitted files AND unique commits. Any probe failure blocks
    /// deletion; uncertainty must never be treated as a clean worktree.
    func discardAssessment() async -> DiscardAssessment {
        let editing = columns.filter { $0.worktreePath != nil || $0.branch != nil }
        let pendingEditing = provisioningColumns.filter { $0.workspaceKind == .worktree }
        guard pendingEditing.isEmpty else {
            return .blocked("Mesh is still provisioning or needs recovery; its worktrees were preserved.")
        }
        var atRisk = 0
        let baseDirectory = baseDirectory
        for column in editing {
            guard let path = column.worktreePath,
                  let branch = column.branch,
                  let baseOID = column.createdBaseOID,
                  isOwnedWorktreePath(path, agentID: column.agent.id) else {
                return .blocked("A Mesh worktree manifest is incomplete; nothing was deleted.")
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<GitService.MeshDiscardInventory, Error> in
                do {
                    let baseService = GitService(repoRoot: baseDirectory)
                    guard try baseService.isRegisteredWorktree(path: path, branch: branch) else {
                        throw GitService.GitError.commandFailed("The Mesh worktree is no longer registered.")
                    }
                    let worktreeService = GitService(repoRoot: URL(fileURLWithPath: path, isDirectory: true))
                    return .success(try worktreeService.meshDiscardInventory(createdBaseOID: baseOID))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case let .success(inventory):
                if inventory.hasRecoverableWork { atRisk += 1 }
            case let .failure(error):
                return .blocked("Could not verify \(column.agent.name)'s worktree: \(error.localizedDescription)")
            }
        }
        return atRisk == 0 ? .safe : .recoverableWork(columns: atRisk)
    }

    /// The only destructive lifecycle path. The caller must have obtained an
    /// explicit user confirmation when the assessment reports recoverable work.
    /// Failure leaves the manifest present and retryable.
    func destroy(allowRecoverableWork: Bool) async -> DiscardAssessment {
        await suspend()
        let assessment = await discardAssessment()
        switch assessment {
        case .safe:
            break
        case .recoverableWork where allowRecoverableWork:
            break
        case .recoverableWork, .blocked:
            return assessment
        }
        lifecycle = .pendingDeletion
        onDescriptorChanged?()
        guard await persistBoundary("Could not save the deletion manifest — nothing was deleted.") else {
            return .blocked(isolationNote ?? "Could not save the deletion manifest — nothing was deleted.")
        }

        let service = GitService(repoRoot: baseDirectory)
        let editingColumns = columns.filter { $0.worktreePath != nil || $0.branch != nil }
        for column in editingColumns {
            guard let path = column.worktreePath, let branch = column.branch else {
                lifecycle = .recoveryRequired
                await persistBestEffort()
                return .blocked("A Mesh cleanup manifest is incomplete; nothing else was deleted.")
            }
            do {
                try await Task.detached(priority: .utility) {
                    try service.worktreeRemove(path: path, branch: branch)
                }.value
                // Persist each successful cleanup before attempting the next.
                // A later Git failure therefore leaves only the genuinely
                // remaining pair in the retryable manifest.
                columns.removeAll { $0.id == column.id }
                retiredColumnIDs.insert(column.id)
                usageCenter.remove(chatID: column.id)
                onDescriptorChanged?()
                guard await persistBoundary("Cleanup paused because the updated recovery manifest could not be saved.") else {
                    return .blocked(isolationNote ?? "Cleanup paused because the recovery manifest could not be saved.")
                }
            } catch {
                lifecycle = .recoveryRequired
                await persistBestEffort()
                return .blocked("Mesh cleanup stopped: \(error.localizedDescription)")
            }
        }
        isDestroyed = true
        lifecycle = .pendingDeletion
        for column in columns { usageCenter.remove(chatID: column.id) }
        columnObservers.removeAll()
        columns.removeAll()
        provisioningColumns.removeAll()
        retiredColumnIDs.removeAll()
        onDescriptorChanged?()
        guard await persistBoundary("Mesh cleanup completed, but its final tombstone could not be saved.") else {
            return .blocked(isolationNote ?? "Mesh cleanup completed, but its final tombstone could not be saved.")
        }
        return .safe
    }

    private func makeConversation(
        columnID: String,
        agent: AgentProfile,
        adapter: AcpAdapter,
        environment: [String: String],
        cwd: String,
        mcp: [JSONValue],
        resumeSessionID: String? = nil,
        initialRows: [AcpTranscriptRow] = [],
        initialDraft: String? = nil,
        initialUsage: AcpPersistedUsage? = nil
    ) -> AcpConversation {
        let conversation = AcpConversation(
            title: agent.name,
            command: adapter.command,
            arguments: adapter.arguments,
            environment: environment,
            cwd: cwd,
            mcpServers: mcp,
            sensitiveGlobs: NativePreviewSettings.shared.sensitiveGlobs,
            draftKey: columnID,
            resumeSessionID: resumeSessionID,
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
        conversation.onTranscriptChanged = { [weak self] rows in
            self?.onTranscriptChanged?(columnID, rows)
        }
        conversation.onProviderSessionID = { [weak self] _ in
            guard let self else { return }
            if self.lifecycle == .suspended { self.lifecycle = .active }
            self.onDescriptorChanged?()
        }
        conversation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &columnObservers)
        let usageTitle = "\(title) · \(agent.name)"
        conversation.$usage
            .compactMap { $0 }
            .sink { [weak self] usage in
                self?.usageCenter.record(
                    chatID: columnID,
                    title: usageTitle,
                    agentID: agent.id,
                    usage: usage.used,
                    max: usage.max,
                    costAmount: usage.costAmount,
                    costCurrency: usage.costCurrency
                )
            }
            .store(in: &columnObservers)
        conversation.$isRunning
            .scan((false, false)) { ($0.1, $1) }
            .filter { $0.0 && !$0.1 }
            .sink { [weak self] _ in self?.usageCenter.recordTurn(chatID: columnID) }
            .store(in: &columnObservers)
        return conversation
    }

    private func isOwnedWorktreePath(_ path: String, agentID: String) -> Bool {
        let rootURL = worktreeRoot.standardizedFileURL
        let expected = rootURL
            .appendingPathComponent("\(id)-\(agentID)", isDirectory: true)
            .standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard candidate.path == expected.path,
              candidate.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path,
              expected.resolvingSymlinksInPath().path.hasPrefix(
                rootURL.resolvingSymlinksInPath().path + "/"
              ) else {
            return false
        }
        // Existing worktrees must be real, user-owned directories. A symlink
        // swapped into the durable root is never adopted or deleted.
        var metadata = stat()
        if lstat(candidate.path, &metadata) == 0 {
            return metadata.st_uid == getuid() && metadata.st_mode & S_IFMT == S_IFDIR
        }
        return errno == ENOENT
    }

    private static func recoveryDescriptor(
        _ descriptor: NativeRestorableMeshColumnDescriptor
    ) -> NativeRestorableMeshColumnDescriptor {
        NativeRestorableMeshColumnDescriptor(
            id: descriptor.id,
            agentID: descriptor.agentID,
            role: descriptor.role,
            worktreePath: descriptor.worktreePath,
            branch: descriptor.branch,
            createdBaseOID: descriptor.createdBaseOID,
            acpSessionID: descriptor.acpSessionID,
            accountBinding: descriptor.accountBinding,
            provisioning: .recoveryRequired,
            workspaceKind: descriptor.workspaceKind
        )
    }

    /// Fan the prompt out to every connected column (each queues if busy).
    /// Flat build mode and manual sends use this directly.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for column in columns {
            column.conversation.send(trimmed)
        }
    }

    // MARK: - Staged build pipeline

    /// Staged send: prompt the SCOUT only; when its turn ends, auto-fan the
    /// original prompt + the scout's contract to the executors. Falls back to a
    /// flat fan-out when the session isn't staged or has no scout column.
    func sendStaged(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard mode == .staged, purpose == .build,
              let scout = columns.first(where: { $0.role == .scout }) else {
            send(trimmed)
            return
        }
        stageTask?.cancel()
        stage = "Scouting…"
        let scoutID = scout.id
        scout.conversation.send(Self.scoutPrompt(for: trimmed))
        stageTask = Task { [weak self] in
            await self?.runStagedPipeline(originalPrompt: trimmed, scoutID: scoutID)
        }
    }

    /// Wait (bounded) for the scout's turn to finish, then fan the original
    /// prompt + the scout's contract to the executors, tracking them to Idle.
    /// A >10-minute scout surfaces a timeout stage and stops waiting; never
    /// crashes.
    private func runStagedPipeline(originalPrompt: String, scoutID: String) async {
        let deadline = Date().addingTimeInterval(10 * 60)
        var sawScoutRun = false
        while true {
            if Task.isCancelled { return }
            if Date() >= deadline {
                stage = "Scout timed out — send again or use flat mode"
                return
            }
            let running = columns.first(where: { $0.id == scoutID })?.conversation.isRunning ?? false
            if running { sawScoutRun = true }
            if sawScoutRun && !running { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if Task.isCancelled { return }
        let rows = columns.first(where: { $0.id == scoutID })?.conversation.rows ?? []
        let contract = Self.lastMessageText(in: rows)
        let executors = columns.filter { $0.role == .executor }
        let executorIDs = executors.map(\.id)
        let prompt = Self.executorPrompt(original: originalPrompt, contract: contract)
        stage = executorIDs.isEmpty ? "Idle" : "Executing…"
        for column in executors {
            column.conversation.send(prompt)
        }
        await waitForSettle(columnIDs: executorIDs)
        if Task.isCancelled { return }
        stage = "Idle"
    }

    // MARK: - Idea brainstorm cycle

    /// Idea send: every column answers the prompt concurrently (no peer content,
    /// no edits), then — after all initial turns end — exactly ONE reaction pass
    /// runs where each column reacts to its peers' answers. Bounded to two turns
    /// per send. Falls back to a flat fan-out when the session isn't idea mode.
    func sendIdea(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard purpose == .idea, !columns.isEmpty else {
            send(trimmed)
            return
        }
        stageTask?.cancel()
        stage = "Ideating…"
        let initial = Self.ideaInitialPrompt(for: trimmed)
        let columnIDs = columns.map(\.id)
        for column in columns {
            column.conversation.send(initial)
        }
        stageTask = Task { [weak self] in
            await self?.runIdeaCycle(originalPrompt: trimmed, columnIDs: columnIDs)
        }
    }

    /// Wait for every column's initial turn to finish, snapshot each answer, then
    /// fan a single reaction pass (each column reacts to the OTHERS' answers) and
    /// track it to Idle. Bounded; never crashes.
    private func runIdeaCycle(originalPrompt: String, columnIDs: [String]) async {
        await waitForSettle(columnIDs: columnIDs, timeoutStage: "Idea timed out — send again")
        if Task.isCancelled { return }
        // Snapshot each column's final initial answer.
        let answers: [(id: String, agent: String, answer: String)] = columns
            .filter { columnIDs.contains($0.id) }
            .map { ($0.id, $0.agent.name, Self.lastMessageText(in: $0.conversation.rows)) }
        stage = "Reacting…"
        for column in columns where columnIDs.contains(column.id) {
            let peers = answers
                .filter { $0.id != column.id }
                .map { (agent: $0.agent, answer: $0.answer) }
            let prompt = Self.ideaReactionPrompt(agent: column.agent.name, original: originalPrompt, peerAnswers: peers)
            column.conversation.send(prompt)
        }
        await waitForSettle(columnIDs: columnIDs)
        if Task.isCancelled { return }
        stage = "Idle"
    }

    /// Poll until the given columns have all been running and then all stopped —
    /// i.e. their current turns have settled. Bounded: a 30s grace covers the
    /// "never started" case, and `timeoutStage`, when given, sets the stage on a
    /// 10-minute hard cap. Cancellation returns early.
    private func waitForSettle(columnIDs: [String], timeoutStage: String? = nil) async {
        guard !columnIDs.isEmpty else { return }
        var sawRunning = false
        let startGrace = Date().addingTimeInterval(30)
        let hardDeadline = Date().addingTimeInterval(10 * 60)
        while true {
            if Task.isCancelled { return }
            if let timeoutStage, Date() >= hardDeadline {
                stage = timeoutStage
                return
            }
            let running = columns.contains { columnIDs.contains($0.id) && $0.conversation.isRunning }
            if running { sawRunning = true }
            if sawRunning && !running { return }
            if !sawRunning && Date() >= startGrace { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    var anyRunning: Bool {
        columns.contains { $0.conversation.isRunning }
    }

    /// A column's working-tree diff vs HEAD (worktree columns only).
    func diff(for columnID: String) async -> String {
        guard let column = columns.first(where: { $0.id == columnID }),
              let path = column.worktreePath else { return "" }
        let service = GitService(repoRoot: URL(fileURLWithPath: path, isDirectory: true))
        let baseOID = column.createdBaseOID
        return await Task.detached(priority: .userInitiated) {
            if let baseOID { return (try? service.diffAgainstBase(baseOID)) ?? "" }
            return (try? service.diffAgainstHead()) ?? ""
        }.value
    }

    /// Per-worktree review lines for judging the run: files changed + rough +/-
    /// line counts, parsed from each editing column's diff against HEAD. Read-only
    /// columns (scout, ideator) have no worktree and are skipped.
    func reviewSummaries() async -> [(columnID: String, agent: String, diffStat: String)] {
        var summaries: [(columnID: String, agent: String, diffStat: String)] = []
        for column in columns {
            guard let path = column.worktreePath else { continue }
            let baseOID = column.createdBaseOID
            let patch = await Task.detached(priority: .userInitiated) { () -> String in
                let service = GitService(repoRoot: URL(fileURLWithPath: path, isDirectory: true))
                if let baseOID { return (try? service.diffAgainstBase(baseOID)) ?? "" }
                return (try? service.diffAgainstHead()) ?? ""
            }.value
            summaries.append((columnID: column.id, agent: column.agent.name, diffStat: MeshDiffStats.stat(fromPatch: patch)))
        }
        return summaries
    }

    // MARK: - Prompt composition (pure, testable)

    /// The last agent message in a transcript — the column's "final answer" for
    /// the scout contract and idea snapshots.
    nonisolated static func lastMessageText(in rows: [AcpTranscriptRow]) -> String {
        for row in rows.reversed() {
            if case let .message(_, text) = row { return text }
        }
        return ""
    }

    /// Staged phase 1: the scout analyzes the repo + request read-only and emits
    /// a numbered task contract. Makes NO edits.
    nonisolated static func scoutPrompt(for prompt: String) -> String {
        """
        [Kaisola Mesh · SCOUT] You are the scout in a staged multi-agent run. Read \
        the repository and the request below, then produce a NUMBERED task \
        contract: an ordered list of concrete, self-contained implementation steps \
        the executor agents will follow. Analysis only — make NO edits, create no \
        files, and run no write commands. Finish with the numbered contract.

        Request:
        \(prompt)
        """
    }

    /// Staged phase 2: an executor implements the request by following the
    /// scout's contract, editing in its own worktree.
    nonisolated static func executorPrompt(original: String, contract: String) -> String {
        let trimmed = contract.trimmingCharacters(in: .whitespacesAndNewlines)
        let contractSection = trimmed.isEmpty
            ? "(The scout produced no contract — use your best judgment to satisfy the request.)"
            : trimmed
        return """
        [Kaisola Mesh · EXECUTOR] You are an executor in a staged multi-agent run. \
        Implement the request by following the scout's numbered task contract, \
        making the actual code edits in this worktree.

        Original request:
        \(original)

        Scout's task contract:
        \(contractSection)
        """
    }

    /// Idea pass 1: each column gives its own concise take, no peer content, no
    /// edits.
    nonisolated static func ideaInitialPrompt(for prompt: String) -> String {
        """
        [Kaisola Mesh · IDEA] You are one voice in a group brainstorm. Give your \
        own concise proposal or answer to the request below. Discussion only — \
        make NO file edits, run no commands, change no state. Be brief and specific.

        Request:
        \(prompt)
        """
    }

    /// Idea pass 2 (the single reaction pass): the column reacts to its peers'
    /// answers. Pure composition from the peer answers — unit-testable.
    nonisolated static func ideaReactionPrompt(agent: String, original: String, peerAnswers: [(agent: String, answer: String)]) -> String {
        let peers = peerAnswers
            .map { "\($0.agent):\n\($0.answer)" }
            .joined(separator: "\n\n---\n\n")
        let peerSection = peers.isEmpty ? "(No peer answers.)" : peers
        return """
        [Kaisola Mesh · IDEA] You are \(agent). Everyone has answered. React \
        briefly: strongest idea, one risk, one improvement. Discussion only — \
        make no edits, run no commands, change no state.

        Original request:
        \(original)

        Peer answers:
        \(peerSection)
        """
    }
}

/// Pure unified-diff stat reducer: files changed + added/removed line counts,
/// computed by parsing the patch text in Swift (no shelling out). Kept free of
/// the main actor so the review path and tests can call it directly.
enum MeshDiffStats {
    static func stat(fromPatch patch: String) -> String {
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No changes"
        }
        var files = 0
        var added = 0
        var removed = 0
        patch.enumerateLines { line, _ in
            if line.hasPrefix("diff --git ") {
                files += 1
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                // File headers — not content lines. (Checked before +/-.)
            } else if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                removed += 1
            }
        }
        if files == 0 {
            // A raw diff without `diff --git` headers: count new-file headers.
            patch.enumerateLines { line, _ in
                if line.hasPrefix("+++ ") { files += 1 }
            }
        }
        let noun = files == 1 ? "file" : "files"
        return "\(files) \(noun) changed, +\(added) -\(removed)"
    }
}
