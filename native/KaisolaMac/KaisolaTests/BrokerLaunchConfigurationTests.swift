import Foundation
import XCTest
@testable import KaisolaMacPreview

final class BrokerLaunchConfigurationTests: XCTestCase {
    func testLaunchConfigurationAcceptsOnlyExactPrivateBrokerLayout() throws {
        let home = URL(fileURLWithPath: "/tmp/kaisola-launch-home")
        let userData = home.appendingPathComponent("Library/Application Support/Kaisola", isDirectory: true)
        let broker = userData.appendingPathComponent("session-broker", isDirectory: true)
        let launchURL = broker.appendingPathComponent("launch-native-123.json")
        let valid = configuration(userData: userData, broker: broker)
        XCTAssertNoThrow(try valid.validate(configurationURL: launchURL, homeDirectory: home))

        let escaped = BrokerLaunchConfiguration(
            protocolVersion: valid.protocolVersion,
            securityEpoch: valid.securityEpoch,
            implementationVersion: valid.implementationVersion,
            packageSchema: valid.packageSchema,
            packageVersion: valid.packageVersion,
            token: valid.token,
            socketPath: valid.socketPath,
            infoFile: "/tmp/attacker/broker.json",
            lockFile: valid.lockFile,
            storageDir: valid.storageDir,
            logFile: valid.logFile,
            startedAt: valid.startedAt,
            version: valid.version,
            smoke: false
        )
        XCTAssertThrowsError(try escaped.validate(configurationURL: launchURL, homeDirectory: home)) {
            XCTAssertEqual($0 as? BrokerLaunchConfigurationError, .unsafePath)
        }
    }

    func testLaunchConfigurationRejectsProbeOnlyBrokerMode() throws {
        let home = URL(fileURLWithPath: "/tmp/kaisola-launch-home")
        let userData = home.appendingPathComponent("Kaisola", isDirectory: true)
        let broker = userData.appendingPathComponent("session-broker", isDirectory: true)
        let valid = configuration(userData: userData, broker: broker)
        let smoke = BrokerLaunchConfiguration(
            protocolVersion: valid.protocolVersion,
            securityEpoch: valid.securityEpoch,
            implementationVersion: valid.implementationVersion,
            packageSchema: valid.packageSchema,
            packageVersion: valid.packageVersion,
            token: valid.token,
            socketPath: valid.socketPath,
            infoFile: valid.infoFile,
            lockFile: valid.lockFile,
            storageDir: valid.storageDir,
            logFile: valid.logFile,
            startedAt: valid.startedAt,
            version: valid.version,
            smoke: true
        )
        XCTAssertThrowsError(
            try smoke.validate(
                configurationURL: broker.appendingPathComponent("launch-native-smoke.json"),
                homeDirectory: home
            )
        ) { XCTAssertEqual($0 as? BrokerLaunchConfigurationError, .invalidConfiguration) }
    }

    private func configuration(userData: URL, broker: URL) -> BrokerLaunchConfiguration {
        BrokerLaunchConfiguration(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 1,
            packageVersion: "1.0.0",
            token: String(repeating: "a", count: 64),
            socketPath: broker.appendingPathComponent("broker.sock").path,
            infoFile: broker.appendingPathComponent("broker.json").path,
            lockFile: broker.appendingPathComponent("broker.lock").path,
            storageDir: userData.appendingPathComponent("terminal-cache").path,
            logFile: broker.appendingPathComponent("broker.log").path,
            startedAt: 1,
            version: "native-test",
            smoke: false
        )
    }
}
