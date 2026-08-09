import AppKit
import KaisolaBrokerProtocol
import KaisolaCore
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

    func testOutboundFramePreflightEnforcesExactMethodAndGlobalLimits() throws {
        let limits = AcpOutboundFrameLimits(
            globalMaximumBytes: 512,
            promptMaximumBytes: 192,
            toolResponseMaximumBytes: 224
        )
        let encoder = AcpOutboundFrameEncoder(limits: limits)

        let emptyPrompt = requestEnvelope(method: "session/prompt", payload: "")
        let promptOverhead = try encoder.measure(
            emptyPrompt,
            purpose: .request(method: "session/prompt")
        ).encodedBytes
        let exactPrompt = requestEnvelope(
            method: "session/prompt",
            payload: String(repeating: "p", count: limits.promptMaximumBytes - promptOverhead)
        )
        let encodedPrompt = try encoder.encode(
            exactPrompt,
            purpose: .request(method: "session/prompt")
        )
        XCTAssertEqual(encodedPrompt.data.count, limits.promptMaximumBytes)
        XCTAssertEqual(encodedPrompt.measurement.encodedBytes, encodedPrompt.data.count)

        let overPrompt = requestEnvelope(
            method: "session/prompt",
            payload: String(
                repeating: "p",
                count: limits.promptMaximumBytes - promptOverhead + 1
            )
        )
        XCTAssertThrowsError(try encoder.encode(
            overPrompt,
            purpose: .request(method: "session/prompt")
        )) { error in
            XCTAssertEqual(
                error as? AcpOutboundFrameError,
                .tooLarge(maximumBytes: limits.promptMaximumBytes)
            )
        }

        let emptyToolResponse = responseEnvelope(payload: "")
        let toolOverhead = try encoder.measure(
            emptyToolResponse,
            purpose: .response(method: "terminal/output")
        ).encodedBytes
        let exactToolResponse = responseEnvelope(
            payload: String(
                repeating: "t",
                count: limits.toolResponseMaximumBytes - toolOverhead
            )
        )
        XCTAssertEqual(
            try encoder.encode(
                exactToolResponse,
                purpose: .response(method: "terminal/output")
            ).data.count,
            limits.toolResponseMaximumBytes
        )
        XCTAssertThrowsError(try encoder.encode(
            responseEnvelope(payload: String(
                repeating: "t",
                count: limits.toolResponseMaximumBytes - toolOverhead + 1
            )),
            purpose: .response(method: "terminal/output")
        ))

        let emptyGlobal = requestEnvelope(method: "initialize", payload: "")
        let globalOverhead = try encoder.measure(
            emptyGlobal,
            purpose: .request(method: "initialize")
        ).encodedBytes
        XCTAssertEqual(
            try encoder.encode(
                requestEnvelope(
                    method: "initialize",
                    payload: String(
                        repeating: "g",
                        count: limits.globalMaximumBytes - globalOverhead
                    )
                ),
                purpose: .request(method: "initialize")
            ).data.count,
            limits.globalMaximumBytes
        )
        XCTAssertThrowsError(try encoder.encode(
            requestEnvelope(
                method: "initialize",
                payload: String(
                    repeating: "g",
                    count: limits.globalMaximumBytes - globalOverhead + 1
                )
            ),
            purpose: .request(method: "initialize")
        ))
    }

    func testOutboundFrameMeasurementMatchesFoundationEscapesAndNumbers() throws {
        let value = JSONValue.object([
            "slashes/and\\quotes\"": .string("\u{0000}\n/é😀\\\""),
            "numbers": .array([
                .integer(Int64.min),
                .number(-0.0),
                .number(Double.greatestFiniteMagnitude),
            ]),
        ])
        let encoder = AcpOutboundFrameEncoder()
        let encoded = try encoder.encode(value, purpose: .request(method: "initialize"))
        XCTAssertEqual(encoded.measurement.encodedBytes, encoded.data.count)
        XCTAssertEqual(encoded.data.last, 0x0A)

        XCTAssertThrowsError(try encoder.encode(
            .number(.infinity),
            purpose: .request(method: "initialize")
        )) { error in
            XCTAssertEqual(error as? AcpOutboundFrameError, .invalidNumber)
        }
    }

    func testBoundaryAttachmentFrameRecordsPeakMemory() throws {
        let attachment = AcpAttachment.image(
            data: Data(repeating: 0xA5, count: AcpAttachmentClassifier.maxImageBytes),
            mimeType: "image/png",
            name: "maximum.png"
        )
        let encoder = AcpOutboundFrameEncoder()
        var receipt: AcpOutboundEncodedFrame?
        let options = XCTMeasureOptions()
        options.iterationCount = 1

        measure(metrics: [XCTMemoryMetric()], options: options) {
            do {
                let blocks = AcpClient.promptBlocks(
                    text: "boundary attachment",
                    attachments: [attachment],
                    promptImageOk: true,
                    promptEmbeddedContextOk: false
                )
                receipt = try encoder.encode(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(1),
                    "method": .string("session/prompt"),
                    "params": .object([
                        "sessionId": .string("session"),
                        "prompt": .array(blocks),
                    ]),
                ]), purpose: .request(method: "session/prompt"))
            } catch {
                XCTFail("boundary attachment encoding failed: \(error)")
            }
        }

        let measured = try XCTUnwrap(receipt)
        XCTAssertGreaterThan(measured.data.count, AcpAttachmentClassifier.maxImageBytes)
        XCTAssertLessThanOrEqual(
            measured.data.count,
            AcpOutboundFrameLimits.production.promptMaximumBytes
        )
    }

    func testBoundaryToolResponseRecordsPeakMemory() throws {
        let output = String(
            repeating: "x",
            count: AcpTerminalHost.maxOutputByteLimit
        )
        let encoder = AcpOutboundFrameEncoder()
        var receipt: AcpOutboundEncodedFrame?
        let options = XCTMeasureOptions()
        options.iterationCount = 1

        measure(metrics: [XCTMemoryMetric()], options: options) {
            do {
                receipt = try encoder.encode(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(2),
                    "result": .object([
                        "output": .string(output),
                        "truncated": .bool(false),
                    ]),
                ]), purpose: .response(method: "terminal/output"))
            } catch {
                XCTFail("boundary tool response encoding failed: \(error)")
            }
        }

        let measured = try XCTUnwrap(receipt)
        XCTAssertGreaterThan(measured.data.count, AcpTerminalHost.maxOutputByteLimit)
        XCTAssertLessThanOrEqual(
            measured.data.count,
            AcpOutboundFrameLimits.production.toolResponseMaximumBytes
        )
    }

    func testOversizedPromptIsRejectedBeforeTransportSend() async throws {
        let transport = OutboundFrameTestTransport()
        let limits = AcpOutboundFrameLimits(
            globalMaximumBytes: 4_096,
            promptMaximumBytes: 256,
            toolResponseMaximumBytes: 512
        )
        let client = AcpClient(transport: transport, outboundFrameLimits: limits)
        _ = try await client.start(
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: "/tmp",
            mcpServers: []
        )

        do {
            try await client.prompt(String(repeating: "sensitive-prompt-", count: 32))
            XCTFail("oversized prompt unexpectedly reached the transport")
        } catch {
            XCTAssertEqual(
                error as? AcpOutboundFrameError,
                .tooLarge(maximumBytes: limits.promptMaximumBytes)
            )
        }
        let sentPromptCount = await transport.sentCount(method: "session/prompt")
        XCTAssertEqual(sentPromptCount, 0)
        await client.stop()
    }

    func testOversizedToolResponseBecomesBoundedSafeError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-outbound-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "PRIVATE-TOOL-OUTPUT-"
        let fileURL = directory.appendingPathComponent("large.txt")
        try (marker + String(repeating: "x", count: 2_048))
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let transport = OutboundFrameTestTransport()
        let limits = AcpOutboundFrameLimits(
            globalMaximumBytes: 4_096,
            promptMaximumBytes: 2_048,
            toolResponseMaximumBytes: 384
        )
        let client = AcpClient(transport: transport, outboundFrameLimits: limits)
        _ = try await client.start(
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: directory.path,
            mcpServers: []
        )

        await transport.emitRequest(
            method: "fs/read_text_file",
            id: 77,
            params: .object(["path": .string(fileURL.path)])
        )
        try await Self.until("bounded tool response") {
            await transport.response(id: 77) != nil
        }
        let responseValue = await transport.response(id: 77)
        let responseData = await transport.responseData(id: 77)
        await client.stop()
        let response = try XCTUnwrap(responseValue)
        XCTAssertNil(response.objectValue?["result"])
        let error = try XCTUnwrap(response.objectValue?["error"]?.objectValue)
        XCTAssertEqual(error["code"]?.intValue, -32001)
        XCTAssertEqual(
            error["data"]?.objectValue?["reason"]?.stringValue,
            AcpOutboundFrameError.tooLarge(maximumBytes: 0).reason
        )
        XCTAssertEqual(
            error["data"]?.objectValue?["maximumBytes"]?.intValue,
            Int64(limits.toolResponseMaximumBytes)
        )
        let encoded = try XCTUnwrap(responseData)
        XCTAssertLessThanOrEqual(encoded.count, limits.toolResponseMaximumBytes)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(marker))
    }

    private func requestEnvelope(method: String, payload: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "method": .string(method),
            "params": .object(["payload": .string(payload)]),
        ])
    }

    private func responseEnvelope(payload: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(1),
            "result": .object(["output": .string(payload)]),
        ])
    }

    private static func until(
        _ description: String,
        timeout: TimeInterval = 3,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor OutboundFrameTestTransport: AcpByteTransport {
    private var inbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var sentMethods: [String: Int] = [:]
    private var responses: [Int64: (value: JSONValue, data: Data)] = [:]

    func start(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) async throws {}

    func send(_ data: Data) async throws {
        let trimmed = data.last == 0x0A ? Data(data.dropLast()) : data
        let value = try JSONDecoder().decode(JSONValue.self, from: trimmed)
        guard let object = value.objectValue else { return }
        if let method = object["method"]?.stringValue {
            sentMethods[method, default: 0] += 1
            switch method {
            case "initialize":
                enqueue(.object([
                    "jsonrpc": .string("2.0"),
                    "id": object["id"] ?? .null,
                    "result": .object([
                        "protocolVersion": .integer(Int64(AcpWire.protocolVersion)),
                        "agentCapabilities": .object([:]),
                    ]),
                ]))
            case "session/new":
                enqueue(.object([
                    "jsonrpc": .string("2.0"),
                    "id": object["id"] ?? .null,
                    "result": .object(["sessionId": .string("session")]),
                ]))
            case "session/prompt":
                enqueue(.object([
                    "jsonrpc": .string("2.0"),
                    "id": object["id"] ?? .null,
                    "result": .object(["stopReason": .string("end_turn")]),
                ]))
            default:
                break
            }
            return
        }
        if let id = object["id"]?.intValue {
            responses[id] = (value, data)
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !inbound.isEmpty { return inbound.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func terminate() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { 0 }

    func sentCount(method: String) -> Int { sentMethods[method] ?? 0 }
    func response(id: Int64) -> JSONValue? { responses[id]?.value }
    func responseData(id: Int64) -> Data? { responses[id]?.data }

    func emitRequest(method: String, id: Int64, params: JSONValue) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
            "params": params,
        ]))
    }

    private func enqueue(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            inbound.append(data)
        }
    }
}
