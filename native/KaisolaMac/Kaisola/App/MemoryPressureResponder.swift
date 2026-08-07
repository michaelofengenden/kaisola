import Foundation

/// System memory pressure purges every discretionary cache (2026-08-06 spec
/// §2g). Owners register a named purge at setup; the responder never imports
/// their worlds. Purges run on the main actor — every registered cache is
/// main-actor state — and only on warning/critical, so the app sheds parked
/// terminal buffers, decoded images, wallpaper bakes, and file indexes
/// before the OS starts compressing or jetsamming anything.
@MainActor
final class MemoryPressureResponder {
    static let shared = MemoryPressureResponder()

    private var purges: [(name: String, purge: @MainActor () -> Void)] = []
    private var source: DispatchSourceMemoryPressure?
    private(set) var lastPurgeAt: Date?

    private init() {}

    func register(name: String, purge: @escaping @MainActor () -> Void) {
        purges.removeAll { $0.name == name }
        purges.append((name, purge))
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.purgeAll() }
        }
        source.activate()
        self.source = source
    }

    /// Also the test seam.
    func purgeAll() {
        for entry in purges { entry.purge() }
        lastPurgeAt = Date()
    }
}
