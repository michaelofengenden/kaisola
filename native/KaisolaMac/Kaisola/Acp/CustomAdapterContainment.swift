import Darwin
import Foundation

/// Host services and direct resources available to one ACP adapter launch.
/// Built-ins retain the historical unrestricted contract; custom adapters use
/// `contained(privileges:)`, which deliberately never exposes the host terminal
/// bridge because that bridge would spawn outside the adapter's Seatbelt.
struct AcpAdapterAccess: Equatable, Sendable {
    let workspaceRead: Bool
    let workspaceWrite: Bool
    let network: Bool
    let childProcess: Bool
    let hostTerminal: Bool

    static let unrestricted = AcpAdapterAccess(
        workspaceRead: true,
        workspaceWrite: true,
        network: true,
        childProcess: true,
        hostTerminal: true
    )

    static func contained(privileges: Set<CustomAdapterPrivilege>) -> AcpAdapterAccess {
        AcpAdapterAccess(
            workspaceRead: privileges.contains(.workspaceRead),
            workspaceWrite: privileges.contains(.workspaceWrite),
            network: privileges.contains(.network),
            childProcess: privileges.contains(.childProcess),
            hostTerminal: false
        )
    }
}

/// Fully prepared process boundary. Keeping environment and access beside the
/// executable makes it difficult for a caller to apply only the wrapper while
/// accidentally handing the adapter the app's inherited environment.
struct AcpAdapterLaunch: Equatable, Sendable {
    let command: String
    let arguments: [String]
    let environment: [String: String]
    let cwd: String
    let access: AcpAdapterAccess
    /// Nil for built-ins. Retained for deterministic contract tests and for an
    /// actionable launch receipt; it never contains credentials or file data.
    let sandboxProfile: String?
}

/// A deny-by-default Seatbelt launch for one integrity-verified, user-approved
/// custom ACP adapter.
///
/// The supported runtime boundary is intentionally narrow: production custom
/// npm adapters run as JavaScript under Kaisola's sealed Node runtime. Shell,
/// Python, native, and arbitrary shebang adapters fail closed rather than
/// recovering the user's login shell (and its dotfiles/environment).
struct CustomAdapterContainment: Equatable, Sendable {
    enum Runtime: Equatable, Sendable {
        /// Resolve and integrity-verify `Contents/Resources/BrokerHelper/bin/node`
        /// at launch. This keeps the runtime inside the signed app seal.
        case bundled
        /// Test seam for a fixed executable already contained in `trustedRoot`.
        case fixed(executableURL: URL, trustedRoot: URL)
    }

    enum ContainmentError: LocalizedError, Equatable {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(reason):
                "Custom ACP adapter containment could not be established: \(reason)"
            }
        }
    }

    let agentID: String
    let executableURL: URL
    let installRoot: URL
    let approval: CustomAdapterApproval
    /// Captured from the resolver's successful verification. Production
    /// launches re-check it before every start/restart; nil is reserved for
    /// direct deterministic containment fixtures.
    let installRecord: InstalledAdapterRecord?
    let runtime: Runtime
    let sandboxExecutableURL: URL
    let stateRoot: URL

    init(
        agentID: String,
        executableURL: URL,
        installRoot: URL,
        approval: CustomAdapterApproval,
        installRecord: InstalledAdapterRecord? = nil,
        runtime: Runtime = .bundled,
        sandboxExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
        stateRoot: URL? = nil
    ) {
        self.agentID = agentID
        self.executableURL = executableURL
        self.installRoot = installRoot
        self.approval = approval
        self.installRecord = installRecord
        self.runtime = runtime
        self.sandboxExecutableURL = sandboxExecutableURL
        self.stateRoot = stateRoot ?? Self.defaultStateRoot(agentID: agentID)
    }

    /// Resolve every path, create the private HOME/cache tree, sanitize the
    /// environment, and produce the exact `sandbox-exec` invocation. Any doubt
    /// is an error; there is no unsandboxed fallback.
    func prepare(environment source: [String: String], cwd: String) throws -> AcpAdapterLaunch {
        guard approval.isCurrentAndValid,
              let credentials = approval.resolvedCredentials,
              let privileges = approval.resolvedPrivileges else {
            throw ContainmentError.unavailable(
                "the stored access review is missing, invalid, or from an older boundary version; review and re-enable it"
            )
        }

        if let installRecord {
            guard installRecord.agentID == agentID else {
                throw ContainmentError.unavailable("the approved install belongs to a different custom agent")
            }
            switch AdapterInstallManager.verify(
                record: installRecord,
                installRoot: installRoot,
                expectedPackage: installRecord.package,
                expectedApproval: approval
            ) {
            case let .verified(verifiedExecutable, _):
                let expected = try Self.requireExecutable(
                    executableURL,
                    label: "the approved adapter executable"
                )
                let verified = try Self.requireExecutable(
                    verifiedExecutable,
                    label: "the re-verified adapter executable"
                )
                guard expected == verified else {
                    throw ContainmentError.unavailable("the approved adapter executable changed")
                }
            case let .drifted(reason):
                throw ContainmentError.unavailable(reason)
            case .notInstalled:
                throw ContainmentError.unavailable("the approved adapter install is gone")
            }
        }

        let sandbox = try Self.requireExecutable(
            sandboxExecutableURL,
            label: "the required /usr/bin/sandbox-exec boundary"
        )
        let canonicalInstall = try Self.requireDirectory(
            installRoot,
            label: "the approved adapter install root"
        )
        let adapter = try Self.requireExecutable(executableURL, label: "the approved adapter executable")
        guard Self.isContained(adapter.path, in: canonicalInstall.path) else {
            throw ContainmentError.unavailable("the approved adapter executable escaped its install root")
        }

        let resolvedRuntime: (executable: URL, trustedRoot: URL)
        switch runtime {
        case .bundled:
            do {
                let package = try BrokerHelperPackageVerification.verifyBundled(
                    requireSignatures: source["KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER"] != "1"
                )
                try Self.requireNodeEntrypoint(adapter)
                resolvedRuntime = (package.nodeExecutable, package.root)
            } catch let error as ContainmentError {
                throw error
            } catch {
                throw ContainmentError.unavailable(
                    "Kaisola's sealed Node runtime failed verification (\(error.localizedDescription))"
                )
            }
        case let .fixed(executableURL, trustedRoot):
            resolvedRuntime = (executableURL, trustedRoot)
        }
        let trustedRuntimeRoot = try Self.requireDirectory(
            resolvedRuntime.trustedRoot,
            label: "the trusted runtime root"
        )
        let runtimeExecutable = try Self.requireExecutable(
            resolvedRuntime.executable,
            label: "the approved runtime"
        )
        guard Self.isContained(runtimeExecutable.path, in: trustedRuntimeRoot.path) else {
            throw ContainmentError.unavailable("the approved runtime escaped its trusted root")
        }

        let workspace = try Self.requireDirectory(
            URL(fileURLWithPath: cwd, isDirectory: true),
            label: "the session workspace"
        )
        let state = try Self.preparePrivateState(at: stateRoot)
        try Self.requireDisjoint([
            ("adapter install", canonicalInstall),
            ("session workspace", workspace),
            ("private adapter state", state.root),
        ])
        let credentialDirectory = try Self.credentialDirectory(
            credentials: credentials,
            source: source,
            protectedRoots: [workspace, canonicalInstall, trustedRuntimeRoot, state.root]
        )
        let sanitized = Self.sanitizedEnvironment(
            source: source,
            credentials: credentials,
            credentialDirectory: credentialDirectory,
            state: state
        )
        let profile = Self.profile(
            privileges: privileges,
            hasCredentialDirectory: credentialDirectory != nil
        )

        var arguments = [
            "-D", "KAISOLA_RUNTIME=\(runtimeExecutable.path)",
            "-D", "KAISOLA_ADAPTER_ROOT=\(canonicalInstall.path)",
            "-D", "KAISOLA_STATE_ROOT=\(state.root.path)",
            "-D", "KAISOLA_WORKSPACE=\(workspace.path)",
        ]
        if let credentialDirectory {
            arguments += ["-D", "KAISOLA_CREDENTIALS=\(credentialDirectory.path)"]
        }
        arguments += ["-p", profile, runtimeExecutable.path, adapter.path]

        return AcpAdapterLaunch(
            command: sandbox.path,
            arguments: arguments,
            environment: sanitized,
            cwd: workspace.path,
            access: .contained(privileges: privileges),
            sandboxProfile: profile
        )
    }

    /// Static SBPL with path parameters supplied as argv values, never string
    /// interpolation. A path containing quotes/newlines therefore cannot add a
    /// rule. The imported system baseline exposes platform libraries and small
    /// amounts of OS metadata, but not the user's home or application data.
    static func profile(
        privileges: Set<CustomAdapterPrivilege>,
        hasCredentialDirectory: Bool = false
    ) -> String {
        var sections = [
            """
            (version 1)
            (deny default)
            (import "system.sb")
            ; `system.sb` opens syslog by default. Custom adapter output already
            ; has ACP stdio, so close that unrelated local Unix socket again.
            (deny network-outbound (literal "/private/var/run/syslog"))
            """,
            """
            (allow process-exec (literal (param "KAISOLA_RUNTIME")))
            (allow process-info-pidinfo (target self))
            (allow process-info-codesignature (target self))
            """,
            """
            (allow file-read-metadata file-test-existence
              (path-ancestors (param "KAISOLA_RUNTIME"))
              (path-ancestors (param "KAISOLA_ADAPTER_ROOT"))
              (path-ancestors (param "KAISOLA_STATE_ROOT"))
              (path-ancestors (param "KAISOLA_WORKSPACE")))
            (allow file-read* file-map-executable
              (literal (param "KAISOLA_RUNTIME"))
              (subpath (param "KAISOLA_ADAPTER_ROOT")))
            (allow file-read* file-write* (subpath (param "KAISOLA_STATE_ROOT")))
            """,
        ]
        if hasCredentialDirectory {
            sections.append("""
            (allow file-read-metadata file-test-existence
              (path-ancestors (param "KAISOLA_CREDENTIALS")))
            (allow file-read* file-write* (subpath (param "KAISOLA_CREDENTIALS")))
            """)
        }
        if privileges.contains(.workspaceRead) {
            sections.append("(allow file-read* (subpath (param \"KAISOLA_WORKSPACE\")))")
        }
        if privileges.contains(.workspaceWrite) {
            sections.append("(allow file-write* (subpath (param \"KAISOLA_WORKSPACE\")))")
        }
        if privileges.contains(.childProcess) {
            sections.append("""
            (allow process-fork)
            (allow process-exec)
            (allow file-read* file-map-executable
              (subpath "/bin")
              (subpath "/sbin")
              (subpath "/usr/bin")
              (subpath "/usr/sbin"))
            """)
            if privileges.contains(.workspaceRead) {
                sections.append(
                    "(allow file-map-executable (subpath (param \"KAISOLA_WORKSPACE\")))"
                )
            }
        }
        if privileges.contains(.network) {
            sections.append("""
            (system-network)
            (allow network-outbound
              (literal "/private/var/run/mDNSResponder")
              (remote ip))
            """)
        }
        return sections.joined(separator: "\n") + "\n"
    }

    private struct StateDirectories {
        let root: URL
        let home: URL
        let temporary: URL
        let cache: URL
        let configuration: URL
        let data: URL
        let npmCache: URL
    }

    private static func defaultStateRoot(agentID: String) -> URL {
        let digest = AdapterInstallManager.sha256(Data(agentID.utf8))
        return NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("acp-adapter-sandboxes", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(24)), isDirectory: true)
    }

    private static func preparePrivateState(at requestedRoot: URL) throws -> StateDirectories {
        let root = requestedRoot.standardizedFileURL
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let configuration = root.appendingPathComponent("config", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let npmCache = root.appendingPathComponent("npm-cache", isDirectory: true)
        for directory in [root, home, temporary, cache, configuration, data, npmCache] {
            try secureDirectory(directory)
        }
        return StateDirectories(
            root: try requireDirectory(root, label: "private adapter state"),
            home: try requireDirectory(home, label: "private adapter home"),
            temporary: try requireDirectory(temporary, label: "private adapter temporary directory"),
            cache: try requireDirectory(cache, label: "private adapter cache"),
            configuration: try requireDirectory(configuration, label: "private adapter configuration"),
            data: try requireDirectory(data, label: "private adapter data"),
            npmCache: try requireDirectory(npmCache, label: "private adapter npm cache")
        )
    }

    private static func secureDirectory(_ url: URL) throws {
        var value = stat()
        if lstat(url.path, &value) == 0 {
            guard value.st_mode & S_IFMT == S_IFDIR,
                  value.st_uid == getuid() else {
                throw ContainmentError.unavailable(
                    "private adapter state at \(url.path) is symlinked, not a directory, or has the wrong owner"
                )
            }
        } else {
            guard errno == ENOENT else {
                throw ContainmentError.unavailable("private adapter state at \(url.path) is unreadable")
            }
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw ContainmentError.unavailable(
                    "private adapter state could not be created (\(error.localizedDescription))"
                )
            }
            guard lstat(url.path, &value) == 0,
                  value.st_mode & S_IFMT == S_IFDIR,
                  value.st_uid == getuid() else {
                throw ContainmentError.unavailable("private adapter state was not created safely")
            }
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw ContainmentError.unavailable("private adapter state permissions could not be restricted")
        }
    }

    private static func sanitizedEnvironment(
        source: [String: String],
        credentials: CustomAgentSpec.Credentials,
        credentialDirectory: URL?,
        state: StateDirectories
    ) -> [String: String] {
        var result: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": state.home.path,
            "CFFIXED_USER_HOME": state.home.path,
            "TMPDIR": state.temporary.path + "/",
            "XDG_CACHE_HOME": state.cache.path,
            "XDG_CONFIG_HOME": state.configuration.path,
            "XDG_DATA_HOME": state.data.path,
            "NPM_CONFIG_CACHE": state.npmCache.path,
            "NODE_REPL_HISTORY": "/dev/null",
            "NO_UPDATE_NOTIFIER": "1",
            "KAISOLA": "1",
            "KAISOLA_ACP_CONTAINMENT": "1",
        ]
        for key in [
            "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TERM", "COLORTERM",
            "NO_COLOR", "FORCE_COLOR", "KAISOLA_SESSION_ID",
        ] {
            if let value = boundedEnvironmentValue(source[key]) { result[key] = value }
        }

        let providerKeys: [String]
        let directoryKey: String?
        switch credentials {
        case .claude:
            providerKeys = [
                "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
                "CLAUDE_CODE_OAUTH_TOKEN",
            ]
            directoryKey = "CLAUDE_CONFIG_DIR"
        case .codex:
            providerKeys = [
                "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_MODEL", "CODEX_CONFIG",
            ]
            directoryKey = "CODEX_HOME"
        case .none:
            providerKeys = []
            directoryKey = nil
        }
        for key in providerKeys {
            if let value = boundedEnvironmentValue(source[key], maximumBytes: 65_536) {
                result[key] = value
            }
        }
        if let directoryKey, let credentialDirectory {
            result[directoryKey] = credentialDirectory.path
        }
        return result
    }

    private static func boundedEnvironmentValue(
        _ value: String?,
        maximumBytes: Int = 4_096
    ) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumBytes,
              !value.contains("\0") else { return nil }
        return value
    }

    private static func credentialDirectory(
        credentials: CustomAgentSpec.Credentials,
        source: [String: String],
        protectedRoots: [URL]
    ) throws -> URL? {
        let key: String?
        switch credentials {
        case .claude: key = "CLAUDE_CONFIG_DIR"
        case .codex: key = "CODEX_HOME"
        case .none: key = nil
        }
        guard let key,
              let rawValue = source[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        guard rawValue.hasPrefix("/"), rawValue.utf8.count <= 4_096,
              rawValue.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ContainmentError.unavailable("the selected credential directory is invalid")
        }
        let directory = try requireDirectory(
            URL(fileURLWithPath: rawValue, isDirectory: true),
            label: "the selected credential directory"
        )
        var value = stat()
        guard lstat(directory.path, &value) == 0, value.st_uid == getuid() else {
            throw ContainmentError.unavailable(
                "the selected credential directory is not owned by the current user"
            )
        }
        let home = (try? requireDirectory(
            FileManager.default.homeDirectoryForCurrentUser,
            label: "the current user home"
        ).path) ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let broadRoots: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes",
            "/bin", "/dev", "/private", "/private/etc", "/private/tmp",
            "/private/var", "/opt", "/sbin", "/usr", home,
        ]
        let overlapsProtectedRoot = protectedRoots.contains { root in
            isContained(directory.path, in: root.path) || isContained(root.path, in: directory.path)
        }
        if broadRoots.contains(directory.path) || overlapsProtectedRoot {
            throw ContainmentError.unavailable(
                "the selected credential directory is too broad or overlaps protected runtime/workspace state; choose the provider's dedicated account directory"
            )
        }
        return directory
    }

    private static func requireNodeEntrypoint(_ url: URL) throws {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 256) ?? Data()
            guard let text = String(data: prefix, encoding: .utf8) else {
                throw ContainmentError.unavailable(
                    "the approved npm executable is not a supported JavaScript entrypoint"
                )
            }
            if text.hasPrefix("#!") {
                let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                guard firstLine.lowercased().contains("node") else {
                    throw ContainmentError.unavailable(
                        "the approved npm executable requests an unsupported runtime; custom ACP adapters must use Node"
                    )
                }
            }
        } catch let error as ContainmentError {
            throw error
        } catch {
            throw ContainmentError.unavailable(
                "the approved npm executable could not be inspected (\(error.localizedDescription))"
            )
        }
    }

    private static func requireExecutable(_ requested: URL, label: String) throws -> URL {
        let canonical = try canonicalExistingURL(requested, label: label)
        var value = stat()
        guard lstat(canonical.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: canonical.path) else {
            throw ContainmentError.unavailable("\(label) is missing or not executable")
        }
        return canonical
    }

    private static func requireDirectory(_ requested: URL, label: String) throws -> URL {
        let canonical = try canonicalExistingURL(requested, label: label)
        var value = stat()
        guard lstat(canonical.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR else {
            throw ContainmentError.unavailable("\(label) is missing or not a directory")
        }
        return canonical
    }

    private static func isContained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func requireDisjoint(_ roots: [(String, URL)]) throws {
        for leftIndex in roots.indices {
            for rightIndex in roots.indices where rightIndex > leftIndex {
                let left = roots[leftIndex]
                let right = roots[rightIndex]
                if isContained(left.1.path, in: right.1.path)
                    || isContained(right.1.path, in: left.1.path) {
                    throw ContainmentError.unavailable(
                        "the \(left.0) overlaps the \(right.0)"
                    )
                }
            }
        }
    }

    /// `URL.resolvingSymlinksInPath()` leaves macOS firmlink spellings such as
    /// `/var` intact even though Seatbelt evaluates them as `/private/var`.
    /// `realpath(3)` gives verification and the profile one kernel-canonical
    /// spelling, preventing both false denials and path-alias policy gaps.
    private static func canonicalExistingURL(_ requested: URL, label: String) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(requested.path, &buffer) != nil else {
            throw ContainmentError.unavailable("\(label) could not be resolved")
        }
        // Do not call `standardizedFileURL` here: Foundation rewrites an
        // existing `/private/var/...` URL back to `/var/...`, undoing the
        // kernel-canonical spelling that Seatbelt requires.
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let path = String(decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path)
    }
}
