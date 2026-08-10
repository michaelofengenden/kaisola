import AppKit
import Combine
import ImageIO
import SwiftUI

// MARK: - Wallpaper-only glass

/// Which file, if any, is currently painting the desktop.
enum DesktopWallpaperResolution: Equatable, Sendable {
    /// A picture file the user actually chose — the common case.
    case picture(URL)
    /// A still standing in for a dynamic aerial, which has no picture file.
    case aerialStill(URL)
    /// Nothing readable: the veil sits on the wallpaper's average colour instead.
    case unavailable

    var url: URL? {
        switch self {
        case let .picture(url), let .aerialStill(url): url
        case .unavailable: nil
        }
    }
}
/// Finds the image that the desktop is actually showing.
///
/// `NSWorkspace.desktopImageURL(for:)` is only half an answer. For a picture
/// desktop it returns the file, but for a dynamic aerial — including the
/// *rotating categories* that macOS 26 ships as its headline desktops — it
/// returns one fixed stand-in path for every screen rather than failing. Taking
/// that at face value paints the stock Big Sur picture behind a user whose
/// desktop is a moving Tahoe drone shot, which looks like a bug, so the
/// sentinel is recognised and the wallpaper store is consulted instead.
enum DesktopWallpaperLocator {
    /// macOS hands this back for every screen whenever the desktop cannot be
    /// expressed as a picture file.
    static let dynamicDesktopSentinelPath = "/System/Library/CoreServices/DefaultDesktop.heic"

    static var defaultSupportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/com.apple.wallpaper", directoryHint: .isDirectory)
    }

    static func isDynamicDesktopSentinel(_ url: URL) -> Bool {
        let candidate = url.standardized
        let sentinel = URL(fileURLWithPath: dynamicDesktopSentinelPath)
        if candidate.path == sentinel.path { return true }
        // The stand-in is itself a symlink — on macOS 26 it lands on
        // `/System/Library/Wallpapers/.default/DefaultAerial.heic` — and the
        // name it points at has moved between releases. Compare after
        // resolving both sides rather than hardcoding this release's target.
        return candidate.resolvingSymlinksInPath().path
            == sentinel.resolvingSymlinksInPath().path
    }

    /// The ladder, with its two disk-touching rungs injected so the ordering
    /// itself is testable. `aerialStill` reads two files, so it is deliberately
    /// a closure that a picture desktop never calls.
    static func resolve(
        desktopImageURL: URL?,
        readableStill: (URL) -> Bool,
        aerialStill: () -> URL?,
        captured: URL? = nil
    ) -> DesktopWallpaperResolution {
        // A captured desktop is the picture actually on screen, so it outranks
        // every deduced one. Everything below this line is inference; this line
        // is observation.
        if let captured, readableStill(captured) { return .picture(captured) }
        if let desktopImageURL,
           !isDynamicDesktopSentinel(desktopImageURL),
           readableStill(desktopImageURL) {
            return .picture(desktopImageURL)
        }
        if let still = aerialStill() { return .aerialStill(still) }
        return .unavailable
    }

    /// Live wiring for `resolve(desktopImageURL:readableStill:aerialStill:)`.
    static func resolveOnDisk(
        desktopImageURL: URL?,
        supportDirectory: URL? = nil,
        pinnedWallpaperPath: String? = nil
    ) -> DesktopWallpaperResolution {
        let support = supportDirectory ?? defaultSupportDirectory
        // A picture the user pinned outranks everything: it is a statement of
        // intent, not an inference, so it is not second-guessed even when the
        // desktop could have been identified.
        //
        // `captured:` stays nil while desktop capture is disabled — see the
        // note in `DesktopBackdropProvider.resolve(isDark:)`. A stale file from
        // an earlier build must never be picked up.
        let pinned = (pinnedWallpaperPath ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resolve(
            desktopImageURL: desktopImageURL,
            readableStill: { CGImageSourceCreateWithURL($0 as CFURL, nil) != nil },
            aerialStill: { currentAerialStill(supportDirectory: support) },
            captured: pinned.isEmpty ? nil : URL(fileURLWithPath: pinned)
        )
    }

    /// The store's `Index.plist` nests a *second*, binary plist inside each
    /// choice's `Configuration` value; the identifier only exists in there.
    /// `AllSpacesAndDisplays` is the live selection and outranks the
    /// `SystemDefault` copy that sits beside it.
    static func aerialAssetID(indexPlist data: Data) -> String? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else { return nil }
        for scope in ["AllSpacesAndDisplays", "Displays", "Spaces", "SystemDefault"] {
            if let dictionary = root as? [String: Any],
               let branch = dictionary[scope],
               let found = nestedAssetID(branch) {
                return found
            }
        }
        return nestedAssetID(root)
    }

    private static func nestedAssetID(_ node: Any) -> String? {
        switch node {
        case let data as Data:
            guard let inner = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else { return nil }
            return inner["assetID"] as? String
        case let dictionary as [String: Any]:
            // Sorted, not `.values`: dictionary iteration order is seeded per
            // process, so a plist holding two asset IDs would pick a different
            // one on some launches — and the asset ID is part of the backdrop
            // cache key, so that is a wallpaper that changes when you restart.
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key], let found = nestedAssetID(value) { return found }
            }
            return nil
        case let array as [Any]:
            for value in array {
                if let found = nestedAssetID(value) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    /// An aerial desktop is normally a rotating *category*, so no single file is
    /// "the" wallpaper and there is no published pointer at whichever clip is
    /// on screen right now. Pick the category's lowest-ordered member whose
    /// still macOS has already downloaded: deterministic — the backdrop cache
    /// key depends on it — never a network fetch, and colour-coherent, because
    /// Apple groups a category by look in the first place.
    static func representativeAerialStill(
        assetID: String,
        manifest data: Data,
        cachedStillIDs: Set<String>
    ) -> String? {
        // A single pinned aerial names its own still; no category to read.
        if cachedStillIDs.contains(assetID) { return assetID }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        let members = assets.compactMap { asset -> (order: Int, id: String)? in
            guard let id = asset["id"] as? String, cachedStillIDs.contains(id) else { return nil }
            let categories = (asset["categories"] as? [String] ?? [])
                + (asset["subcategories"] as? [String] ?? [])
            guard categories.contains(assetID) else { return nil }
            return (asset["preferredOrder"] as? Int ?? .max, id)
        }
        return members.min { lhs, rhs in
            lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
        }?.id
    }

    /// Whether the store names a *rotating* desktop rather than one picture.
    ///
    /// macOS 26's headline desktops are shuffles, and the store records the
    /// shuffle itself — `shuffle-all-aerials` — where a pinned wallpaper would
    /// record an asset UUID. It is neither a still's name nor a category in the
    /// manifest, whose categories are all UUIDs, so every lookup keyed on it
    /// found nothing and the backdrop fell all the way through to the flat grey
    /// fallback. Michael saw a featureless canvas and reasonably read it as the
    /// glass erasing his wallpaper; the glass had simply never been given one.
    static func isShuffleAssetID(_ id: String) -> Bool {
        id.hasPrefix("shuffle-")
    }

    /// Which aerial a shuffled desktop is currently showing.
    ///
    /// The pick lives in the wallpaper agent and is written nowhere readable —
    /// the store holds only the shuffle's name and its cadence. What the agent
    /// does leave behind is the file it plays, so the most recently *read*
    /// video is the strongest evidence available, and it beats the alternative
    /// (an arbitrary member of the set) decisively.
    ///
    /// It is a heuristic and is documented as one: a shuffle that rotates while
    /// the app sleeps can leave the previous pick as the newest read. That is a
    /// wrong aerial rather than no aerial, which is the trade being made.
    ///
    /// Pure, with the readings injected, so the ordering is testable without a
    /// wallpaper agent.
    static func shuffledAerialStill(
        videoAccess: [(id: String, accessedAt: Date)],
        cachedStillIDs: Set<String>
    ) -> String? {
        videoAccess
            .filter { cachedStillIDs.contains($0.id) }
            .max { $0.accessedAt < $1.accessedAt }?
            .id
    }

    /// Access times for every downloaded aerial video, newest last read first.
    private static func aerialVideoAccess(directory: URL) -> [(id: String, accessedAt: Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".mov") else { return nil }
            let url = directory.appending(path: name)
            guard let accessed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                .modificationDate
            ] as? Date else { return nil }
            // `atime` is what actually tracks playback, and `URLResourceValues`
            // exposes it where `FileAttributeKey` does not.
            let access = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?
                .contentAccessDate ?? accessed
            return (String(name.dropLast(4)), access)
        }
    }

    private static func currentAerialStill(supportDirectory: URL) -> URL? {
        let thumbnails = supportDirectory
            .appending(path: "aerials/thumbnails", directoryHint: .isDirectory)
        guard let index = try? Data(
            contentsOf: supportDirectory.appending(path: "Store/Index.plist")
        ), let assetID = aerialAssetID(indexPlist: index) else { return nil }

        let pinned = thumbnails.appending(path: "\(assetID).png")
        if FileManager.default.fileExists(atPath: pinned.path) { return pinned }

        guard let manifest = try? Data(
            contentsOf: supportDirectory.appending(path: "aerials/manifest/entries.json")
        ), let cached = try? FileManager.default.contentsOfDirectory(atPath: thumbnails.path)
        else { return nil }
        let ids = Set(cached.lazy.filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
        // A shuffle names no category, so ask which video is being played
        // before falling back to a representative member of the set.
        if isShuffleAssetID(assetID) {
            let access = aerialVideoAccess(
                directory: supportDirectory.appending(path: "aerials/videos", directoryHint: .isDirectory)
            )
            if let playing = shuffledAerialStill(videoAccess: access, cachedStillIDs: ids) {
                return thumbnails.appending(path: "\(playing).png")
            }
            // Nothing downloaded yet: any real aerial beats a flat grey panel.
            if let any = ids.sorted().first {
                return thumbnails.appending(path: "\(any).png")
            }
            return nil
        }
        guard let pick = representativeAerialStill(
            assetID: assetID,
            manifest: manifest,
            cachedStillIDs: ids
        ) else { return nil }
        return thumbnails.appending(path: "\(pick).png")
    }
}

/// How much of the desktop one watch tick is allowed to read.
///
/// The two rungs are two orders of magnitude apart, measured on this machine:
/// three `stat`s cost **0.045 ms**, and `NSWorkspace.desktopImageURL(for:)`
/// costs **4.1 ms** — and the latter has to run on the main actor, because
/// `NSScreen` is not `Sendable`. A 4 ms main-thread stall is a dropped frame,
/// so it cannot be what a five-second timer does.
enum DesktopProbeDepth: Equatable, Sendable {
    /// `stat` only: the painted file, the wallpaper store's index, and the
    /// aerial thumbnail cache. Catches every desktop change that goes through
    /// the wallpaper store, which on macOS 26 is every change made from System
    /// Settings, Finder's "Set Desktop Picture", or the Wallpaper API.
    case shallow
    /// The above plus `desktopImageURL(for:)`. The only thing this adds is a
    /// desktop whose *path* moved without the store being rewritten — a
    /// rotating picture folder advancing — so it is taken on a slow cadence
    /// rather than every tick.
    case deep
}

/// The cheap fingerprint of "which picture the desktop is showing".
///
/// Nothing in AppKit publishes a wallpaper-changed event that can be relied on
/// (see `DesktopBackdropProvider.desktopChangedNotification` for what is
/// observed and what that is worth), so the backstop is this: a handful of
/// modification dates that a change cannot avoid moving, compared on a timer.
/// It is deliberately *not* the backdrop cache key — building that key reads
/// and parses two files, and this has to be affordable every few seconds.
struct DesktopWallpaperSignature: Equatable, Sendable {
    /// What `NSWorkspace` reports, on a `deep` probe only; `nil` on a shallow
    /// one, and a `nil` on either side is not evidence of a change.
    let desktopImagePath: String?
    /// The file the current backdrop was baked from — "set as desktop picture"
    /// over a path that never changed lands here.
    let paintedModified: Date?
    /// `Store/Index.plist`, which the wallpaper agent rewrites for every
    /// desktop choice, including picking a different aerial *category*.
    let storeModified: Date?
    /// The aerial thumbnail cache directory. A rotating category has no
    /// published pointer at the clip playing right now, so the backdrop picks a
    /// deterministic representative from the stills macOS has downloaded — and
    /// this directory's mtime is what moves when that set grows.
    let thumbnailsModified: Date?
}

/// What a watch tick found, against the previous one.
enum DesktopSignalDecision: Equatable {
    /// Nothing moved, or there is no baseline yet — either way, no hint.
    case unchanged
    /// Something the desktop is made of moved. Hint the provider.
    case changed
}

/// What a "the desktop may have changed" hint should do about it.
enum DesktopResolveDecision: Equatable {
    /// The rate-limit floor has expired; read the desktop now.
    case resolveNow
    /// Inside the floor with nothing armed yet: arm one resolve for when the
    /// floor expires, in `after` seconds.
    case deferBy(TimeInterval)
    /// Inside the floor and a deferred resolve is already armed. Doing nothing
    /// is correct — the armed resolve will pick up whatever this hint saw.
    case alreadyScheduled
}

/// Owns the one rendered desktop backdrop the whole app shares.
///
/// Every glass surface reads the same published painting, so a window with a
/// sidebar and a canvas decodes and blurs the wallpaper once, not twice. There
/// is no per-frame and no idle work: rendering happens only when the resolved
/// key changes, and re-*resolution* is rate-limited because a focus change or a
/// Space switch is a hint that the desktop may have changed, not proof.
@MainActor
final class DesktopBackdropProvider: ObservableObject {
    static let shared = DesktopBackdropProvider()

    @Published private(set) var painting: DesktopPainting = .flat(DesktopTintSampler.fallback)
    /// The clear half of the same bake — see `DesktopBake.clearStill`. Published
    /// in the same resolve that publishes `painting`, so the idle canvas can
    /// never crossfade between two different desktops.
    @Published private(set) var clearStill: CGImage?

    /// The floor between two disk reads. Every hint — notification, watch tick,
    /// or activation — is funnelled through it.
    static let minimumResolveInterval: TimeInterval = 2
    /// Enough for a light/dark pair on each of two recently seen desktops.
    private static let cacheLimit = 4

    /// The distributed notification the wallpaper agent posts when the desktop
    /// changes, and an honest account of what observing it is worth.
    ///
    /// `WallpaperAgent` links `NSDistributedNotificationCenter` and carries the
    /// string `com.apple.desktop`, so the long-standing notification is very
    /// likely still posted on macOS 26 — but that is inference from `nm` and
    /// `strings`, not a measurement: confirming it needs an actual desktop
    /// change, and changing the developer's desktop to find out is not a thing
    /// this code is allowed to do. So it is observed as a *fast path* and
    /// nothing depends on it. `desktopWatchInterval` below is the guarantee.
    static var desktopChangedNotification: Notification.Name {
        Notification.Name("com.apple.desktop")
    }

    /// How often the shallow watch tick runs while Kaisola is the active app.
    ///
    /// Three `stat`s, 0.045 ms — 0.001% duty at this cadence, and the timer
    /// carries a wide tolerance so the wakeups coalesce with whatever else the
    /// process is doing. It is suspended entirely when the app is not active,
    /// because `didBecomeActive` already forces a resolve on the way back in,
    /// which makes an unattended app cost exactly nothing.
    static let desktopWatchInterval: TimeInterval = 5
    /// How often a tick is allowed to be `deep` — see `DesktopProbeDepth`.
    static let desktopDeepProbeInterval: TimeInterval = 30

    private var cache: [DesktopBackdropKey: DesktopBake] = [:]
    private var cacheOrder: [DesktopBackdropKey] = []

    /// Memory-pressure hook (2026-08-06 spec §2g): bakes rebuild lazily on
    /// the next resolve, so dropping them under pressure costs one re-bake.
    func purgeBakes() {
        cache.removeAll()
        cacheOrder.removeAll()
    }
    private var work: Task<Void, Never>?
    private var deferredResolve: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    /// Bumped on every resolve so a detached stage that finishes after a newer
    /// resolve started cannot publish its stale painting. `Task.cancel()` is not
    /// enough on its own: `Task.detached` deliberately does not inherit
    /// cancellation, so the decode and the bake always run to completion once
    /// started and the only safe thing to do with a superseded result is to
    /// drop it here.
    private var generation = 0
    private var lastResolved = Date.distantPast
    private var lastAppearanceIsDark: Bool?
    private var observers: [any NSObjectProtocol] = []
    private var lastKey: DesktopBackdropKey?
    private var lastDeepProbe = Date.distantPast

    /// The last fingerprint a watch tick read, and the number of times anything
    /// has said "the desktop may have changed".
    ///
    /// Deliberately not `@Published`: a hint is not a repaint, and publishing
    /// one would invalidate every glass surface in the app on a timer. They are
    /// observable so the watch can be *proved* to fire rather than asserted to —
    /// see `testTheWallpaperWatchFiresOnADistributedDesktopNotification`.
    private(set) var wallpaperSignature: DesktopWallpaperSignature?
    private(set) var wallpaperSignals = 0

    var tintColor: Color {
        let tint = painting.tint
        return Color(red: tint.red, green: tint.green, blue: tint.blue)
    }

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        // Space switches and screen reconfiguration can both change which
        // desktop picture applies; becoming key is when a wallpaper the user
        // changed in System Settings first matters to us; waking is when a
        // desktop set to rotate "on wake" has already rotated.
        observers = [
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.noteDesktopSignal()
                    self?.startWatching()
                }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stopWatching() } },
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
            // A window dragged onto another display changes neither the
            // wallpaper file nor the Space, but it does change how wide the
            // desktop the still is stretched across is — which the bake's blur
            // is now stated against. Deliberately **not** funnelled straight
            // into `noteDesktopSignal`: this notification also fires the first
            // time any window acquires a screen, so an unconditional hint would
            // turn opening a window into a desktop re-resolve and reset the
            // watch's baseline in the process.
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteScreenWidthChange() } },
            // The fast path. `object: nil` because the agent's object string is
            // not documented and has changed across releases; the name alone is
            // specific enough, and a spurious hint costs one coalesced resolve.
            distributed.addObserver(
                forName: Self.desktopChangedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
        ]
    }

    /// Whether a hint should resolve now, arm a deferred resolve, or defer to
    /// one that is already armed.
    ///
    /// Pure so the coalescing rule is testable without a clock, a desktop, or a
    /// run loop — the previous rule looked correct in the source and was inert
    /// in fact, which is the failure mode a unit test catches and a reading
    /// does not.
    static func hintDecision(
        now: Date,
        lastResolved: Date,
        deferredResolveArmed: Bool,
        floor: TimeInterval = minimumResolveInterval
    ) -> DesktopResolveDecision {
        let elapsed = now.timeIntervalSince(lastResolved)
        if elapsed >= floor { return .resolveNow }
        if deferredResolveArmed { return .alreadyScheduled }
        return .deferBy(floor - elapsed)
    }

    /// How much a watch tick at `now` is allowed to read.
    ///
    /// Pure, so the "4 ms call is not on the 5-second path" rule is a test
    /// rather than a comment that a later edit can quietly break.
    static func probeDepth(
        now: Date,
        lastDeepProbe: Date,
        interval: TimeInterval = desktopDeepProbeInterval
    ) -> DesktopProbeDepth {
        now.timeIntervalSince(lastDeepProbe) >= interval ? .deep : .shallow
    }

    /// Whether a fingerprint that just came back means the desktop moved.
    ///
    /// Two rules that are easy to get wrong and impossible to see in a reading:
    ///
    /// * **No baseline is not a change.** The first tick after a resolve exists
    ///   to record what "unchanged" looks like. Treating it as a change would
    ///   make the watch re-resolve every time it started.
    /// * **A field only one side has proves nothing.** A shallow tick does not
    ///   pay for `desktopImageURL`, so its `desktopImagePath` is `nil`; if a
    ///   missing value counted as different, every shallow tick after a deep one
    ///   would fire, and the whole point of the two rungs would be lost.
    static func signalDecision(
        previous: DesktopWallpaperSignature?,
        current: DesktopWallpaperSignature
    ) -> DesktopSignalDecision {
        guard let previous else { return .unchanged }
        if previous.paintedModified != current.paintedModified { return .changed }
        if previous.storeModified != current.storeModified { return .changed }
        if previous.thumbnailsModified != current.thumbnailsModified { return .changed }
        if let old = previous.desktopImagePath,
           let new = current.desktopImagePath,
           old != new { return .changed }
        return .unchanged
    }

    /// The fingerprint itself. `modificationDate` is injected so the whole rule
    /// — which files are read, and which of them a `deep` probe adds — is
    /// testable against a fixture directory rather than against the developer's
    /// own desktop.
    nonisolated static func signature(
        depth: DesktopProbeDepth,
        desktopImagePath: String?,
        paintedPath: String?,
        supportDirectory: URL,
        modificationDate: (URL) -> Date?
    ) -> DesktopWallpaperSignature {
        DesktopWallpaperSignature(
            desktopImagePath: depth == .deep ? desktopImagePath : nil,
            paintedModified: paintedPath.flatMap { modificationDate(URL(fileURLWithPath: $0)) },
            storeModified: modificationDate(supportDirectory.appending(path: "Store/Index.plist")),
            thumbnailsModified: modificationDate(
                supportDirectory.appending(path: "aerials/thumbnails", directoryHint: .isDirectory)
            )
        )
    }

    nonisolated static func modificationDateOnDisk(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Whether the watch is currently armed. Observable so "an app with no
    /// glass surface never starts a timer" is a test rather than a claim.
    var isWatchingDesktop: Bool { watch != nil }

    /// Start the watch. Idempotent, and a no-op until a glass surface has
    /// actually asked for a backdrop — an app whose windows are all solid
    /// never starts a timer.
    private func startWatching() {
        guard watch == nil, lastAppearanceIsDark != nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Self.desktopWatchInterval),
                    tolerance: .seconds(Self.desktopWatchInterval / 2)
                )
                guard !Task.isCancelled, let self else { return }
                await self.probeDesktop()
            }
        }
    }

    private func stopWatching() {
        watch?.cancel()
        watch = nil
    }

    /// One watch tick.
    ///
    /// The main actor pays only for `desktopImageURL`, and only on a deep tick;
    /// the `stat`s run detached. A tick that finds nothing does not touch the
    /// backdrop at all, so the steady state is three `stat`s every five seconds
    /// and no allocation, no decode, and no repaint.
    ///
    /// `supportDirectory` is a parameter only so the whole chain — filesystem
    /// change, fingerprint, decision, coalescing door — can be driven end to end
    /// against a fixture. There is no way to test it against the real store: it
    /// would mean changing the developer's desktop.
    func probeDesktop(
        supportDirectory: URL = DesktopWallpaperLocator.defaultSupportDirectory
    ) async {
        guard lastAppearanceIsDark != nil else { return }
        let depth = Self.probeDepth(now: Date(), lastDeepProbe: lastDeepProbe)
        var desktopImagePath: String?
        if depth == .deep {
            lastDeepProbe = Date()
            desktopImagePath = Self.currentScreen()
                .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }?.path
        }
        let paintedPath = lastKey?.path
        let support = supportDirectory
        let current = await Task.detached(priority: .utility) {
            Self.signature(
                depth: depth,
                desktopImagePath: desktopImagePath,
                paintedPath: paintedPath,
                supportDirectory: support,
                modificationDate: Self.modificationDateOnDisk
            )
        }.value
        let decision = Self.signalDecision(previous: wallpaperSignature, current: current)
        wallpaperSignature = current
        guard decision == .changed else { return }
        noteDesktopSignal()
    }

    /// The one door every "the desktop may have changed" signal goes through —
    /// the distributed notification, a watch tick that found something, a Space
    /// switch, a wake, an activation, a screen change, a new key window.
    ///
    /// It records the signal and then defers entirely to `invalidate`, so the
    /// coalescing contract is unchanged: a burst still arms exactly one
    /// deferred resolve, and the generation counter still drops stale bakes.
    private func noteDesktopSignal() {
        wallpaperSignals += 1
        invalidate()
    }

    /// Ask for the backdrop that matches `isDark`. Cheap and idempotent: an
    /// appearance flip always re-resolves, anything else waits out the
    /// rate limit.
    func refresh(isDark: Bool) {
        let appearanceChanged = isDark != lastAppearanceIsDark
        lastAppearanceIsDark = isDark
        // The first surface to ask for a backdrop is what arms the watch; an
        // app with nothing but solid chrome never starts a timer at all.
        startWatching()
        guard appearanceChanged
            || Date().timeIntervalSince(lastResolved) >= Self.minimumResolveInterval else { return }
        // An appearance flip supersedes any armed hint: it is about to do the
        // read that hint was waiting for, and for the newer appearance.
        deferredResolve?.cancel()
        deferredResolve = nil
        lastResolved = Date()
        resolve(isDark: isDark)
    }

    /// A hint arrived that the desktop may have changed.
    ///
    /// The floor exists because these hints are cheap to emit and expensive to
    /// honour: each resolve is an `Index.plist` read, an `entries.json` parse,
    /// and a main-thread `desktopImageURL(for:)` call. It used to be inert —
    /// this method reset `lastResolved` to `.distantPast` and then asked
    /// `refresh` whether enough time had passed since `lastResolved`, which it
    /// always had. Every Space switch, activation, screen change, and key-window
    /// change therefore paid for a full re-resolution.
    ///
    /// Coalescing properly means a hint inside the floor is neither dropped nor
    /// duplicated: it arms exactly one resolve for the moment the floor expires,
    /// and every further hint before then rides on that one.
    private func invalidate() {
        guard lastAppearanceIsDark != nil else { return }
        switch Self.hintDecision(
            now: Date(),
            lastResolved: lastResolved,
            deferredResolveArmed: deferredResolve != nil
        ) {
        case .alreadyScheduled:
            return
        case .resolveNow:
            guard let isDark = lastAppearanceIsDark else { return }
            lastResolved = Date()
            resolve(isDark: isDark)
        case let .deferBy(delay):
            deferredResolve = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.deferredResolve = nil
                guard let isDark = self.lastAppearanceIsDark else { return }
                self.lastResolved = Date()
                self.resolve(isDark: isDark)
            }
        }
    }

    /// Reading the wallpaper URL stays on the main actor — `NSScreen` is not
    /// `Sendable`, so the alternative is smuggling one into a detached task —
    /// but it now runs only on a resolve, and `invalidate` guarantees at most
    /// one of those per `minimumResolveInterval`. The hot path a burst of hints
    /// travels no longer touches it at all.
    private func resolve(isDark: Bool) {
        generation &+= 1
        let generation = generation
        let screen = Self.currentScreen()
        let desktopImageURL = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        // The blur is stated in screen points and the still now spans the whole
        // desktop, so how wide that desktop is belongs to the bake — and so to
        // the cache key. See `DesktopBackdropKey.screenPoints`.
        let screenPoints = Double(screen?.frame.width ?? 1512)
        // Resolved here, on the main actor: `NSScreen` is not `Sendable`, and
        // the capture below runs off it.
        let displayID = screen?.displayID
        let texture = NativePreviewSettings.shared.glassTexture
        let colour = NativePreviewSettings.shared.glassColour
        // Read on the main actor; the resolve below runs off it.
        let pinnedWallpaper = NativePreviewSettings.shared.glassWallpaper
        work?.cancel()
        work = Task { [weak self] in
            // Observe the desktop before deducing it. The capture writes a file
            // the ladder below prefers, so a shuffled or dynamic desktop bakes
            // the picture actually on screen rather than a guessed stand-in.
            // Desktop capture is OFF.
            //
            // It shipped twice and grabbed the wrong content both times: first
            // other applications' windows (`excludingWindows` can only exclude
            // what it was handed), then — after switching to naming the Dock's
            // `Wallpaper-<UUID>` window directly — a frame containing Kaisola's
            // own Settings popover on white. The identification is evidently
            // still wrong, and the failure mode of getting it wrong is putting
            // other people's screens inside this app's chrome.
            //
            // That is not a bug to iterate on in place. `DesktopCaptureSource`
            // is left intact and unreferenced so the work is not lost, and the
            // resolution ladder below runs exactly as it did before capture
            // existed. Re-enabling it needs a test that asserts what the
            // captured frame actually contains, which is the check that was
            // missing both times.
            _ = displayID
            let key = await Task.detached(priority: .utility) {
                Self.key(
                    desktopImageURL: desktopImageURL,
                    pinnedWallpaperPath: pinnedWallpaper,
                    isDark: isDark,
                    screenPoints: screenPoints,
                    texture: texture,
                    colour: colour
                )
            }.value
            guard let self, generation == self.generation else { return }
            // Whatever this resolve concluded is the new baseline: the file it
            // painted has just been read, so the next watch tick must compare
            // against *that* rather than fire a second time on the change this
            // resolve already honoured.
            self.lastKey = key
            self.wallpaperSignature = nil
            guard let key else {
                painting = .flat(DesktopTintSampler.fallback)
                clearStill = nil
                return
            }
            if let cached = cache[key] {
                painting = cached.painting
                clearStill = cached.clearStill
                return
            }
            let rendered = await Task.detached(priority: .utility) {
                DesktopBackdropRenderer.renderBake(key: key)
            }.value
            guard generation == self.generation else { return }
            let resolved = rendered
                ?? DesktopBake(painting: .flat(DesktopTintSampler.fallback), clearStill: nil)
            self.store(resolved, for: key)
            self.painting = resolved.painting
            self.clearStill = resolved.clearStill
        }
    }

    private func store(_ bake: DesktopBake, for key: DesktopBackdropKey) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = bake
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// Waits for whatever resolve is in flight, and exists for one reason: a
    /// resolve deliberately clears the watch's baseline signature when it lands
    /// ("whatever this resolve concluded is the new baseline"), so a test that
    /// drives `probeDesktop` has to know the previous resolve has finished
    /// rather than race it. Without this the watch test passes or fails
    /// depending on how long a bake happens to take.
    func settleResolves() async { await work?.value }

    /// Hint only if the display the glass is on is a **different width** from
    /// the one the current backdrop was baked for. Everything else about the
    /// wallpaper is unchanged by a window moving between screens, and the
    /// quantization in `DesktopBackdropKey` means two similar displays do not
    /// count as different either.
    private func noteScreenWidthChange() {
        guard let baked = lastKey?.screenPoints,
              let width = Self.currentScreen()?.frame.width,
              baked != DesktopBackdropKey.quantized(screenPoints: Double(width))
        else { return }
        noteDesktopSignal()
    }

    private nonisolated static func key(
        desktopImageURL: URL?,
        pinnedWallpaperPath: String?,
        isDark: Bool,
        screenPoints: Double,
        texture: GlassTexture,
        colour: GlassColour
    ) -> DesktopBackdropKey? {
        guard let url = DesktopWallpaperLocator.resolveOnDisk(
            desktopImageURL: desktopImageURL,
            pinnedWallpaperPath: pinnedWallpaperPath
        ).url else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return DesktopBackdropKey(
            path: url.path,
            modified: modified,
            isDark: isDark,
            screenPoints: screenPoints,
            texture: texture,
            colour: colour
        )
    }

    /// The desktop under *this* window, falling back to the primary display.
    private static func currentScreen() -> NSScreen? {
        NSApp?.keyWindow?.screen ?? NSApp?.mainWindow?.screen ?? NSScreen.main
    }
}
