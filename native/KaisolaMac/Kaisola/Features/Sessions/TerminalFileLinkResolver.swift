import Foundation

/// Finds the file an agent's citation actually meant.
///
/// Agent CLIs cite files the way a person would — `PILOT_REPORT.md`, not
/// `pilot/prospective_yh/PILOT_REPORT.md` — and the terminal resolves that
/// against its working directory, which for an agent session is the project
/// root. When the file lives in a subdirectory the resolved path simply does
/// not exist, and nothing downstream checked: the preview opened a tab onto
/// nothing, and Reveal in Finder handed Finder a path it could not select, so
/// Finder opened showing nothing. Michael: "md files aren't openable even
/// though I press them in a link from claude code, but then reveal in finder
/// button also doesn't work."
///
/// So a citation that does not resolve is searched for by name under the
/// project. One match is opened; several are reported rather than guessed at.
enum TerminalFileLinkResolver {
    enum Outcome: Equatable {
        /// The path resolved directly, or a search found exactly one file.
        case found(URL)
        /// The name exists in more than one place; picking one would be a coin
        /// toss, and opening the wrong file silently is worse than saying so.
        case ambiguous(name: String, count: Int)
        case missing(name: String)
    }

    /// Directories never worth walking: huge, and nothing an agent cites lives
    /// in them.
    static let skippedDirectories: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", ".next", "dist",
        "build", "Pods", ".venv", "venv", "__pycache__", ".worktrees",
    ]

    /// A ceiling on the walk so a citation into a giant tree cannot hang the
    /// click. Deep enough for any real repository layout.
    static let searchLimit = 20_000

    static func resolve(
        _ url: URL,
        projectRoot: URL?,
        fileManager: FileManager = .default
    ) -> Outcome {
        let direct = url.standardizedFileURL
        if fileManager.fileExists(atPath: direct.path) { return .found(direct) }

        let name = direct.lastPathComponent
        guard !name.isEmpty, let projectRoot else { return .missing(name: name) }

        let matches = search(name: name, under: projectRoot, fileManager: fileManager)
        switch matches.count {
        case 0: return .missing(name: name)
        case 1: return .found(matches[0])
        default: return .ambiguous(name: name, count: matches.count)
        }
    }

    /// Every file called `name` under `root`, bounded.
    static func search(
        name: String,
        under root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root.standardizedFileURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var matches: [URL] = []
        var visited = 0
        for case let candidate as URL in enumerator {
            visited += 1
            if visited > searchLimit { break }
            if skippedDirectories.contains(candidate.lastPathComponent),
               (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
                continue
            }
            guard candidate.lastPathComponent == name else { continue }
            guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
            matches.append(candidate.standardizedFileURL)
            // Two is already ambiguous; counting the rest changes nothing and
            // costs the remainder of the walk.
            if matches.count >= 2 { break }
        }
        return matches
    }

    /// The nearest directory that exists on the way up from `url`.
    ///
    /// Reveal in Finder has to show *something*. Handing Finder a path that is
    /// not there opens a window selecting nothing, which reads as the button
    /// being broken; the containing folder at least lands you where the file
    /// was supposed to be.
    static func revealTarget(for url: URL, fileManager: FileManager = .default) -> URL? {
        var candidate = url.standardizedFileURL
        if fileManager.fileExists(atPath: candidate.path) { return candidate }
        for _ in 0..<64 {
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { return nil }
            candidate = parent
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
