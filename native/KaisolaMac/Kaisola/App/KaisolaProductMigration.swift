import Foundation

/// One-time bridge from the preview bundle identity to the production Kaisola
/// identity. File-backed workspace state and API credentials deliberately stay
/// in their existing secure locations for this cutover; only the defaults
/// domain changes when the app adopts `com.kaisola.mac`.
enum KaisolaProductMigration {
    static let productionBundleIdentifier = "com.kaisola.mac"
    static let legacyBundleIdentifier = "com.kaisola.mac.preview"
    static let completionKey = "kaisola.production-cutover.v1"

    static func run(
        defaults: UserDefaults = .standard,
        legacyDomain: [String: Any]? = nil,
        currentBundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        guard currentBundleIdentifier == productionBundleIdentifier,
              defaults.bool(forKey: completionKey) == false else { return }

        let source = legacyDomain
            ?? defaults.persistentDomain(forName: legacyBundleIdentifier)
            ?? [:]
        for (key, value) in source where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: completionKey)
    }
}
