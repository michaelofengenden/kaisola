import Foundation

/// The needs-you inbox's presentation logic, kept pure so grouping, filtering,
/// and the stale-row rule are testable without a popover.
///
/// The inbox is cross-project by construction (`AttentionCenter.Entry` carries
/// no project), so project affiliation is resolved at render time by looking
/// the target up among live surfaces. That lookup is injected as `context`,
/// which is also what decides staleness: an entry whose target no longer
/// exists renders dimmed with a clear affordance instead of a jump that lands
/// on a "session unavailable" screen.
enum AttentionInboxModel {
    struct Row: Equatable, Identifiable {
        let entry: AttentionCenter.Entry
        /// False when the target surface is gone — the row dims and offers
        /// clear-only.
        let targetExists: Bool

        var id: String { entry.id }
    }

    struct Section: Equatable, Identifiable {
        /// nil groups entries whose project could not be named — closed
        /// projects and gone surfaces.
        let projectName: String?
        let rows: [Row]

        var id: String { projectName ?? "\u{1F}elsewhere" }
        var title: String { projectName ?? "Elsewhere" }
    }

    /// Newest first inside each section; sections ordered by their newest
    /// entry so the project that just needed you is on top, with the
    /// no-project group always last.
    static func sections(
        entries: [AttentionCenter.Entry],
        kinds: Set<AttentionCenter.Kind>? = nil,
        context: (String) -> (projectName: String?, exists: Bool)
    ) -> [Section] {
        let filtered = entries.filter { kinds?.contains($0.kind) ?? true }
        var grouped: [String?: [Row]] = [:]
        for entry in filtered.sorted(by: { $0.at > $1.at }) {
            let resolved = context(entry.targetID)
            grouped[resolved.projectName, default: []].append(
                Row(entry: entry, targetExists: resolved.exists)
            )
        }
        return grouped
            .map { Section(projectName: $0.key, rows: $0.value) }
            .sorted { lhs, rhs in
                switch (lhs.projectName, rhs.projectName) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                default:
                    return (lhs.rows.first?.entry.at ?? .distantPast)
                        > (rhs.rows.first?.entry.at ?? .distantPast)
                }
            }
    }

    /// The filter chips, in display order, with their labels. "All" is the
    /// nil filter and lives in the view.
    static let filterChips: [(kinds: Set<AttentionCenter.Kind>, label: String)] = [
        ([.permission], "Permissions"),
        ([.turnCompleted, .sessionResponded], "Done"),
        ([.bell], "Bells"),
    ]
}
