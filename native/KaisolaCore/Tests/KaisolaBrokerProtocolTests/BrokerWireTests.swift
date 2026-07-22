import Foundation
import XCTest
@testable import KaisolaBrokerProtocol
import KaisolaTestSupport

final class BrokerWireTests: XCTestCase {
    func testConstantsMatchTheShippingNodeBroker() {
        XCTAssertEqual(BrokerWire.protocolVersion, 2)
        XCTAssertEqual(BrokerWire.securityEpoch, 1)
        XCTAssertEqual(BrokerWire.implementationVersion, 1)
        XCTAssertEqual(BrokerWire.helperPackageSchema, 1)
        XCTAssertEqual(BrokerWire.compatibleImplementationVersions, 1...2)
        XCTAssertEqual(BrokerWire.terminalObserveFeature, "terminal-observe-v1")
        XCTAssertEqual(BrokerWire.observerRoleFeature, "observer-role-v1")
        XCTAssertEqual(BrokerWire.observerMethods, [
            "broker.status",
            "terminal.list",
            "terminal.diagnostics",
            "terminal.subscribe",
            "terminal.unsubscribe",
        ])
        XCTAssertEqual(BrokerWire.maximumFrameBytes, 56 * 1_024 * 1_024)
    }

    func testCrossLanguageCompatibilityMatrix() throws {
        struct Fixture: Decodable {
            struct Combination: Decodable {
                let name: String
                let protocolVersion: Int
                let securityEpoch: Int
                let implementationVersion: Int?
                let supported: Bool

                enum CodingKeys: String, CodingKey {
                    case name
                    case protocolVersion = "protocol"
                    case securityEpoch, implementationVersion, supported
                }
            }

            let schemaVersion: Int
            let combinations: [Combination]
        }

        let url = try RepositoryFixtures.brokerFixture(named: "compatibility-v1")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertFalse(fixture.combinations.isEmpty)
        for row in fixture.combinations {
            XCTAssertEqual(
                BrokerWire.accepts(
                    protocolVersion: row.protocolVersion,
                    securityEpoch: row.securityEpoch,
                    implementationVersion: row.implementationVersion
                ),
                row.supported,
                row.name
            )
        }
    }

    func testDecoderHandlesSplitAndCoalescedFrames() throws {
        var decoder = BrokerLineFrameDecoder(maximumFrameBytes: 64)
        XCTAssertEqual(try decoder.push(Data("{\"type\":\"hel".utf8)), [])
        let frames = try decoder.push(Data("lo\"}\n{\"type\":\"event\"}\n".utf8))

        XCTAssertEqual(frames.map { String(decoding: $0, as: UTF8.self) }, [
            #"{"type":"hello"}"#,
            #"{"type":"event"}"#,
        ])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        XCTAssertNoThrow(try decoder.finish())
    }

    func testDecoderRejectsOversizeBeforeAnUnboundedBufferForms() throws {
        var decoder = BrokerLineFrameDecoder(maximumFrameBytes: 8)
        XCTAssertThrowsError(try decoder.push(Data(repeating: 0x61, count: 9))) { error in
            XCTAssertEqual(error as? BrokerWireError, .frameTooLarge(maximum: 8))
        }
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testStreamingDecoderDoesNotRetainLargeBatchesOfSmallFrames() throws {
        let frame = Data(repeating: 0x61, count: 1_023)
        let frameCount = 60_000 // 58.6 MiB including newline delimiters.
        var payload = Data()
        payload.reserveCapacity(1_024 * frameCount)
        for _ in 0..<frameCount {
            payload.append(frame)
            payload.append(0x0A)
        }
        XCTAssertGreaterThan(payload.count, BrokerWire.maximumFrameBytes)

        var decoder = BrokerLineFrameDecoder(maximumFrameBytes: 2_048)
        var delivered = 0

        try decoder.consume(payload) { value in
            XCTAssertEqual(value.count, frame.count)
            delivered += 1
        }

        XCTAssertEqual(delivered, frameCount)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        XCTAssertNoThrow(try decoder.finish())
    }

    func testStreamingDecoderAppliesSynchronousBackpressure() throws {
        enum Stop: Error { case requested }
        var decoder = BrokerLineFrameDecoder(maximumFrameBytes: 64)
        var delivered = 0

        XCTAssertThrowsError(try decoder.consume(Data("{}\n{}\n".utf8)) { _ in
            delivered += 1
            throw Stop.requested
        }) { error in
            XCTAssertTrue(error is Stop)
        }
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testDecoderRejectsInvalidUTF8AndIncompleteFinalFrame() throws {
        var invalid = BrokerLineFrameDecoder(maximumFrameBytes: 8)
        XCTAssertThrowsError(try invalid.push(Data([0xFF, 0x0A]))) { error in
            XCTAssertEqual(error as? BrokerWireError, .invalidUTF8)
        }

        var partial = BrokerLineFrameDecoder(maximumFrameBytes: 8)
        _ = try partial.push(Data("{}".utf8))
        XCTAssertThrowsError(try partial.finish()) { error in
            XCTAssertEqual(error as? BrokerWireError, .incompleteFrame)
        }
    }
}
