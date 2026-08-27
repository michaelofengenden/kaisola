import CryptoKit
import Darwin
import Foundation

/// Identity of the terminal engine a connection speaks to. With the engine
/// in-process this is synthesized by `InProcessTerminalService`; the shape
/// survives from the detached-broker era because persisted resume cursors and
/// test doubles are scoped by `persistenceIdentity`.
struct BrokerInfo: Equatable, Sendable {
    let protocolVersion: Int
    let securityEpoch: Int
    let implementationVersion: Int?
    let packageSchema: Int?
    let packageVersion: String?
    let contentDigest: String?
    let pid: Int32
    let socketPath: String
    let token: String
    let startedAt: Int64
    let version: String

    init(
        protocolVersion: Int,
        securityEpoch: Int,
        implementationVersion: Int? = nil,
        packageSchema: Int? = nil,
        packageVersion: String? = nil,
        contentDigest: String? = nil,
        pid: Int32,
        socketPath: String,
        token: String,
        startedAt: Int64,
        version: String
    ) {
        self.protocolVersion = protocolVersion
        self.securityEpoch = securityEpoch
        self.implementationVersion = implementationVersion
        self.packageSchema = packageSchema
        self.packageVersion = packageVersion
        self.contentDigest = contentDigest
        self.pid = pid
        self.socketPath = socketPath
        self.token = token
        self.startedAt = startedAt
        self.version = version
    }

    /// A non-secret, stable scope for native resume cursors. Hashing the
    /// launch material keeps a cursor from one engine identity from ever
    /// being replayed against another.
    var persistenceIdentity: String {
        let material = [
            String(protocolVersion),
            String(securityEpoch),
            String(pid),
            String(startedAt),
            socketPath,
            token,
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

protocol BrokerInfoLocating: Sendable {
    func locate() throws -> BrokerInfo
}

/// Profile naming that outlived broker discovery: `NativeSessionStore` still
/// scopes its archive by whether the app runs the development profile.
enum BrokerInfoLocator {
    enum PreviewProfile: String, Sendable {
        case native
        case development
        case installed
    }

    static let developmentProfileName = "Kaisola Dev"
    static let nativeOwnProfileName = "Kaisola Native"

    static var defaultPreviewProfile: PreviewProfile {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["KAISOLA_NATIVE_BROKER_PROFILE"],
           let profile = PreviewProfile(rawValue: explicit) {
            return profile
        }
        // Backward compatibility for older development launcher scripts.
        if environment["KAISOLA_NATIVE_USE_DEV_PROFILE"] == "1" {
            return .development
        }
        return .native
    }
}

/// A deliberately narrow launch contract for paired native/Electron resource
/// measurements. The normal app never consults this root: only an explicitly
/// named workload may route its fixture state beneath the caller's private
/// temporary directory.
struct NativeResourceWorkloadConfiguration: Equatable, Sendable {
    static let idleID = "one-window-idle-terminal-fresh-broker"
    static let streamingID = "one-window-streaming-terminal-fresh-broker"
    static let restoredWindowsID = "three-restored-project-windows-fresh-broker"
    static let supportedIDs: Set<String> = [idleID, streamingID, restoredWindowsID]

    let workloadID: String
    let root: URL

    var appStateRoot: URL {
        root.appendingPathComponent("app-state", isDirectory: true)
    }

    var workspaceRoot: URL {
        root.appendingPathComponent("workspace", isDirectory: true)
    }

    var restoredWorkspaceRoots: [URL] {
        (1...3).map { index in
            root.appendingPathComponent("workspace-\(index)", isDirectory: true)
        }
    }

    var expectedWindowCount: Int {
        workloadID == Self.restoredWindowsID ? 3 : 1
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> NativeResourceWorkloadConfiguration? {
        guard let workloadID = environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"],
              supportedIDs.contains(workloadID),
              let rawRoot = environment["KAISOLA_NATIVE_RESOURCE_ROOT"],
              rawRoot.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let temporary = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(temporary.path + "/") else { return nil }
        return NativeResourceWorkloadConfiguration(workloadID: workloadID, root: root)
    }
}
