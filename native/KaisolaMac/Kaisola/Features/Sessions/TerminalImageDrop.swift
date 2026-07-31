import AppKit
import Foundation

/// Turns a file dropped on a terminal pane into something the CLI running in it
/// actually understands.
///
/// The previous behaviour pasted a shell-quoted path and a comment claimed
/// "Claude and Codex recognize an image path as an image attachment". They do
/// not — a bare or quoted path is inert text to both, so dropping a screenshot
/// attached nothing.
///
/// What was verified to work:
///
/// - **Claude Code** attaches images through `@<path>`, including absolute paths
///   outside the working directory. The syntax is **whitespace-delimited**, so a
///   path containing a space silently fails — and backslash-escaping the space
///   is worse than useless: instead of erroring, the CLI proceeds and describes
///   an image it never received. macOS names every screenshot
///   `Screenshot 2026-07-27 at 9.13.45 PM.png`, so essentially every real
///   screenshot hits this. The fix is to *rename*, never to escape.
/// - **Codex** now reads a clipboard image through its Control-V TUI command,
///   which `OwnedTerminalView` also reaches from macOS Command-V. It still has
///   no text syntax that turns a dropped file path into a mid-session image;
///   `-i/--image` remains the file-path form for initial launch. A file dropped
///   on Codex therefore keeps the quoted-path behavior.
///
/// Anything that is not an image, and any session not running a known agent,
/// keeps the shell-quoted path — that is the correct thing to hand a plain
/// shell, where `@path` would simply be a syntax error.
enum TerminalImageDrop {
    /// Which insertion syntax the foreground process understands.
    enum AgentSyntax: Equatable {
        /// `@<path>` — whitespace-delimited, requires a space-free path.
        case claudeMention
        /// No dropped-path attachment syntax; paste a path like a plain shell.
        case pathOnly
    }

    /// The exact PTY insertion plus any attachment degradation the terminal
    /// must disclose. Keeping this structured prevents the AppKit drop path
    /// from guessing whether a quoted image path was intentional (Codex/plain
    /// shell) or an attachment failure (Claude).
    struct InsertionPlan: Equatable {
        let text: String
        let unattachedClaudeImageCount: Int

        var warningMessage: String? {
            guard unattachedClaudeImageCount > 0 else { return nil }
            if unattachedClaudeImageCount == 1 {
                return "Image wasn’t attached to Claude — the file path was pasted instead."
            }
            return "\(unattachedClaudeImageCount) images weren’t attached to Claude — their file paths were pasted instead."
        }
    }

    /// Extensions Claude accepts as image attachments.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Matches the ACP attachment cap so the two surfaces agree.
    static let maximumImageBytes = 5 * 1_024 * 1_024

    /// Staged copies live outside the user's repository on purpose: dropping a
    /// screenshot should never dirty a working tree or land in a commit. Claude
    /// reads absolute paths outside the cwd without an `--add-dir` grant.
    static var stagingDirectory: URL {
        NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("dropped-images", isDirectory: true)
    }

    static func syntax(forLaunchCommand command: String?) -> AgentSyntax {
        switch command {
        case "claude": .claudeMention
        default: .pathOnly
        }
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Image-only clipboard payloads are normally PNG/TIFF data; copying an
    /// image file in Finder instead exposes one or more file URLs. Keep this
    /// detection side-effect free so the terminal can decide whether Paste is
    /// text or Codex's image-specific Control-V command before touching the PTY.
    static func pasteboardContainsImage(_ pasteboard: NSPasteboard) -> Bool {
        if let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], values.contains(where: isImage) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// Text to bracketed-paste for a drop of `urls`.
    ///
    /// Images destined for Claude are copied to a space-free staged name first;
    /// if staging fails for any reason the path form is used rather than
    /// emitting a `@path` that would silently attach nothing.
    static func insertionText(
        for urls: [URL],
        syntax: AgentSyntax,
        stage: (URL) -> URL? = { stageImage($0) }
    ) -> String {
        insertionPlan(for: urls, syntax: syntax, stage: stage).text
    }

    /// Builds the insertion and records every Claude image that had to fall
    /// back to inert path text. Callers should surface `warningMessage` after
    /// pasting so the user never assumes Claude received pixels it did not.
    static func insertionPlan(
        for urls: [URL],
        syntax: AgentSyntax,
        stage: (URL) -> URL? = { stageImage($0) }
    ) -> InsertionPlan {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else {
            return InsertionPlan(text: "", unattachedClaudeImageCount: 0)
        }

        var unattachedClaudeImageCount = 0
        let tokens: [String] = files.map { url in
            guard syntax == .claudeMention, isImage(url) else {
                return shellQuote(url.standardizedFileURL.path)
            }
            guard let staged = stage(url) else {
                unattachedClaudeImageCount += 1
                return shellQuote(url.standardizedFileURL.path)
            }
            return "@" + staged.standardizedFileURL.path
        }
        return InsertionPlan(
            text: tokens.joined(separator: " ") + " ",
            unattachedClaudeImageCount: unattachedClaudeImageCount
        )
    }

    /// Copy an image to a space-free, collision-free staged path.
    static func stageImage(_ url: URL, now: Date = Date()) -> URL? {
        let source = url.standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumImageBytes else { return nil }

        let directory = stagingDirectory
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil else { return nil }

        let destination = directory.appendingPathComponent(
            stagedName(for: source, now: now),
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// `Screenshot 2026-07-27 at 9.13.45 PM.png` → `screenshot-2026-07-27-at-9-13-45-pm-<stamp>.png`.
    ///
    /// Every scalar outside `[a-z0-9-_]` collapses to `-`, so the result cannot
    /// contain whitespace, parentheses, or angle brackets — the characters that
    /// break `@` mentions. A timestamp suffix keeps repeated drops of the same
    /// screenshot name from colliding.
    static func stagedName(for url: URL, now: Date = Date()) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        var sanitized = ""
        var lastWasDash = false
        for character in base {
            if allowed.contains(character) {
                sanitized.append(character)
                lastWasDash = character == "-"
            } else if !lastWasDash {
                sanitized.append("-")
                lastWasDash = true
            }
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if sanitized.isEmpty { sanitized = "image" }
        if sanitized.count > 48 { sanitized = String(sanitized.prefix(48)) }

        let ext = url.pathExtension.lowercased()
        let extensionSuffix = imageExtensions.contains(ext) ? ext : "png"
        let stamp = Int(now.timeIntervalSince1970 * 1_000)
        return "\(sanitized)-\(stamp).\(extensionSuffix)"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
