import Dispatch
import Foundation
import ServiceManagement

protocol BrokerHelperLaunching: Sendable {
    func packageManifest() async throws -> BrokerHelperManifest
    func launch(configurationURL: URL) async throws -> Int32
}

struct BrokerBootstrapProcessOutput: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
}

/// Drain both bootstrap pipes while the process is running. Waiting first can
/// deadlock as soon as either pipe reaches its kernel buffer capacity.
enum BrokerBootstrapProcessDrainer {
    static let retainedBytesPerStream = 64 * 1024

    static func waitForExit(
        _ process: Process,
        stdout: Pipe,
        stderr: Pipe
    ) -> BrokerBootstrapProcessOutput {
        let outputDrain = BoundedBootstrapPipeDrain(limit: retainedBytesPerStream)
        let errorDrain = BoundedBootstrapPipeDrain(limit: retainedBytesPerStream)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputDrain.consume(stdout.fileHandleForReading)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorDrain.consume(stderr.fileHandleForReading)
            group.leave()
        }

        process.waitUntilExit()
        group.wait()
        return BrokerBootstrapProcessOutput(
            stdout: outputDrain.string,
            stderr: errorDrain.string,
            terminationStatus: process.terminationStatus
        )
    }
}

private final class BoundedBootstrapPipeDrain: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var retained = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var string: String {
        lock.withLock { String(decoding: retained, as: UTF8.self) }
    }

    func consume(_ handle: FileHandle) {
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 16 * 1024),
                      !next.isEmpty else { return }
                chunk = next
            } catch {
                return
            }
            lock.withLock {
                let remaining = max(0, limit - retained.count)
                if remaining > 0 {
                    retained.append(contentsOf: chunk.prefix(remaining))
                }
            }
        }
    }
}

actor BrokerBootstrapClient: BrokerHelperLaunching {
    private let bundle: Bundle
    private let registrationRecordURL: URL
    private let environment: [String: String]
    /// Always spawn the sealed bootstrap directly instead of going through the
    /// SMAppService agent. The fallback (separate native broker) uses this: the
    /// bootstrap double-forks a broker that provably outlives the app, and it
    /// needs no login-item registration/approval.
    private let directOnly: Bool

    init(
        bundle: Bundle = .main,
        registrationRecordURL: URL = NativePreviewPaths.helperRegistrationRecord,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directOnly: Bool = false
    ) {
        self.bundle = bundle
        self.registrationRecordURL = registrationRecordURL
        self.environment = environment
        self.directOnly = directOnly
    }

    func packageManifest() throws -> BrokerHelperManifest {
        try verifiedPackage().manifest
    }

    func launch(configurationURL: URL) async throws -> Int32 {
        let package = try verifiedPackage()
        if directOnly || environment["KAISOLA_NATIVE_DIRECT_HELPER"] == "1" {
            return try directLaunch(package: package, configurationURL: configurationURL)
        }
        try ensureRegistered(packageIdentity: package.manifest.contentDigest)
        return try await xpcLaunch(configurationURL: configurationURL)
    }

    private func verifiedPackage() throws -> VerifiedBrokerHelperPackage {
        try BrokerHelperPackageVerification.verifyBundled(
            bundle: bundle,
            requireSignatures: environment["KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER"] != "1"
        )
    }

    private func ensureRegistered(packageIdentity: String) throws {
        let service = SMAppService.agent(plistName: brokerBootstrapPlistName)
        let priorVersion = try? String(
            data: Data(contentsOf: registrationRecordURL),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        if service.status == .enabled, priorVersion == packageIdentity { return }
        if service.status == .enabled {
            try service.unregister()
        }
        switch service.status {
        case .notRegistered:
            try service.register()
        case .enabled:
            break
        case .requiresApproval:
            throw BrokerBootstrapError.requiresApproval
        case .notFound:
            throw BrokerBootstrapError.serviceNotFound
        @unknown default:
            throw BrokerBootstrapError.registrationFailed
        }
        guard service.status == .enabled else {
            if service.status == .requiresApproval { throw BrokerBootstrapError.requiresApproval }
            throw BrokerBootstrapError.registrationFailed
        }
        try NativePreviewPaths.prepareApplicationSupport()
        try Data("\(packageIdentity)\n".utf8).write(to: registrationRecordURL, options: .atomic)
        _ = chmod(registrationRecordURL.path, 0o600)
    }

    private func xpcLaunch(configurationURL: URL) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: brokerBootstrapMachService, options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: BrokerBootstrapXPCProtocol.self)
            connection.invalidationHandler = {
                // The reply path owns completion. A launchd activation may
                // invalidate immediately after the short-lived bootstrap exits.
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate()
                continuation.resume(throwing: BrokerBootstrapError.xpcFailed(error.localizedDescription))
            } as? BrokerBootstrapXPCProtocol
            guard let proxy else {
                connection.invalidate()
                continuation.resume(throwing: BrokerBootstrapError.registrationFailed)
                return
            }
            connection.resume()
            proxy.launchBroker(configurationPath: configurationURL.path) { pid, message in
                connection.invalidate()
                guard let pid, pid.int32Value > 1 else {
                    continuation.resume(throwing: BrokerBootstrapError.launchRejected(message as String?))
                    return
                }
                continuation.resume(returning: pid.int32Value)
            }
        }
    }

    private func directLaunch(
        package: VerifiedBrokerHelperPackage,
        configurationURL: URL
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = package.bootstrapExecutable
        process.arguments = ["--launch", configurationURL.path]
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let collected = BrokerBootstrapProcessDrainer.waitForExit(
            process,
            stdout: output,
            stderr: errors
        )
        guard collected.terminationStatus == 0,
              let match = collected.stdout.range(
                  of: #"BROKER_BOOTSTRAP_PID=([0-9]+)"#,
                  options: .regularExpression
              ),
              let pid = Int32(collected.stdout[match].split(separator: "=").last ?? ""),
              pid > 1 else {
            let message = collected.stderr
                .replacingOccurrences(of: #"^BROKER_BOOTSTRAP_ERROR="#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrokerBootstrapError.launchRejected(message.isEmpty ? nil : message)
        }
        return pid
    }
}

enum BrokerBootstrapError: Error, Equatable, LocalizedError {
    case requiresApproval
    case serviceNotFound
    case registrationFailed
    case xpcFailed(String)
    case launchRejected(String?)

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "Allow Kaisola in System Settings → General → Login Items, then reconnect."
        case .serviceNotFound:
            "Kaisola's packaged session helper could not be found."
        case .registrationFailed:
            "Kaisola's session helper could not be registered."
        case .xpcFailed:
            "Kaisola's session helper did not answer the secure launch request."
        case let .launchRejected(message):
            message?.isEmpty == false ? message : "Kaisola's session helper could not start saved-session continuity."
        }
    }
}
