import Combine
import Darwin
import Foundation
import KaisolaCore

/// Version 1 of the Mesh host hook lifecycle. Payloads are JSON objects whose
/// keys are stable, whose user-controlled fields are bounded, and whose secret
/// values are redacted before either preview or execution.
enum MeshLifecycleHookEvent: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case beforeSubmit
    case afterResponse
    case compaction
    case subagentStarted
    case subagentStopped
    case turnCompleted
}

/// A mesh-scoped hook observes the whole run. A column-scoped hook is invoked
/// only for payloads carrying a concrete column identity.
enum MeshLifecycleHookScope: String, Codable, Equatable, Hashable, Sendable {
    case mesh
    case column
}

/// Declared effects are audit metadata, not a capability grant. Version 1 does
/// not pass host credentials or interpret hook output as a prompt mutation.
enum MeshLifecycleHookSideEffect: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case none
    case notification
    case metrics
    case workspaceRead
    case workspaceWrite
    case network
}

enum MeshLifecycleHookFailurePolicy: String, Codable, Equatable, Sendable {
    /// Record the failure and continue the host lifecycle.
    case `continue`
    /// Refuse only a before-submit prompt. Post-submit lifecycle events can
    /// never be configured to retroactively fail closed.
    case failClosed
}

/// One external hook declaration. Executables are launched directly (never
/// through a shell), receive one bounded JSON payload on stdin, inherit no host
/// secrets, and are killed when their declared timeout expires.
struct MeshLifecycleHookConfiguration: Codable, Equatable, Sendable {
    static let apiVersion = 1
    static let minimumTimeoutMilliseconds = 10
    static let maximumTimeoutMilliseconds = 5_000

    let apiVersion: Int
    let id: String
    let executable: String
    let arguments: [String]
    let events: Set<MeshLifecycleHookEvent>
    let scope: MeshLifecycleHookScope
    let sideEffects: Set<MeshLifecycleHookSideEffect>
    let timeoutMilliseconds: Int
    let failurePolicy: MeshLifecycleHookFailurePolicy
    let enabled: Bool

    init(
        apiVersion: Int = Self.apiVersion,
        id: String,
        executable: String,
        arguments: [String] = [],
        events: Set<MeshLifecycleHookEvent>,
        scope: MeshLifecycleHookScope,
        sideEffects: Set<MeshLifecycleHookSideEffect>,
        timeoutMilliseconds: Int = 1_000,
        failurePolicy: MeshLifecycleHookFailurePolicy = .continue,
        enabled: Bool = true
    ) {
        self.apiVersion = apiVersion
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.events = events
        self.scope = scope
        self.sideEffects = sideEffects
        self.timeoutMilliseconds = timeoutMilliseconds
        self.failurePolicy = failurePolicy
        self.enabled = enabled
    }

    var validationErrors: [String] {
        var errors: [String] = []
        if apiVersion != Self.apiVersion {
            errors.append("Unsupported hook API version \(apiVersion); expected \(Self.apiVersion).")
        }
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || id.utf8.count > 128 {
            errors.append("Hook id must contain 1–128 UTF-8 bytes.")
        }
        if !executable.hasPrefix("/") || executable.utf8.count > 4_096 {
            errors.append("Hook executable must be a bounded absolute path.")
        }
        if arguments.count > 64 || arguments.contains(where: { $0.utf8.count > 4_096 }) {
            errors.append("Hook arguments exceed the 64-item or 4 KiB per-item limit.")
        }
        if events.isEmpty { errors.append("Hook events cannot be empty.") }
        if sideEffects.isEmpty {
            errors.append("Hook side effects must be declared.")
        } else if sideEffects.contains(.none), sideEffects.count != 1 {
            errors.append("The none side effect cannot be combined with other effects.")
        }
        if !(Self.minimumTimeoutMilliseconds...Self.maximumTimeoutMilliseconds).contains(timeoutMilliseconds) {
            errors.append("Hook timeout must be 10–5000 milliseconds.")
        }
        if failurePolicy == .failClosed,
           (events.isEmpty || events.contains(where: { $0 != .beforeSubmit })) {
            errors.append("Fail-closed hooks may subscribe only to beforeSubmit.")
        }
        return errors
    }
}

/// The documented v1 stdin payload. `fields` is event-specific:
/// - beforeSubmit: prompt
/// - afterResponse: response, agentID, role
/// - compaction: previousUsed, currentUsed, max
/// - subagentStarted/subagentStopped: agentID, role
/// - turnCompleted: agentID, role, response
struct MeshLifecycleHookPayload: Codable, Equatable, Sendable {
    static let apiVersion = 1
    static let maximumEncodedBytes = 16_384
    private static let maximumFieldBytes = 4_096
    private static let maximumFields = 32

    let apiVersion: Int
    let event: MeshLifecycleHookEvent
    let meshID: String
    let projectID: String
    let columnID: String?
    let fields: [String: String]

    init(
        apiVersion: Int = Self.apiVersion,
        event: MeshLifecycleHookEvent,
        meshID: String,
        projectID: String,
        columnID: String? = nil,
        fields: [String: String] = [:]
    ) {
        self.apiVersion = apiVersion
        self.event = event
        self.meshID = meshID
        self.projectID = projectID
        self.columnID = columnID
        self.fields = fields
    }

    fileprivate func redactedAndBounded() -> Self {
        var safeFields: [String: String] = [:]
        var remaining = 12_000
        for rawKey in fields.keys.sorted().prefix(Self.maximumFields) {
            let key = Self.boundedUTF8(rawKey, maximumBytes: 128)
            guard !key.isEmpty, remaining > 0 else { continue }
            let sensitiveKey = key.lowercased().contains("secret")
                || key.lowercased().contains("token")
                || key.lowercased().contains("password")
                || key.lowercased().contains("authorization")
                || key.lowercased().replacingOccurrences(of: "_", with: "").contains("apikey")
            let redacted = sensitiveKey ? "[redacted]" : Self.redact(fields[rawKey] ?? "")
            let budget = min(Self.maximumFieldBytes, remaining)
            let value = Self.boundedUTF8(redacted, maximumBytes: budget)
            safeFields[key] = value
            remaining -= key.utf8.count + value.utf8.count + 8
        }
        return Self(
            apiVersion: apiVersion,
            event: event,
            meshID: Self.boundedUTF8(meshID, maximumBytes: 256),
            projectID: Self.boundedUTF8(projectID, maximumBytes: 256),
            columnID: columnID.map { Self.boundedUTF8($0, maximumBytes: 256) },
            fields: safeFields
        )
    }

    fileprivate static func encoded(_ payload: Self) -> Data {
        var safe = payload.redactedAndBounded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            let data = (try? encoder.encode(safe)) ?? Data("{}".utf8)
            if data.count <= maximumEncodedBytes || safe.fields.isEmpty { return data }
            var fields = safe.fields
            if let last = fields.keys.sorted().last { fields.removeValue(forKey: last) }
            safe = Self(
                apiVersion: safe.apiVersion,
                event: safe.event,
                meshID: safe.meshID,
                projectID: safe.projectID,
                columnID: safe.columnID,
                fields: fields
            )
        }
    }

    fileprivate static func redact(_ input: String) -> String {
        var safe = boundedUTF8(input, maximumBytes: 16_384)
        let replacements: [(String, String)] = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._~+\-/=]+"#, "$1[redacted]"),
            (#"(?i)\b(?:sk|ghp|github_pat|xox[baprs]|AIza)[-_A-Za-z0-9]{8,}\b"#, "[redacted]"),
            (#"(?i)((?:api[_-]?key|token|secret|password|authorization)\s*[:=]\s*)[^\s,;]+"#, "$1[redacted]"),
        ]
        for (pattern, replacement) in replacements {
            safe = safe.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return safe
    }

    fileprivate static func boundedUTF8(_ input: String, maximumBytes: Int) -> String {
        guard input.utf8.count > maximumBytes else { return input }
        var bytes = Array(input.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }
}

struct MeshLifecycleHookExecutionOutput: Equatable, Sendable {
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String

    init(exitStatus: Int32, standardOutput: String, standardError: String) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

struct MeshLifecycleHookReceipt: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case succeeded
        case failed
        case timedOut
        case reentrant
        case invalid
    }

    let hookID: String
    let event: MeshLifecycleHookEvent
    let outcome: Outcome
    let message: String
    let blocked: Bool
}

struct MeshLifecycleHookDecision: Equatable, Sendable {
    let allowed: Bool
    let receipts: [MeshLifecycleHookReceipt]
}

struct MeshLifecycleHookPreview: Equatable, Sendable {
    let apiVersion: Int
    let hookID: String
    let event: MeshLifecycleHookEvent
    let scope: MeshLifecycleHookScope
    let sideEffects: Set<MeshLifecycleHookSideEffect>
    let timeoutMilliseconds: Int
    let failurePolicy: MeshLifecycleHookFailurePolicy
    let encodedPayload: String
    let validationErrors: [String]
}

/// Executes validated hook declarations in stable id order. The actor retains
/// active hook ids across suspension points, preventing a hook-triggered host
/// callback from recursively invoking the same integration.
actor MeshLifecycleHookHost {
    typealias Executor = @Sendable (
        MeshLifecycleHookConfiguration,
        Data
    ) async throws -> MeshLifecycleHookExecutionOutput

    private let configurations: [MeshLifecycleHookConfiguration]
    private let executor: Executor
    private var activeHookIDs: Set<String> = []

    init(
        configurations: [MeshLifecycleHookConfiguration],
        executor: @escaping Executor = MeshLifecycleHookProcessExecutor.execute
    ) {
        self.configurations = configurations.sorted { $0.id < $1.id }
        self.executor = executor
    }

    func preview(
        configurationID: String,
        payload: MeshLifecycleHookPayload
    ) -> MeshLifecycleHookPreview {
        guard let configuration = configurations.first(where: { $0.id == configurationID }) else {
            return MeshLifecycleHookPreview(
                apiVersion: MeshLifecycleHookConfiguration.apiVersion,
                hookID: configurationID,
                event: payload.event,
                scope: .mesh,
                sideEffects: [],
                timeoutMilliseconds: 0,
                failurePolicy: .continue,
                encodedPayload: String(decoding: MeshLifecycleHookPayload.encoded(payload), as: UTF8.self),
                validationErrors: ["Unknown hook id."]
            )
        }
        return MeshLifecycleHookPreview(
            apiVersion: configuration.apiVersion,
            hookID: configuration.id,
            event: payload.event,
            scope: configuration.scope,
            sideEffects: configuration.sideEffects,
            timeoutMilliseconds: configuration.timeoutMilliseconds,
            failurePolicy: configuration.failurePolicy,
            encodedPayload: String(decoding: MeshLifecycleHookPayload.encoded(payload), as: UTF8.self),
            validationErrors: configuration.validationErrors
        )
    }

    func invoke(_ payload: MeshLifecycleHookPayload) async -> MeshLifecycleHookDecision {
        let matching = configurations.filter { configuration in
            configuration.enabled
                && configuration.events.contains(payload.event)
                && (configuration.scope == .mesh || payload.columnID != nil)
        }
        guard !matching.isEmpty else { return MeshLifecycleHookDecision(allowed: true, receipts: []) }
        let encoded = MeshLifecycleHookPayload.encoded(payload)
        var receipts: [MeshLifecycleHookReceipt] = []
        var allowed = true
        for configuration in matching {
            let blocks = configuration.failurePolicy == .failClosed && payload.event == .beforeSubmit
            let receipt: MeshLifecycleHookReceipt
            let validationErrors = configuration.validationErrors
            if !validationErrors.isEmpty {
                receipt = Self.receipt(
                    configuration: configuration,
                    event: payload.event,
                    outcome: .invalid,
                    detail: validationErrors.joined(separator: " "),
                    blocked: blocks
                )
            } else if activeHookIDs.contains(configuration.id) {
                receipt = Self.receipt(
                    configuration: configuration,
                    event: payload.event,
                    outcome: .reentrant,
                    detail: "Recursive hook invocation was refused.",
                    blocked: blocks
                )
            } else {
                activeHookIDs.insert(configuration.id)
                let result = await execute(configuration, payload: encoded)
                activeHookIDs.remove(configuration.id)
                switch result {
                case let .completed(output) where output.exitStatus == 0:
                    receipt = Self.receipt(
                        configuration: configuration,
                        event: payload.event,
                        outcome: .succeeded,
                        detail: Self.combinedOutput(output),
                        blocked: false
                    )
                case let .completed(output):
                    receipt = Self.receipt(
                        configuration: configuration,
                        event: payload.event,
                        outcome: .failed,
                        detail: "Exit \(output.exitStatus). \(Self.combinedOutput(output))",
                        blocked: blocks
                    )
                case let .failed(message):
                    receipt = Self.receipt(
                        configuration: configuration,
                        event: payload.event,
                        outcome: .failed,
                        detail: message,
                        blocked: blocks
                    )
                case .timedOut:
                    receipt = Self.receipt(
                        configuration: configuration,
                        event: payload.event,
                        outcome: .timedOut,
                        detail: "Timed out after \(configuration.timeoutMilliseconds) ms.",
                        blocked: blocks
                    )
                }
            }
            receipts.append(receipt)
            if receipt.blocked { allowed = false }
        }
        return MeshLifecycleHookDecision(allowed: allowed, receipts: receipts)
    }

    private enum TimedExecution: Sendable {
        case completed(MeshLifecycleHookExecutionOutput)
        case failed(String)
        case timedOut
    }

    private func execute(
        _ configuration: MeshLifecycleHookConfiguration,
        payload: Data
    ) async -> TimedExecution {
        await withTaskGroup(of: TimedExecution.self) { group in
            group.addTask { [executor] in
                do { return .completed(try await executor(configuration, payload)) }
                catch { return .failed(error.localizedDescription) }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(configuration.timeoutMilliseconds))
                    return .timedOut
                } catch {
                    return .failed("Hook execution was cancelled.")
                }
            }
            let first = await group.next() ?? .failed("Hook execution did not start.")
            group.cancelAll()
            return first
        }
    }

    private static func combinedOutput(_ output: MeshLifecycleHookExecutionOutput) -> String {
        [output.standardOutput, output.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func receipt(
        configuration: MeshLifecycleHookConfiguration,
        event: MeshLifecycleHookEvent,
        outcome: MeshLifecycleHookReceipt.Outcome,
        detail: String,
        blocked: Bool
    ) -> MeshLifecycleHookReceipt {
        let redacted = MeshLifecycleHookPayload.redact(detail)
        let bounded = MeshLifecycleHookPayload.boundedUTF8(redacted, maximumBytes: 512)
        return MeshLifecycleHookReceipt(
            hookID: configuration.id,
            event: event,
            outcome: outcome,
            message: bounded,
            blocked: blocked
        )
    }
}

/// Direct-process executor used by the production hook host. Output is written
/// to owner-only temporary files so a chatty hook cannot fill an unread pipe.
private enum MeshLifecycleHookProcessExecutor {
    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancellationRequested = false

        func install(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldTerminate = cancellationRequested
            lock.unlock()
            if shouldTerminate, process.isRunning { process.terminate() }
        }

        func terminate() {
            lock.lock()
            cancellationRequested = true
            let process = self.process
            lock.unlock()
            guard let process, process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.forceKillIfRunning(pid: pid)
            }
        }

        private func forceKillIfRunning(pid: Int32) {
            lock.lock()
            let process = self.process
            lock.unlock()
            if process?.processIdentifier == pid, process?.isRunning == true {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    static func execute(
        _ configuration: MeshLifecycleHookConfiguration,
        _ payload: Data
    ) async throws -> MeshLifecycleHookExecutionOutput {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let state = ProcessState()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                let input = Pipe()
                let stdout = try FileHandle(forWritingTo: stdoutURL)
                let stderr = try FileHandle(forWritingTo: stderrURL)
                defer {
                    try? stdout.close()
                    try? stderr.close()
                }
                process.executableURL = URL(fileURLWithPath: configuration.executable)
                process.arguments = configuration.arguments
                process.environment = [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8",
                    "KAISOLA_HOOK_API_VERSION": "\(MeshLifecycleHookConfiguration.apiVersion)",
                ]
                process.standardInput = input
                process.standardOutput = stdout
                process.standardError = stderr
                try process.run()
                state.install(process)
                input.fileHandleForWriting.write(payload)
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                if Task.isCancelled { throw CancellationError() }
                try? stdout.synchronize()
                try? stderr.synchronize()
                let stdoutData = (try? Data(contentsOf: stdoutURL, options: .mappedIfSafe)) ?? Data()
                let stderrData = (try? Data(contentsOf: stderrURL, options: .mappedIfSafe)) ?? Data()
                return MeshLifecycleHookExecutionOutput(
                    exitStatus: process.terminationStatus,
                    standardOutput: String(decoding: stdoutData.prefix(4_096), as: UTF8.self),
                    standardError: String(decoding: stderrData.prefix(4_096), as: UTF8.self)
                )
            }.value
        } onCancel: {
            state.terminate()
        }
    }
}

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
    /// Prompts waiting behind the currently active scout -> executor pipeline.
    /// A second send must never cancel the first pipeline and strand its scout
    /// result; staged runs are therefore drained in strict FIFO order.
    @Published private(set) var stagedQueuedPromptCount = 0
    @Published private(set) var stagedQueueIsRunning = false
    @Published private(set) var lifecycle: NativeMeshLifecycle
    /// Bounded, user-visible audit trail for hook success/failure. Hook stdout
    /// and stderr are redacted and capped before reaching this collection.
    @Published private(set) var hookReceipts: [MeshLifecycleHookReceipt] = []
    @Published private(set) var hookNotice: String?
    @Published private(set) var hookSubmissionInProgress = false
    @Published var draft: String {
        didSet { onDraftChanged?(draft) }
    }

    /// AppModel injects persistence without coupling Mesh to a concrete store.
    var onDescriptorChanged: (() -> Void)?
    /// Awaited at worktree transaction boundaries. AppModel writes the Mesh
    /// manifest before Git registration and immediately after adoption.
    var persistDescriptor: (() async throws -> Void)?
    var onTranscriptChanged: ((
        _ columnID: String,
        _ rows: [AcpTranscriptRow],
        _ startOrdinal: Int64
    ) -> Void)?
    var loadEarlierTranscript: ((
        _ columnID: String,
        _ beforeOrdinal: Int64,
        _ limit: Int
    ) async -> AcpTranscriptStore.Page?)?
    var onColumnDraftChanged: ((_ columnID: String, _ draft: String) -> Void)?
    var onColumnAttachmentsChanged: ((
        _ columnID: String,
        _ attachments: [AcpAttachment]
    ) -> Void)?
    var onColumnSessionIDChanged: ((_ columnID: String, _ sessionID: String) -> Void)?
    var onFileActivity: ((_ columnID: String, _ activity: AcpFileActivity) -> Bool)?
    var onDraftChanged: ((String) -> Void)?

    private let fileManager: FileManager
    private let worktreeRoot: URL
    private let usageCenter: UsageCenter
    private let hookHost: MeshLifecycleHookHost?
    private var hookUsageByColumn: [String: Int] = [:]
    private var hookStartedColumnIDs: Set<String> = []
    /// Relay each column's live conversation state through this Mesh object so
    /// parent project navigation can show accurate working activity.
    private var columnObservers = Set<AnyCancellable>()
    /// Drives the staged / idea handoff. Staged sends share one FIFO drain task;
    /// idea sends retain their bounded cancel-and-restart behavior.
    private var stageTask: Task<Void, Never>?
    private var stagedPromptQueue: [String] = []
    /// Prevents a cancelled drain's deferred cleanup from clearing a newer
    /// coordinator task that started while an awaited stop was yielding.
    private var stagedDrainGeneration = 0
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

    private struct WorktreeCleanupTarget: Sendable {
        let id: String
        let agentName: String
        let path: String
        let branch: String
        let createdBaseOID: String
    }

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
        initialStagedPrompts: [String] = [],
        worktreeRoot: URL = NativePreviewPaths.meshWorktreesDirectory,
        fileManager: FileManager = .default,
        usageCenter: UsageCenter = .shared,
        hookHost: MeshLifecycleHookHost? = nil
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
        self.hookHost = hookHost
        self.stagedPromptQueue = initialStagedPrompts
        self.stagedQueuedPromptCount = initialStagedPrompts.count
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
        columns = Self.roles(for: agents, mode: mode, purpose: purpose).map { assignment in
            let agent = assignment.agent
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
                role: assignment.role,
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
                    isolationNote = "Not a git repo — columns share the project folder (no isolation)."
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
            await startColumn(columnID: column.id)
        }
        lifecycle = provisioningColumns.isEmpty ? .active : .recoveryRequired
        onDescriptorChanged?()
        _ = await persistBoundary("Could not save the active Mesh manifest — recovery remains required.")
    }

    struct RestoredColumnState: Sendable {
        let descriptor: NativeRestorableMeshColumnDescriptor
        let rows: [AcpTranscriptRow]
        let rowStartOrdinal: Int64
        let earlierRowCount: Int
        let totalRowCount: Int
        let initialDraft: String?
        let initialAttachments: [AcpAttachment]
        let persistedSessionID: String?
        let usage: AcpPersistedUsage?

        init(
            descriptor: NativeRestorableMeshColumnDescriptor,
            rows: [AcpTranscriptRow],
            rowStartOrdinal: Int64 = 0,
            earlierRowCount: Int = 0,
            totalRowCount: Int? = nil,
            initialDraft: String?,
            initialAttachments: [AcpAttachment] = [],
            persistedSessionID: String? = nil,
            usage: AcpPersistedUsage?
        ) {
            self.descriptor = descriptor
            self.rows = rows
            self.rowStartOrdinal = rowStartOrdinal
            self.earlierRowCount = earlierRowCount
            self.totalRowCount = totalRowCount ?? rows.count
            self.initialDraft = initialDraft
            self.initialAttachments = initialAttachments
            self.persistedSessionID = persistedSessionID
            self.usage = usage
        }
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
            columns: live + provisioningColumns,
            stagedPrompts: stagedPromptQueue
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
        // A mesh the user deleted stays deleted (2026-08-06 spec §4e): a
        // pendingDeletion manifest resumes destruction instead of restoring
        // columns. No adapters start; failure keeps the retryable recovery
        // surface; success completes the tombstone through the caller's
        // pendingDeletion cleanup path.
        if lifecycle == .pendingDeletion {
            // The constructor has no live columns yet. Seed the exact persisted
            // cleanup manifest so destruction can resume a registered
            // worktree or a branch-only partial transaction without launching
            // an adapter or recreating a directory.
            provisioningColumns = states.map(\.descriptor)
            _ = await destroy(allowRecoverableWork: true)
            onDescriptorChanged?()
            return
        }
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
                resumeSessionID: hadPersistedBinding
                    ? (descriptor.acpSessionID ?? state.persistedSessionID)
                    : nil,
                initialRows: state.rows,
                initialRowStartOrdinal: state.rowStartOrdinal,
                initialEarlierRowCount: state.earlierRowCount,
                initialTotalRowCount: state.totalRowCount,
                initialDraft: state.initialDraft,
                initialAttachments: state.initialAttachments,
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
        } else if lifecycle != .pendingDeletion {
            // pendingDeletion is handled at entry and must never flip back to
            // a live lifecycle here (§4e) — the old `|| !columns.isEmpty`
            // escape hatch was exactly how deleted meshes came back.
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
        cancelStageCoordinator()
        stage = "Interrupted"
        for column in columns {
            let wasConnected = column.conversation.isConnected
            _ = await column.conversation.stop()
            if wasConnected {
                await runSubagentHook(.subagentStopped, column: column)
                hookStartedColumnIDs.remove(column.id)
            }
        }
        if lifecycle != .pendingDeletion {
            lifecycle = provisioningColumns.isEmpty ? .suspended : .recoveryRequired
        }
        onDescriptorChanged?()
        await persistBestEffort()
    }

    /// End every active turn without closing the Mesh or deleting transcripts,
    /// drafts, queued prompts, branches, or worktrees.
    func stopAllTurns() async {
        startupGeneration &+= 1
        cancelStageCoordinator()
        for column in columns where column.conversation.isRunning {
            _ = await column.conversation.stop()
        }
        stage = "Stopped"
        onDescriptorChanged?()
        await persistBestEffort()
    }

    /// Stop one column while keeping the rest visible. A staged orchestration
    /// cannot safely advance after a human interrupts one participant, so its
    /// coordinator is cancelled while other already-running columns continue.
    func stopTurn(columnID: String) async {
        guard let column = columns.first(where: { $0.id == columnID }) else { return }
        startupGeneration &+= 1
        cancelStageCoordinator()
        _ = await column.conversation.stop()
        stage = "\(column.agent.name) stopped"
        onDescriptorChanged?()
        await persistBestEffort()
    }

    /// Inventory uncommitted files AND unique commits. Any probe failure blocks
    /// deletion; uncertainty must never be treated as a clean worktree.
    func discardAssessment() async -> DiscardAssessment {
        let pendingEditing = provisioningColumns.filter { $0.workspaceKind == .worktree }
        guard pendingEditing.isEmpty || lifecycle == .pendingDeletion else {
            return .blocked("Mesh is still provisioning or needs recovery; its worktrees were preserved.")
        }
        let targets: [WorktreeCleanupTarget]
        do {
            targets = try worktreeCleanupTargets(includeProvisioning: lifecycle == .pendingDeletion)
        } catch {
            return .blocked(error.localizedDescription)
        }
        var atRisk = 0
        let baseDirectory = baseDirectory
        for target in targets {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<GitService.MeshDiscardInventory?, Error> in
                do {
                    let baseService = GitService(repoRoot: baseDirectory)
                    switch try baseService.worktreeRemovalPhase(path: target.path, branch: target.branch) {
                    case .registered:
                        let worktreeService = GitService(
                            repoRoot: URL(fileURLWithPath: target.path, isDirectory: true)
                        )
                        return .success(
                            try worktreeService.meshDiscardInventory(
                                createdBaseOID: target.createdBaseOID
                            )
                        )
                    case .branchCleanupPending, .complete:
                        // The destructive worktree step already completed.
                        // There is no directory left to inventory or confirm.
                        return .success(nil)
                    }
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case let .success(inventory?):
                if inventory.hasRecoverableWork { atRisk += 1 }
            case .success(nil):
                break
            case let .failure(error):
                return .blocked("Could not verify \(target.agentName)'s worktree: \(error.localizedDescription)")
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
        let cleanupTargets: [WorktreeCleanupTarget]
        do {
            cleanupTargets = try worktreeCleanupTargets(includeProvisioning: true)
        } catch {
            lifecycle = .pendingDeletion
            isolationNote = error.localizedDescription
            await persistBestEffort()
            return .blocked(error.localizedDescription)
        }
        for target in cleanupTargets {
            do {
                _ = try await Task.detached(priority: .utility) {
                    try service.worktreeRemove(path: target.path, branch: target.branch)
                }.value
                // Persist each successful cleanup before attempting the next.
                // A later Git failure therefore leaves only the genuinely
                // remaining pair in the retryable manifest.
                columns.removeAll { $0.id == target.id }
                provisioningColumns.removeAll { $0.id == target.id }
                retiredColumnIDs.insert(target.id)
                usageCenter.remove(chatID: target.id)
                onDescriptorChanged?()
                guard await persistBoundary("Cleanup paused because the updated recovery manifest could not be saved.") else {
                    return .blocked(isolationNote ?? "Cleanup paused because the recovery manifest could not be saved.")
                }
            } catch {
                // Deletion intent was persisted before the first Git mutation.
                // Keep that lifecycle plus the exact path/branch manifest so a
                // relaunch can derive branchCleanupPending and resume safely.
                lifecycle = .pendingDeletion
                isolationNote = "Mesh cleanup stopped: \(error.localizedDescription)"
                onDescriptorChanged?()
                await persistBestEffort()
                return .blocked(isolationNote ?? "Mesh cleanup stopped.")
            }
        }
        isDestroyed = true
        lifecycle = .pendingDeletion
        for column in columns { usageCenter.remove(chatID: column.id) }
        columnObservers.removeAll()
        columns.removeAll()
        provisioningColumns.removeAll()
        retiredColumnIDs.removeAll()
        stagedPromptQueue.removeAll()
        stagedQueuedPromptCount = 0
        onDescriptorChanged?()
        guard await persistBoundary("Mesh cleanup completed, but its final tombstone could not be saved.") else {
            return .blocked(isolationNote ?? "Mesh cleanup completed, but its final tombstone could not be saved.")
        }
        return .safe
    }

    private func worktreeCleanupTargets(
        includeProvisioning: Bool
    ) throws -> [WorktreeCleanupTarget] {
        var targets: [WorktreeCleanupTarget] = []
        for column in columns where column.worktreePath != nil || column.branch != nil {
            guard let path = column.worktreePath,
                  let branch = column.branch,
                  let createdBaseOID = column.createdBaseOID,
                  isOwnedWorktreePath(path, agentID: column.agent.id) else {
                throw GitService.GitError.commandFailed(
                    "A Mesh worktree manifest is incomplete; nothing else was deleted."
                )
            }
            targets.append(WorktreeCleanupTarget(
                id: column.id,
                agentName: column.agent.name,
                path: path,
                branch: branch,
                createdBaseOID: createdBaseOID
            ))
        }
        if includeProvisioning {
            for descriptor in provisioningColumns where descriptor.workspaceKind == .worktree {
                guard let path = descriptor.worktreePath,
                      let branch = descriptor.branch,
                      let createdBaseOID = descriptor.createdBaseOID,
                      isOwnedWorktreePath(path, agentID: descriptor.agentID) else {
                    throw GitService.GitError.commandFailed(
                        "A Mesh cleanup manifest is incomplete; nothing else was deleted."
                    )
                }
                targets.append(WorktreeCleanupTarget(
                    id: descriptor.id,
                    agentName: AgentRegistry.profile(id: descriptor.agentID)?.name ?? descriptor.agentID,
                    path: path,
                    branch: branch,
                    createdBaseOID: createdBaseOID
                ))
            }
        }
        return targets
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
        initialRowStartOrdinal: Int64 = 0,
        initialEarlierRowCount: Int = 0,
        initialTotalRowCount: Int? = nil,
        initialDraft: String? = nil,
        initialAttachments: [AcpAttachment] = [],
        initialUsage: AcpPersistedUsage? = nil
    ) -> AcpConversation {
        let conversation = AcpConversation(
            title: agent.name,
            command: adapter.command,
            arguments: adapter.arguments,
            containment: adapter.containment,
            environment: environment,
            cwd: cwd,
            mcpServers: mcp,
            sensitiveGlobs: NativePreviewSettings.shared.sensitiveGlobs,
            draftKey: columnID,
            resumeSessionID: resumeSessionID,
            initialRows: initialRows,
            initialRowStartOrdinal: initialRowStartOrdinal,
            initialEarlierRowCount: initialEarlierRowCount,
            initialTotalRowCount: initialTotalRowCount,
            initialDraft: initialDraft,
            initialAttachments: initialAttachments,
            initialUsage: initialUsage.map {
                AcpUsage(
                    used: $0.latestUsed,
                    max: $0.latestMax,
                    costAmount: $0.costAmount,
                    costCurrency: $0.costCurrency
                )
            }
        )
        conversation.onTranscriptChanged = { [weak self] rows, startOrdinal in
            self?.onTranscriptChanged?(columnID, rows, startOrdinal)
        }
        conversation.loadEarlierRows = { [weak self] beforeOrdinal, limit in
            guard let self else { return nil }
            return await self.loadEarlierTranscript?(columnID, beforeOrdinal, limit)
        }
        conversation.onFileActivity = { [weak self] activity in
            self?.onFileActivity?(columnID, activity) ?? false
        }
        conversation.onDraftChanged = { [weak self] draft in
            self?.onColumnDraftChanged?(columnID, draft)
        }
        conversation.onAttachmentsChanged = { [weak self] attachments in
            self?.onColumnAttachmentsChanged?(columnID, attachments)
        }
        conversation.onProviderSessionID = { [weak self] sessionID in
            guard let self else { return }
            self.onColumnSessionIDChanged?(columnID, sessionID)
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
                guard let self else { return }
                self.usageCenter.record(
                    chatID: columnID,
                    title: usageTitle,
                    agentID: agent.id,
                    usage: usage.used,
                    max: usage.max,
                    costAmount: usage.costAmount,
                    costCurrency: usage.costCurrency
                )
                let previous = self.hookUsageByColumn.updateValue(usage.used, forKey: columnID)
                if let previous, usage.used < previous {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        _ = await self.invokeHook(.init(
                            event: .compaction,
                            meshID: self.id,
                            projectID: self.projectID,
                            columnID: columnID,
                            fields: [
                                "agentID": agent.id,
                                "role": self.columns.first(where: { $0.id == columnID })?.role.rawValue ?? "unknown",
                                "previousUsed": "\(previous)",
                                "currentUsed": "\(usage.used)",
                                "max": "\(usage.max)",
                            ]
                        ))
                    }
                }
            }
            .store(in: &columnObservers)
        conversation.$isRunning
            .scan((false, false)) { ($0.1, $1) }
            .filter { $0.0 && !$0.1 }
            .sink { [weak self] _ in
                guard let self else { return }
                self.usageCenter.recordTurn(chatID: columnID)
                Task { @MainActor [weak self] in
                    await self?.runColumnCompletionHooks(columnID: columnID)
                }
            }
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

    /// The hook-aware UI/API submission path. The original prompt is not
    /// removed from the draft or handed to an agent until every configured
    /// fail-closed before-submit hook succeeds. Hook output is audit-only and
    /// is never interpreted as replacement prompt text.
    @discardableResult
    func submit(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hookSubmissionInProgress else { return false }
        hookSubmissionInProgress = true
        defer { hookSubmissionInProgress = false }
        let decision = await invokeHook(.init(
            event: .beforeSubmit,
            meshID: id,
            projectID: projectID,
            fields: ["prompt": trimmed]
        ))
        guard decision.allowed else { return false }
        switch (purpose, mode) {
        case (.idea, _): return sendIdea(trimmed)
        case (.build, .staged): return sendStaged(trimmed)
        case (.build, .flat): return send(trimmed)
        }
    }

    /// Safe approval harness: callers can render the exact redacted stdin JSON,
    /// declared effects, timeout, and validation errors without launching the
    /// executable or enabling the hook.
    func previewHook(
        configurationID: String,
        event: MeshLifecycleHookEvent,
        columnID: String? = nil,
        fields: [String: String] = [:]
    ) async -> MeshLifecycleHookPreview? {
        guard let hookHost else { return nil }
        return await hookHost.preview(
            configurationID: configurationID,
            payload: .init(
                event: event,
                meshID: id,
                projectID: projectID,
                columnID: columnID,
                fields: fields
            )
        )
    }

    private func invokeHook(
        _ payload: MeshLifecycleHookPayload
    ) async -> MeshLifecycleHookDecision {
        guard let hookHost else { return MeshLifecycleHookDecision(allowed: true, receipts: []) }
        let decision = await hookHost.invoke(payload)
        appendHookReceipts(decision.receipts)
        return decision
    }

    private func appendHookReceipts(_ receipts: [MeshLifecycleHookReceipt]) {
        guard !receipts.isEmpty else { return }
        hookReceipts.append(contentsOf: receipts)
        if hookReceipts.count > 64 {
            hookReceipts.removeFirst(hookReceipts.count - 64)
        }
        if let failure = receipts.last(where: { $0.outcome != .succeeded }) {
            let fallback = failure.outcome == .timedOut
                ? "Lifecycle hook \(failure.hookID) timed out."
                : "Lifecycle hook \(failure.hookID) failed."
            hookNotice = failure.message.isEmpty ? fallback : failure.message
        }
    }

    private func runColumnCompletionHooks(columnID: String) async {
        guard let column = columns.first(where: { $0.id == columnID }) else { return }
        let response = Self.lastMessageText(in: column.conversation.rows)
        let common = [
            "agentID": column.agent.id,
            "role": column.role.rawValue,
            "response": response,
        ]
        if !response.isEmpty {
            _ = await invokeHook(.init(
                event: .afterResponse,
                meshID: id,
                projectID: projectID,
                columnID: columnID,
                fields: common
            ))
        }
        _ = await invokeHook(.init(
            event: .turnCompleted,
            meshID: id,
            projectID: projectID,
            columnID: columnID,
            fields: common
        ))
    }

    private func runSubagentHook(
        _ event: MeshLifecycleHookEvent,
        column: Column
    ) async {
        _ = await invokeHook(.init(
            event: event,
            meshID: id,
            projectID: projectID,
            columnID: column.id,
            fields: [
                "agentID": column.agent.id,
                "role": column.role.rawValue,
            ]
        ))
    }

    /// Starts one lazily restored/focused column and emits subagentStarted once
    /// only after its adapter actually connects. Multiple SwiftUI `.task`
    /// callers safely collapse onto the conversation's idempotent start.
    func startColumn(columnID: String) async {
        guard let column = columns.first(where: { $0.id == columnID }) else { return }
        await column.conversation.start()
        if column.conversation.isConnected,
           hookStartedColumnIDs.insert(column.id).inserted {
            await runSubagentHook(.subagentStarted, column: column)
        }
    }

    /// Fan the prompt out to every connected column (each queues if busy).
    /// Flat build mode and manual sends use this directly.
    @discardableResult
    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var accepted = false
        for column in columns {
            accepted = column.conversation.send(trimmed) || accepted
        }
        return accepted
    }

    /// Waiting prompts in exact dispatch order. This snapshot powers both the
    /// inspector and restoration; it never includes a possibly-dispatched
    /// prompt currently owned by the active scout/executor pipeline.
    var stagedPrompts: [String] { stagedPromptQueue }

    /// Remove one waiting prompt without disturbing the active pipeline.
    @discardableResult
    func removeStagedPrompt(at index: Int) -> Bool {
        guard stagedPromptQueue.indices.contains(index) else { return false }
        return removeStagedPrompt(stagedPromptQueue[index], at: index)
    }

    /// UI-safe variant: a live drain can shift the FIFO between a render and a
    /// click, so refuse a stale row action rather than remove a different item.
    @discardableResult
    func removeStagedPrompt(_ expectedPrompt: String, at index: Int) -> Bool {
        guard stagedPromptQueue.indices.contains(index) else { return false }
        guard stagedPromptQueue[index] == expectedPrompt else { return false }
        stagedPromptQueue.remove(at: index)
        stagedQueueDidChange()
        return true
    }

    /// Explicitly continue a restored or retry-paused FIFO. Restoration never
    /// auto-dispatches work merely because the app relaunched.
    @discardableResult
    func resumeStagedQueue() -> Bool {
        guard mode == .staged, purpose == .build, !stagedPromptQueue.isEmpty else {
            return false
        }
        guard let scout = columns.first(where: { $0.role == .scout }) else {
            stage = "Scout unavailable — queued prompts paused"
            return false
        }
        return beginStagedDrain(scoutID: scout.id)
    }

    var canResumeStagedQueue: Bool {
        mode == .staged
            && purpose == .build
            && !stagedPromptQueue.isEmpty
            && !stagedQueueIsRunning
            && stageTask == nil
            && columns.contains(where: { $0.role == .scout })
    }

    private func stagedQueueDidChange() {
        stagedQueuedPromptCount = stagedPromptQueue.count
        onDescriptorChanged?()
    }

    private func beginStagedDrain(scoutID: String) -> Bool {
        guard stageTask == nil, !stagedPromptQueue.isEmpty else { return false }
        stagedDrainGeneration &+= 1
        let generation = stagedDrainGeneration
        stagedQueueIsRunning = true
        stageTask = Task { [weak self] in
            await self?.drainStagedQueue(scoutID: scoutID, generation: generation)
        }
        return true
    }

    private func cancelStageCoordinator() {
        stagedDrainGeneration &+= 1
        stageTask?.cancel()
        stageTask = nil
        stagedQueueIsRunning = false
    }

    // MARK: - Staged build pipeline

    /// Staged send: prompt the SCOUT only; when its turn ends, auto-fan the
    /// original prompt + the scout's contract to the executors. Falls back to a
    /// flat fan-out when the session isn't staged or has no scout column.
    @discardableResult
    func sendStaged(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard mode == .staged, purpose == .build,
              let scout = columns.first(where: { $0.role == .scout }) else {
            return send(trimmed)
        }
        stagedPromptQueue.append(trimmed)
        stagedQueueDidChange()
        // The active pipeline owns stageTask until it drains or reaches a safe
        // stop. Never cancel it just because another prompt arrived.
        _ = beginStagedDrain(scoutID: scout.id)
        return true
    }

    private enum StagedPipelineResult {
        case completed
        /// The scout never accepted the prompt, so it is safe to put it back at
        /// the head of the FIFO and wait for a later user retry/send.
        case retryable
        /// Work may have reached one or more agents; automatic replay could
        /// duplicate edits, so stop without re-enqueueing the active prompt.
        case stopped
        case cancelled
    }

    private func drainStagedQueue(scoutID: String, generation: Int) async {
        defer {
            if stagedDrainGeneration == generation {
                stageTask = nil
                stagedQueueIsRunning = false
            }
        }
        while !Task.isCancelled, !stagedPromptQueue.isEmpty {
            let prompt = stagedPromptQueue.removeFirst()
            stagedQueueDidChange()
            switch await runStagedPipeline(originalPrompt: prompt, scoutID: scoutID) {
            case .completed:
                continue
            case .retryable:
                stagedPromptQueue.insert(prompt, at: 0)
                stagedQueueDidChange()
                return
            case .stopped, .cancelled:
                return
            }
        }
        if !Task.isCancelled { stage = "Idle" }
    }

    /// Wait (bounded) for the scout's turn to finish, then fan the original
    /// prompt + the scout's contract to the executors, tracking them to Idle.
    /// A >10-minute scout surfaces a timeout stage and stops waiting; never
    /// crashes.
    private func runStagedPipeline(originalPrompt: String, scoutID: String) async -> StagedPipelineResult {
        guard let scout = columns.first(where: { $0.id == scoutID }) else {
            stage = "Scout unavailable — prompt kept in queue"
            return .retryable
        }
        stage = "Scouting…"
        let priorScoutMessageCount = scout.conversation.rows.reduce(into: 0) { count, row in
            if case .message = row { count += 1 }
        }
        guard scout.conversation.send(Self.scoutPrompt(for: originalPrompt)) else {
            stage = "Scout disconnected — prompt kept in queue"
            return .retryable
        }
        let scoutSettle = await waitForSettle(
            columnIDs: [scoutID],
            timeoutStage: "Scout timed out — queued prompts paused"
        )
        guard !Task.isCancelled else { return .cancelled }
        guard scoutSettle == .settled else { return .stopped }
        let scoutMessageCount = scout.conversation.rows.reduce(into: 0) { count, row in
            if case .message = row { count += 1 }
        }
        guard scoutMessageCount > priorScoutMessageCount,
              !Self.lastUserTurnFailed(in: scout.conversation.rows) else {
            stage = "Scout failed before producing a contract — pipeline paused"
            return .stopped
        }
        let rows = columns.first(where: { $0.id == scoutID })?.conversation.rows ?? []
        let contract = Self.lastMessageText(in: rows)
        let executors = columns.filter { $0.role == .executor }
        let prompt = Self.executorPrompt(original: originalPrompt, contract: contract)
        var executorIDs: [String] = []
        for column in executors {
            if column.conversation.send(prompt) { executorIDs.append(column.id) }
        }
        if executors.isEmpty {
            stage = "Idle"
            return .completed
        }
        guard !executorIDs.isEmpty else {
            stage = "Executors disconnected — pipeline paused"
            return .stopped
        }
        stage = executorIDs.count == executors.count
            ? "Executing…"
            : "Executing with \(executorIDs.count) of \(executors.count) agents…"
        let executorSettle = await waitForSettle(
            columnIDs: executorIDs,
            timeoutStage: "Executors timed out — queued prompts paused"
        )
        guard !Task.isCancelled else { return .cancelled }
        guard executorSettle == .settled else { return .stopped }
        if executors.contains(where: { column in
            executorIDs.contains(column.id) && Self.lastUserTurnFailed(in: column.conversation.rows)
        }) {
            stage = "An executor failed — queued prompts paused"
            return .stopped
        }
        if executorIDs.count != executors.count {
            stage = "Some executors were unavailable — pipeline paused"
            return .stopped
        }
        stage = "Idle"
        return .completed
    }

    // MARK: - Idea brainstorm cycle

    /// Idea send: every column answers the prompt concurrently (no peer content,
    /// no edits), then — after all initial turns end — exactly ONE reaction pass
    /// runs where each column reacts to its peers' answers. Bounded to two turns
    /// per send. Falls back to a flat fan-out when the session isn't idea mode.
    @discardableResult
    func sendIdea(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard purpose == .idea, !columns.isEmpty else {
            return send(trimmed)
        }
        cancelStageCoordinator()
        stage = "Ideating…"
        let initial = Self.ideaInitialPrompt(for: trimmed)
        var columnIDs: [String] = []
        for column in columns {
            if column.conversation.send(initial) { columnIDs.append(column.id) }
        }
        guard !columnIDs.isEmpty else {
            stage = "Ideators disconnected — draft preserved"
            return false
        }
        if columnIDs.count != columns.count {
            stage = "Ideating with \(columnIDs.count) of \(columns.count) agents…"
        }
        stageTask = Task { [weak self] in
            await self?.runIdeaCycle(originalPrompt: trimmed, columnIDs: columnIDs)
        }
        return true
    }

    /// Wait for every column's initial turn to finish, snapshot each answer, then
    /// fan a single reaction pass (each column reacts to the OTHERS' answers) and
    /// track it to Idle. Bounded; never crashes.
    private func runIdeaCycle(originalPrompt: String, columnIDs: [String]) async {
        let initialSettle = await waitForSettle(
            columnIDs: columnIDs,
            timeoutStage: "Idea timed out — send again"
        )
        guard !Task.isCancelled, initialSettle == .settled else { return }
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
        let reactionSettle = await waitForSettle(
            columnIDs: columnIDs,
            timeoutStage: "Reaction timed out — send again"
        )
        guard !Task.isCancelled, reactionSettle == .settled else { return }
        stage = "Idle"
    }

    /// Poll until the given columns have all been running and then all stopped —
    /// i.e. their current turns have settled. Bounded: a 30s grace covers the
    /// "never started" case, and `timeoutStage`, when given, sets the stage on a
    /// 10-minute hard cap. Cancellation and disconnects are explicit outcomes,
    /// so callers never continue into a later phase after a failed handoff.
    private enum SettleResult: Equatable {
        case settled
        case didNotStart
        case timedOut
        case disconnected
        case cancelled
    }

    private func waitForSettle(columnIDs: [String], timeoutStage: String? = nil) async -> SettleResult {
        guard !columnIDs.isEmpty else { return .settled }
        var sawRunning = false
        // `AcpConversation.send` marks a dispatched or queued turn running
        // synchronously. Five seconds is ample scheduling grace without hiding
        // a rejected handoff for half a minute.
        let startGrace = Date().addingTimeInterval(5)
        let hardDeadline = Date().addingTimeInterval(10 * 60)
        while true {
            if Task.isCancelled { return .cancelled }
            if Date() >= hardDeadline {
                stage = timeoutStage ?? "Agents timed out — queued prompts paused"
                return .timedOut
            }
            let targets = columns.filter { columnIDs.contains($0.id) }
            let running = targets.contains { $0.conversation.isRunning }
            if running { sawRunning = true }
            if sawRunning && !running { return .settled }
            if !sawRunning,
               (targets.count != columnIDs.count || targets.allSatisfy({ !$0.conversation.isConnected })) {
                stage = "Agent disconnected before the handoff started"
                return .disconnected
            }
            if !sawRunning && Date() >= startGrace {
                stage = "Agent did not start — queued prompts paused"
                return .didNotStart
            }
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

    /// Graft a column's worktree diff onto the base project and report what
    /// happened as a value. Success, "there was nothing to apply", a conflicted
    /// graft, and an outright failure are four cases the caller can switch on;
    /// the view never has to read English out of an error to decide how loud to
    /// be about it.
    func integrate(columnID: String) async -> MeshIntegrationOutcome {
        let name = columns.first { $0.id == columnID }?.agent.name ?? "column"
        let base = baseDirectory
        let patch = await diff(for: columnID)
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noChanges(agent: name)
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try GitService(repoRoot: base).applyPatch(patch)
            }.value
            return .applied(agent: name, destination: base.lastPathComponent)
        } catch {
            return .from(applyError: error, agent: name)
        }
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

    nonisolated static func lastUserTurnFailed(in rows: [AcpTranscriptRow]) -> Bool {
        for row in rows.reversed() {
            if case let .user(_, _, failed) = row { return failed }
        }
        return false
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

/// What one integration attempt did, carried as a value instead of a sentence.
/// Success, "there was nothing to apply", a conflicted graft, and an outright
/// failure are four cases; severity, symbol, the VoiceOver announcement and the
/// offered recovery are all computed from the case. The message is display text
/// only, so a permission or I/O failure keeps its weight no matter how git
/// happened to word it. Kept free of the main actor so tests can build outcomes
/// directly.
enum MeshIntegrationOutcome: Equatable, Sendable {
    case applied(agent: String, destination: String)
    case noChanges(agent: String)
    case conflicted(agent: String, paths: [String])
    case failed(agent: String, reason: Reason)

    /// Why an integration failed, mirroring `GitService.PatchApplyFailure`
    /// without its conflict/empty cases — those are outcomes of their own above.
    /// `detail` is git's own words, shown but never inspected.
    enum Reason: Equatable, Sendable {
        case notARepository
        case permissionDenied(detail: String)
        case patchRejected(detail: String)
        case io(detail: String)
        case gitFailed(detail: String)

        var detail: String {
            switch self {
            case .notARepository: ""
            case let .permissionDenied(detail), let .patchRejected(detail),
                 let .io(detail), let .gitFailed(detail): detail
            }
        }

        /// Shown when git said nothing useful, so the line is never blank.
        var headline: String {
            switch self {
            case .notARepository: "the destination folder is not a git repository."
            case .permissionDenied: "the destination folder is not writable."
            case .patchRejected: "git refused this diff and left the project unchanged."
            case .io: "the integration could not run."
            case .gitFailed: "git apply failed."
            }
        }

        var symbol: String {
            switch self {
            case .notARepository: "questionmark.folder"
            case .permissionDenied: "lock.fill"
            case .patchRejected: "xmark.circle.fill"
            case .io: "externaldrive.badge.exclamationmark"
            case .gitFailed: "exclamationmark.octagon.fill"
            }
        }
    }

    /// How loud the status line should be. Views map this to a tint; nothing
    /// maps a message to a tint.
    enum Severity: Equatable, Sendable {
        case success
        case informational
        case warning
        case failure

        /// Spoken first, so VoiceOver carries the urgency that the tint carries
        /// visually.
        var spokenLabel: String {
            switch self {
            case .success: "Integration succeeded"
            case .informational: "Integration notice"
            case .warning: "Integration needs you"
            case .failure: "Integration failed"
            }
        }
    }

    /// The recovery a given outcome earns. Buttons come from this list, so a
    /// failure always offers a way forward and a success does not offer a
    /// pointless retry.
    enum Recovery: String, Equatable, Sendable, Identifiable {
        case reviewDiff
        case retry
        case revealDestination
        case dismiss

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reviewDiff: "Review Diff"
            case .retry: "Try Again"
            case .revealDestination: "Reveal in Finder"
            case .dismiss: "Dismiss"
            }
        }

        var symbol: String {
            switch self {
            case .reviewDiff: "doc.text.magnifyingglass"
            case .retry: "arrow.clockwise"
            case .revealDestination: "folder"
            case .dismiss: "xmark"
            }
        }

        var help: String {
            switch self {
            case .reviewDiff: "Re-read this column's worktree diff"
            case .retry: "Attempt the integration again"
            case .revealDestination: "Open the base project in Finder"
            case .dismiss: "Hide this integration status"
            }
        }
    }

    var severity: Severity {
        switch self {
        case .applied: .success
        case .noChanges: .informational
        case .conflicted: .warning
        case .failed: .failure
        }
    }

    var symbol: String {
        switch self {
        case .applied: "checkmark.circle.fill"
        case .noChanges: "tray"
        case .conflicted: "exclamationmark.triangle.fill"
        case let .failed(_, reason): reason.symbol
        }
    }

    var message: String {
        switch self {
        case let .applied(agent, destination):
            "Applied \(agent)'s diff to \(destination)."
        case let .noChanges(agent):
            "\(agent): no changes to apply."
        case let .conflicted(agent, paths):
            "\(agent): applied with conflicts in \(GitService.PatchApplyFailure.naming(paths)). Resolve the git markers (<<<<<<< / ======= / >>>>>>>) left in those files."
        case let .failed(agent, reason):
            "\(agent): \(reason.detail.isEmpty ? reason.headline : reason.detail)"
        }
    }

    var accessibilityAnnouncement: String {
        "\(severity.spokenLabel). \(message)"
    }

    var recoveryActions: [Recovery] {
        switch self {
        case .applied, .noChanges:
            [.dismiss]
        case .conflicted:
            [.revealDestination, .dismiss]
        case let .failed(_, reason):
            switch reason {
            case .notARepository: [.revealDestination, .dismiss]
            case .permissionDenied: [.revealDestination, .retry, .dismiss]
            case .patchRejected: [.reviewDiff, .retry, .dismiss]
            case .io, .gitFailed: [.retry, .dismiss]
            }
        }
    }

    /// Narrow a thrown apply error to an outcome. Everything is decided by the
    /// typed case; the error's text only ever becomes display detail. An error
    /// from outside `GitService` is a genuine unknown and stays a failure.
    static func from(applyError: Error, agent: String) -> MeshIntegrationOutcome {
        guard let failure = applyError as? GitService.PatchApplyFailure else {
            return .failed(agent: agent, reason: .gitFailed(detail: applyError.localizedDescription))
        }
        let detail = failure.errorDescription ?? ""
        switch failure {
        case .emptyPatch:
            return .noChanges(agent: agent)
        case let .conflicted(paths, _):
            return .conflicted(agent: agent, paths: paths)
        case .notARepository:
            return .failed(agent: agent, reason: .notARepository)
        case .permissionDenied:
            return .failed(agent: agent, reason: .permissionDenied(detail: detail))
        case .patchRejected:
            return .failed(agent: agent, reason: .patchRejected(detail: detail))
        case .io:
            return .failed(agent: agent, reason: .io(detail: detail))
        case .gitFailed:
            return .failed(agent: agent, reason: .gitFailed(detail: detail))
        }
    }
}
