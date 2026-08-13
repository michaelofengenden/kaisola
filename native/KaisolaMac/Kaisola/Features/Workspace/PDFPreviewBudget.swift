import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import QuartzCore

struct PDFPreviewBudgetFixtureSpecification: Codable, Equatable, Sendable {
    let id: String
    let fileName: String
    let expectedOutcome: String
    let expectedPageCount: Int
    let pageWidthPoints: Double
    let pageHeightPoints: Double
    let minimumBytes: Int
    let maximumBytes: Int
    let pagingPageIndexes: [Int]
    let measuresSustainedScroll: Bool
    let rasterWidthPixels: Int?
    let rasterHeightPixels: Int?
}

enum PDFPreviewBudgetFixtureCatalog {
    static let specifications: [PDFPreviewBudgetFixtureSpecification] = [
        PDFPreviewBudgetFixtureSpecification(
            id: "many-page",
            fileName: "many-page.pdf",
            expectedOutcome: "rendered",
            expectedPageCount: 96,
            pageWidthPoints: 612,
            pageHeightPoints: 792,
            minimumBytes: 8 * 1_024,
            maximumBytes: 2 * 1_048_576,
            pagingPageIndexes: [1, 12, 24, 48, 72, 95],
            measuresSustainedScroll: true,
            rasterWidthPixels: nil,
            rasterHeightPixels: nil
        ),
        PDFPreviewBudgetFixtureSpecification(
            id: "image-heavy",
            fileName: "image-heavy.pdf",
            expectedOutcome: "rendered",
            expectedPageCount: 6,
            pageWidthPoints: 612,
            pageHeightPoints: 792,
            minimumBytes: 8 * 1_048_576,
            maximumBytes: 19 * 1_048_576,
            pagingPageIndexes: [1, 2, 3, 4, 5],
            measuresSustainedScroll: true,
            rasterWidthPixels: 896,
            rasterHeightPixels: 896
        ),
        PDFPreviewBudgetFixtureSpecification(
            id: "malformed",
            fileName: "malformed.pdf",
            expectedOutcome: "rejected",
            expectedPageCount: 0,
            pageWidthPoints: 0,
            pageHeightPoints: 0,
            minimumBytes: PDFPreviewBudgetFixtureWriter.malformedBytes.count,
            maximumBytes: PDFPreviewBudgetFixtureWriter.malformedBytes.count,
            pagingPageIndexes: [],
            measuresSustainedScroll: false,
            rasterWidthPixels: nil,
            rasterHeightPixels: nil
        ),
        PDFPreviewBudgetFixtureSpecification(
            id: "large-page",
            fileName: "large-page.pdf",
            expectedOutcome: "rendered",
            expectedPageCount: 1,
            pageWidthPoints: 14_400,
            pageHeightPoints: 14_400,
            minimumBytes: 512,
            maximumBytes: 1_048_576,
            pagingPageIndexes: [],
            measuresSustainedScroll: false,
            rasterWidthPixels: nil,
            rasterHeightPixels: nil
        ),
    ]

    static func specification(id: String) -> PDFPreviewBudgetFixtureSpecification? {
        specifications.first { $0.id == id }
    }
}

struct PDFPreviewBudgetGeneratedFixture: Equatable, Sendable {
    let specification: PDFPreviewBudgetFixtureSpecification
    let url: URL
    let byteCount: Int
}

struct PDFPreviewBudgetFixtureArtifact: Codable, Equatable, Sendable {
    let fileName: String
    let byteCount: Int
    let sha256: String

    static func capture(
        _ fixture: PDFPreviewBudgetGeneratedFixture
    ) throws -> PDFPreviewBudgetFixtureArtifact {
        PDFPreviewBudgetFixtureArtifact(
            fileName: fixture.specification.fileName,
            byteCount: fixture.byteCount,
            sha256: try digest(of: fixture.url)
        )
    }

    func isValid(for specification: PDFPreviewBudgetFixtureSpecification) -> Bool {
        fileName == specification.fileName
            && byteCount >= specification.minimumBytes
            && byteCount <= specification.maximumBytes
            && sha256.count == 64
            && sha256.allSatisfy { character in
                character.isNumber || ("a"..."f").contains(String(character))
            }
    }

    private static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum PDFPreviewBudgetFixtureLoader {
    static func load(
        specification: PDFPreviewBudgetFixtureSpecification,
        root: URL,
        expectedArtifact: PDFPreviewBudgetFixtureArtifact
    ) throws -> PDFPreviewBudgetGeneratedFixture {
        guard expectedArtifact.isValid(for: specification) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(
            specification.fileName,
            isDirectory: false
        ).standardizedFileURL
        guard candidate.deletingLastPathComponent() == canonicalRoot else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try candidate.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              candidate.resolvingSymlinksInPath() == candidate,
              values.fileSize == expectedArtifact.byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fixture = PDFPreviewBudgetGeneratedFixture(
            specification: specification,
            url: candidate,
            byteCount: expectedArtifact.byteCount
        )
        guard try PDFPreviewBudgetFixtureArtifact.capture(fixture) == expectedArtifact else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return fixture
    }
}

enum PDFPreviewBudgetFixtureWriter {
    static let malformedBytes = Data(
        "%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\n".utf8
    )

    static func write(
        _ specification: PDFPreviewBudgetFixtureSpecification,
        to directory: URL
    ) throws -> PDFPreviewBudgetGeneratedFixture {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(specification.fileName, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
        switch specification.id {
        case "many-page":
            try writeManyPagePDF(specification, to: url)
        case "image-heavy":
            try writeImageHeavyPDF(specification, to: url)
        case "malformed":
            try malformedBytes.write(to: url, options: .atomic)
        case "large-page":
            try writeLargePagePDF(specification, to: url)
        default:
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let byteCount = values.fileSize else { throw CocoaError(.fileReadUnknown) }
        return PDFPreviewBudgetGeneratedFixture(
            specification: specification,
            url: url,
            byteCount: byteCount
        )
    }

    private static func makeContext(
        specification: PDFPreviewBudgetFixtureSpecification,
        url: URL
    ) throws -> CGContext {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: specification.pageWidthPoints,
            height: specification.pageHeightPoints
        )
        let metadata: [CFString: Any] = [
            kCGPDFContextCreator: "Kaisola deterministic PDF preview budget v1",
            kCGPDFContextTitle: specification.id,
        ]
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            metadata as CFDictionary
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return context
    }

    private static func beginPage(
        _ context: CGContext,
        specification: PDFPreviewBudgetFixtureSpecification
    ) {
        let mediaBox = CGRect(
            x: 0,
            y: 0,
            width: specification.pageWidthPoints,
            height: specification.pageHeightPoints
        )
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
    }

    private static func writeManyPagePDF(
        _ specification: PDFPreviewBudgetFixtureSpecification,
        to url: URL
    ) throws {
        let context = try makeContext(specification: specification, url: url)
        for page in 0..<specification.expectedPageCount {
            beginPage(context, specification: specification)
            context.setLineWidth(1.25)
            for row in 0..<24 {
                let hue = CGFloat((page * 17 + row * 11) % 255) / 255
                context.setFillColor(CGColor(
                    red: 0.12 + hue * 0.42,
                    green: 0.18 + CGFloat(row % 5) * 0.09,
                    blue: 0.58 - hue * 0.24,
                    alpha: 1
                ))
                let width = CGFloat(170 + ((page + row * 7) % 330))
                context.fill(CGRect(x: 54, y: 54 + CGFloat(row) * 28, width: width, height: 12))
            }
            context.setStrokeColor(CGColor(gray: 0.18, alpha: 1))
            context.move(to: CGPoint(x: 54, y: 744))
            context.addLine(to: CGPoint(x: 558, y: 744))
            context.strokePath()
            context.endPDFPage()
        }
        context.closePDF()
        try canonicalizeGeneratedPDF(specification, at: url)
    }

    private static func writeImageHeavyPDF(
        _ specification: PDFPreviewBudgetFixtureSpecification,
        to url: URL
    ) throws {
        guard let width = specification.rasterWidthPixels,
              let height = specification.rasterHeightPixels else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let context = try makeContext(specification: specification, url: url)
        for page in 0..<specification.expectedPageCount {
            beginPage(context, specification: specification)
            guard let image = deterministicImage(width: width, height: height, seed: UInt32(page + 1)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 36, y: 126, width: 540, height: 540))
            context.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
            context.setLineWidth(2)
            context.stroke(CGRect(x: 36, y: 126, width: 540, height: 540))
            context.endPDFPage()
        }
        context.closePDF()
        try canonicalizeGeneratedPDF(specification, at: url)
    }

    private static func deterministicImage(width: Int, height: Int, seed: UInt32) -> CGImage? {
        var pixels = Data(count: width * height * 3)
        pixels.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var state = 0xA341_316C ^ (seed &* 0x9E37_79B9)
            for index in bytes.indices {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                bytes[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func writeLargePagePDF(
        _ specification: PDFPreviewBudgetFixtureSpecification,
        to url: URL
    ) throws {
        let context = try makeContext(specification: specification, url: url)
        beginPage(context, specification: specification)
        let pageRect = CGRect(
            x: 0,
            y: 0,
            width: specification.pageWidthPoints,
            height: specification.pageHeightPoints
        )
        context.setStrokeColor(CGColor(red: 0.15, green: 0.32, blue: 0.64, alpha: 1))
        context.setLineWidth(12)
        for index in 0...40 {
            let offset = CGFloat(index) * pageRect.width / 40
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset, y: pageRect.height))
            context.move(to: CGPoint(x: 0, y: offset))
            context.addLine(to: CGPoint(x: pageRect.width, y: offset))
        }
        context.strokePath()
        context.setFillColor(CGColor(red: 0.76, green: 0.22, blue: 0.2, alpha: 1))
        context.fill(CGRect(
            x: pageRect.midX - 1_200,
            y: pageRect.midY - 1_200,
            width: 2_400,
            height: 2_400
        ))
        context.endPDFPage()
        context.closePDF()
        try canonicalizeGeneratedPDF(specification, at: url)
    }

    /// Quartz injects the wall clock and a random trailer ID even when every
    /// drawn byte is fixed. Both fields are fixed-width, so canonicalizing them
    /// after `closePDF()` preserves every xref offset and makes repeat fixture
    /// generation byte-for-byte stable on the same PDFKit runtime.
    private static func canonicalizeGeneratedPDF(
        _ specification: PDFPreviewBudgetFixtureSpecification,
        at url: URL
    ) throws {
        let documentIDs: [String: String] = [
            "many-page": "ff1539c611f103813e9158ed05609fa9",
            "image-heavy": "ef07c7b1e2e67bffaa402a2ca47243c8",
            "large-page": "25d255df44a8f36aadb53c3c1ee55e03",
        ]
        guard let documentID = documentIDs[specification.id] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let original = try Data(contentsOf: url)
        guard var contents = String(data: original, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        contents = try replaceExactlyOnce(
            #"/ModDate \(D:\d{14}(?:Z00|[+-]\d{2})'\d{2}'\)"#,
            with: "/ModDate (D:20010101000000Z00'00')",
            in: contents
        )
        contents = try replaceExactlyOnce(
            #"/CreationDate \(D:\d{14}(?:Z00|[+-]\d{2})'\d{2}'\)"#,
            with: "/CreationDate (D:20010101000000Z00'00')",
            in: contents
        )
        contents = try replaceExactlyOnce(
            #"(/ID \[ <)[0-9A-Fa-f]{32}(>\s*<)[0-9A-Fa-f]{32}(> \])"#,
            with: "$1\(documentID)$2\(documentID)$3",
            in: contents
        )
        guard let canonical = contents.data(using: .isoLatin1, allowLossyConversion: false),
              canonical.count == original.count else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        try canonical.write(to: url, options: .atomic)
    }

    private static func replaceExactlyOnce(
        _ pattern: String,
        with replacement: String,
        in source: String
    ) throws -> String {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard expression.numberOfMatches(in: source, range: range) == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return expression.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: replacement
        )
    }
}

enum PDFPreviewBudgetPhase: String, Codable, Equatable, Sendable {
    case generate
    case render
}

struct PDFPreviewBudgetConfiguration: Equatable, Sendable {
    let fixture: PDFPreviewBudgetFixtureSpecification
    let root: URL
    let phase: PDFPreviewBudgetPhase
    let expectedArtifact: PDFPreviewBudgetFixtureArtifact?

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> PDFPreviewBudgetConfiguration? {
        guard environment["KAISOLA_NATIVE_PDF_PREVIEW_BUDGET"] == "1",
              let fixtureID = environment["KAISOLA_NATIVE_PDF_PREVIEW_FIXTURE"],
              let fixture = PDFPreviewBudgetFixtureCatalog.specification(id: fixtureID),
              let rawPhase = environment["KAISOLA_NATIVE_PDF_PREVIEW_PHASE"],
              let phase = PDFPreviewBudgetPhase(rawValue: rawPhase),
              let rawRoot = environment["KAISOLA_NATIVE_PDF_PREVIEW_ROOT"],
              rawRoot.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let temporary = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(temporary.path + "/") else { return nil }
        let expectedBytes = environment["KAISOLA_NATIVE_PDF_PREVIEW_EXPECTED_BYTES"]
        let expectedSHA256 = environment["KAISOLA_NATIVE_PDF_PREVIEW_EXPECTED_SHA256"]
        let artifact: PDFPreviewBudgetFixtureArtifact?
        switch phase {
        case .generate:
            guard expectedBytes == nil, expectedSHA256 == nil else { return nil }
            artifact = nil
        case .render:
            guard let expectedBytes,
                  let byteCount = Int(expectedBytes),
                  let expectedSHA256 else { return nil }
            let candidate = PDFPreviewBudgetFixtureArtifact(
                fileName: fixture.fileName,
                byteCount: byteCount,
                sha256: expectedSHA256
            )
            guard candidate.isValid(for: fixture) else { return nil }
            artifact = candidate
        }
        return PDFPreviewBudgetConfiguration(
            fixture: fixture,
            root: root,
            phase: phase,
            expectedArtifact: artifact
        )
    }
}

struct PDFPreviewBudgetThresholds: Codable, Equatable, Sendable {
    // Paging is gated twice, because one gate over these sample counts cannot
    // do both jobs. A fixture turns 5 or 6 pages, and a 95th percentile over 5
    // samples is arithmetically just the slowest one, so the old single
    // `maximumSubsequentPagingP95LatencyMs: 750` was really "no page turn may
    // ever exceed 750ms" wearing a percentile's name.
    //
    // That mattered because one page turn is legitimately far slower than the
    // rest. Across seven CI runs the slowest `image-heavy` sample was the jump
    // to the last page every single time, never another index, at 479, 512,
    // 600, 632, 747, 771 and 880ms. The limit sat about 1.2x above a genuine
    // recurring cost, so ordinary runner variance failed the job on two of
    // those seven runs while nothing had regressed.
    //
    // The median is the stable statistic: over the same runs it stayed within
    // 22-87ms for both paging fixtures, so 250ms leaves roughly 3x of room and
    // still catches any regression that moves paging as a whole.
    //
    // The ceiling is deliberately not "a bit above the worst sample we have
    // seen". A first attempt set it at 1500ms on seven runs topping out at
    // 880ms, and the very next CI run turned that last page in 1698ms while its
    // median sat at 64ms — nothing had regressed, the tail is simply that heavy
    // on a shared runner. Chasing the tail with a slightly larger number just
    // repeats the mistake the p95 gate made.
    //
    // So the ceiling is anchored to something with a meaning instead: a page
    // turn must never cost as much as opening the document cold, which is
    // `maximumFirstVisiblePageLatencyMs`. That is a real pathology rather than a
    // percentile, it clears the worst sample yet observed by about 1.8x, and it
    // leaves the median as the gate that actually detects regressions.
    static let standard = PDFPreviewBudgetThresholds(
        maximumFirstVisiblePageLatencyMs: 3_000,
        maximumSubsequentPagingMedianLatencyMs: 250,
        maximumSubsequentPagingLatencyMs: 3_000,
        maximumMalformedRejectionLatencyMs: 1_000,
        scrollMeasurementDurationSeconds: 3,
        maximumScrollP95IntervalMs: 50,
        maximumScrollIntervalMs: 250,
        minimumScrollCallbackCoverage: 0.8,
        maximumPeakPhysicalFootprintBytes: 768 * 1_048_576
    )

    let maximumFirstVisiblePageLatencyMs: Double
    let maximumSubsequentPagingMedianLatencyMs: Double
    let maximumSubsequentPagingLatencyMs: Double
    let maximumMalformedRejectionLatencyMs: Double
    let scrollMeasurementDurationSeconds: Double
    let maximumScrollP95IntervalMs: Double
    let maximumScrollIntervalMs: Double
    let minimumScrollCallbackCoverage: Double
    let maximumPeakPhysicalFootprintBytes: Int
}

struct PDFPreviewBudgetDiagnostic: Codable, Equatable, Sendable {
    let fixture: String
    let threshold: String
    let observed: Double
    let limit: Double
}

struct PDFPreviewScrollMetrics: Codable, Equatable, Sendable {
    let callbackCount: Int
    let measurementDurationSeconds: Double
    let nominalFrameDurationMs: Double
    let p95IntervalMs: Double
    let maximumIntervalMs: Double
    let callbackCoverage: Double

    static func summarize(
        callbackTimestamps: [Double],
        nominalFrameDurations: [Double]
    ) -> PDFPreviewScrollMetrics? {
        guard callbackTimestamps.count >= 2,
              callbackTimestamps.allSatisfy(\.isFinite),
              zip(callbackTimestamps, callbackTimestamps.dropFirst()).allSatisfy({ $0 < $1 }) else {
            return nil
        }
        let usableDurations = nominalFrameDurations.filter { $0.isFinite && $0 > 0 }
        guard !usableDurations.isEmpty else { return nil }
        let intervals = zip(callbackTimestamps, callbackTimestamps.dropFirst()).map {
            earlier, later in later - earlier
        }
        guard let maximumInterval = intervals.max(), maximumInterval > 0 else { return nil }
        let duration = callbackTimestamps.last! - callbackTimestamps.first!
        guard duration > 0 else { return nil }
        let nominal = percentile(usableDurations, fraction: 0.5)
        let coverage = min(1, Double(intervals.count) * nominal / duration)
        return PDFPreviewScrollMetrics(
            callbackCount: callbackTimestamps.count,
            measurementDurationSeconds: duration,
            nominalFrameDurationMs: nominal * 1_000,
            p95IntervalMs: percentile(intervals, fraction: 0.95) * 1_000,
            maximumIntervalMs: maximumInterval * 1_000,
            callbackCoverage: coverage
        )
    }
}

struct PDFPreviewBudgetMeasurements: Codable, Equatable, Sendable {
    let firstVisiblePageLatencyMs: Double?
    let subsequentPagingLatenciesMs: [Double]
    let malformedRejectionLatencyMs: Double?
    let scroll: PDFPreviewScrollMetrics?
}

struct PDFPreviewBudgetFixtureResult: Codable, Equatable, Sendable {
    let fixture: String
    let generatedBytes: Int
    let actualPageCount: Int
    let outcome: String
    let firstVisiblePageLatencyMs: Double?
    let subsequentPagingLatenciesMs: [Double]
    let subsequentPagingMedianLatencyMs: Double?
    let subsequentPagingMaximumLatencyMs: Double?
    let malformedRejectionLatencyMs: Double?
    let scroll: PDFPreviewScrollMetrics?
    let diagnostics: [PDFPreviewBudgetDiagnostic]
    let pass: Bool

    static func evaluate(
        specification: PDFPreviewBudgetFixtureSpecification,
        byteCount: Int,
        actualPageCount: Int,
        outcome: String,
        measurements: PDFPreviewBudgetMeasurements,
        thresholds: PDFPreviewBudgetThresholds = .standard
    ) -> PDFPreviewBudgetFixtureResult {
        var diagnostics: [PDFPreviewBudgetDiagnostic] = []
        func maximum(_ threshold: String, observed: Double, limit: Double) {
            guard observed > limit else { return }
            diagnostics.append(PDFPreviewBudgetDiagnostic(
                fixture: specification.id,
                threshold: threshold,
                observed: observed,
                limit: limit
            ))
        }
        func minimum(_ threshold: String, observed: Double, limit: Double) {
            guard observed < limit else { return }
            diagnostics.append(PDFPreviewBudgetDiagnostic(
                fixture: specification.id,
                threshold: threshold,
                observed: observed,
                limit: limit
            ))
        }
        func exact(_ threshold: String, observed: Double, limit: Double) {
            guard observed != limit else { return }
            diagnostics.append(PDFPreviewBudgetDiagnostic(
                fixture: specification.id,
                threshold: threshold,
                observed: observed,
                limit: limit
            ))
        }

        minimum("generatedBytes.minimum", observed: Double(byteCount), limit: Double(specification.minimumBytes))
        maximum("generatedBytes.maximum", observed: Double(byteCount), limit: Double(specification.maximumBytes))
        exact("pageCount.exact", observed: Double(actualPageCount), limit: Double(specification.expectedPageCount))
        if outcome != specification.expectedOutcome {
            diagnostics.append(PDFPreviewBudgetDiagnostic(
                fixture: specification.id,
                threshold: "outcome.exact",
                observed: outcome == "rendered" ? 1 : 0,
                limit: specification.expectedOutcome == "rendered" ? 1 : 0
            ))
        }

        var pagingMedian: Double?
        var pagingMaximum: Double?
        if specification.expectedOutcome == "rendered" {
            maximum(
                "firstVisiblePageLatencyMs.maximum",
                observed: measurements.firstVisiblePageLatencyMs ?? -1,
                limit: thresholds.maximumFirstVisiblePageLatencyMs
            )
            if measurements.firstVisiblePageLatencyMs == nil {
                exact("firstVisiblePageLatencyMs.present", observed: 0, limit: 1)
            }
            if !specification.pagingPageIndexes.isEmpty {
                exact(
                    "subsequentPagingSamples.count",
                    observed: Double(measurements.subsequentPagingLatenciesMs.count),
                    limit: Double(specification.pagingPageIndexes.count)
                )
                if !measurements.subsequentPagingLatenciesMs.isEmpty {
                    let typical = median(of: measurements.subsequentPagingLatenciesMs)
                    let slowest = measurements.subsequentPagingLatenciesMs.max() ?? 0
                    pagingMedian = typical
                    pagingMaximum = slowest
                    maximum(
                        "subsequentPagingMedianLatencyMs.maximum",
                        observed: typical,
                        limit: thresholds.maximumSubsequentPagingMedianLatencyMs
                    )
                    maximum(
                        "subsequentPagingMaximumLatencyMs.maximum",
                        observed: slowest,
                        limit: thresholds.maximumSubsequentPagingLatencyMs
                    )
                }
            }
            if specification.measuresSustainedScroll {
                guard let scroll = measurements.scroll else {
                    exact("scroll.completed", observed: 0, limit: 1)
                    return PDFPreviewBudgetFixtureResult(
                        fixture: specification.id,
                        generatedBytes: byteCount,
                        actualPageCount: actualPageCount,
                        outcome: outcome,
                        firstVisiblePageLatencyMs: measurements.firstVisiblePageLatencyMs,
                        subsequentPagingLatenciesMs: measurements.subsequentPagingLatenciesMs,
                        subsequentPagingMedianLatencyMs: pagingMedian,
                        subsequentPagingMaximumLatencyMs: pagingMaximum,
                        malformedRejectionLatencyMs: measurements.malformedRejectionLatencyMs,
                        scroll: nil,
                        diagnostics: diagnostics,
                        pass: false
                    )
                }
                minimum(
                    "scroll.measurementDurationSeconds.minimum",
                    observed: scroll.measurementDurationSeconds,
                    limit: thresholds.scrollMeasurementDurationSeconds * 0.95
                )
                maximum(
                    "scroll.p95IntervalMs.maximum",
                    observed: scroll.p95IntervalMs,
                    limit: thresholds.maximumScrollP95IntervalMs
                )
                maximum(
                    "scroll.maximumIntervalMs.maximum",
                    observed: scroll.maximumIntervalMs,
                    limit: thresholds.maximumScrollIntervalMs
                )
                minimum(
                    "scroll.callbackCoverage.minimum",
                    observed: scroll.callbackCoverage,
                    limit: thresholds.minimumScrollCallbackCoverage
                )
            }
        } else {
            if let rejection = measurements.malformedRejectionLatencyMs {
                maximum(
                    "malformedRejectionLatencyMs.maximum",
                    observed: rejection,
                    limit: thresholds.maximumMalformedRejectionLatencyMs
                )
            } else {
                exact("malformedRejectionLatencyMs.present", observed: 0, limit: 1)
            }
        }

        return PDFPreviewBudgetFixtureResult(
            fixture: specification.id,
            generatedBytes: byteCount,
            actualPageCount: actualPageCount,
            outcome: outcome,
            firstVisiblePageLatencyMs: measurements.firstVisiblePageLatencyMs,
            subsequentPagingLatenciesMs: measurements.subsequentPagingLatenciesMs,
            subsequentPagingMedianLatencyMs: pagingMedian,
            subsequentPagingMaximumLatencyMs: pagingMaximum,
            malformedRejectionLatencyMs: measurements.malformedRejectionLatencyMs,
            scroll: measurements.scroll,
            diagnostics: diagnostics,
            pass: diagnostics.isEmpty
        )
    }

    static func harnessFailure(
        specification: PDFPreviewBudgetFixtureSpecification,
        message: String
    ) -> PDFPreviewBudgetFixtureResult {
        let diagnostic = PDFPreviewBudgetDiagnostic(
            fixture: specification.id,
            threshold: "measurement.completed",
            observed: 0,
            limit: 1
        )
        return PDFPreviewBudgetFixtureResult(
            fixture: specification.id,
            generatedBytes: 0,
            actualPageCount: 0,
            outcome: "harness-failed-\(message.prefix(80))",
            firstVisiblePageLatencyMs: nil,
            subsequentPagingLatenciesMs: [],
            subsequentPagingMedianLatencyMs: nil,
            subsequentPagingMaximumLatencyMs: nil,
            malformedRejectionLatencyMs: nil,
            scroll: nil,
            diagnostics: [diagnostic],
            pass: false
        )
    }
}

struct PDFPreviewBudgetBuildReceipt: Codable, Equatable, Sendable {
    let optimized: Bool
    let bundleIdentifier: String
    let bundlePath: String
    let version: String
    let build: String
}

struct PDFPreviewBudgetAppReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let workload: String
    let phase: PDFPreviewBudgetPhase
    let fixture: String
    let appPid: Int32
    let build: PDFPreviewBudgetBuildReceipt
    let thresholds: PDFPreviewBudgetThresholds
    let specification: PDFPreviewBudgetFixtureSpecification
    let result: PDFPreviewBudgetFixtureResult
}

struct PDFPreviewBudgetGenerationReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let workload: String
    let phase: PDFPreviewBudgetPhase
    let fixture: String
    let appPid: Int32
    let build: PDFPreviewBudgetBuildReceipt
    let specification: PDFPreviewBudgetFixtureSpecification
    let artifact: PDFPreviewBudgetFixtureArtifact
}

@MainActor
enum PDFPreviewViewConfiguration {
    static var initialUpscaleCapPageCount: Int { 96 }

    static func capsInitialUpscale(pageCount: Int) -> Bool {
        pageCount >= initialUpscaleCapPageCount
    }

    static func install(document: PDFDocument?, in view: PDFView) {
        guard view.document !== document else { return }
        if view.document != nil {
            view.setCurrentSelection(nil, animate: false)
            view.document = nil
        }

        let capsInitialUpscale = capsInitialUpscale(pageCount: document?.pageCount ?? 0)
        view.autoScales = !capsInitialUpscale
        if capsInitialUpscale {
            view.scaleFactor = 1
        }
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        if capsInitialUpscale,
           view.bounds.width > 0,
           view.bounds.height > 0 {
            let fitScale = view.scaleFactorForSizeToFit
            if fitScale.isFinite, fitScale > 0, fitScale < 1 {
                view.scaleFactor = fitScale
            }
        }
    }
}

final class PDFPreviewBudgetPage: PDFPage {
    private let lock = NSLock()
    private var completedDrawCountStorage = 0

    nonisolated override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        lock.lock()
        defer { lock.unlock() }
        completedDrawCountStorage += 1
    }

    nonisolated var completedDrawCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedDrawCountStorage
    }
}

final class PDFPreviewBudgetDocument: PDFDocument {
    override var pageClass: AnyClass {
        PDFPreviewBudgetPage.self
    }
}

enum PDFPreviewBudgetDocumentIO {
    static func load(url: URL) -> PDFDocumentPayload? {
        guard let document = PDFPreviewBudgetDocument(url: url), document.pageCount > 0 else {
            return nil
        }
        return PDFDocumentPayload(value: document)
    }
}

actor PDFPreviewBudgetDocumentWorker {
    static let shared = PDFPreviewBudgetDocumentWorker()

    func load(url: URL) -> PDFDocumentPayload? {
        PDFPreviewBudgetDocumentIO.load(url: url)
    }
}

@MainActor
private final class PDFPreviewScrollProbe: NSObject {
    private let view: PDFView
    private let duration: Double
    private var continuation: CheckedContinuation<PDFPreviewScrollMetrics?, Never>?
    private var displayLink: CADisplayLink?
    private var timeoutTask: Task<Void, Never>?
    private var timestamps: [Double] = []
    private var nominalDurations: [Double] = []
    private var startedAt: Double?
    private var completed = false

    init(view: PDFView, duration: Double) {
        self.view = view
        self.duration = duration
    }

    func run() async -> PDFPreviewScrollMetrics? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            guard let documentView = view.documentView,
                  let scrollView = documentView.enclosingScrollView,
                  documentView.bounds.height > scrollView.contentView.bounds.height else {
                finish(nil)
                return
            }
            let displayLink = view.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
            self.displayLink = displayLink
            displayLink.add(to: .main, forMode: .common)
            timeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(duration + 5))
                finish(nil)
            }
        }
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard !completed,
              let documentView = view.documentView,
              let scrollView = documentView.enclosingScrollView else { return }
        let now = CACurrentMediaTime()
        if startedAt == nil { startedAt = now }
        let elapsed = now - (startedAt ?? now)
        timestamps.append(now)
        let reportedDuration = displayLink.targetTimestamp - displayLink.timestamp
        nominalDurations.append(reportedDuration > 0 ? reportedDuration : displayLink.duration)

        let clipView = scrollView.contentView
        let maximumY = max(0, documentView.bounds.height - clipView.bounds.height)
        let progress = min(1, elapsed / duration)
        let travel = 0.5 - 0.5 * cos(progress * .pi * 2)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: maximumY * travel))
        scrollView.reflectScrolledClipView(clipView)
        view.needsDisplay = true

        guard elapsed >= duration else { return }
        finish(PDFPreviewScrollMetrics.summarize(
            callbackTimestamps: timestamps,
            nominalFrameDurations: nominalDurations
        ))
    }

    private func finish(_ metrics: PDFPreviewScrollMetrics?) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        displayLink?.invalidate()
        displayLink = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: metrics)
    }
}

@MainActor
final class PDFPreviewBudgetRunner {
    static let receiptPrefix = "KAISOLA_NATIVE_PDF_PREVIEW_BUDGET_RECEIPT="
    static let workload = "bounded-pdf-preview-v2"

    private let configuration: PDFPreviewBudgetConfiguration
    private var window: NSWindow?
    private var view: PDFView?

    init(configuration: PDFPreviewBudgetConfiguration) {
        self.configuration = configuration
    }

    func start() {
        Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        switch configuration.phase {
        case .generate:
            await generate()
        case .render:
            await render()
        }
    }

    private func generate() async {
        do {
            let specification = configuration.fixture
            let root = configuration.root
            let generated = try await Task.detached(priority: .userInitiated) {
                try PDFPreviewBudgetFixtureWriter.write(specification, to: root)
            }.value
            let artifact = try await Task.detached(priority: .userInitiated) {
                try PDFPreviewBudgetFixtureArtifact.capture(generated)
            }.value
            emit(PDFPreviewBudgetGenerationReceipt(
                schemaVersion: 3,
                workload: Self.workload,
                phase: .generate,
                fixture: specification.id,
                appPid: ProcessInfo.processInfo.processIdentifier,
                build: buildReceipt(),
                specification: specification,
                artifact: artifact
            ))
        } catch {
            emitFailure("fixture-generation")
        }
        NSApp.terminate(nil)
    }

    private func render() async {
        let result: PDFPreviewBudgetFixtureResult
        do {
            let specification = configuration.fixture
            let root = configuration.root
            guard let expectedArtifact = configuration.expectedArtifact else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let generated = try await Task.detached(priority: .userInitiated) {
                try PDFPreviewBudgetFixtureLoader.load(
                    specification: specification,
                    root: root,
                    expectedArtifact: expectedArtifact
                )
            }.value
            result = try await measure(generated)
        } catch {
            result = .harnessFailure(
                specification: configuration.fixture,
                message: error.localizedDescription
            )
        }
        emit(PDFPreviewBudgetAppReceipt(
            schemaVersion: 3,
            workload: Self.workload,
            phase: .render,
            fixture: configuration.fixture.id,
            appPid: ProcessInfo.processInfo.processIdentifier,
            build: buildReceipt(),
            thresholds: .standard,
            specification: configuration.fixture,
            result: result
        ))
    }

    private func measure(
        _ generated: PDFPreviewBudgetGeneratedFixture
    ) async throws -> PDFPreviewBudgetFixtureResult {
        let specification = generated.specification
        if specification.expectedOutcome == "rejected" {
            let started = CACurrentMediaTime()
            let payload = await PDFPreviewBudgetDocumentWorker.shared.load(url: generated.url)
            let elapsed = milliseconds(since: started)
            return PDFPreviewBudgetFixtureResult.evaluate(
                specification: specification,
                byteCount: generated.byteCount,
                actualPageCount: payload?.value.pageCount ?? 0,
                outcome: payload == nil ? "rejected" : "rendered",
                measurements: PDFPreviewBudgetMeasurements(
                    firstVisiblePageLatencyMs: nil,
                    subsequentPagingLatenciesMs: [],
                    malformedRejectionLatencyMs: elapsed,
                    scroll: nil
                )
            )
        }

        let (window, view) = makeWindowIfNeeded()
        window.orderFrontRegardless()
        let firstStarted = CACurrentMediaTime()
        guard let payload = await PDFPreviewBudgetDocumentWorker.shared.load(url: generated.url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let document = payload.value
        guard let firstPage = document.page(at: 0) as? PDFPreviewBudgetPage else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let firstBaseline = firstPage.completedDrawCount
        PDFPreviewViewConfiguration.install(document: document, in: view)
        try await waitForVisiblePage(firstPage, view: view, afterDrawCount: firstBaseline)
        let firstVisible = milliseconds(since: firstStarted)

        var paging: [Double] = []
        for index in specification.pagingPageIndexes {
            guard let page = document.page(at: index) as? PDFPreviewBudgetPage else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let baseline = page.completedDrawCount
            let started = CACurrentMediaTime()
            view.go(to: page)
            view.needsDisplay = true
            try await waitForVisiblePage(page, view: view, afterDrawCount: baseline)
            paging.append(milliseconds(since: started))
        }

        let scroll: PDFPreviewScrollMetrics?
        if specification.measuresSustainedScroll {
            view.go(to: firstPage)
            try? await Task.sleep(for: .milliseconds(250))
            scroll = await PDFPreviewScrollProbe(
                view: view,
                duration: PDFPreviewBudgetThresholds.standard.scrollMeasurementDurationSeconds
            ).run()
        } else {
            scroll = nil
        }

        return PDFPreviewBudgetFixtureResult.evaluate(
            specification: specification,
            byteCount: generated.byteCount,
            actualPageCount: document.pageCount,
            outcome: "rendered",
            measurements: PDFPreviewBudgetMeasurements(
                firstVisiblePageLatencyMs: firstVisible,
                subsequentPagingLatenciesMs: paging,
                malformedRejectionLatencyMs: nil,
                scroll: scroll
            )
        )
    }

    private func makeWindowIfNeeded() -> (NSWindow, PDFView) {
        if let window, let view { return (window, view) }
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kaisola PDF Preview Budget"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        self.window = window
        self.view = view
        return (window, view)
    }

    private func waitForVisiblePage(
        _ page: PDFPreviewBudgetPage,
        view: PDFView,
        afterDrawCount: Int
    ) async throws {
        let deadline = CACurrentMediaTime() + 15
        while CACurrentMediaTime() < deadline {
            view.needsDisplay = true
            view.displayIfNeeded()
            if page.completedDrawCount > afterDrawCount, view.currentPage === page { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func milliseconds(since start: Double) -> Double {
        (CACurrentMediaTime() - start) * 1_000
    }

    private func buildReceipt() -> PDFPreviewBudgetBuildReceipt {
#if DEBUG
        let optimized = false
#else
        let optimized = true
#endif
        return PDFPreviewBudgetBuildReceipt(
            optimized: optimized,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        )
    }

    private func emit<Receipt: Encodable>(_ receipt: Receipt) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(receipt) else {
            print("\(Self.receiptPrefix)FAIL encoding")
            try? FileHandle.standardOutput.synchronize()
            return
        }
        FileHandle.standardOutput.write(Data(Self.receiptPrefix.utf8))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        try? FileHandle.standardOutput.synchronize()
    }

    private func emitFailure(_ reason: String) {
        print("\(Self.receiptPrefix)FAIL \(reason)")
        try? FileHandle.standardOutput.synchronize()
    }
}

/// The middle sample, averaging the two middle ones for an even count. Paging
/// fixtures produce 5 or 6 samples, too few for a percentile to mean anything,
/// and one of them is reliably an order of magnitude slower than the rest.
private func median(of values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func percentile(_ values: [Double], fraction: Double) -> Double {
    let sorted = values.sorted()
    let index = min(
        sorted.count - 1,
        max(0, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
    )
    return sorted[index]
}
