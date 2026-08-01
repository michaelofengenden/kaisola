import Foundation
import XCTest
@testable import Kaisola

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
            contentDigest: valid.contentDigest,
            packageRoot: valid.packageRoot,
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
            contentDigest: valid.contentDigest,
            packageRoot: valid.packageRoot,
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

    func testLegacyLaunchWithoutStagedPackageKeepsExactSingleBrokerLayout() throws {
        let home = URL(fileURLWithPath: "/tmp/kaisola-launch-home")
        let userData = home.appendingPathComponent("Kaisola", isDirectory: true)
        let broker = userData.appendingPathComponent("session-broker", isDirectory: true)
        let current = configuration(userData: userData, broker: broker)
        let legacy = BrokerLaunchConfiguration(
            protocolVersion: current.protocolVersion,
            securityEpoch: current.securityEpoch,
            implementationVersion: current.implementationVersion,
            packageSchema: current.packageSchema,
            packageVersion: current.packageVersion,
            contentDigest: current.contentDigest,
            packageRoot: nil,
            token: current.token,
            socketPath: broker.appendingPathComponent("broker.sock").path,
            infoFile: broker.appendingPathComponent("broker.json").path,
            lockFile: broker.appendingPathComponent("broker.lock").path,
            storageDir: userData.appendingPathComponent("terminal-cache").path,
            logFile: broker.appendingPathComponent("broker.log").path,
            startedAt: current.startedAt,
            version: current.version,
            smoke: false
        )

        XCTAssertNoThrow(try legacy.validate(
            configurationURL: broker.appendingPathComponent("launch-native-legacy.json"),
            homeDirectory: home
        ))
    }

    private func configuration(userData: URL, broker: URL) -> BrokerLaunchConfiguration {
        let digest = String(repeating: "a", count: 64)
        let metadata = broker.appendingPathComponent(
            BrokerLaunchConfiguration.generationMetadataDirectoryName,
            isDirectory: true
        )
        return BrokerLaunchConfiguration(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 1,
            packageVersion: "1.0.0",
            contentDigest: digest,
            packageRoot: userData
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .path,
            token: String(repeating: "a", count: 64),
            socketPath: broker.appendingPathComponent(
                BrokerLaunchConfiguration.generationSocketLeaf(
                    userData: userData,
                    contentDigest: digest
                )
            ).path,
            infoFile: metadata.appendingPathComponent("\(digest).json").path,
            lockFile: metadata.appendingPathComponent("\(digest).lock").path,
            storageDir: userData.appendingPathComponent("terminal-cache").path,
            logFile: metadata.appendingPathComponent("\(digest).log").path,
            startedAt: 1,
            version: "native-test",
            smoke: false
        )
    }
}
