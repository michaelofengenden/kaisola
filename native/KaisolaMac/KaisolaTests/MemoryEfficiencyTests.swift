import AppKit
import KaisolaBrokerProtocol
import XCTest
@testable import Kaisola

/// R2-B memory caps and hooks (2026-08-06 spec §2).
final class MemoryEfficiencyTests: XCTestCase {
    @MainActor
    func testScrollbackDefaultIsTheWindowedFiveThousand() {
        XCTAssertEqual(NativePreviewSettings.terminalScrollbackDefault, 5_000)
    }

    @MainActor
    func testParkedSurfaceConstantsHoldTheTrade() {
        XCTAssertEqual(TerminalSurfaceCache.maximumRetainedSurfaces, 3)
        XCTAssertEqual(TerminalSurfaceCache.parkedScrollbackLines, 500)
    }

    func testImageWidthBucketsRoundUpAndCarryRetinaHeadroom() {
        // 300pt display width → 600px needed → 640 bucket.
        XCTAssertEqual(MarkdownLocalImageCache.widthBucket(300), 640)
        XCTAssertEqual(MarkdownLocalImageCache.widthBucket(150), 320)
        XCTAssertEqual(MarkdownLocalImageCache.widthBucket(320.5), 1024)
        // Beyond the largest bucket = full resolution.
        XCTAssertEqual(MarkdownLocalImageCache.widthBucket(2000), 0)
        XCTAssertEqual(MarkdownLocalImageCache.widthBucket(nil), 0)
    }

    func testDecodedCostChargesPixelsNotFileBytes() {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        image.addRepresentation(rep)
        XCTAssertEqual(MarkdownLocalImageCache.decodedCost(image), 100 * 50 * 4)
    }

    @MainActor
    func testMemoryPressurePurgesEveryRegisteredCache() {
        var purged: [String] = []
        MemoryPressureResponder.shared.register(name: "test-a") { purged.append("a") }
        MemoryPressureResponder.shared.register(name: "test-b") { purged.append("b") }
        MemoryPressureResponder.shared.purgeAll()
        XCTAssertTrue(purged.contains("a") && purged.contains("b"))
        XCTAssertNotNil(MemoryPressureResponder.shared.lastPurgeAt)
        // Re-registration replaces, never duplicates.
        purged.removeAll()
        MemoryPressureResponder.shared.register(name: "test-a") { purged.append("a2") }
        MemoryPressureResponder.shared.purgeAll()
        XCTAssertEqual(purged.filter { $0.hasPrefix("a") }, ["a2"])
    }

    func testFrameDecoderReleasesLargeHighWaterStorage() throws {
        var decoder = BrokerLineFrameDecoder(maximumFrameBytes: 8 * 1_024 * 1_024)
        var frames = 0
        // A 1 MiB frame split across chunks forces the buffer path.
        let big = Data(repeating: 0x61, count: 1_024 * 1_024)
        try decoder.consume(big, onFrame: { _ in frames += 1 })
        try decoder.consume(Data([0x0A]), onFrame: { _ in frames += 1 })
        XCTAssertEqual(frames, 1)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        // Still functional after the storage release.
        try decoder.consume(Data("ok\n".utf8), onFrame: { _ in frames += 1 })
        XCTAssertEqual(frames, 2)
    }
}
