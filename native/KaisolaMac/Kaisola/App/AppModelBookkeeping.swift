import Foundation

/// A bounded, insertion-ordered set of surface identifiers.
///
/// AppModel keeps tombstones for surfaces the user explicitly closed so late,
/// already-buffered events cannot resurrect state that was just deleted. Those
/// tombstones are only useful for as long as such an event can still arrive,
/// but a plain `Set` kept every id a window ever closed for the life of the
/// process. Bounding by recency keeps the guarantee where it matters and gives
/// the structure a ceiling.
struct BoundedIdentifierSet: Equatable, Sendable {
    let limit: Int
    private var order: [String] = []
    private var members: Set<String> = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { members.count }
    var isEmpty: Bool { members.isEmpty }
    /// Oldest first.
    var identifiers: [String] { order }

    func contains(_ identifier: String) -> Bool { members.contains(identifier) }

    mutating func insert(_ identifier: String) {
        if members.contains(identifier) {
            order.removeAll { $0 == identifier }
        } else {
            members.insert(identifier)
        }
        order.append(identifier)
        while order.count > limit {
            members.remove(order.removeFirst())
        }
    }

    @discardableResult
    mutating func remove(_ identifier: String) -> Bool {
        guard members.remove(identifier) != nil else { return false }
        order.removeAll { $0 == identifier }
        return true
    }

    mutating func removeAll() {
        order.removeAll()
        members.removeAll()
    }
}

/// Per-surface bookkeeping keyed by identifier.
enum SurfaceBookkeeping {
    /// Drop entries for surfaces that no longer exist. Intent tokens, pending
    /// operations, and timers are all keyed by a terminal or chat id; when the
    /// broker's authoritative inventory stops listing one, the entries fencing
    /// its suspended work can never match again.
    static func pruned<Value>(
        _ entries: [String: Value],
        keeping liveIDs: Set<String>
    ) -> [String: Value] {
        guard entries.contains(where: { !liveIDs.contains($0.key) }) else { return entries }
        return entries.filter { liveIDs.contains($0.key) }
    }
}

/// Shutdown work that must outlive the surface that started it.
///
/// Closing a chat starts an async ACP stop that has to be awaited at window
/// teardown so application termination cannot strand a child adapter. Keeping
/// those tasks in a plain dictionary meant every close in the window's life
/// stayed there — including the ones that had already finished seconds later.
/// Each entry carries a token so a completed shutdown removes only itself and
/// never the newer shutdown that replaced it.
@MainActor
final class ShutdownTaskRegistry {
    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var entries: [String: Entry] = [:]

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// Start (or replace) the shutdown for `id`. The returned task is the same
    /// one the registry retains; awaiting it also guarantees the entry is gone.
    @discardableResult
    func start(
        _ id: String,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let token = UUID()
        entries[id]?.task.cancel()
        let task = Task { @MainActor [weak self] in
            await operation()
            guard let self, self.entries[id]?.token == token else { return }
            self.entries[id] = nil
        }
        entries[id] = Entry(token: token, task: task)
        return task
    }

    /// Await every in-flight shutdown. Entries prune themselves as they finish;
    /// the final clear covers one that was superseded while suspended.
    func drain() async {
        for task in entries.values.map(\.task) {
            await task.value
        }
        entries.removeAll()
    }
}
