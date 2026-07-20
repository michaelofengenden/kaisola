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

    @MainActor
    func testPairedDesktopSelectsItsExactBonjourService() {
        let desktopId = "desktop-12345678-90ab-cdef"
        let other = CompanionDiscoveredDesktop(
            endpoint: .service(name: "Kaisola-someone-else", type: "_kaisola._tcp", domain: "local", interface: nil),
            name: "Kaisola-someone-else"
        )
        let wantedName = CompanionTransport.serviceInstanceName(for: desktopId)
        let wanted = CompanionDiscoveredDesktop(
            endpoint: .service(name: wantedName, type: "_kaisola._tcp", domain: "local", interface: nil),
            name: wantedName
        )

        XCTAssertEqual(wantedName, "Kaisola-345678-90ab-cdef")
        XCTAssertEqual(
            CompanionTransport.preferredDesktop(in: [other, wanted], desktopId: desktopId)?.name,
            wantedName
        )
        XCTAssertNil(CompanionTransport.preferredDesktop(in: [other], desktopId: desktopId))
    }
}
