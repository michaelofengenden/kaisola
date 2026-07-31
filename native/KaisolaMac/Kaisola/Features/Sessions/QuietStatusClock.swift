import Foundation

/// Remembers when each surface last CHANGED status, so rows can show
/// time-in-state ("working for 34m"), not time-since-creation.
struct QuietStatusClock {
    private var entries: [String: (status: QuietSessionStatus, at: Date)] = [:]

    mutating func note(id: String, status: QuietSessionStatus, at: Date) {
        if entries[id]?.status != status {
            entries[id] = (status, at)
        }
    }

    func since(id: String) -> Date? { entries[id]?.at }
}

enum QuietTimeLabel {
    static func label(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
