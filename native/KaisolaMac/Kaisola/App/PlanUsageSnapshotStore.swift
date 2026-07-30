import Foundation

/// Last-known provider plan usage, persisted so account cards paint on launch.
///
/// The in-memory `planUsageCache` in `UsageCenter` dies with the process, so the
/// first read after every launch paid the full cost — helper verification, a
/// login-shell PATH probe, and a subprocess per account — with the UI showing a
/// bare "Reading provider account limits…" spinner for seconds. Persisting the
/// last good reading means the cards render immediately from disk and the live
/// probe just replaces them when it lands.
///
/// Entries are keyed by `UsageCenter.planUsageContextKey`, which already folds
/// in the workspace, the account environment, and digests of the credential
/// files themselves. That is what makes this safe to show eagerly: a different
/// project, a different account, or a re-authentication all produce a different
/// key, so a stale entry can never be displayed under the wrong context — it
/// simply misses and the spinner behaves as before.
///
/// Nothing secret is written. The payload is labels, plan names, percentages,
/// and timestamps; credentials stay in the Keychain and the CLIs' own stores.
struct PlanUsageSnapshotStore: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var providers: [UsageCenter.ProviderPlanUsage]
        var fetchedAt: Date
    }

    private struct Payload: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]
    }

    private static let schemaVersion = 1
    /// Bounded so a long-lived install with many projects cannot grow this
    /// unboundedly; oldest readings are dropped first.
    private static let maximumEntries = 24

    let fileURL: URL

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("plan-usage-snapshots.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func entries() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else { return [:] }
        return payload.entries
    }

    func save(_ entries: [String: Entry]) {
        var bounded = entries
        if bounded.count > Self.maximumEntries {
            let keep = bounded
                .sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(Self.maximumEntries)
            bounded = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let payload = Payload(schemaVersion: Self.schemaVersion, entries: bounded)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)"
        )
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
