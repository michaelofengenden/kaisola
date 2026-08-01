import Combine
import CoreServices
import Foundation

/// One debounced, bounded set of exact workspace paths. Consumers may refresh
/// only affected directories; `requiresFullRefresh` is the correctness fallback
/// for dropped/coalesced events, a root event, or a path-count overflow.
struct WorkspaceChangeBatch: Equatable, Sendable {
    let token: Int
    let paths: [URL]
    let requiresFullRefresh: Bool

    static let empty = WorkspaceChangeBatch(
        token: 0,
        paths: [],
        requiresFullRefresh: false
    )
}

/// Live filesystem watching for the workspace rail (`WorkspaceRailView`).
///
/// Agents write files constantly, but the tree previously only refreshed on a
/// manual "Refresh" or the palette index's 30s TTL — so freshly created,
/// edited, moved, or deleted files stayed invisible until the user poked it.
/// This watcher recursively observes a project root and publishes a monotonic
/// `changeToken`; the rail keys its re-listing off that token so the tree
/// tracks whatever the agents (or the user) are doing on disk.
///
/// **Why FSEvents, not `DispatchSource`.** FSEvents watches an entire subtree
/// from a single stream. A `DispatchSource(.vnode)` fan-out would need one file
/// descriptor per directory and manual re-registration as directories come and
/// go — untenable for a deep repo. FSEvents handles recursion in the kernel.
///
/// **Bursts are coalesced twice.** An agent rewriting a dozen files, a
/// `git checkout`, or `npm install` churn would otherwise fire a storm of
/// refreshes. The stream's own 0.5s latency batches the OS notifications, and a
/// trailing 700ms debounce collapses whatever survives filtering into at most
/// one `changeToken` bump per window (≤1 bump / 700ms).
///
/// **Delivery is on the main thread.** The stream is bound to the main dispatch
/// queue (`FSEventStreamSetDispatchQueue(.main)` — the non-deprecated successor
/// to `FSEventStreamScheduleWithRunLoop`, which Apple deprecated in macOS 13).
/// The main queue is serviced by the main run loop, so this preserves
/// main-thread delivery while also draining in every common run-loop mode
/// (menu/scroll/resize tracking), so the tree keeps updating during UI
/// interaction. The C callback carries no Swift context, so it recovers `self`
/// from the opaque `info` pointer and hops to the MainActor to touch published
/// state.
@MainActor
final class WorkspaceWatcher: ObservableObject {
    /// Advanced (never reset) whenever a relevant change settles. Observers key
    /// their refresh off the change in value; the exact number is meaningless.
    @Published private(set) var changeToken: Int = 0
    @Published private(set) var changeBatch: WorkspaceChangeBatch = .empty

    private let root: URL

    /// The live FSEvents stream. `nonisolated(unsafe)` so the teardown can run
    /// from the nonisolated `deinit`; every access is single-threaded by
    /// construction — created in `init` on the main actor, mutated only in
    /// `start`/`teardownStream`, and the stream is stopped before `self` is
    /// deallocated so the callback's unretained recovery never dangles.
    nonisolated(unsafe) private var stream: FSEventStreamRef?

    /// The pending trailing-edge debounce. Non-nil means a bump is already
    /// scheduled for the current window, so further events are absorbed.
    private var pendingBump: Task<Void, Never>?
    private var pendingPaths: Set<String> = []
    private var pendingRequiresFullRefresh = false

    /// FSEvents coalescing latency: the OS batches raw notifications over this
    /// window before delivering a callback.
    private static let latency: CFTimeInterval = 0.5

    /// Trailing debounce applied on top of the FSEvents latency, capping the
    /// bump rate at ≤1 per this interval.
    private static let debounceNanoseconds: UInt64 = 700_000_000
    static let maximumDetailedPaths = 256

    init(root: URL) {
        self.root = root.standardizedFileURL
        start()
    }

    deinit {
        // deinit is nonisolated and runs on whichever thread drops the last
        // reference (in practice the main thread, since a SwiftUI @StateObject
        // is released on the main actor). It only touches the C stream through
        // the nonisolated(unsafe) handle. The MainActor `pendingBump` Task holds
        // `self` weakly, so it simply no-ops once we're gone and needs no
        // teardown here.
        teardownStream()
    }

    /// Stop watching and release the stream. Idempotent, and safe to call ahead
    /// of `deinit`. MainActor-isolated so it can also cancel the pending bump.
    func stop() {
        pendingBump?.cancel()
        pendingBump = nil
        pendingPaths.removeAll()
        pendingRequiresFullRefresh = false
        teardownStream()
    }

    // MARK: - Relevance (pure, testable)

    /// True unless any path component is an ignored build/vendor directory
    /// (`node_modules`, `.git`, `build`, `dist`, …). The match is component-wise,
    /// not substring, so a file literally named `rebuild` is *not* caught by
    /// `build`. Pure and free of I/O, so it is unit-testable without a live
    /// stream.
    nonisolated static func isRelevant(path: String) -> Bool {
        for component in path.split(separator: "/", omittingEmptySubsequences: true)
        where ProjectFiles.ignoredNames.contains(String(component)) {
            return false
        }
        return true
    }

    /// FSEvents explicitly tells clients when its detail stream is incomplete.
    /// Those batches must never drive targeted invalidation.
    nonisolated static func requiresFullRefresh(
        flags: [FSEventStreamEventFlags]
    ) -> Bool {
        let unsafeFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        return flags.contains { $0 & unsafeFlags != 0 }
    }

    // MARK: - FSEvents lifecycle

    private func start() {
        // Never start on a missing path or a non-directory root: watching simply
        // never begins (no crash), and every teardown path stays a safe no-op.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    /// Tear the stream down: stop → invalidate → release, then drop the handle.
    /// nonisolated so `deinit` can call it; a nil handle makes it a no-op, so
    /// `stop()` followed by `deinit` is safe (no double free).
    nonisolated private func teardownStream() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// The C event callback. A `@convention(c)` closure cannot capture context,
    /// so it recovers `self` from the opaque `info` pointer and hops to the
    /// MainActor. Capturing `watcher` across the hop is safe: a `@MainActor`
    /// class is implicitly `Sendable`, and the strong capture keeps it alive for
    /// the (brief) duration of the hop.
    private static let eventCallback: FSEventStreamCallback = {
        _, info, eventCount, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
        // With kFSEventStreamCreateFlagUseCFTypes the payload is a CFArray of
        // CFString, toll-free bridged to [String].
        let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
        let flags = Array(UnsafeBufferPointer(
            start: eventFlags,
            count: Int(eventCount)
        ))
        Task { @MainActor in
            watcher.ingest(paths, flags: flags)
        }
    }

    /// Called on the MainActor for each delivered batch. Drops batches whose
    /// paths are all ignored, otherwise arms the debounce.
    private func ingest(
        _ paths: [String],
        flags: [FSEventStreamEventFlags]
    ) {
        if Self.requiresFullRefresh(flags: flags) {
            pendingRequiresFullRefresh = true
            pendingPaths.removeAll(keepingCapacity: true)
            scheduleBump()
            return
        }
        let rootPath = root.path
        for rawPath in paths where Self.isRelevant(path: rawPath) {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            if path == rootPath || pendingPaths.count >= Self.maximumDetailedPaths {
                pendingRequiresFullRefresh = true
                pendingPaths.removeAll(keepingCapacity: true)
                break
            }
            pendingPaths.insert(path)
        }
        guard pendingRequiresFullRefresh || !pendingPaths.isEmpty else { return }
        scheduleBump()
    }

    /// Trailing-edge debounce: the first event of a window schedules one bump
    /// 700ms out; further events in that window find `pendingBump` already set
    /// and are absorbed. A single bump re-lists the whole visible tree, so every
    /// change in the window is reflected. Net rate: ≤1 bump / 700ms.
    private func scheduleBump() {
        guard pendingBump == nil else { return }
        pendingBump = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.pendingBump = nil
            self.bump()
        }
    }

    private func bump() {
        changeToken &+= 1
        let paths = pendingPaths.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let requiresFullRefresh = pendingRequiresFullRefresh
        pendingPaths.removeAll(keepingCapacity: true)
        pendingRequiresFullRefresh = false

        // Keep the palette index in step without throwing away cached indexes
        // for other projects or crawling this entire project after one edit.
        ProjectFileIndex.shared.invalidate(
            root: root,
            changedPaths: paths,
            requiresFullRefresh: requiresFullRefresh
        )
        changeBatch = WorkspaceChangeBatch(
            token: changeToken,
            paths: paths,
            requiresFullRefresh: requiresFullRefresh
        )
    }
}
