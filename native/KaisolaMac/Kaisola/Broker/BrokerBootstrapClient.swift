import Dispatch
import Foundation
import ServiceManagement

protocol BrokerHelperLaunching: Sendable {
    func packageManifest() async throws -> BrokerHelperManifest
    func launch(configurationURL: URL) async throws -> Int32
    func verifiedStagedPackage(at root: URL) async throws -> VerifiedBrokerHelperPackage
    func validateStagedPackage(
        at root: URL,
        expected manifest: BrokerHelperManifest
    ) async throws
}

extension BrokerHelperLaunching {
    func verifiedStagedPackage(at root: URL) async throws -> VerifiedBrokerHelperPackage {
        try BrokerHelperPackageVerification.verify(root: root, requireSignatures: false)
    }

    func validateStagedPackage(
        at root: URL,
        expected manifest: BrokerHelperManifest
    ) async throws {
        let schema2Expectation: BrokerHelperPackageExpectation?
        switch manifest.packageKind {
        case .nodeV1:
            schema2Expectation = nil
        case let .nativeV2(appRelease, _):
            // This expected manifest came from the independently verified
            // application bundle. Reuse that trusted release identity when
            // checking the copied generation; learning it from the staged
            // manifest would make its app-release seal circular.
            schema2Expectation = BrokerHelperPackageExpectation(
                packageVersion: manifest.packageVersion,
                appReleaseVersion: appRelease.version,
                appReleaseBuild: appRelease.build
            )
        }
        let verified = try BrokerHelperPackageVerification.verify(
            root: root,
            requireSignatures: false,
            schema2Expectation: schema2Expectation
        )
        guard verified.manifest == manifest else {
            throw BrokerHelperPackageError.stagedPackageMismatch
        }
    }
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

enum BrokerSessionBrokerRuntime: Equatable, Sendable {
    case node
    case swift

    static let selectionEnvironmentKey = "KAISOLA_SESSION_BROKER_RUNTIME"

    init(environment: [String: String]) {
        // Native execution is a development-only canary. An absent, explicit
        // Node, or unrecognized value must retain the stable current runtime.
        // Only this exact spelling opts into the Swift broker.
        self = environment[Self.selectionEnvironmentKey] == "swift" ? .swift : .node
    }
}

actor BrokerBootstrapClient: BrokerHelperLaunching {
    private let bundle: Bundle
    private let registrationRecordURL: URL
    private let environment: [String: String]
    private let runtime: BrokerSessionBrokerRuntime
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
        runtime = BrokerSessionBrokerRuntime(environment: environment)
        self.directOnly = directOnly
    }

    func packageManifest() throws -> BrokerHelperManifest {
        try verifiedPackage().manifest
    }

    func verifiedStagedPackage(at root: URL) async throws -> VerifiedBrokerHelperPackage {
        let expectation = try BrokerHelperPackageVerification.bundledNativeExpectation(
            bundle: bundle
        )
        // Runtime selection chooses only the next package. It must not erase
        // the authority needed to inspect a staged Swift generation after the
        // user unsets the development opt-in. Schema 1 ignores this native
        // expectation, while schema 2 remains bound to the enclosing release
        // during rollback and generation draining.
        return try BrokerHelperPackageVerification.verify(
            root: root,
            requireSignatures: false,
            schema2Expectation: expectation
        )
    }

    func launch(configurationURL: URL) async throws -> Int32 {
        let package = try stagedPackage(for: configurationURL)
        if directOnly || environment["KAISOLA_NATIVE_DIRECT_HELPER"] == "1" {
            return try directLaunch(package: package, configurationURL: configurationURL)
        }
        try ensureRegistered(packageIdentity: package.manifest.contentDigest)
        return try await xpcLaunch(configurationURL: configurationURL)
    }

    private func verifiedPackage() throws -> VerifiedBrokerHelperPackage {
        let requireSignatures = environment["KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER"] != "1"
        switch runtime {
        case .node:
            return try BrokerHelperPackageVerification.verifyBundled(
                bundle: bundle,
                requireSignatures: requireSignatures
            )
        case .swift:
            return try BrokerHelperPackageVerification.verifyBundledNative(
                bundle: bundle,
                requireSignatures: requireSignatures
            )
        }
    }

    private func stagedPackage(for configurationURL: URL) throws -> VerifiedBrokerHelperPackage {
        let bundled = try verifiedPackage()
        let configuration: BrokerLaunchConfiguration
        do {
            configuration = try JSONDecoder().decode(
                BrokerLaunchConfiguration.self,
                from: Data(contentsOf: configurationURL, options: [.mappedIfSafe])
            )
        } catch {
            throw BrokerLaunchConfigurationError.invalidConfiguration
        }
        try configuration.validate(configurationURL: configurationURL)
        guard configuration.contentDigest == bundled.manifest.contentDigest,
              configuration.packageSchema == bundled.manifest.schemaVersion,
              configuration.packageVersion == bundled.manifest.packageVersion,
              configuration.implementationVersion == bundled.manifest.brokerImplementationVersion,
              let packageRoot = configuration.packageRoot else {
            throw BrokerHelperPackageError.incompatibleManifest
        }
        return try BrokerHelperPackageStaging.stage(
            bundled,
            at: URL(fileURLWithPath: packageRoot, isDirectory: true)
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
        var launchEnvironment = environment
        launchEnvironment["KAISOLA_STAGED_BROKER_HELPER"] = "1"
        process.environment = launchEnvironment
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
