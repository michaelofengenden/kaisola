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

struct MarkdownImagePayload: @unchecked Sendable {
    let image: NSImage
}

/// The cache identity of a resolved Markdown image.
///
/// This used to be the workspace watcher's monotonic change token, which made
/// every cache lookup a guaranteed miss after *any* write anywhere in the
/// project — including the document's own 700 ms Markdown autosave. Every image
/// then blanked to a placeholder and re-decoded, the document's height
/// collapsed while they were gone, and the viewport was dragged back toward the
/// top. Keying on what actually identifies the bytes keeps an agent-written
/// replacement refreshing while a save of the Markdown file changes nothing.
struct MarkdownImageIdentity: Equatable, Hashable, Sendable {
    let path: String
    let modifiedAt: Date?
    let bytes: Int

    var cacheKey: String {
        "\(path)#\(modifiedAt?.timeIntervalSince1970 ?? 0)#\(bytes)"
    }
}

/// Thread-safe decoded-image cache for rendered Markdown. The same decoded
/// image backs both the continuous editor's inline drawing and any structural
/// renderer, so scrolling an image-heavy document never re-reads from disk.
final class MarkdownLocalImageCache: @unchecked Sendable {
    static let shared = MarkdownLocalImageCache()
    private let images = NSCache<NSString, NSImage>()

    private init() {
        images.countLimit = 64
        images.totalCostLimit = 128 * 1_048_576
    }

    /// Resolve a Markdown image reference to a workspace-contained file.
    ///
    /// Returns `nil` for remote and `data:` sources, for anything resolving
    /// outside the workspace (symlinks included), and for files over the
    /// preview's image ceiling.
    nonisolated static func identity(
        source: String,
        documentURL: URL,
        workspaceRoot: URL?
    ) -> MarkdownImageIdentity? {
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
        return MarkdownImageIdentity(
            path: candidate.path,
            modifiedAt: attributes[.modificationDate] as? Date,
            bytes: bytes
        )
    }

    func load(
        source: String,
        documentURL: URL,
        workspaceRoot: URL?,
        displayWidth: CGFloat? = nil
    ) -> MarkdownImagePayload? {
        guard let identity = Self.identity(
            source: source,
            documentURL: documentURL,
            workspaceRoot: workspaceRoot
        ) else { return nil }
        return load(identity, displayWidth: displayWidth)
    }

    /// Memory-pressure hook (spec §2g).
    func purge() {
        images.removeAllObjects()
    }

    func load(_ identity: MarkdownImageIdentity) -> MarkdownImagePayload? {
        load(identity, displayWidth: nil)
    }

    /// `displayWidth` (document points) selects a downsample bucket; nil loads
    /// full resolution. Cost accounting uses DECODED pixel bytes — charging
    /// file size undercounted a 3 MB PNG's ~48 MB bitmap by an order of
    /// magnitude, letting the "128 MiB" ceiling admit over a gigabyte of
    /// pixels (2026-08-06 spec §2f).
    func load(_ identity: MarkdownImageIdentity, displayWidth: CGFloat?) -> MarkdownImagePayload? {
        let bucket = Self.widthBucket(displayWidth)
        let key = "\(identity.cacheKey)|w\(bucket)" as NSString
        if let cached = images.object(forKey: key) { return MarkdownImagePayload(image: cached) }
        guard let image = Self.decode(path: identity.path, bucket: bucket) else { return nil }
        images.setObject(image, forKey: key, cost: Self.decodedCost(image))
        return MarkdownImagePayload(image: image)
    }

    /// Bucketed so a narrow 1x decode never serves a wide 2x request: widths
    /// round UP to the next bucket, and the bucket rides in the cache key.
    static func widthBucket(_ displayWidth: CGFloat?) -> Int {
        guard let displayWidth, displayWidth > 0 else { return 0 } // 0 = full res
        let buckets = [320, 640, 1024, 1600, 2400]
        let scaled = Int((displayWidth * 2).rounded(.up)) // retina headroom
        return buckets.first { $0 >= scaled } ?? 0
    }

    static func decodedCost(_ image: NSImage) -> Int {
        let pixels = image.representations.reduce(0) { best, rep in
            max(best, rep.pixelsWide * rep.pixelsHigh)
        }
        return max(1, pixels * 4)
    }

    private static func decode(path: String, bucket: Int) -> NSImage? {
        guard bucket > 0,
              let source = CGImageSourceCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL, nil
              ),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: bucket,
              ] as CFDictionary) else {
            return NSImage(contentsOfFile: path)
        }
        return NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
    }
}
