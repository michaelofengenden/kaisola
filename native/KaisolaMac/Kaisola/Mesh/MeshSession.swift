import Combine
import Foundation

/// How a Mesh fans work out. `.flat` (v1 default) sends the SAME prompt to every
/// agent at once. `.staged` runs the scout → execute pipeline: one agent scouts
/// the repo read-only and writes a numbered task contract, then the rest execute
/// it in isolated worktrees. Orthogonal to `MeshPurpose`.
enum MeshMode: Equatable, Sendable {
    case flat
    case staged
}

/// Why a Mesh is running. `.build` makes edits (worktrees, diffs, integrate).
/// `.idea` is a bounded read-only brainstorm — no worktrees regardless of repo,
/// one initial answer per column then a single automatic reaction pass.
enum MeshPurpose: Equatable, Sendable {
    case build
    case idea
}

/// A column's role in the run. Flat build columns are `.peer`; a staged build
/// run has one `.scout` (read-only, shared base) and the rest `.executor`
/// (worktrees); an idea run's columns are all `.ideator` (read-only, shared).
enum MeshRole: String, Equatable, Sendable {
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
        /// The isolated worktree this column works in (nil = shared workspace).
        let worktreePath: String?
        let branch: String?
    }

    /// A pure agent → role mapping, computed WITHOUT spawning anything so the
    /// assignment logic is unit-testable.
    struct RoleAssignment: Equatable, Sendable {
        let agent: AgentProfile
        let role: MeshRole
    }

    let id: String
    let title: String
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

    private let fileManager = FileManager.default
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
    private var isShutDown = false

    init(
        id: String = "mesh-\(UUID().uuidString.lowercased().prefix(8))",
        baseDirectory: URL,
        mode: MeshMode = .flat,
        purpose: MeshPurpose = .build
    ) {
        self.id = id
        self.baseDirectory = baseDirectory
        self.mode = mode
        self.purpose = purpose
        self.title = "Mesh · \(baseDirectory.lastPathComponent)"
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
            return Column(
                id: "\(id)-visual-\(agent.id)",
                agent: agent,
                role: .peer,
                conversation: conversation,
                worktreePath: nil,
                branch: nil
            )
        }
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
        guard !isShutDown else { return }
        startupGeneration &+= 1
        let generation = startupGeneration
        let service = GitService(repoRoot: baseDirectory)
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
        let baseIsRepo = await Task.detached(priority: .userInitiated) {
            (try? service.status()) != nil
        }.value
        guard !isShutDown, startupGeneration == generation else { return }
        // Filtered adapter order determines role assignment (first = scout).
        for assignment in Self.roles(for: usable, mode: mode, purpose: purpose) {
            let agent = assignment.agent
            // Resolve adapters from the SAME environment the columns run with,
            // so a dev/test adapter override actually governs the spawn.
            guard let adapter = AcpAdapter.forAgent(agent.id, environment: environment) else { continue }
            var worktree: String?
            var branch: String?
            if assignment.role.usesWorktree, baseIsRepo {
                let candidateBranch = "\(GitService.meshBranchPrefix)\(id.suffix(6))-\(agent.id)"
                let candidatePath = fileManager.temporaryDirectory
                    .appendingPathComponent("kaisola-mesh", isDirectory: true)
                    .appendingPathComponent("\(id)-\(agent.id)", isDirectory: true).path
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try service.worktreeAdd(path: candidatePath, branch: candidateBranch)
                    }.value
                    guard !isShutDown, startupGeneration == generation else {
                        try? await Task.detached(priority: .utility) {
                            try service.worktreeRemove(path: candidatePath, branch: candidateBranch)
                        }.value
                        return
                    }
                    worktree = candidatePath
                    branch = candidateBranch
                } catch {
                    // Fail closed: no isolated column, no column at all.
                    isolationNote = "Could not create a worktree for \(agent.name) — column skipped."
                    continue
                }
            } else if assignment.role.usesWorktree, isolationNote == nil {
                isolationNote = "Not a git repo — columns share the workspace (no isolation)."
            }
            let cwd = worktree ?? baseDirectory.path
            let conversation = AcpConversation(
                title: agent.name,
                command: adapter.command,
                arguments: adapter.arguments,
                environment: environment,
                cwd: cwd,
                mcpServers: mcp,
                sensitiveGlobs: NativePreviewSettings.shared.sensitiveGlobs
            )
            conversation.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &columnObservers)
            let columnID = "\(id)-\(agent.id)"
            let usageTitle = "\(title) · \(agent.name)"
            // Mesh columns are first-class ACP sessions. Feed their live
            // context/cost updates into the same Usage pane as ordinary chats;
            // previously a multi-agent run was entirely invisible there.
            conversation.$usage
                .compactMap { $0 }
                .sink { usage in
                    UsageCenter.shared.record(
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
                .sink { _ in UsageCenter.shared.recordTurn(chatID: columnID) }
                .store(in: &columnObservers)
            columns.append(Column(
                id: columnID,
                agent: agent,
                role: assignment.role,
                conversation: conversation,
                worktreePath: worktree,
                branch: branch
            ))
        }
        for column in columns {
            guard !isShutDown, startupGeneration == generation else { return }
            await column.conversation.start()
        }
    }

    /// How many worktree columns hold uncommitted changes — the Close guard
    /// asks before destroying them.
    func dirtyColumnCount() async -> Int {
        let paths = columns.compactMap(\.worktreePath)
        guard !paths.isEmpty else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            paths.filter { path in
                let service = GitService(repoRoot: URL(fileURLWithPath: path, isDirectory: true))
                guard let status = try? service.status() else { return false }
                return !status.isClean
            }.count
        }.value
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
        return await Task.detached(priority: .userInitiated) {
            (try? service.diffAgainstHead()) ?? ""
        }.value
    }

    /// Per-worktree review lines for judging the run: files changed + rough +/-
    /// line counts, parsed from each editing column's diff against HEAD. Read-only
    /// columns (scout, ideator) have no worktree and are skipped.
    func reviewSummaries() async -> [(columnID: String, agent: String, diffStat: String)] {
        var summaries: [(columnID: String, agent: String, diffStat: String)] = []
        for column in columns {
            guard let path = column.worktreePath else { continue }
            let patch = await Task.detached(priority: .userInitiated) { () -> String in
                let service = GitService(repoRoot: URL(fileURLWithPath: path, isDirectory: true))
                return (try? service.diffAgainstHead()) ?? ""
            }.value
            summaries.append((columnID: column.id, agent: column.agent.name, diffStat: MeshDiffStats.stat(fromPatch: patch)))
        }
        return summaries
    }

    /// Stop every agent and clean up Mesh worktrees + branches. Cleanup runs
    /// sequentially — concurrent git processes contend on the repo lock and
    /// would leave stray branches behind.
    func shutdown() {
        isShutDown = true
        startupGeneration &+= 1
        stageTask?.cancel()
        stageTask = nil
        stage = "Idle"
        let service = GitService(repoRoot: baseDirectory)
        let cleanups = columns.compactMap { column -> (String, String)? in
            column.conversation.stop()
            UsageCenter.shared.remove(chatID: column.id)
            guard let path = column.worktreePath, let branch = column.branch else { return nil }
            return (path, branch)
        }
        columnObservers.removeAll()
        columns.removeAll()
        guard !cleanups.isEmpty else { return }
        Task.detached(priority: .utility) {
            for (path, branch) in cleanups {
                try? service.worktreeRemove(path: path, branch: branch)
            }
        }
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
