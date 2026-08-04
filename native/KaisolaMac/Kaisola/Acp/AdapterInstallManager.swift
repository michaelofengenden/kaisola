import CryptoKit
import Foundation

/// One resolved, pinned ACP adapter install — the durable form of a user's
/// approval (adversarial review, finding 2: `npx <pkg>@latest` is mutable
/// code, so approving it approves nothing in particular).
///
/// The record freezes what the approval meant: the package as typed, the
/// version npm resolved it to, a SHA-256 over the lockfile that pins the
/// complete dependency graph, and the executable's path inside the install.
/// At spawn time `AdapterInstallManager.verify` recomputes the hash; any
/// drift — an edited lockfile, a swapped binary, a vanished install — refuses
/// the chat surface until the user approves again.
struct InstalledAdapterRecord: Codable, Equatable, Identifiable {
    let agentID: String
    let package: String
    let resolvedVersion: String
    /// Relative to the agent's install root.
    let binRelativePath: String
    let lockfileSHA256: String
    let installedAt: Date

    var id: String { agentID }
}

/// Installs, verifies, and records custom-agent ACP adapters.
///
/// Install layout: `<application support>/acp-adapters/<agentID>/` holding a
/// plain npm prefix (`node_modules`, `package-lock.json`). Installation runs
/// with **scripts disabled** — a lifecycle script executing during
/// enablement would be arbitrary code before the user's approval finished
/// meaning anything. The adapter itself still runs with the user's ordinary
/// access once enabled; the enable sheet says so in those words (finding 1).
struct AdapterInstallManager: Sendable {
    struct Store: Sendable {
        let fileURL: URL

        init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("acp-adapter-installs.json", isDirectory: false)) {
            self.fileURL = fileURL
        }

        private struct Payload: Codable {
            var installs: [InstalledAdapterRecord]
        }

        func records() -> [InstalledAdapterRecord] {
            guard let data = try? Data(contentsOf: fileURL),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
            return payload.installs
        }

        func record(agentID: String) -> InstalledAdapterRecord? {
            records().first { $0.agentID == agentID }
        }

        func upsert(_ record: InstalledAdapterRecord) {
            var current = records().filter { $0.agentID != record.agentID }
            current.append(record)
            write(Payload(installs: current))
        }

        func remove(agentID: String) {
            let current = records()
            let remaining = current.filter { $0.agentID != agentID }
            guard remaining.count != current.count else { return }
            write(Payload(installs: remaining))
        }

        private func write(_ payload: Payload) {
            let directory = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard let data = try? JSONEncoder().encode(payload) else { return }
            let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
            do {
                try data.write(to: temporary, options: [])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
    }

    enum VerifyResult: Equatable {
        case verified(binURL: URL)
        /// The named reason feeds the settings row and the refusal toast.
        case drifted(reason: String)
        case notInstalled
    }

    enum InstallError: LocalizedError, Equatable {
        case invalidPackage(String)
        case installFailed(String)
        case unresolvable(String)

        var errorDescription: String? {
            switch self {
            case let .invalidPackage(reason): reason
            case let .installFailed(reason): "The install failed: \(reason)"
            case let .unresolvable(reason): "The installed package could not be resolved: \(reason)"
            }
        }
    }

    let store: Store
    let installsRoot: URL

    init(
        store: Store = Store(),
        installsRoot: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("acp-adapters", isDirectory: true)
    ) {
        self.store = store
        self.installsRoot = installsRoot
    }

    func installRoot(agentID: String) -> URL {
        installsRoot.appendingPathComponent(agentID, isDirectory: true)
    }

    /// Whether an agent's recorded install still is what the user approved.
    /// Pure over the filesystem: recompute the lockfile hash, require the
    /// executable to exist. Every mismatch names itself.
    func verify(agentID: String) -> VerifyResult {
        guard let record = store.record(agentID: agentID) else { return .notInstalled }
        let root = installRoot(agentID: agentID)
        let lockfile = root.appendingPathComponent("package-lock.json")
        guard let lockData = try? Data(contentsOf: lockfile) else {
            return .drifted(reason: "The install's lockfile is missing.")
        }
        let hash = Self.sha256(lockData)
        guard hash == record.lockfileSHA256 else {
            return .drifted(reason: "The install's dependency graph changed since it was approved.")
        }
        let bin = root.appendingPathComponent(record.binRelativePath)
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            return .drifted(reason: "The adapter executable is missing or not executable.")
        }
        return .verified(binURL: bin)
    }

    /// Resolve a package into a pinned install and record it. `runner` is the
    /// process seam (tests fabricate installs instead of running npm): it
    /// receives the install root and the validated package, performs
    /// `npm install --ignore-scripts` into that prefix, and throws on failure.
    func install(
        agentID: String,
        package rawPackage: String,
        runner: @Sendable (URL, String) async throws -> Void = AdapterInstallManager.npmInstall,
        now: Date = Date()
    ) async throws -> InstalledAdapterRecord {
        let package = rawPackage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = CustomAgentSpec.packageNameError(package) {
            throw InstallError.invalidPackage(reason)
        }
        let root = installRoot(agentID: agentID)
        // A fresh prefix per approval: stale files from an earlier install
        // must not survive into a new approval's hash.
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try await runner(root, package)
        } catch {
            throw InstallError.installFailed(error.localizedDescription)
        }
        let lockfile = root.appendingPathComponent("package-lock.json")
        guard let lockData = try? Data(contentsOf: lockfile) else {
            throw InstallError.unresolvable("npm produced no lockfile to pin.")
        }
        let bareName = Self.bareName(of: package)
        guard let resolved = Self.resolvedVersion(lockData: lockData, packageName: bareName) else {
            throw InstallError.unresolvable("the lockfile does not name \(bareName)'s version.")
        }
        guard let binRelative = Self.binRelativePath(root: root, packageName: bareName) else {
            throw InstallError.unresolvable("\(bareName) declares no executable.")
        }
        let record = InstalledAdapterRecord(
            agentID: agentID,
            package: package,
            resolvedVersion: resolved,
            binRelativePath: binRelative,
            lockfileSHA256: Self.sha256(lockData),
            installedAt: now
        )
        store.upsert(record)
        return record
    }

    /// Remove an install and its record — disabling is reversible and total.
    func uninstall(agentID: String) {
        store.remove(agentID: agentID)
        try? FileManager.default.removeItem(at: installRoot(agentID: agentID))
    }

    /// The package name without its version suffix (scope-aware).
    static func bareName(of package: String) -> String {
        if package.hasPrefix("@") {
            guard let slash = package.firstIndex(of: "/") else { return package }
            let afterScope = package[package.index(after: slash)...]
            if let at = afterScope.firstIndex(of: "@") {
                return String(package[..<at])
            }
            return package
        }
        if let at = package.firstIndex(of: "@") {
            return String(package[..<at])
        }
        return package
    }

    /// The resolved version for `packageName` out of npm's v2/v3 lockfile.
    static func resolvedVersion(lockData: Data, packageName: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: lockData) as? [String: Any] else {
            return nil
        }
        if let packages = root["packages"] as? [String: Any],
           let entry = packages["node_modules/\(packageName)"] as? [String: Any],
           let version = entry["version"] as? String {
            return version
        }
        // npm v1 lockfiles nest under "dependencies".
        if let dependencies = root["dependencies"] as? [String: Any],
           let entry = dependencies[packageName] as? [String: Any],
           let version = entry["version"] as? String {
            return version
        }
        return nil
    }

    /// The executable's install-relative path, read from the installed
    /// package's own `bin` declaration (string or map; first map entry wins).
    static func binRelativePath(root: URL, packageName: String) -> String? {
        let packageDirectory = "node_modules/\(packageName)"
        let manifest = root
            .appendingPathComponent(packageDirectory, isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let binPath: String?
        if let bin = json["bin"] as? String {
            binPath = bin
        } else if let bin = json["bin"] as? [String: Any] {
            binPath = bin.sorted { $0.key < $1.key }.first?.value as? String
        } else {
            binPath = nil
        }
        guard let binPath else { return nil }
        let normalized = binPath.hasPrefix("./") ? String(binPath.dropFirst(2)) : binPath
        guard !normalized.hasPrefix("/"), !normalized.contains("..") else { return nil }
        return "\(packageDirectory)/\(normalized)"
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The real installer: npm through a login shell (the user's PATH, the
    /// same resolution the adapters themselves get), scripts disabled.
    @Sendable
    static func npmInstall(root: URL, package: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // The package name passed here has survived `packageNameError`, whose
        // character set contains nothing a shell can interpret.
        process.arguments = [
            "-ilc",
            "npm install --prefix \(Self.shellQuote(root.path)) --ignore-scripts --no-fund --no-audit --loglevel=error \(Self.shellQuote(package))",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.installFailed(
                message?.isEmpty == false ? String(message!.suffix(300)) : "npm exited \(process.terminationStatus)"
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
