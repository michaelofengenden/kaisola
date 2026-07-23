import AppKit
import Foundation

/// Named window states (frame + selected project), persisted in UserDefaults —
/// the native counterpart of Electron's SavedWindows. Saving under an existing
/// name replaces it.
struct SavedWindowState: Codable, Equatable, Identifiable, Sendable {
    let name: String
    /// NSWindow frame descriptor string (NSStringFromRect form).
    let frame: String
    let projectName: String?

    var id: String { name }
}

struct SavedWindowsStore {
    private let key: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, key: String = "savedWindows") {
        self.defaults = defaults
        self.key = key
    }

    func all() -> [SavedWindowState] {
        guard let data = defaults.data(forKey: key),
              let states = try? JSONDecoder().decode([SavedWindowState].self, from: data) else { return [] }
        return states
    }

    func save(_ state: SavedWindowState) {
        var states = all().filter { $0.name != state.name }
        states.append(state)
        states.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist(states)
    }

    func remove(name: String) {
        persist(all().filter { $0.name != name })
    }

    private func persist(_ states: [SavedWindowState]) {
        if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: key)
        }
    }
}
