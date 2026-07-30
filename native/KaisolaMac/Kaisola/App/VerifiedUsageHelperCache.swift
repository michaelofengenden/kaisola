import Foundation

/// Process-lifetime memo for the usage reader's helper verification.
///
/// `BrokerHelperPackageVerification.verify` is genuinely expensive: it runs a
/// strict `SecStaticCodeCheckValidity` over the containing application and then
/// streams a SHA-256 over every packaged file — which includes a ~227 MB Node
/// binary. That is a couple of seconds of work, and the usage refresh ran it
/// *every* time: on launch, on each project switch, and after each TTL expiry.
/// It is the single largest reason account and usage cards feel slow to appear.
///
/// Deliberately scoped to this one caller rather than added inside
/// `BrokerHelperPackageVerification`. Broker startup adopts and launches a
/// privileged helper and must keep verifying strictly every time; reading usage
/// numbers does not warrant re-proving the same bytes on a 3-minute cadence.
///
/// Invalidation keys on the manifest's identity — path, size, and modification
/// time — plus `requireSignatures`, so a replaced or re-signed helper (an update
/// swapping the app bundle, say) re-verifies from scratch rather than inheriting
/// a stale pass. A cached *failure* is never stored: errors always re-run, so a
/// transient verification failure can't latch the feature off for the session.
final class VerifiedUsageHelperCache: @unchecked Sendable {
    static let shared = VerifiedUsageHelperCache()

    private struct Key: Hashable {
        let path: String
        let requireSignatures: Bool
        let manifestSize: Int64
        let manifestModified: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [Key: VerifiedBrokerHelperPackage] = [:]

    private init() {}

    func package(root: URL, requireSignatures: Bool) throws -> VerifiedBrokerHelperPackage {
        guard let key = Self.key(root: root, requireSignatures: requireSignatures) else {
            // No readable manifest stat means no trustworthy cache identity, so
            // fall through to a full verification and let it report the failure.
            return try BrokerHelperPackageVerification.verify(
                root: root,
                requireSignatures: requireSignatures
            )
        }

        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached { return cached }

        let package = try BrokerHelperPackageVerification.verify(
            root: root,
            requireSignatures: requireSignatures
        )
        lock.lock()
        entries[key] = package
        lock.unlock()
        return package
    }

    /// Test seam.
    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private static func key(root: URL, requireSignatures: Bool) -> Key? {
        let manifest = root.appendingPathComponent("manifest.json", isDirectory: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: manifest.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Key(
            path: root.standardizedFileURL.path,
            requireSignatures: requireSignatures,
            manifestSize: size.int64Value,
            manifestModified: modified.timeIntervalSince1970
        )
    }
}
