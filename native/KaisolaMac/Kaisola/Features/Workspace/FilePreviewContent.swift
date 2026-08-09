import AppKit
import Foundation
import PDFKit

extension Notification.Name {
    /// Synchronous lifecycle barrier posted before AppKit hides windows for
    /// termination. File editors own their drafts locally, so they flush while
    /// those views are still mounted and only then does model teardown begin.
    static let kaisolaFlushFilePreviews = Notification.Name("kaisolaFlushFilePreviews")
    /// Synchronous request posted immediately before a workspace file rename
    /// or Trash operation. A mounted editor gets one chance to save its draft;
    /// an unresolved conflict vetoes the mutation.
    static let kaisolaPrepareWorkspaceFileMutation = Notification.Name("kaisolaPrepareWorkspaceFileMutation")
    /// App-menu request scoped to one AppModel/window. The mounted editor owns
    /// the dirty-state prompt, so Command-W must enter here rather than having
    /// the menu mutate the model directly.
    static let kaisolaCloseActiveFileTab = Notification.Name("kaisolaCloseActiveFileTab")
}

/// Mutable by design: NotificationCenter delivery is synchronous on the
/// posting thread, so the mounted preview can veto a filesystem mutation before
/// the rail starts its detached operation.
@MainActor
final class WorkspaceFileMutationBarrierRequest {
    let item: URL
    private(set) var mayProceed = true

    init(item: URL) {
        self.item = item.standardizedFileURL
    }

    func block() {
        mayProceed = false
    }
}

/// What a file resolves to for previewing/editing. Pure so tests can drive it.
enum FilePreviewContent: Equatable, Sendable {
    case text(String)
    case markdown(String)
    case csv(String)
    case json(String)
    case html(String)
    case docx
    case pdf
    case image
    case tooLarge(Int)
    case binary
    case unreadable

    static let maxTextBytes = 1_048_576
    static let maxImageBytes = 25 * 1_048_576
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "svg", "icns"]
    static let binaryExtensions: Set<String> = [
        "a", "bin", "class", "dmg", "dylib", "exe", "framework", "o", "pkg", "so", "wasm", "zip",
    ]

    static func load(
        url: URL,
        mappings: PreviewMappingStore = PreviewMappingStore()
    ) -> FilePreviewContent {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return .unreadable }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return size <= maxImageBytes ? .image : .tooLarge(size)
        }
        if ext == "docx" { return size <= maxDocumentBytes ? .docx : .tooLarge(size) }
        if ext == "pdf" { return size <= maxDocumentBytes ? .pdf : .tooLarge(size) }
        if binaryExtensions.contains(ext) { return .binary }
        guard size <= maxTextBytes else { return .tooLarge(size) }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        // Recheck the actual payload: an agent may append between stat(2) and
        // the read, and the preview's memory bound must apply to what we loaded.
        guard data.count <= maxTextBytes else { return .tooLarge(data.count) }
        guard let text = decodeText(data) else { return .binary }
        if ext == "html" || ext == "htm" { return .html(text) }
        if ext == "csv" || ext == "tsv" { return .csv(text) }
        if ext == "json" || ext == "ipynb" { return .json(text) }
        if ext == "md" || ext == "markdown" { return .markdown(text) }
        // Custom preview mappings run *after* every built-in decision — a
        // mapping can never take over an image, a document, the binary sniff,
        // or a built-in text kind; it only decides how bytes that already
        // passed the size cap and text decode get styled.
        if let custom = mappings.kind(forExtension: ext) {
            switch custom {
            case .html: return .html(text)
            case .csv: return .csv(text)
            case .json: return .json(text)
            case .markdown: return .markdown(text)
            case .text: return .text(text)
            }
        }
        return .text(text)
    }

    /// Prefer explicit Unicode BOMs, then UTF-8 and common repository-export
    /// encodings. Latin-1 is intentionally last and only after a binary-control
    /// sniff, because it can otherwise "decode" arbitrary executable bytes.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data, encoding: .utf32BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: data, encoding: .utf32LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16)
        }
        guard !looksBinary(data) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let shiftJIS = String(data: data, encoding: .shiftJIS) { return shiftJIS }
        return String(data: data, encoding: .isoLatin1)
    }

    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8_192)
        guard !sample.isEmpty else { return false }
        var suspicious = 0
        for byte in sample {
            if byte == 0 { return true }
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) {
                suspicious += 1
            }
        }
        return suspicious * 100 > sample.count * 2
    }

    static let maxDocumentBytes = 20 * 1_048_576
}

/// One fail-closed policy for links originating in local previews. Rendered
/// Markdown may hand an arbitrary URL to SwiftUI's `OpenURLAction`; never let a
/// README launch a custom scheme or reveal an arbitrary `file:` URL through
/// Launch Services. Web links are explicit http(s) destinations, while local
/// links are resolved against the document and routed back through Kaisola's
/// workspace preview.
enum WorkspacePreviewLinkPolicy {
    enum Decision: Equatable {
        case external(URL)
        case workspaceFile(URL, line: Int?)
        case blocked
    }

    static func decision(
        for link: URL,
        documentURL: URL,
        workspaceRoot: URL?
    ) -> Decision {
        if let scheme = link.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                guard link.host?.isEmpty == false,
                      link.user == nil,
                      link.password == nil else { return .blocked }
                return .external(link)
            }
            guard scheme == "file",
                  link.host?.isEmpty != false else { return .blocked }
        } else {
            // `//host/path` is a scheme-relative network URL, not a project
            // path. A fragment-only link needs in-document anchor support and
            // must not accidentally become a filesystem navigation.
            guard link.host == nil,
                  !link.absoluteString.hasPrefix("//"),
                  !link.absoluteString.hasPrefix("#") else { return .blocked }
        }

        let decodedPath = link.path.removingPercentEncoding ?? link.path
        guard !decodedPath.isEmpty else { return .blocked }
        let base = documentURL.deletingLastPathComponent().standardizedFileURL
        let candidate: URL
        if link.isFileURL || decodedPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: decodedPath).standardizedFileURL
        } else {
            candidate = URL(fileURLWithPath: decodedPath, relativeTo: base).standardizedFileURL
        }
        let boundary = (workspaceRoot ?? base).standardizedFileURL
        guard isContained(candidate, in: boundary) else { return .blocked }
        return .workspaceFile(candidate, line: lineNumber(from: link.fragment))
    }

    /// Resolve both sides before comparing so `..` walks and symlinked files
    /// cannot escape the project boundary.
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let base = canonicalPath(directory)
        let candidate = canonicalPath(url)
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    /// `resolvingSymlinksInPath()` can leave a symlinked parent unresolved when
    /// the leaf does not exist. Resolve the nearest existing ancestor first,
    /// then append the missing suffix without giving it another interpretation.
    private static func canonicalPath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while ancestor.path != "/",
              !FileManager.default.fileExists(atPath: ancestor.path) {
            missingComponents.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    private static func lineNumber(from fragment: String?) -> Int? {
        guard let fragment,
              fragment.first?.lowercased() == "l",
              let line = Int(fragment.dropFirst()),
              line > 0 else { return nil }
        return line
    }
}

/// Pure navigation/save state machine for a mounted preview. Rendered Markdown
/// owns a short autosave debounce, but a file switch must flush immediately.
/// If a previous snapshot is already saving, its completion decides whether the
/// latest draft needs one more save before navigation can commit.
enum FilePreviewNavigationPolicy {
    enum RequestDecision: Equatable {
        case navigate
        case autosave
        case awaitCurrentSave
        case prompt
    }

    enum SaveCompletion: Equatable {
        case stay
        case completePendingAction
        case saveLatestDraft
        case prompt
    }

    static func requestDecision(
        isDirty: Bool,
        isMarkdown: Bool,
        isSaving: Bool,
        hasExternalConflict: Bool
    ) -> RequestDecision {
        guard isDirty else { return .navigate }
        guard isMarkdown, !hasExternalConflict else { return .prompt }
        return isSaving ? .awaitCurrentSave : .autosave
    }

    static func saveCompletion(
        hasPendingAction: Bool,
        isDirty: Bool,
        isMarkdown: Bool
    ) -> SaveCompletion {
        guard hasPendingAction else { return .stay }
        guard isDirty else { return .completePendingAction }
        return isMarkdown ? .saveLatestDraft : .prompt
    }

    static func shouldRetrySupersededSave(
        taskCancelled: Bool,
        remainsOnLoadedFile: Bool,
        recoveryGenerationChanged: Bool,
        autosavePendingAction: Bool,
        hasPendingAction: Bool
    ) -> Bool {
        !taskCancelled
            && remainsOnLoadedFile
            && recoveryGenerationChanged
            && autosavePendingAction
            && hasPendingAction
    }
}

/// The changed-on-disk warning is collapsible but never dismissible: it is the
/// only persistent sign that a later save can overwrite an agent's or another
/// app's edit. Closing the banner folds it into a compact header indicator, and
/// only a reload, a save that went through the conflict decision, or discarding
/// the draft ends the conflict.
struct FilePreviewConflictState: Equatable {
    enum Event: Equatable {
        /// The watcher saw the mounted file change under an open draft.
        case detectedExternalChange(isDirty: Bool)
        case collapseRequested
        case expandRequested
        case reloaded
        case savedThroughConflictDecision
        case draftDiscarded
        /// Another document mounted; a conflict never survives a load.
        case documentLoaded
    }

    private(set) var isActive = false
    private(set) var isCollapsed = false

    var showsBanner: Bool { isActive && !isCollapsed }
    var showsCompactIndicator: Bool { isActive && isCollapsed }

    /// Save stays reachable during a conflict — the write itself routes into
    /// the reload/overwrite decision — but the control says so before it is
    /// pressed rather than after.
    var saveHelpText: String { isActive ? "Save — file changed on disk" : "Save" }

    var saveAccessibilityLabel: String { isActive ? "Save, file changed on disk" : "Save" }

    mutating func apply(_ event: Event) {
        switch event {
        case let .detectedExternalChange(isDirty):
            // A clean preview follows the newer file automatically, so only a
            // dirty draft can be in conflict with it.
            guard isDirty else {
                resolve()
                return
            }
            // Collapse is sticky: a repeated agent write must not reopen a
            // banner the user deliberately folded away.
            isActive = true
        case .collapseRequested:
            guard isActive else { return }
            isCollapsed = true
        case .expandRequested:
            guard isActive else { return }
            isCollapsed = false
        case .reloaded, .savedThroughConflictDecision, .draftDiscarded, .documentLoaded:
            resolve()
        }
    }

    private mutating func resolve() {
        isActive = false
        isCollapsed = false
    }
}

/// User-facing preview feedback is deliberately typed so ordinary recovery is
/// never presented as a save failure. The view supplies semantic color while
/// this value owns stable icon and accessibility metadata for every channel.
struct FilePreviewNotice: Equatable {
    enum Severity: Equatable {
        case information
        case warning
        case error

        var systemImageName: String {
            switch self {
            case .information: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var accessibilityName: String {
            switch self {
            case .information: "Information"
            case .warning: "Warning"
            case .error: "Error"
            }
        }
    }

    let severity: Severity
    let message: String

    var accessibilityLabel: String {
        "\(severity.accessibilityName): \(message)"
    }

    static func recoveredDraft(diskChanged: Bool) -> Self {
        Self(
            severity: diskChanged ? .warning : .information,
            message: diskChanged
                ? "Recovered an unsaved draft; the file also changed on disk."
                : "Recovered an unsaved draft."
        )
    }

    static func warning(_ message: String) -> Self {
        Self(severity: .warning, message: message)
    }

    static func error(_ message: String) -> Self {
        Self(severity: .error, message: message)
    }
}

/// AppKit's Office Open XML reader/writer is synchronous and the attributed
/// string classes predate Sendable. Keep that work off the main actor and move
/// the immutable result across the boundary in this explicit wrapper.
struct RichDocumentPayload: @unchecked Sendable {
    let value: NSAttributedString
}

/// PDFKit documents are immutable for this read-only surface after loading.
/// The wrapper makes that ownership boundary explicit when the dedicated PDF
/// worker moves the parsed document back to the MainActor.
struct PDFDocumentPayload: @unchecked Sendable {
    let value: PDFDocument
}

enum PDFDocumentIO {
    static func load(url: URL) -> PDFDocumentPayload? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        return PDFDocumentPayload(value: document)
    }
}

enum RichDocumentIO {
    static func load(url: URL) -> RichDocumentPayload? {
        guard let value = try? NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        ) else { return nil }
        return RichDocumentPayload(value: value)
    }

    static func write(_ value: NSAttributedString, to url: URL) throws {
        try data(value).write(to: url, options: .atomic)
    }

    static func data(_ value: NSAttributedString) throws -> Data {
        try value.data(
            from: NSRange(location: 0, length: value.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
    }

    static func load(data: Data) -> RichDocumentPayload? {
        guard let value = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        ) else { return nil }
        return RichDocumentPayload(value: value)
    }
}

enum FilePreviewSaveResult: Sendable {
    case saved(Date?)
    case changedOnDisk
    case failed(String)
}

/// Disk reads/writes used by the preview are deliberately actor-independent so
/// they can run on a utility executor. The modification-date guard prevents an
/// agent edit that lands after the preview opened from being silently replaced.
enum FilePreviewDiskState {
    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    nonisolated static func changed(onDisk url: URL, since expected: Date?) -> Bool {
        modificationDate(of: url) != expected
    }

    nonisolated static func writeText(
        _ text: String,
        to url: URL,
        expectedModificationDate: Date?,
        force: Bool
    ) -> FilePreviewSaveResult {
        guard force || !changed(onDisk: url, since: expectedModificationDate) else {
            return .changedOnDisk
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .saved(modificationDate(of: url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
