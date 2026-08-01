import AppKit
import Foundation
import SwiftUI

/// A paste/drop payload already reduced to Sendable filesystem bytes. AppKit
/// objects never cross the actor boundary: clipboard images become PNG data on
/// the main actor, while file drops carry only their URL.
enum MarkdownImageImport: Sendable {
    case file(URL)
    case data(Data, suggestedName: String, fileExtension: String)
}

struct MarkdownAssetInsertion: Equatable, Sendable {
    let fileURL: URL
    let markdown: String
}

struct MarkdownAssetImportBatch: Sendable {
    let insertions: [MarkdownAssetInsertion]
    let errors: [String]
}

/// Places one or more portable image links at a source selection without
/// joining them to adjacent prose. Shared by the whole-file source editor and
/// the exact block-local editor so paste/drop behavior does not depend on the
/// current Markdown editing mode.
enum MarkdownImageInsertion {
    static func text(snippets: [String], source: String, range: NSRange) -> String {
        let nsSource = source as NSString
        let safeLocation = min(max(0, range.location), nsSource.length)
        let safeLength = min(max(0, range.length), nsSource.length - safeLocation)
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        var insertion = snippets.joined(separator: "\n")
        if safeRange.location > 0,
           nsSource.substring(with: NSRange(location: safeRange.location - 1, length: 1)) != "\n" {
            insertion = "\n" + insertion
        }
        let end = NSMaxRange(safeRange)
        if end < nsSource.length,
           nsSource.substring(with: NSRange(location: end, length: 1)) != "\n" {
            insertion += "\n"
        }
        return insertion
    }
}

/// Copies pasted/dropped images into a portable folder beside the Markdown
/// document: `assets/<document-name>/image.png`. Keeping assets relative to the
/// document makes the inserted links work in GitHub, static-site generators,
/// and the Electron app without an app-specific URL scheme.
enum MarkdownAssetStore {
    static let maxImageBytes = 25 * 1_048_576
    private static let rasterExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff",
    ]

    nonisolated static func importImages(
        _ imports: [MarkdownImageImport],
        markdownURL: URL,
        workspaceRoot: URL?
    ) -> MarkdownAssetImportBatch {
        var insertions: [MarkdownAssetInsertion] = []
        var errors: [String] = []
        for item in imports.prefix(20) {
            do {
                insertions.append(try importImage(
                    item,
                    markdownURL: markdownURL,
                    workspaceRoot: workspaceRoot
                ))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if imports.count > 20 {
            errors.append("Paste or drop at most 20 images at a time.")
        }
        return MarkdownAssetImportBatch(insertions: insertions, errors: errors)
    }

    private nonisolated static func importImage(
        _ item: MarkdownImageImport,
        markdownURL: URL,
        workspaceRoot: URL?
    ) throws -> MarkdownAssetInsertion {
        let document = markdownURL.standardizedFileURL
        let documentDirectory = document.deletingLastPathComponent()
        if let workspaceRoot {
            guard isContained(document, in: workspaceRoot) else {
                throw MarkdownAssetError.documentOutsideWorkspace
            }
        }

        let documentName = sanitizedName(
            document.deletingPathExtension().lastPathComponent,
            fallback: "document"
        )
        let assetDirectory = documentDirectory
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(documentName, isDirectory: true)
        // An existing `assets` symlink must not turn an innocent paste into a
        // write outside the open project.
        if let workspaceRoot {
            guard isContained(assetDirectory, in: workspaceRoot) else {
                throw MarkdownAssetError.assetDirectoryOutsideWorkspace
            }
        }
        try FileManager.default.createDirectory(
            at: assetDirectory,
            withIntermediateDirectories: true
        )

        let data: Data
        let sourceName: String
        let fileExtension: String
        switch item {
        case let .file(source):
            let ext = source.pathExtension.lowercased()
            guard rasterExtensions.contains(ext) else {
                throw MarkdownAssetError.unsupportedImage(source.lastPathComponent)
            }
            let byteCount = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard byteCount <= maxImageBytes else {
                throw MarkdownAssetError.imageTooLarge(source.lastPathComponent)
            }
            data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard data.count <= maxImageBytes else {
                throw MarkdownAssetError.imageTooLarge(source.lastPathComponent)
            }
            sourceName = source.deletingPathExtension().lastPathComponent
            fileExtension = ext
        case let .data(bytes, suggestedName, ext):
            guard bytes.count <= maxImageBytes else {
                throw MarkdownAssetError.imageTooLarge(suggestedName)
            }
            let normalizedExtension = ext.lowercased()
            guard rasterExtensions.contains(normalizedExtension) else {
                throw MarkdownAssetError.unsupportedImage(suggestedName)
            }
            data = bytes
            sourceName = suggestedName
            fileExtension = normalizedExtension
        }

        guard !data.isEmpty else { throw MarkdownAssetError.emptyImage(sourceName) }
        let baseName = sanitizedName(sourceName, fallback: "image")
        let destination = uniqueDestination(
            directory: assetDirectory,
            baseName: baseName,
            fileExtension: fileExtension
        )
        // `Data` deliberately forbids combining `.atomic` with
        // `.withoutOverwriting`; exclusive creation is the important property
        // here because a paste must never replace an existing project asset.
        try data.write(to: destination, options: .withoutOverwriting)

        let relativePath = "assets/\(documentName)/\(destination.lastPathComponent)"
        let alt = baseName.replacingOccurrences(of: "]", with: "\\]")
        return MarkdownAssetInsertion(
            fileURL: destination,
            markdown: "![\(alt)](\(relativePath))"
        )
    }

    private nonisolated static func uniqueDestination(
        directory: URL,
        baseName: String,
        fileExtension: String
    ) -> URL {
        let manager = FileManager.default
        for suffix in 0..<10_000 {
            let name = suffix == 0 ? baseName : "\(baseName)-\(suffix + 1)"
            let candidate = directory
                .appendingPathComponent(name, isDirectory: false)
                .appendingPathExtension(fileExtension)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory
            .appendingPathComponent("\(baseName)-\(UUID().uuidString.lowercased())")
            .appendingPathExtension(fileExtension)
    }

    private nonisolated static func sanitizedName(_ raw: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String((collapsed.isEmpty ? fallback : collapsed).prefix(64))
    }

    private nonisolated static func isContained(_ url: URL, in directory: URL) -> Bool {
        let base = resolvedURLIncludingExistingAncestors(directory).path
        let candidate = resolvedURLIncludingExistingAncestors(url).path
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    /// `resolvingSymlinksInPath()` does not reliably resolve an existing
    /// symlink when a later path component has not been created yet. Resolve
    /// the closest existing ancestor first, then restore the missing suffix.
    private nonisolated static func resolvedURLIncludingExistingAncestors(_ url: URL) -> URL {
        let manager = FileManager.default
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []
        while !manager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private enum MarkdownAssetError: LocalizedError {
        case documentOutsideWorkspace
        case assetDirectoryOutsideWorkspace
        case unsupportedImage(String)
        case imageTooLarge(String)
        case emptyImage(String)

        var errorDescription: String? {
            switch self {
            case .documentOutsideWorkspace:
                "Images can only be added to Markdown files inside the open project."
            case .assetDirectoryOutsideWorkspace:
                "The Markdown asset folder resolves outside the open project."
            case let .unsupportedImage(name):
                "\(name) is not a supported raster image."
            case let .imageTooLarge(name):
                "\(name) is larger than \(maxImageBytes / 1_048_576) MB."
            case let .emptyImage(name):
                "\(name) contains no image data."
            }
        }
    }
}

private struct MarkdownImagePayload: @unchecked Sendable {
    let image: NSImage
}

/// Thread-safe decoded-image cache for rendered Markdown. LazyVStack may
/// remount offscreen blocks during momentum; decoding from disk in blockView on
/// each remount made image-heavy documents hitch. The workspace watcher token
/// is part of the key, so agent-written replacements still refresh.
private final class MarkdownLocalImageCache: @unchecked Sendable {
    static let shared = MarkdownLocalImageCache()
    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 64
        images.totalCostLimit = 128 * 1_048_576
    }

    func load(
        source: String,
        documentURL: URL,
        workspaceRoot: URL?,
        revision: Int
    ) -> MarkdownImagePayload? {
        guard !source.contains("://"), !source.hasPrefix("data:") else { return nil }
        let decoded = source.removingPercentEncoding ?? source
        let base = documentURL.deletingLastPathComponent().standardizedFileURL
        let candidate = URL(fileURLWithPath: decoded, relativeTo: base)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let boundary = (workspaceRoot ?? base).standardizedFileURL.resolvingSymlinksInPath()
        let boundaryPath = boundary.path.hasSuffix("/") ? boundary.path : boundary.path + "/"
        guard candidate.path == boundary.path || candidate.path.hasPrefix(boundaryPath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              let bytes = attributes[.size] as? Int,
              bytes <= FilePreviewContent.maxImageBytes else { return nil }
        let key = "\(candidate.path)#\(revision)" as NSString
        if let cached = images.object(forKey: key) { return MarkdownImagePayload(image: cached) }
        guard let image = NSImage(contentsOf: candidate) else { return nil }
        images.setObject(image, forKey: key, cost: max(1, bytes))
        return MarkdownImagePayload(image: image)
    }
}

struct MarkdownLocalImageView: View {
    let source: String
    let alt: String?
    let declaredWidth: Double?
    let declaredHeight: Double?
    let alignment: MarkdownDocument.ContentAlignment?
    let availableWidth: CGFloat
    let zoom: CGFloat
    let documentURL: URL
    let workspaceRoot: URL?
    let revision: Int
    @State private var image: NSImage?
    @State private var didFinishLoading = false

    private var loadIdentity: String {
        "\(documentURL.path)|\(source)|\(revision)"
    }

    var body: some View {
        Group {
            if let image {
                let renderedSize = MarkdownPreviewLayout.imageSize(
                    intrinsicSize: image.size,
                    declaredWidth: declaredWidth,
                    declaredHeight: declaredHeight,
                    availableWidth: availableWidth,
                    zoom: zoom
                )
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: renderedSize.width, height: renderedSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12 * zoom, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .accessibilityLabel(alt ?? "Markdown image")
            } else if !didFinishLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: frameAlignment)
                    .accessibilityLabel("Loading Markdown image")
            } else {
                Label(alt ?? "Image unavailable", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        }
        .task(id: loadIdentity) {
            image = nil
            didFinishLoading = false
            let payload = await Task.detached(priority: .utility) {
                MarkdownLocalImageCache.shared.load(
                    source: source,
                    documentURL: documentURL,
                    workspaceRoot: workspaceRoot,
                    revision: revision
                )
            }.value
            guard !Task.isCancelled else { return }
            image = payload?.image
            didFinishLoading = true
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }
}
