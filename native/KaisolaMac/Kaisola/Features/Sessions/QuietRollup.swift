import Foundation

/// Collapsed-header aggregate: "3 ● ●" — count of active sessions plus one
/// dot per distinct active state, amber (needs-you) always at the outer edge.
struct QuietRollup: Equatable {
    let total: Int
    let dots: [QuietSessionStatus]

    static func of(_ statuses: [QuietSessionStatus]) -> QuietRollup {
        let active = statuses.filter { $0 != .idle && $0 != .ended }
        // Outermost-last display priority: done < working < failed < needsYou.
        let order: [QuietSessionStatus] = [.doneUnseen, .working, .failed, .needsYou]
        let distinct = order.filter { state in active.contains(state) }
        return QuietRollup(total: active.count, dots: Array(distinct.suffix(3)))
    }
}
