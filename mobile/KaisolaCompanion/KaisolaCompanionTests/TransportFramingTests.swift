import XCTest
import Network
@testable import KaisolaCompanion

final class TransportFramingTests: XCTestCase {
    func testLengthFramingMatchesNodeBigEndianWireFormatAcrossChunks() throws {
        let first = Data(#"{"v":1}"#.utf8)
        let second = Data(#"{"type":"hello"}"#.utf8)
        let wire = try CompanionLengthFrameDecoder.encode(first) + CompanionLengthFrameDecoder.encode(second)
        XCTAssertEqual(Array(wire.prefix(4)), [0, 0, 0, UInt8(first.count)])

        var decoder = CompanionLengthFrameDecoder()
        XCTAssertTrue(try decoder.push(Data(wire.prefix(5))).isEmpty)
        XCTAssertEqual(try decoder.push(Data(wire.dropFirst(5))), [first, second])
    }

    func testLengthFramingRejectsZeroAndOversizedFrames() throws {
        var decoder = CompanionLengthFrameDecoder(maximumFrameBytes: 8)
        XCTAssertThrowsError(try decoder.push(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try CompanionLengthFrameDecoder.encode(Data(repeating: 1, count: 9), maximumFrameBytes: 8))
    }

    @MainActor
    func testSignedTransportHintCreatesDirectEndpointAndRejectsInvalidPorts() {
        let hint = CompanionPairingTransportHint(
            service: "_kaisola._tcp",
            protocol: "tcp",
            host: "192.168.1.23",
            port: 49_321
        )
        guard case let .hostPort(host, port)? = CompanionTransport.directEndpoint(from: hint) else {
            return XCTFail("Expected a direct host and port endpoint")
        }
        XCTAssertEqual(String(describing: host), "192.168.1.23")
        XCTAssertEqual(port.rawValue, 49_321)
        XCTAssertNil(CompanionTransport.directEndpoint(from: CompanionPairingTransportHint(
            service: "_kaisola._tcp", protocol: "tcp", host: "192.168.1.23", port: 0
        )))
    }
}
