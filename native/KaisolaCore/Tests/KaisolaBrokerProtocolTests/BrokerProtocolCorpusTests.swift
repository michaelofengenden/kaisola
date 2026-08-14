import Foundation
import XCTest
@testable import KaisolaBrokerProtocol
import KaisolaTestSupport

final class BrokerProtocolCorpusTests: XCTestCase {
    private struct Corpus: Decodable {
        struct IdentifierConstraints: Decodable, Equatable {
            let pattern: String
            let maximumUtf8Bytes: Int
        }

        struct Method: Decodable {
            let method: String
            let requiredAccess: String
            let requestScenario: String
            let responseScenario: String
        }

        struct Scenario: Decodable {
            struct Input: Decodable {
                let exitCode: Int?
                let signal: Int?
                let method: String?
                let chunksHex: [String]?
                let snapshotEndOffset: Int?
                let liveStartOffset: Int?
            }

            struct Expected: Decodable, Equatable {
                let exitCode: Int?
                var signal: Int?
                let writeHex: String?
                let text: String?
                let replacementCount: Int?
                let order: [String]?
                let duplicateBytes: Int?
            }

            let id: String
            let kind: String
            let negotiatedFeatures: [String]?
            let input: Input
            var expected: Expected
        }

        struct FrameCase: Decodable {
            struct Purpose: Decodable {
                let type: String
                let method: String?
                let channel: String?
            }

            let id: String
            let purpose: Purpose
            let encodedBytes: Int
            let expected: String
        }

        let schemaVersion: Int
        let protocolVersion: Int
        let identifierConstraints: IdentifierConstraints
        let methods: [Method]
        var semanticScenarios: [Scenario]
        let frameCases: [FrameCase]
    }

    private enum ValidationError: Error, Equatable {
        case mismatch(String)
    }

    private let administratorMethods: Set<String> = [
        "broker.cancelRollingUpdate",
        "broker.prepareRollingUpdate",
        "broker.retireDraining",
        "broker.shutdown",
        "broker.shutdownForUpdate",
    ]

    private let controllerMethods: Set<String> = [
        "terminal.agentTurn",
        "terminal.attach",
        "terminal.available",
        "terminal.cancelRelease",
        "terminal.controlLease",
        "terminal.create",
        "terminal.detachOwner",
        "terminal.detachRenderer",
        "terminal.kill",
        "terminal.output",
        "terminal.release",
        "terminal.resize",
        "terminal.scheduleRelease",
        "terminal.setFocused",
        "terminal.signal",
        "terminal.snapshot",
        "terminal.waitForExit",
        "terminal.write",
    ]

    private func loadCorpus() throws -> Corpus {
        let url = try RepositoryFixtures.brokerFixture(named: "protocol-2-golden-v1")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func require(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw ValidationError.mismatch(label) }
    }

    private func bytes(hex: String) throws -> Data {
        let encoded = Array(hex.utf8)
        try require(encoded.count.isMultiple(of: 2), "hex.length")

        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 97...102: byte - 87
            default: nil
            }
        }

        var decoded: [UInt8] = []
        decoded.reserveCapacity(encoded.count / 2)
        for index in stride(from: 0, to: encoded.count, by: 2) {
            guard let high = nibble(encoded[index]), let low = nibble(encoded[index + 1]) else {
                throw ValidationError.mismatch("hex.character")
            }
            decoded.append(high << 4 | low)
        }
        return Data(decoded)
    }

    private func maximumBytes(for purpose: Corpus.FrameCase.Purpose) throws -> Int {
        switch purpose.type {
        case "transport":
            return BrokerWire.maximumFrameBytes
        case "request":
            return BrokerWire.maximumEncodedBytes(for: .request(try XCTUnwrap(purpose.method)))
        case "response":
            return BrokerWire.maximumEncodedBytes(for: .response(try XCTUnwrap(purpose.method)))
        case "event":
            return BrokerWire.maximumEncodedBytes(for: .event(try XCTUnwrap(purpose.channel)))
        default:
            throw ValidationError.mismatch("frame.purpose")
        }
    }

    // These entries freeze initial normalization examples; they are not a
    // complete black-box protocol suite.
    private func validateScenario(_ scenario: Corpus.Scenario) throws {
        switch scenario.id {
        case "exit.legacy":
            try require(scenario.kind == "exit-payload", scenario.id)
            try require(scenario.negotiatedFeatures == [], scenario.id)
            try require(scenario.input.exitCode == scenario.expected.exitCode, scenario.id)
            try require(scenario.expected.signal == nil, scenario.id)
        case "exit.structured":
            try require(scenario.kind == "exit-payload", scenario.id)
            try require(
                scenario.negotiatedFeatures == [BrokerWire.terminalExitStatusFeature],
                scenario.id
            )
            try require(scenario.input.exitCode == scenario.expected.exitCode, scenario.id)
            try require(scenario.input.signal == scenario.expected.signal, scenario.id)
        case "terminal-signal.etx":
            try require(scenario.kind == "terminal-signal-write", scenario.id)
            try require(scenario.input.method == "terminal.signal", scenario.id)
            try require(scenario.expected.writeHex == "03", scenario.id)
            let writeBytes = try bytes(hex: scenario.expected.writeHex ?? "")
            try require(writeBytes == Data([0x03]), scenario.id)
        case "utf8.split-scalar", "utf8.invalid-sequence":
            try require(scenario.kind == "utf8-stream-normalization", scenario.id)
            let chunks = try XCTUnwrap(scenario.input.chunksHex)
            let data = try chunks.reduce(into: Data()) { result, hex in
                result.append(try bytes(hex: hex))
            }
            let text = String(decoding: data, as: UTF8.self)
            try require(text == scenario.expected.text, scenario.id)
            try require(
                text.filter { $0 == "\u{FFFD}" }.count == scenario.expected.replacementCount,
                scenario.id
            )
        case "observer.snapshot-before-live":
            try require(scenario.kind == "observer-ordering", scenario.id)
            try require(scenario.input.snapshotEndOffset == scenario.input.liveStartOffset, scenario.id)
            try require(scenario.expected.order == ["snapshot", "live"], scenario.id)
            try require(scenario.expected.duplicateBytes == 0, scenario.id)
        default:
            throw ValidationError.mismatch("scenario.unsupported")
        }
    }

    private func validate(_ corpus: Corpus) throws {
        try require(corpus.schemaVersion == 1, "schemaVersion")
        try require(corpus.protocolVersion == BrokerWire.protocolVersion, "protocolVersion")
        try require(
            corpus.identifierConstraints == .init(
                pattern: "^[a-z0-9]+(?:[.-][a-z0-9]+)*$",
                maximumUtf8Bytes: 80
            ),
            "identifierConstraints"
        )
        let expression = try NSRegularExpression(pattern: corpus.identifierConstraints.pattern)
        var identifiers: [String] = []
        let validateIdentifier: (String) throws -> Void = { identifier in
            let range = NSRange(identifier.startIndex..., in: identifier)
            try self.require(expression.firstMatch(in: identifier, range: range)?.range == range, identifier)
            try self.require(identifier.utf8.count <= corpus.identifierConstraints.maximumUtf8Bytes, identifier)
            identifiers.append(identifier)
        }

        let methodNames = corpus.methods.map(\.method)
        try require(Set(methodNames).count == methodNames.count, "method.unique")
        try require(methodNames == methodNames.sorted(), "method.order")
        for method in corpus.methods {
            try validateIdentifier(method.requestScenario)
            try validateIdentifier(method.responseScenario)
            try require(method.requestScenario.hasPrefix("request."), method.method)
            try require(method.responseScenario.hasPrefix("response."), method.method)
        }
        try require(Set(identifiers).count == identifiers.count, "method.scenario.unique")

        let observers = Set(corpus.methods.filter { $0.requiredAccess == "observer" }.map(\.method))
        let controllers = Set(corpus.methods.filter { $0.requiredAccess == "controller" }.map(\.method))
        let administrators = Set(corpus.methods.filter { $0.requiredAccess == "administrator" }.map(\.method))
        try require(observers == BrokerWire.observerMethods, "methods.observer")
        try require(controllers == controllerMethods, "methods.controller")
        try require(administrators == administratorMethods, "methods.administrator")
        try require(
            observers.count + controllers.count + administrators.count == corpus.methods.count,
            "methods.access"
        )

        try require(
            corpus.semanticScenarios.map(\.id) == [
                "exit.legacy",
                "exit.structured",
                "observer.snapshot-before-live",
                "terminal-signal.etx",
                "utf8.invalid-sequence",
                "utf8.split-scalar",
            ],
            "scenario.order"
        )
        for scenario in corpus.semanticScenarios {
            try validateIdentifier(scenario.id)
            try validateScenario(scenario)
        }

        var frameIDs: Set<String> = []
        for frameCase in corpus.frameCases {
            try validateIdentifier(frameCase.id)
            try require(frameIDs.insert(frameCase.id).inserted, "frame.unique")
            let maximum = try maximumBytes(for: frameCase.purpose)
            let accepted = frameCase.expected == "accept"
            try require(frameCase.expected == "accept" || frameCase.expected == "reject", frameCase.id)
            try require(frameCase.encodedBytes == (accepted ? maximum : maximum + 1), frameCase.id)
            try require((frameCase.encodedBytes <= maximum) == accepted, frameCase.id)
        }
    }

    func testSwiftValidatesInitialProtocol2ContractInventoryAgainstBrokerWire() throws {
        try validate(loadCorpus())
    }

    func testSwiftInventoryConsumerRejectsMutatedStructuredExitExpectation() throws {
        var drifted = try loadCorpus()
        let index = try XCTUnwrap(drifted.semanticScenarios.firstIndex { $0.id == "exit.structured" })
        drifted.semanticScenarios[index].expected.signal = 9

        XCTAssertThrowsError(try validate(drifted)) { error in
            XCTAssertEqual(error as? ValidationError, .mismatch("exit.structured"))
        }
    }
}
