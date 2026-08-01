import Foundation

/// Preview tabs are disposable only while they are clean. Both VS Code and
/// JetBrains promote a preview as soon as editing begins; keeping this policy
/// pure makes the loss-prevention boundary independently testable.
enum FilePreviewTabPolicy {
    static func shouldPromoteEditedPreview(
        loadedURL: URL?,
        isDirty: Bool,
        tabs: [AppModel.FileWorkbenchTab]
    ) -> Bool {
        guard isDirty, let loadedURL else { return false }
        return tabs.contains {
            $0.url.standardizedFileURL == loadedURL.standardizedFileURL && !$0.isPinned
        }
    }

    static func isModified(
        _ tab: AppModel.FileWorkbenchTab,
        loadedURL: URL?,
        isDirty: Bool
    ) -> Bool {
        isDirty && tab.url.standardizedFileURL == loadedURL?.standardizedFileURL
    }

    /// Duplicate leaf names are common in source trees. Keep ordinary tabs
    /// compact, but append the workspace-relative parent whenever a filename
    /// alone would be ambiguous (for example `README.md — docs`).
    static func displayTitle(
        for tab: AppModel.FileWorkbenchTab,
        among tabs: [AppModel.FileWorkbenchTab],
        workspaceRoot: URL?
    ) -> String {
        let url = tab.url.standardizedFileURL
        let filename = url.lastPathComponent
        let duplicateCount = tabs.reduce(into: 0) { count, candidate in
            if candidate.url.lastPathComponent == filename { count += 1 }
        }
        guard duplicateCount > 1 else { return filename }

        let parent = url.deletingLastPathComponent().standardizedFileURL
        if let root = workspaceRoot?.standardizedFileURL {
            if parent == root {
                let rootName = root.lastPathComponent
                return "\(filename) — \(rootName.isEmpty ? "workspace" : rootName)"
            }
            let rootPath = root.path
            let parentPath = parent.path
            if parentPath.hasPrefix(rootPath + "/") {
                let relativeParent = String(parentPath.dropFirst(rootPath.count + 1))
                if !relativeParent.isEmpty { return "\(filename) — \(relativeParent)" }
            }
        }
        let parentName = parent.lastPathComponent
        return "\(filename) — \(parentName.isEmpty ? parent.path : parentName)"
    }
}
