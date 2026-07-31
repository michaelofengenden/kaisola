import Foundation
import KaisolaBrokerProtocol
import XCTest
@testable import Kaisola

/// The separate-broker fallback: when Electron's live broker predates
/// observation, the app must NOT dead-end (and must NOT touch that broker) —
/// it connects to its own native-profile broker instead.
final class AppModelBrokerFallbackTests: XCTestCase {

    @MainActor
    func testFallsBackToSeparateNativeBrokerWhenElectronBrokerLacksObservation() async throws {
        let electronInfo = Self.info(socket: "/tmp/kaisola-electron.sock", version: "0.1.60")
        let nativeInfo = Self.info(socket: "/tmp/kaisola-native-own.sock", version: "0.1.95-native")
        let client = FeatureGatedBrokerClient(rejectingSocketPath: electronInfo.socketPath)

        let model = AppModel(
            brokerPreparer: FixedPreparer(info: electronInfo),
            fallbackPreparer: FixedPreparer(info: nativeInfo),
            client: client,
            reconnectBackoff: BrokerReconnectBackoff(baseNanoseconds: 1, maximumNanoseconds: 2, jitterFraction: 0),
            sleep: { _ in await Task.yield() },
            jitter: { 0 }
        )
        await model.reload()

        XCTAssertTrue(model.connectionState.isConnected, "should be connected via the fallback broker")
        XCTAssertTrue(model.usingSeparateBroker)
        if case let .connected(version, _, _) = model.connectionState {
            XCTAssertTrue(version.contains("separate background service"))
            XCTAssertTrue(version.contains("0.1.95-native"))
        } else {
            XCTFail("expected connected state")
        }
        // The Electron broker was probed once and then left alone.
        let electronConnects = await client.connectAttempts(for: electronInfo.socketPath)
        XCTAssertEqual(electronConnects, 1)
    }

    @MainActor
    func testNoFallbackConfiguredStillReportsOfflineHonestly() async throws {
        let electronInfo = Self.info(socket: "/tmp/kaisola-electron.sock", version: "0.1.60")
        let client = FeatureGatedBrokerClient(rejectingSocketPath: electronInfo.socketPath)
        let model = AppModel(
            brokerPreparer: FixedPreparer(info: electronInfo),
            fallbackPreparer: nil,
            client: client,
            reconnectBackoff: BrokerReconnectBackoff(baseNanoseconds: 1, maximumNanoseconds: 2, jitterFraction: 0),
            sleep: { _ in await Task.yield() },
            jitter: { 0 }
        )
        await model.reload()
        XCTAssertFalse(model.connectionState.isConnected)
        XCTAssertFalse(model.usingSeparateBroker)
    }

    private static func info(socket: String, version: String) -> BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            pid: 4_242,
            socketPath: socket,
            token: String(repeating: "b", count: 64),
            startedAt: 1_784_250_002_000,
            version: version
        )
    }
}

private struct FixedPreparer: BrokerInfoPreparing {
    let info: BrokerInfo
    func prepare() async throws -> BrokerInfo { info }
}

/// Accepts every broker except the one whose socket path is marked as the
/// featureless Electron broker — that one throws observeFeatureMissing exactly
/// like the real hello check.
private actor FeatureGatedBrokerClient: ObserveOnlyBrokerServing {
    private let rejectingSocketPath: String
    private var attempts: [String: Int] = [:]

    init(rejectingSocketPath: String) {
        self.rejectingSocketPath = rejectingSocketPath
    }

    func connectAttempts(for socketPath: String) -> Int {
        attempts[socketPath] ?? 0
    }

    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {}
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {}

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        attempts[info.socketPath, default: 0] += 1
        guard info.socketPath != rejectingSocketPath else {
            throw BrokerClientError.observeFeatureMissing
        }
        return BrokerHello(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: nil,
            packageVersion: nil,
            features: [BrokerWire.terminalObserveFeature, BrokerWire.observerRoleFeature],
            pid: info.pid,
            startedAt: info.startedAt,
            version: info.version,
            serverEnforcedObserver: true
        )
    }

    func inventory() async throws -> BrokerStatus {
        try BrokerStatus(
            status: .object([
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
            ]),
            diagnostics: .array([]),
            live: .array([]),
            expectedHello: BrokerHello(
                protocolVersion: BrokerWire.protocolVersion,
                securityEpoch: BrokerWire.securityEpoch,
                implementationVersion: BrokerWire.implementationVersion,
                packageSchema: nil,
                packageVersion: nil,
                features: [BrokerWire.terminalObserveFeature, BrokerWire.observerRoleFeature],
                pid: 4_242,
                startedAt: 1_784_250_002_000,
                version: "0.1.95-native",
                serverEnforcedObserver: true
            )
        )
    }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        throw BrokerClientError.connectionClosed
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {}
    func disconnect() async {}
}
