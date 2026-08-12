import AppKit

/// Converts two already-rendered terminal viewport snapshots into one bounded
/// VoiceOver utterance. The renderer has already interpreted ANSI/OSC/DCS, so
/// this policy never exposes the raw PTY stream. Line overlap handles the
/// ordinary scrolling case; a cursor-addressed repaint speaks only its newest
/// readable line instead of the whole viewport.
enum TerminalAccessibilityAnnouncementPolicy {
    static let throttleInterval: TimeInterval = 0.8
    static let maximumCharacters = 600

    static func announcement(previous: String, current: String) -> String? {
        let previous = normalizedSnapshot(previous)
        let current = normalizedSnapshot(current)
        guard !current.isEmpty, current != previous else { return nil }

        let candidate: String
        if current.hasPrefix(previous) {
            candidate = String(current.dropFirst(previous.count))
        } else {
            let oldLines = previous.split(separator: "\n", omittingEmptySubsequences: false)
            let newLines = current.split(separator: "\n", omittingEmptySubsequences: false)
            var overlap = min(oldLines.count, newLines.count)
            while overlap > 0,
                  !oldLines.suffix(overlap).elementsEqual(newLines.prefix(overlap)) {
                overlap -= 1
            }
            if overlap > 0, overlap < newLines.count {
                candidate = newLines.dropFirst(overlap).joined(separator: "\n")
            } else {
                candidate = newLines.last(where: {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }).map(String.init) ?? current
            }
        }

        let readable = readableText(candidate)
        guard !readable.isEmpty else { return nil }
        return String(readable.suffix(maximumCharacters))
    }

    private static func normalizedSnapshot(_ input: String) -> String {
        var lines = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func readableText(_ input: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A:
                scalars.append(scalar)
            case 0x20...0x7E, 0xA0...0x10FFFF:
                scalars.append(scalar)
            default:
                continue
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Owns the bounded accessibility snapshot and announcement lifecycle for one
/// terminal view. Rendering can replace or replay independently; this adapter
/// keeps VoiceOver throttling, focus gating, and raw-stream sanitization state
/// out of the renderer and exposes deterministic seams to its focused tests.
@MainActor
final class TerminalAccessibilityAdapter: NSObject {
    typealias Snapshot = (_ retainedSource: String) -> String

    private weak var element: NSView?
    private let snapshot: Snapshot
    private var retainedSource = ""
    private var baseline = ""
    private var needsBaseline = true

    private(set) var isAnnouncementScheduled = false
    private(set) var announcementScheduleCount = 0
    var isVoiceOverEnabled: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }
    var announcementPoster: ((String) -> Void)?

    init(element: NSView, snapshot: @escaping Snapshot) {
        self.element = element
        self.snapshot = snapshot
    }

    func updateRetainedSource(_ source: String) {
        retainedSource = source
    }

    func currentSnapshot() -> String {
        snapshot(retainedSource)
    }

    func seedBaseline() {
        cancelPendingAnnouncement()
        baseline = currentSnapshot()
        needsBaseline = false
    }

    func noteLiveOutput() {
        guard isVoiceOverEnabled(), isFocused else {
            cancelPendingAnnouncement()
            needsBaseline = true
            return
        }
        if needsBaseline {
            baseline = currentSnapshot()
            needsBaseline = false
            return
        }
        guard !isAnnouncementScheduled else { return }
        isAnnouncementScheduled = true
        announcementScheduleCount += 1
        perform(
            #selector(deliverAnnouncement),
            with: nil,
            afterDelay: TerminalAccessibilityAnnouncementPolicy.throttleInterval
        )
    }

    /// Deterministic test seam; production reaches the same delivery through
    /// the main-run-loop selector scheduled by `noteLiveOutput()`.
    func deliverAnnouncementNow() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(deliverAnnouncement),
            object: nil
        )
        isAnnouncementScheduled = false
        deliverAnnouncement()
    }

    private var isFocused: Bool {
        guard let element else { return false }
        return element.window?.firstResponder === element
    }

    private func cancelPendingAnnouncement() {
        guard isAnnouncementScheduled else { return }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(deliverAnnouncement),
            object: nil
        )
        isAnnouncementScheduled = false
    }

    @objc private func deliverAnnouncement() {
        isAnnouncementScheduled = false
        guard isVoiceOverEnabled(), isFocused, let element else {
            needsBaseline = true
            return
        }

        let current = currentSnapshot()
        let previous = baseline
        baseline = current
        needsBaseline = false
        guard let announcement = TerminalAccessibilityAnnouncementPolicy.announcement(
            previous: previous,
            current: current
        ) else { return }

        if let announcementPoster {
            announcementPoster(announcement)
        } else {
            NSAccessibility.post(
                element: element,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }
}
