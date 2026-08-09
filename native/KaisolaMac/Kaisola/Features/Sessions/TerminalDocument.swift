import Combine
import Foundation

/// The exact broker bytes represented by the latest document publication.
/// SwiftTerm can consume this directly when its rendered cursor matches,
/// keeping the retained full string solely as reconstruction/history state.
struct TerminalSurfaceDelta: Equatable, Sendable {
    let epoch: String
    let startOffset: Int64
    let endOffset: Int64
    let data: String

    init?(epoch: String, startOffset: Int64, endOffset: Int64, data: String) {
        guard !epoch.isEmpty,
              startOffset >= 0,
              startOffset + Int64(data.utf8.count) == endOffset else { return nil }
        self.epoch = epoch
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.data = data
    }
}

/// A short, contiguous burst of broker output. AppModel merges packets for one
/// display interval before publishing its large retained document, bounding
/// SwiftUI invalidations without changing byte-exact cursor semantics.
struct TerminalOutputBatch: Equatable, Sendable {
    static let maximumBytes = 2 * 1_024 * 1_024
    let projectID: String
    let terminalID: String
    let epoch: String
    let startOffset: Int64
    private(set) var endOffset: Int64
    private(set) var data: String

    init?(
        projectID: String,
        terminalID: String,
        epoch: String,
        startOffset: Int64,
        endOffset: Int64,
        data: String
    ) {
        guard !projectID.isEmpty,
              !terminalID.isEmpty,
              !epoch.isEmpty,
              startOffset >= 0,
              data.utf8.count <= Self.maximumBytes,
              startOffset + Int64(data.utf8.count) == endOffset else { return nil }
        self.projectID = projectID
        self.terminalID = terminalID
        self.epoch = epoch
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.data = data
    }

    mutating func append(epoch: String, startOffset: Int64, endOffset: Int64, data: String) -> Bool {
        guard self.epoch == epoch,
              self.endOffset == startOffset,
              self.data.utf8.count + data.utf8.count <= Self.maximumBytes,
              startOffset + Int64(data.utf8.count) == endOffset else { return false }
        self.data.append(data)
        self.endOffset = endOffset
        return true
    }
}

/// Copy-on-write terminal history in bounded UTF-8-safe pages. A published
/// document snapshot shares immutable page strings with the next snapshot.
/// Snapshots and bulk replay use 1 MiB sealed pages to avoid thousands of
/// allocator regions at maximum depth; incremental output accumulates only in
/// a 16 KiB mutable tail, so a SwiftUI-held prior value can make each append
/// copy at most that tail rather than a growing megabyte. The full 64 MiB
/// history remains byte-exact and broker-pageable.
struct TerminalScrollback: Equatable, Sendable {
    static let targetPageBytes = 1_024 * 1_024
    static let mutableTailBytes = 16 * 1_024

    private(set) var pages: [String]
    private(set) var byteCount: Int

    init(_ output: String = "") {
        pages = Self.pages(from: output)
        byteCount = output.utf8.count
    }

    var output: String {
        switch pages.count {
        case 0: ""
        case 1: pages[0]
        default: pages.joined()
        }
    }

    mutating func append(_ data: String) {
        guard !data.isEmpty else { return }
        let dataBytes = data.utf8.count
        if let last = pages.indices.last,
           pages[last].utf8.count + dataBytes <= Self.mutableTailBytes {
            pages[last].append(data)
        } else {
            pages.append(contentsOf: Self.pages(from: data))
        }
        byteCount += dataBytes
    }

    /// Drops at least `byteCount - targetBytes`, rounding forward only when a
    /// byte target lands inside a Unicode scalar. Returns whether any history
    /// was removed.
    @discardableResult
    mutating func trim(to targetBytes: Int) -> Bool {
        guard byteCount > targetBytes else { return false }
        var bytesToDrop = byteCount - max(0, targetBytes)
        var wholePages = 0
        while wholePages < pages.count {
            let pageBytes = pages[wholePages].utf8.count
            guard pageBytes <= bytesToDrop else { break }
            bytesToDrop -= pageBytes
            wholePages += 1
        }
        if wholePages > 0 { pages.removeFirst(wholePages) }
        if bytesToDrop > 0, !pages.isEmpty {
            var first = pages[0]
            let utf8 = first.utf8
            var boundary = utf8.index(
                utf8.startIndex,
                offsetBy: min(bytesToDrop, utf8.count)
            )
            while boundary < utf8.endIndex,
                  boundary.samePosition(in: first) == nil {
                boundary = utf8.index(after: boundary)
            }
            if let stringBoundary = boundary.samePosition(in: first) {
                first.removeSubrange(first.startIndex..<stringBoundary)
                if first.isEmpty { pages.removeFirst() }
                else { pages[0] = first }
            } else {
                pages.removeAll(keepingCapacity: true)
            }
        }
        byteCount = pages.reduce(into: 0) { $0 += $1.utf8.count }
        return true
    }

    func accessibilityTail(maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        var remaining = maxCharacters
        var reversed: [Substring] = []
        for page in pages.reversed() where remaining > 0 {
            let suffix = page.suffix(remaining)
            reversed.append(suffix)
            remaining -= suffix.count
        }
        return reversed.reversed().map(String.init).joined()
    }

    /// Returns the retained suffix after an exact UTF-8 byte count without
    /// joining the page table. Broker cursors always land on scalar boundaries;
    /// a non-boundary request is rejected so the caller can recover by reset.
    func suffix(droppingUTF8Bytes requested: Int64) -> [String]? {
        guard requested >= 0, requested <= Int64(byteCount) else { return nil }
        var remaining = Int(requested)
        var result: [String] = []
        for page in pages {
            let pageBytes = page.utf8.count
            if remaining >= pageBytes {
                remaining -= pageBytes
                continue
            }
            if remaining > 0 {
                let utf8 = page.utf8
                let boundary = utf8.index(utf8.startIndex, offsetBy: remaining)
                guard let stringBoundary = boundary.samePosition(in: page) else { return nil }
                result.append(String(page[stringBoundary...]))
                remaining = 0
            } else {
                result.append(page)
            }
        }
        return remaining == 0 ? result : nil
    }

    private static func pages(from output: String) -> [String] {
        guard output.utf8.count > targetPageBytes else {
            return output.isEmpty ? [] : [output]
        }
        let utf8 = output.utf8
        var byteStart = utf8.startIndex
        var result: [String] = []
        result.reserveCapacity((utf8.count / targetPageBytes) + 1)
        while byteStart < utf8.endIndex {
            var byteEnd = utf8.index(
                byteStart,
                offsetBy: targetPageBytes,
                limitedBy: utf8.endIndex
            ) ?? utf8.endIndex
            while byteEnd < utf8.endIndex,
                  byteEnd.samePosition(in: output) == nil {
                byteEnd = utf8.index(after: byteEnd)
            }
            guard let start = byteStart.samePosition(in: output),
                  let end = byteEnd.samePosition(in: output),
                  start < end else { break }
            result.append(String(output[start..<end]))
            byteStart = byteEnd
        }
        return result
    }
}

struct TerminalDocument: Equatable, Sendable {
    /// Cold select now tops up to a single ~4 MiB tail instead of paging the
    /// whole spool ("fetch a tail on cold select, not the whole spool"), so
    /// the tail policy makes a large resident buffer pointless: nothing fills
    /// it past the first frame. Deep history beyond this cap is the
    /// transcript viewer's job — it pages further `terminal.history` straight
    /// from the broker's durable spool instead of holding it all in memory.
    // 5 MiB (was 16; 2026-08-06 spec §2c): the observer tail policy's own
    // comment proves bytes past ~4 MiB are unreachable by the renderer — a
    // deeper tail could not put a single additional row within reach — so
    // 5 MiB keeps one slack megabyte and returns up to 11 MiB per retained
    // document to the user.
    static let maximumRetainedBytes = 5 * 1_024 * 1_024

    /// How far *below* the cap a trim drops the buffer.
    ///
    /// Trimming exactly the overflow meant that a saturated buffer memmoved the
    /// whole remaining ~8 MB for every arriving chunk, however small — on the
    /// main actor, for every PTY packet. Undershooting amortises that move
    /// across the ~2 MB of output that follows it, while keeping the retained
    /// ceiling at exactly `maximumRetainedBytes`: the cap is a memory budget
    /// spanning every retained surface, so it must not drift upwards.
    static let retainedTrimSlackBytes = 1 * 1_024 * 1_024

    var sessionID: String?
    private(set) var scrollback: TerminalScrollback
    var cursor: TerminalCursor?
    var truncated: Bool
    var exited: Bool
    var errorMessage: String?
    var surfaceDelta: TerminalSurfaceDelta? = nil

    var output: String { scrollback.output }

    init(
        sessionID: String?,
        output: String,
        cursor: TerminalCursor?,
        truncated: Bool,
        exited: Bool,
        errorMessage: String?,
        surfaceDelta: TerminalSurfaceDelta? = nil
    ) {
        self.init(
            sessionID: sessionID,
            scrollback: TerminalScrollback(output),
            cursor: cursor,
            truncated: truncated,
            exited: exited,
            errorMessage: errorMessage,
            surfaceDelta: surfaceDelta
        )
    }

    init(
        sessionID: String?,
        scrollback: TerminalScrollback,
        cursor: TerminalCursor?,
        truncated: Bool,
        exited: Bool,
        errorMessage: String?,
        surfaceDelta: TerminalSurfaceDelta? = nil
    ) {
        self.sessionID = sessionID
        self.scrollback = scrollback
        self.cursor = cursor
        self.truncated = truncated
        self.exited = exited
        self.errorMessage = errorMessage
        self.surfaceDelta = surfaceDelta
    }

    static let empty = TerminalDocument(
        sessionID: nil,
        output: "",
        cursor: nil,
        truncated: false,
        exited: false,
        errorMessage: nil
    )

    /// An empty canvas already bound to a real session. Publishing this before
    /// an async subscribe prevents the prior terminal from flashing beneath a
    /// newly-selected sidebar row while the broker returns its retained tail.
    static func loading(sessionID: String) -> TerminalDocument {
        TerminalDocument(
            sessionID: sessionID,
            output: "",
            cursor: nil,
            truncated: false,
            exited: false,
            errorMessage: nil
        )
    }

    static func failure(sessionID: String, message: String) -> TerminalDocument {
        TerminalDocument(
            sessionID: sessionID,
            output: "",
            cursor: nil,
            truncated: false,
            exited: false,
            errorMessage: message
        )
    }

    /// Shown while the broker cannot read a terminal's retained spool. The
    /// scrollback on screen stays where it is, so the wording says the history
    /// is stale rather than gone, and the next reconnect or gap recovery
    /// resubscribes on its own.
    static func spoolReadDiagnostic(_ code: String) -> String {
        "Could not read this terminal's saved history (\(code)). Showing the last output received; retrying."
    }

    func applying(_ result: TerminalSubscriptionResult, sessionID: String) -> TerminalDocument {
        switch result {
        case let .snapshot(snapshot, resetReason):
            let readDiagnostic = snapshot.readError.map(Self.spoolReadDiagnostic)
            // A cursor-based resubscribe returns only bytes after the cursor.
            // Preserve the already-rendered prefix when the broker proves the
            // suffix is exactly contiguous; reset snapshots still replace it.
            if resetReason == nil,
               self.sessionID == sessionID,
               let cursor,
               cursor.streamEpoch == snapshot.streamEpoch,
               cursor.offset == snapshot.startOffset {
                var document = self
                document.scrollback.append(snapshot.output)
                document.cursor = TerminalCursor(
                    streamEpoch: snapshot.streamEpoch,
                    offset: snapshot.endOffset
                )
                document.exited = snapshot.exited
                // Only a failed read changes the retention verdict here: a
                // healthy contiguous resubscribe is exactly as complete as the
                // document already was.
                document.truncated = truncated || snapshot.readError != nil
                document.errorMessage = readDiagnostic
                document.surfaceDelta = TerminalSurfaceDelta(
                    epoch: snapshot.streamEpoch,
                    startOffset: snapshot.startOffset,
                    endOffset: snapshot.endOffset,
                    data: snapshot.output
                )
                document.trimRetainedOutputIfNeeded()
                return document
            }
            // A spool the broker could not read is not an empty transcript.
            // Replacing the rendered scrollback here is the destructive half
            // of that confusion: a single transient EACCES on the spool file
            // would wipe the session the user is looking at. Keep the last
            // good frame and its cursor — the next contiguity failure routes
            // through the ordinary gap recovery, which resubscribes — and
            // carry a diagnostic that says the history is stale, not gone.
            if let readDiagnostic, self.sessionID == sessionID {
                var document = self
                document.truncated = true
                document.exited = snapshot.exited
                document.errorMessage = readDiagnostic
                document.surfaceDelta = nil
                return document
            }
            var document = TerminalDocument(
                sessionID: sessionID,
                output: snapshot.output,
                cursor: TerminalCursor(streamEpoch: snapshot.streamEpoch, offset: snapshot.endOffset),
                truncated: snapshot.truncated || resetReason != nil,
                exited: snapshot.exited,
                errorMessage: readDiagnostic
            )
            document.trimRetainedOutputIfNeeded()
            return document
        case let .current(cursor):
            return TerminalDocument(
                sessionID: sessionID,
                output: self.sessionID == sessionID ? output : "",
                cursor: cursor,
                truncated: self.sessionID == sessionID && truncated,
                exited: self.sessionID == sessionID && exited,
                errorMessage: nil
            )
        }
    }

    mutating func append(epoch: String, startOffset: Int64, endOffset: Int64, data: String) -> Bool {
        guard let cursor,
              cursor.streamEpoch == epoch,
              cursor.offset == startOffset,
              startOffset + Int64(data.utf8.count) == endOffset else { return false }
        scrollback.append(data)
        self.cursor = TerminalCursor(streamEpoch: epoch, offset: endOffset)
        surfaceDelta = TerminalSurfaceDelta(
            epoch: epoch,
            startOffset: startOffset,
            endOffset: endOffset,
            data: data
        )
        trimRetainedOutputIfNeeded()
        return true
    }

    private mutating func trimRetainedOutputIfNeeded() {
        let byteCount = scrollback.byteCount
        guard byteCount > Self.maximumRetainedBytes else { return }

        let target = max(0, Self.maximumRetainedBytes - Self.retainedTrimSlackBytes)
        if scrollback.trim(to: target) { truncated = true }
    }
}

/// A card-local publication lane for high-frequency terminal output.
///
/// `AppModel` owns IDE structure (projects, panes, selection, attention), while
/// each mounted terminal observes one of these feeds. Streaming bytes therefore
/// update SwiftTerm without invalidating the root sidebar, workspace rail,
/// menus, sheets, and footer on every coalesced broker packet.
@MainActor
final class TerminalSurfaceFeed: ObservableObject {
    @Published private(set) var document: TerminalDocument

    init(document: TerminalDocument) {
        self.document = document
    }

    func replace(with document: TerminalDocument) {
        guard self.document != document else { return }
        self.document = document
    }
}
