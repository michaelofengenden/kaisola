import Foundation

/// The explanation shown when the protected workspace archive could not be
/// restored, and the state of the user's attempts to recover from it.
///
/// `NativeWorkspaceStateStore` fails closed on an archive it cannot decode:
/// schema 2 carries the only durable identity for potentially unintegrated Mesh
/// work, so corruption must never be reinterpreted as an empty archive that the
/// next ordinary save overwrites. Failing closed *silently*, though, produced
/// the worst version of that: an unexplained empty workspace whose every later
/// save also threw, forever, with nothing on screen to say so.
///
/// The two failures need opposite handling, and the notice keeps them apart:
///
/// - a corrupt archive is unrecoverable by this build, so the app preserves it
///   beside the original and starts a fresh one — which makes saving work
///   again, at the cost of the previous layout;
/// - an archive written by a newer Kaisola is perfectly good data this build
///   must not interpret, so it stays exactly where it is and saves stay blocked
///   until the user opens the newer version again.
struct WorkspaceRestorationNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The bytes could not be decoded at all.
        case corruptArchive
        /// A newer schema than this build knows how to read.
        case newerVersionData(schemaVersion: Int)
        /// Present and possibly intact, but not readable here (size cap,
        /// ownership, permissions, an unexpected file type).
        case unreadable(reason: String)

        /// Whether the app may move this archive aside on its own. Only
        /// undecodable bytes qualify; anything that might still be meaningful
        /// to another build stays exactly where its owner expects it.
        var allowsPreservingAside: Bool {
            switch self {
            case .corruptArchive: true
            case .newerVersionData, .unreadable: false
            }
        }

        init(storeError: Error) {
            switch storeError as? NativeWorkspaceStateStore.StoreError {
            case .corruptArchive:
                self = .corruptArchive
            case .unsupportedSchema(let found):
                self = .newerVersionData(schemaVersion: found)
            case .archiveTooLarge(let maxBytes):
                self = .unreadable(
                    reason: "it is larger than the \(maxBytes / 1_024) KB limit"
                )
            case .unsafePath:
                self = .unreadable(
                    reason: "it is not a private file owned by your user account"
                )
            default:
                self = .unreadable(
                    reason: (storeError as NSError).localizedDescription
                )
            }
        }
    }

    /// What became of the bytes this build could not read. Only one of these
    /// leaves saving blocked, so the notice stores the disposition rather than
    /// inferring it from a preserved-copy URL that two very different outcomes
    /// both leave empty.
    enum ArchiveDisposition: Equatable, Sendable {
        /// Still exactly where it was — deliberately, for data this build must
        /// not touch, or because moving it aside failed. Saves cannot land.
        case protectedInPlace
        /// This window moved the unreadable bytes here and started fresh.
        case movedAside(URL)
        /// The archive was already gone when this window looked: a sibling
        /// window hit the same damage first and preserved the bytes. The path
        /// is clear here too, so saving works — this window simply is not the
        /// one that can name the kept file.
        case alreadyPreservedByAnotherWindow

        /// A repeat failure that preserved nothing must not forget that an
        /// earlier attempt already cleared the path.
        func carryingForward(_ previous: ArchiveDisposition) -> ArchiveDisposition {
            self == .protectedInPlace ? previous : self
        }
    }

    let kind: Kind
    /// The archive that failed to load.
    let archiveURL: URL
    /// What happened to the bytes that could not be read.
    let disposition: ArchiveDisposition
    /// Retries the user has already asked for since this problem appeared.
    private(set) var retryCount: Int
    /// A retry is running now.
    private(set) var isRetrying: Bool
    /// The banner is hidden. The notice itself is durable: the compact
    /// indicator stays until restoration actually succeeds.
    private(set) var isBannerDismissed: Bool

    init(
        kind: Kind,
        archiveURL: URL,
        disposition: ArchiveDisposition,
        retryCount: Int = 0,
        isRetrying: Bool = false,
        isBannerDismissed: Bool = false
    ) {
        self.kind = kind
        self.archiveURL = archiveURL
        self.disposition = disposition
        self.retryCount = retryCount
        self.isRetrying = isRetrying
        self.isBannerDismissed = isBannerDismissed
    }

    /// Where this window preserved the unreadable bytes, when it is the window
    /// that moved them.
    var preservedCopyURL: URL? {
        if case .movedAside(let url) = disposition { return url }
        return nil
    }

    /// True while the archive is still protected in place, which is exactly
    /// when further layout saves cannot land.
    var savesBlocked: Bool { disposition == .protectedInPlace }

    /// What Reveal in Finder should select: the preserved bytes when this
    /// window moved them, otherwise the protected archive itself. Once a
    /// sibling window has preserved them there is no file here to select, so
    /// the folder holding the kept copy is the honest target.
    var revealURL: URL {
        switch disposition {
        case .movedAside(let url): url
        case .protectedInPlace: archiveURL
        case .alreadyPreservedByAnotherWindow: archiveURL.deletingLastPathComponent()
        }
    }

    var title: String {
        switch kind {
        case .corruptArchive:
            "Window Layout Couldn't Be Restored"
        case .newerVersionData:
            "Saved by a Newer Version of Kaisola"
        case .unreadable:
            "Window Layout Couldn't Be Read"
        }
    }

    var message: String {
        switch kind {
        case .corruptArchive:
            switch disposition {
            case .movedAside(let preservedCopyURL):
                "Kaisola couldn't read your saved layout, so it kept the damaged "
                    + "file as \(preservedCopyURL.lastPathComponent) and started a "
                    + "fresh one. Projects, panes, and drafts from the last session "
                    + "aren't in this window; new changes are being saved normally."
            case .alreadyPreservedByAnotherWindow:
                "Kaisola couldn't read your saved layout, so it started a fresh "
                    + "one. Another Kaisola window had already kept the damaged file "
                    + "beside it. Projects, panes, and drafts from the last session "
                    + "aren't in this window; new changes are being saved normally."
            case .protectedInPlace:
                "Kaisola couldn't read your saved layout and couldn't move the "
                    + "damaged file aside, so this window's layout changes aren't "
                    + "being saved. The original file is untouched."
            }
        case .newerVersionData(let schemaVersion):
            "This layout was saved by a newer version of Kaisola (data format "
                + "\(schemaVersion)). It's left untouched so that version can still "
                + "read it, which means layout changes in this window aren't being "
                + "saved. Open the newer version to get your layout back."
        case .unreadable(let reason):
            "Kaisola couldn't read \(archiveURL.lastPathComponent) because \(reason). "
                + "The file is untouched, so this window's layout changes aren't "
                + "being saved."
        }
    }

    /// The compact, always-available form for the collapsed indicator.
    var summary: String {
        switch kind {
        case .corruptArchive:
            savesBlocked ? "Window layout not saving" : "Window layout not restored"
        case .newerVersionData:
            "Layout saved by a newer version"
        case .unreadable:
            "Window layout unreadable"
        }
    }

    var revealActionTitle: String {
        switch disposition {
        case .protectedInPlace: "Reveal Archive in Finder"
        case .movedAside: "Reveal Kept Copy in Finder"
        case .alreadyPreservedByAnotherWindow: "Reveal Kept Copies in Finder"
        }
    }

    /// Carry the user's interaction history into a freshly observed failure so
    /// a failed retry does not present itself as a first occurrence.
    func continuing(_ previous: WorkspaceRestorationNotice?) -> WorkspaceRestorationNotice {
        guard let previous else { return self }
        return WorkspaceRestorationNotice(
            kind: kind,
            archiveURL: archiveURL,
            disposition: disposition.carryingForward(previous.disposition),
            retryCount: previous.retryCount + (previous.isRetrying ? 1 : 0),
            isRetrying: false,
            isBannerDismissed: false
        )
    }

    mutating func beginRetry() {
        isRetrying = true
        // The user just asked for this; showing them the outcome is the point.
        isBannerDismissed = false
    }

    mutating func dismissBanner() {
        isBannerDismissed = true
    }

    mutating func presentBanner() {
        isBannerDismissed = false
    }
}
