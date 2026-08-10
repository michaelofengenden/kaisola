import AppKit
import PDFKit
import XCTest
@testable import Kaisola

final class PDFPreviewBudgetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-pdf-budget-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testFixtureCatalogIsExactDocumentedAndBelowTheProductCap() {
        let specifications = PDFPreviewBudgetFixtureCatalog.specifications

        XCTAssertEqual(specifications.map(\.id), [
            "many-page", "image-heavy", "malformed", "large-page",
        ])
        XCTAssertEqual(specifications.map(\.fileName), [
            "many-page.pdf", "image-heavy.pdf", "malformed.pdf", "large-page.pdf",
        ])
        XCTAssertEqual(specifications.map(\.expectedOutcome), [
            "rendered", "rendered", "rejected", "rendered",
        ])
        XCTAssertEqual(specifications.map(\.expectedPageCount), [96, 6, 0, 1])
        XCTAssertEqual(specifications[0].pagingPageIndexes, [1, 12, 24, 48, 72, 95])
        XCTAssertEqual(specifications[1].pagingPageIndexes, [1, 2, 3, 4, 5])
        XCTAssertEqual(specifications.map(\.measuresSustainedScroll), [true, true, false, false])
        XCTAssertEqual(specifications[1].rasterWidthPixels, 896)
        XCTAssertEqual(specifications[1].rasterHeightPixels, 896)
        XCTAssertEqual(specifications[3].pageWidthPoints, 14_400)
        XCTAssertEqual(specifications[3].pageHeightPoints, 14_400)
        XCTAssertTrue(specifications.allSatisfy { $0.maximumBytes <= FilePreviewContent.maxDocumentBytes })
    }

    func testGeneratedFixturesMatchTheirExactShapeAndBounds() throws {
        for specification in PDFPreviewBudgetFixtureCatalog.specifications {
            let generated = try PDFPreviewBudgetFixtureWriter.write(specification, to: root)
            let generatedData = try Data(contentsOf: generated.url)
            XCTAssertEqual(generated.specification, specification)
            XCTAssertEqual(generated.url.lastPathComponent, specification.fileName)
            XCTAssertGreaterThanOrEqual(generated.byteCount, specification.minimumBytes)
            XCTAssertLessThanOrEqual(generated.byteCount, specification.maximumBytes)
            XCTAssertLessThanOrEqual(generated.byteCount, FilePreviewContent.maxDocumentBytes)

            let repeated = try PDFPreviewBudgetFixtureWriter.write(
                specification,
                to: root.appendingPathComponent("repeat-\(specification.id)", isDirectory: true)
            )
            XCTAssertEqual(try Data(contentsOf: repeated.url), generatedData)

            if specification.expectedOutcome == "rejected" {
                XCTAssertEqual(generatedData, PDFPreviewBudgetFixtureWriter.malformedBytes)
                XCTAssertNil(PDFDocumentIO.load(url: generated.url))
                continue
            }

            let document = try XCTUnwrap(PDFDocumentIO.load(url: generated.url)?.value)
            XCTAssertEqual(document.pageCount, specification.expectedPageCount)
            let firstPage = try XCTUnwrap(document.page(at: 0))
            let mediaBox = firstPage.bounds(for: .mediaBox)
            XCTAssertEqual(mediaBox.width, specification.pageWidthPoints, accuracy: 0.01)
            XCTAssertEqual(mediaBox.height, specification.pageHeightPoints, accuracy: 0.01)
        }
    }

    func testLaunchConfigurationRequiresAnExplicitFixtureAndPrivateTemporaryRoot() throws {
        let privateRoot = root.appendingPathComponent("run", isDirectory: true)
        let valid = PDFPreviewBudgetConfiguration.resolve(
            environment: [
                "KAISOLA_NATIVE_PDF_PREVIEW_BUDGET": "1",
                "KAISOLA_NATIVE_PDF_PREVIEW_FIXTURE": "image-heavy",
                "KAISOLA_NATIVE_PDF_PREVIEW_ROOT": privateRoot.path,
            ],
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(valid?.fixture.id, "image-heavy")
        XCTAssertEqual(
            valid?.root.standardizedFileURL.resolvingSymlinksInPath().path,
            privateRoot.standardizedFileURL.resolvingSymlinksInPath().path
        )

        XCTAssertNil(PDFPreviewBudgetConfiguration.resolve(
            environment: [
                "KAISOLA_NATIVE_PDF_PREVIEW_BUDGET": "1",
                "KAISOLA_NATIVE_PDF_PREVIEW_FIXTURE": "not-a-fixture",
                "KAISOLA_NATIVE_PDF_PREVIEW_ROOT": privateRoot.path,
            ],
            temporaryDirectory: FileManager.default.temporaryDirectory
        ))
        XCTAssertNil(PDFPreviewBudgetConfiguration.resolve(
            environment: [
                "KAISOLA_NATIVE_PDF_PREVIEW_BUDGET": "1",
                "KAISOLA_NATIVE_PDF_PREVIEW_FIXTURE": "many-page",
                "KAISOLA_NATIVE_PDF_PREVIEW_ROOT": "/Applications/not-private",
            ],
            temporaryDirectory: FileManager.default.temporaryDirectory
        ))
        XCTAssertNil(PDFPreviewBudgetConfiguration.resolve(
            environment: [
                "KAISOLA_NATIVE_PDF_PREVIEW_FIXTURE": "many-page",
                "KAISOLA_NATIVE_PDF_PREVIEW_ROOT": privateRoot.path,
            ],
            temporaryDirectory: FileManager.default.temporaryDirectory
        ))
    }

    func testPassingMeasurementsProduceNoDiagnostics() throws {
        let specification = try XCTUnwrap(PDFPreviewBudgetFixtureCatalog.specification(id: "many-page"))
        let result = PDFPreviewBudgetFixtureResult.evaluate(
            specification: specification,
            byteCount: 64_000,
            actualPageCount: 96,
            outcome: "rendered",
            measurements: PDFPreviewBudgetMeasurements(
                firstVisiblePageLatencyMs: 250,
                subsequentPagingLatenciesMs: [80, 100, 120, 140, 160, 180],
                malformedRejectionLatencyMs: nil,
                scroll: PDFPreviewScrollMetrics(
                    callbackCount: 175,
                    measurementDurationSeconds: 3,
                    nominalFrameDurationMs: 16.67,
                    p95IntervalMs: 22,
                    maximumIntervalMs: 55,
                    callbackCoverage: 0.97
                )
            )
        )

        XCTAssertTrue(result.pass)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.subsequentPagingP95LatencyMs, 180)
    }

    func testEveryViolatedThresholdNamesTheFixtureAndExactLimit() throws {
        let specification = try XCTUnwrap(PDFPreviewBudgetFixtureCatalog.specification(id: "many-page"))
        let thresholds = PDFPreviewBudgetThresholds.standard
        let result = PDFPreviewBudgetFixtureResult.evaluate(
            specification: specification,
            byteCount: specification.maximumBytes + 1,
            actualPageCount: 95,
            outcome: "rendered",
            measurements: PDFPreviewBudgetMeasurements(
                firstVisiblePageLatencyMs: thresholds.maximumFirstVisiblePageLatencyMs + 1,
                subsequentPagingLatenciesMs: Array(
                    repeating: thresholds.maximumSubsequentPagingP95LatencyMs + 1,
                    count: specification.pagingPageIndexes.count
                ),
                malformedRejectionLatencyMs: nil,
                scroll: PDFPreviewScrollMetrics(
                    callbackCount: 2,
                    measurementDurationSeconds: thresholds.scrollMeasurementDurationSeconds,
                    nominalFrameDurationMs: 16.67,
                    p95IntervalMs: thresholds.maximumScrollP95IntervalMs + 1,
                    maximumIntervalMs: thresholds.maximumScrollIntervalMs + 1,
                    callbackCoverage: thresholds.minimumScrollCallbackCoverage - 0.01
                )
            )
        )

        XCTAssertFalse(result.pass)
        XCTAssertEqual(Set(result.diagnostics.map(\.fixture)), ["many-page"])
        XCTAssertEqual(Set(result.diagnostics.map(\.threshold)), [
            "generatedBytes.maximum",
            "pageCount.exact",
            "firstVisiblePageLatencyMs.maximum",
            "subsequentPagingP95LatencyMs.maximum",
            "scroll.p95IntervalMs.maximum",
            "scroll.maximumIntervalMs.maximum",
            "scroll.callbackCoverage.minimum",
        ])
        XCTAssertEqual(
            result.diagnostics.first { $0.threshold == "firstVisiblePageLatencyMs.maximum" }?.limit,
            thresholds.maximumFirstVisiblePageLatencyMs
        )
    }

    func testMalformedFixtureHasARejectionBudgetAndNeverRequiresRenderMetrics() throws {
        let specification = try XCTUnwrap(PDFPreviewBudgetFixtureCatalog.specification(id: "malformed"))
        let thresholds = PDFPreviewBudgetThresholds.standard
        let passing = PDFPreviewBudgetFixtureResult.evaluate(
            specification: specification,
            byteCount: PDFPreviewBudgetFixtureWriter.malformedBytes.count,
            actualPageCount: 0,
            outcome: "rejected",
            measurements: PDFPreviewBudgetMeasurements(
                firstVisiblePageLatencyMs: nil,
                subsequentPagingLatenciesMs: [],
                malformedRejectionLatencyMs: thresholds.maximumMalformedRejectionLatencyMs,
                scroll: nil
            )
        )
        XCTAssertTrue(passing.pass)

        let failing = PDFPreviewBudgetFixtureResult.evaluate(
            specification: specification,
            byteCount: PDFPreviewBudgetFixtureWriter.malformedBytes.count,
            actualPageCount: 0,
            outcome: "rejected",
            measurements: PDFPreviewBudgetMeasurements(
                firstVisiblePageLatencyMs: nil,
                subsequentPagingLatenciesMs: [],
                malformedRejectionLatencyMs: thresholds.maximumMalformedRejectionLatencyMs + 1,
                scroll: nil
            )
        )
        XCTAssertEqual(failing.diagnostics.map(\.threshold), ["malformedRejectionLatencyMs.maximum"])
    }

    func testCadenceSummaryUsesDeterministicP95AndCoverage() throws {
        let nominal = 1.0 / 60.0
        let timestamps = (0...180).map { Double($0) * nominal }
        let summary = try XCTUnwrap(PDFPreviewScrollMetrics.summarize(
            callbackTimestamps: timestamps,
            nominalFrameDurations: Array(repeating: nominal, count: timestamps.count)
        ))

        XCTAssertEqual(summary.callbackCount, 181)
        XCTAssertEqual(summary.measurementDurationSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(summary.p95IntervalMs, nominal * 1_000, accuracy: 0.001)
        XCTAssertEqual(summary.maximumIntervalMs, nominal * 1_000, accuracy: 0.001)
        XCTAssertEqual(summary.callbackCoverage, 1, accuracy: 0.001)
        XCTAssertNil(PDFPreviewScrollMetrics.summarize(
            callbackTimestamps: [1, 1],
            nominalFrameDurations: [nominal, nominal]
        ))
    }

    @MainActor
    func testInstalledProbeUsesTheProductPDFViewConfigurationAndDismantlePath() throws {
        let specification = try XCTUnwrap(
            PDFPreviewBudgetFixtureCatalog.specification(id: "large-page")
        )
        let generated = try PDFPreviewBudgetFixtureWriter.write(specification, to: root)
        let document = try XCTUnwrap(PDFDocumentIO.load(url: generated.url)?.value)
        let replacement = try XCTUnwrap(PDFDocumentIO.load(url: generated.url)?.value)
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))

        PDFPreviewViewConfiguration.install(document: document, in: view)

        XCTAssertTrue(view.document === document)
        XCTAssertNotNil(view.documentView)
        XCTAssertTrue(view.autoScales)
        XCTAssertEqual(view.displayMode, .singlePageContinuous)
        XCTAssertEqual(view.displayDirection, .vertical)
        XCTAssertTrue(view.displaysPageBreaks)
        XCTAssertTrue(view.pageShadowsEnabled)
        XCTAssertGreaterThan(view.maxScaleFactor, view.minScaleFactor)

        PDFPreviewViewConfiguration.install(document: replacement, in: view)

        XCTAssertFalse(replacement === document)
        XCTAssertTrue(view.document === replacement)
        XCTAssertNotNil(view.documentView)
        XCTAssertTrue(view.autoScales)
        XCTAssertEqual(view.displayMode, .singlePageContinuous)
        XCTAssertEqual(view.displayDirection, .vertical)

        PDFFilePreview.dismantleNSView(view, coordinator: ())
        XCTAssertNil(view.document)
    }

    func testInstalledProbeWaitsForTheInstrumentedPDFPageDrawCompletion() throws {
        let specification = try XCTUnwrap(
            PDFPreviewBudgetFixtureCatalog.specification(id: "large-page")
        )
        let generated = try PDFPreviewBudgetFixtureWriter.write(specification, to: root)
        let document = try XCTUnwrap(PDFPreviewBudgetDocumentIO.load(url: generated.url)?.value)
        let page = try XCTUnwrap(document.page(at: 0) as? PDFPreviewBudgetPage)
        XCTAssertTrue(page.document === document)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let baseline = page.completedDrawCount

        page.draw(with: .mediaBox, to: context)

        XCTAssertEqual(page.completedDrawCount, baseline + 1)
    }
}
