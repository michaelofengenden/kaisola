import Foundation

struct WorkspaceAgentFileActivity: Equatable, Sendable {
    let sequence: UInt64
    let projectID: String
    let surfaceID: String
    let fileURL: URL
}

enum WorkspaceAgentFileFollowPolicy {
    /// Resolve one ACP-declared path against the conversation workspace. The
    /// target must already be a real file and its canonical path must remain in
    /// the project, so `..` and symlink escapes fail closed.
    static func resolve(path rawPath: String, workspaceRoot: URL) -> URL? {
        guard !rawPath.isEmpty,
              !rawPath.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        let root = workspaceRoot.standardizedFileURL
        let candidate = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath).standardizedFileURL
            : root.appendingPathComponent(rawPath).standardizedFileURL
        guard candidate.path != root.path,
              WorkspacePreviewLinkPolicy.isContained(candidate, in: root) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    static func shouldOpen(
        _ activity: WorkspaceAgentFileActivity,
        enabled: Bool,
        selectedProjectID: String?,
        selectedChatID: String?,
        selectedMeshID: String?
    ) -> Bool {
        enabled
            && selectedProjectID == activity.projectID
            && (selectedChatID == activity.surfaceID || selectedMeshID == activity.surfaceID)
    }
}
