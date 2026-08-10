import CryptoKit
import Foundation
import KaisolaCore
import Security
import XCTest
@testable import Kaisola

private struct LegacyCompanionRosterArchive: Codable {
    let version: Int
    let devices: [LegacyCompanionPairedDeviceRecord]
}

private struct LegacyCompanionPairedDeviceRecord: Codable {
    let deviceId: String
    let displayName: String
    let identityPublic: String
    let x25519StaticPublic: String
    let capabilities: [CompanionCapability]
    let pairedAt: Int64
    let lastSeenAt: Int64
}

final class CompanionHostFoundationTests: XCTestCase {
    private let desktopSigningSeed = Data((0..<32).map { UInt8($0) })
    private let desktopAgreementSeed = Data((32..<64).map { UInt8($0) })
    private let phoneSigningSeed = Data((64..<96).map { UInt8($0) })
    private let phoneAgreementSeed = Data((96..<128).map { UInt8($0) })

    func testAccountScopedRosterPathsAndRecordsCannotCrossAccounts() async throws {
        let accountA = try CompanionAccountScope(accountID: "firebase-account-a")
        let accountB = try CompanionAccountScope(accountID: "firebase-account-b")
        XCTAssertEqual(accountA, try CompanionAccountScope(accountID: "firebase-account-a"))
        XCTAssertNotEqual(accountA, accountB)
        XCTAssertFalse(accountA.rawValue.contains("firebase-account-a"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-companion-account-rosters-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountAFile = NativePreviewPaths.companionDevices(
            accountScope: accountA,
            directory: directory
        )
        let accountBFile = NativePreviewPaths.companionDevices(
            accountScope: accountB,
            directory: directory
        )
        XCTAssertNotEqual(accountAFile, accountBFile)
        XCTAssertFalse(accountAFile.lastPathComponent.contains("firebase-account-a"))

        let accountAStore = try CompanionDeviceRosterStore(
            fileURL: accountAFile,
            accountScope: accountA
        )
        let device = try CompanionIdentity(
            id: "device-account-scope",
            role: .device,
            displayName: "Scoped iPhone"
        )
        let record = try await accountAStore.pair(
            peer: CompanionIdentityPin(
                id: device.id,
                identityPublic: device.identityPublic,
                x25519StaticPublic: device.x25519StaticPublic
            ),
            displayName: device.displayName,
            capabilities: [.observe],
            now: 100
        )
        XCTAssertEqual(record.accountScope, accountA)

        XCTAssertThrowsError(try CompanionDeviceRosterStore(
            fileURL: accountAFile,
            accountScope: accountB
        )) { error in
            XCTAssertEqual(error as? CompanionDeviceRosterError, .accountMismatch)
        }
        let accountBStore = try CompanionDeviceRosterStore(
            fileURL: accountBFile,
            accountScope: accountB
        )
        let accountBDevices = await accountBStore.list()
        XCTAssertTrue(accountBDevices.isEmpty)
        let restoredA = try CompanionDeviceRosterStore(
            fileURL: accountAFile,
            accountScope: accountA
        )
        let restoredADevices = await restoredA.list()
        XCTAssertEqual(restoredADevices, [record])
    }

    @MainActor
    func testRevocationFenceInvalidatesEveryTransportAndRejectsRacedResume() {
        let fence = CompanionDeviceRevocationFence()
        let nearby = fence.authorize(
            deviceID: "device-revocation-test",
            connectionID: "nearby-connection",
            resumed: true
        )
        let link = fence.authorize(
            deviceID: "device-revocation-test",
            connectionID: "link-connection",
            resumed: true
        )

        XCTAssertNotNil(nearby)
        XCTAssertNotNil(link)
        XCTAssertTrue(nearby.map(fence.isAuthorized) == true)
        XCTAssertTrue(link.map(fence.isAuthorized) == true)
        XCTAssertEqual(fence.token(connectionID: "nearby-connection"), nearby)
        XCTAssertEqual(fence.token(connectionID: "link-connection"), link)
        XCTAssertEqual(
            fence.revoke(deviceID: "device-revocation-test"),
            ["link-connection", "nearby-connection"]
        )
        XCTAssertFalse(nearby.map(fence.isAuthorized) == true)
        XCTAssertFalse(link.map(fence.isAuthorized) == true)
        XCTAssertNil(fence.token(connectionID: "nearby-connection"))
        XCTAssertNil(fence.token(connectionID: "link-connection"))
        XCTAssertNil(fence.authorize(
            deviceID: "device-revocation-test",
            connectionID: "raced-resume",
            resumed: true
        ))

        let repaired = fence.authorize(
            deviceID: "device-revocation-test",
            connectionID: "explicit-new-pairing",
            resumed: false
        )
        XCTAssertNotNil(repaired)
        XCTAssertTrue(repaired.map(fence.isAuthorized) == true)
    }

    @MainActor
    func testAccountTransitionClearsOnlyInMemoryRevocationIdentity() {
        let fence = CompanionDeviceRevocationFence()
        let accountAToken = fence.authorize(
            deviceID: "shared-device-id",
            connectionID: "account-a-link",
            resumed: true
        )
        XCTAssertNotNil(accountAToken)
        XCTAssertEqual(
            fence.revoke(deviceID: "shared-device-id"),
            ["account-a-link"]
        )
        XCTAssertNil(fence.authorize(
            deviceID: "shared-device-id",
            connectionID: "account-b-link-before-reset",
            resumed: true
        ))

        fence.resetForAccountChange()

        XCTAssertFalse(accountAToken.map(fence.isAuthorized) == true)
        let accountBToken = fence.authorize(
            deviceID: "shared-device-id",
            connectionID: "account-b-link",
            resumed: true
        )
        XCTAssertNotNil(accountBToken)
        XCTAssertTrue(accountBToken.map(fence.isAuthorized) == true)
    }

    func testDesktopIdentityIsStableAndPrivateKeysNeverSynchronize() throws {
        let service = "com.kaisola.mac.companion-identity.test-\(UUID().uuidString)"
        let store = CompanionIdentityStore(service: service)
        defer { store.deleteAll() }
        do {
            let first = try store.loadOrCreate(displayName: "Test Mac")
            let second = try store.loadOrCreate(displayName: "Renamed Mac")
            XCTAssertEqual(first.role, .desktop)
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(first.identityPublic, second.identityPublic)
            XCTAssertEqual(first.x25519StaticPublic, second.x25519StaticPublic)
            XCTAssertEqual(second.displayName, "Renamed Mac")
            try second.keyRecord.verify(
                identityPublic: second.identityPublic,
                expectedRole: .desktop,
                expectedId: second.id
            )
        } catch CompanionIdentityStoreError.keychain(let status)
            where status == errSecMissingEntitlement {
            throw XCTSkip("Test host lacks the data-protection Keychain entitlement.")
        }
    }

    func testRosterRoundTripsValidatedPublicMetadataAtMode0600() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-companion-roster-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("devices-v1.json")
        let accountScope = try CompanionAccountScope(accountID: "roster-round-trip-account")
        let store = try CompanionDeviceRosterStore(
            fileURL: file,
            accountScope: accountScope
        )
        let device = try CompanionIdentity(
            id: "device-test",
            role: .device,
            displayName: "Test iPhone"
        )

        let paired = try await store.pair(
            peer: CompanionIdentityPin(
                id: device.id,
                identityPublic: device.identityPublic,
                x25519StaticPublic: device.x25519StaticPublic
            ),
            displayName: "  Test iPhone  ",
            capabilities: [.observe],
            now: 100
        )
        XCTAssertEqual(paired.displayName, "Test iPhone")
        var attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reopened = try CompanionDeviceRosterStore(
            fileURL: file,
            accountScope: accountScope
        )
        let reopenedDevices = await reopened.list()
        XCTAssertEqual(reopenedDevices, [paired])
        try await reopened.markSeen(device.id, now: 200)
        let lastSeenAt = await reopened.device(device.id)?.lastSeenAt
        XCTAssertEqual(lastSeenAt, 200)
        let updated = try await reopened.updateCapabilities(
            [.terminalControl, .observe, .agentControl],
            for: device.id
        )
        XCTAssertEqual(updated.capabilities, [.observe, .agentControl, .terminalControl])
        do {
            _ = try await reopened.updateCapabilities([.terminalControl], for: device.id)
            XCTFail("Expected a grant without observe to fail closed")
        } catch {
            XCTAssertEqual(error as? CompanionDeviceRosterError, .invalidStore)
        }
        let retainedCapabilities = await reopened.device(device.id)?.capabilities
        XCTAssertEqual(retainedCapabilities, [.observe, .agentControl, .terminalControl])
        let reopenedAfterUpdate = try CompanionDeviceRosterStore(
            fileURL: file,
            accountScope: accountScope
        )
        let persistedCapabilities = await reopenedAfterUpdate.device(device.id)?.capabilities
        XCTAssertEqual(persistedCapabilities, [.observe, .agentControl, .terminalControl])
        let revoked = try await reopened.revoke(device.id, now: 300)
        XCTAssertTrue(revoked)
        let remainingDevices = await reopened.list()
        XCTAssertTrue(remainingDevices.isEmpty)
        let tombstone = await reopened.revokedDevice(device.id)
        XCTAssertEqual(tombstone?.pin, paired.pin)
        XCTAssertEqual(tombstone?.revokedAt, 300)

        let reopenedAfterRevocation = try CompanionDeviceRosterStore(
            fileURL: file,
            accountScope: accountScope
        )
        let reopenedTombstone = await reopenedAfterRevocation.revokedDevice(device.id)
        XCTAssertEqual(reopenedTombstone, tombstone)

        attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRosterRejectsOverlyPermissiveOrSymlinkedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-companion-roster-unsafe-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("devices-v1.json")
        try Data(#"{"version":1,"devices":[]}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try CompanionDeviceRosterStore(
            fileURL: file,
            accountScope: try CompanionAccountScope(accountID: "unsafe-roster-account")
        )) { error in
            XCTAssertEqual(error as? CompanionDeviceRosterError, .unsafePath)
        }
    }

    func testUnscopedVersionOneRosterCannotBeAdoptedByTheFirstSignedInAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-companion-roster-v1-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("devices-v1.json")
        let identity = try CompanionIdentity(
            id: "device-legacy-roster",
            role: .device,
            displayName: "Legacy iPhone"
        )
        let record = LegacyCompanionPairedDeviceRecord(
            deviceId: identity.id,
            displayName: identity.displayName,
            identityPublic: identity.identityPublic,
            x25519StaticPublic: identity.x25519StaticPublic,
            capabilities: [.observe],
            pairedAt: 100,
            lastSeenAt: 100
        )
        try JSONEncoder().encode(LegacyCompanionRosterArchive(
            version: 1,
            devices: [record]
        )).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )

        XCTAssertThrowsError(try CompanionDeviceRosterStore(
            fileURL: file,
            accountScope: try CompanionAccountScope(accountID: "first-account-after-upgrade")
        )) { error in
            XCTAssertEqual(error as? CompanionDeviceRosterError, .accountMismatch)
        }
        let untouched = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any]
        XCTAssertEqual(untouched?["version"] as? Int, 1)
        XCTAssertEqual((untouched?["devices"] as? [Any])?.count, 1)
    }

    func testBonjourAdvertisementMatchesShippingPhoneContract() throws {
        let desktopID = "desktop-12345678-90ab-cdef-1234-567890abcdef"
        let advertisement = try CompanionListenerAdvertisement(desktopID: desktopID)
        XCTAssertEqual(advertisement.instanceName, "Kaisola-234-567890abcdef")
        XCTAssertEqual(CompanionListenerAdvertisement.serviceType, "_kaisola._tcp")
        let txt = NetService.dictionary(fromTXTRecord: advertisement.txtRecord)
        XCTAssertEqual(txt["v"].flatMap { String(data: $0, encoding: .utf8) }, "1")
        XCTAssertEqual(txt["id"].flatMap { String(data: $0, encoding: .utf8) }, desktopID)
    }

    func testAppDeclaresLocalNetworkAndBonjourUsage() throws {
        let infoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kaisola/App/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["NSBonjourServices"] as? [String], ["_kaisola._tcp"])
        XCTAssertFalse((plist["NSLocalNetworkUsageDescription"] as? String)?.isEmpty ?? true)
    }

    func testPairingCodeRendersAsAReadableBitmap() throws {
        let image = try XCTUnwrap(CompanionQRCode.image(for: #"{"type":"kaisola-companion-pairing"}"#))
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertEqual(image.size.width, image.size.height)
        XCTAssertNil(CompanionQRCode.image(for: ""))
    }

    @MainActor
    func testPairNewDeviceIgnoresRepeatActivationWhileAnOfferIsInFlight() throws {
        let activation = CompanionPairingOfferActivation()
        let first = try XCTUnwrap(activation.begin())
        XCTAssertTrue(activation.isCreating)
        XCTAssertNil(activation.begin())
        XCTAssertNil(activation.begin())
        XCTAssertTrue(activation.finish(first))
        XCTAssertFalse(activation.isCreating)
        let second = try XCTUnwrap(activation.begin())
        XCTAssertNotEqual(second, first)
    }

    @MainActor
    func testOnlyTheNewestOfferActivationMayApplyItsResult() throws {
        let activation = CompanionPairingOfferActivation()
        let abandoned = try XCTUnwrap(activation.begin())
        activation.discard()
        XCTAssertFalse(activation.isCreating)
        let newest = try XCTUnwrap(activation.begin())
        XCTAssertFalse(activation.finish(abandoned))
        XCTAssertTrue(activation.isCreating)
        XCTAssertTrue(activation.finish(newest))
        XCTAssertFalse(activation.isCreating)
        XCTAssertFalse(activation.finish(newest))
    }

    func testPairNewDeviceButtonRendersTheGatedProgressState() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Kaisola/Features/Settings/CompanionSettingsTab.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".disabled(offerActivation.isCreating)"))
        XCTAssertTrue(source.contains("ProgressView().controlSize(.mini)"))
        XCTAssertTrue(source.contains("CompanionPairingOfferActivation.progressLabel"))
    }

    func testPairingGrantDraftIsResetAtEveryOfferBoundary() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Kaisola/Features/Settings/CompanionSettingsTab.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(
            "@State private var pairingGrantDraft = CompanionPairingGrantDraft()"
        ))
        XCTAssertTrue(source.contains("let selection = pairingGrantDraft.selection"))
        XCTAssertTrue(source.contains(
            "allowsTerminalControl: selection.allowsTerminalControl"
        ))
        XCTAssertEqual(
            source.components(separatedBy: ".disabled(pairingGrantControlsDisabled)").count - 1,
            2,
            "an active or in-flight offer must freeze both exact grant choices"
        )
        XCTAssertTrue(source.contains("pairingGrantDraft.reset(after: .offerCreationFailed)"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "pairingGrantDraft.reset(after: .cancelled)").count - 1,
            3,
            "cancel, host loss, and owned confirmation failure must all clear grants"
        )
        XCTAssertTrue(source.contains("pairingGrantDraft.reset(after: .confirmed)"))
        XCTAssertTrue(source.contains("pairingGrantDraft.reset(after: .expired)"))
        XCTAssertTrue(source.contains(".onChange(of: host.pairingPayload?.pairingNonce)"))
        XCTAssertTrue(source.contains(".task(id: host.pairingPayload)"))
        XCTAssertTrue(source.contains("CompanionPairingOfferExpiryFence(payload: payload)"))
    }

    func testPairingGrantDraftDefaultsToViewOnlyAndSnapshotsExactOptIn() {
        var draft = CompanionPairingGrantDraft()
        XCTAssertEqual(
            draft.selection,
            CompanionPairingGrantSelection(
                allowsAgentControl: false,
                allowsTerminalControl: false
            )
        )

        draft.allowsAgentControl = true
        draft.allowsTerminalControl = true
        let optedIn = draft.selection
        draft.allowsAgentControl = false
        draft.allowsTerminalControl = false

        XCTAssertEqual(
            optedIn,
            CompanionPairingGrantSelection(
                allowsAgentControl: true,
                allowsTerminalControl: true
            ),
            "offer creation must use the synchronous selection, not later toggle mutations"
        )
    }

    func testPairingGrantDraftResetsAfterEveryTerminalTransition() {
        XCTAssertEqual(
            Set(CompanionPairingGrantDraft.ResetReason.allCases),
            [.offerCreationFailed, .cancelled, .confirmed, .expired]
        )
        for reason in CompanionPairingGrantDraft.ResetReason.allCases {
            var draft = CompanionPairingGrantDraft(
                allowsAgentControl: true,
                allowsTerminalControl: true
            )
            draft.reset(after: reason)
            XCTAssertEqual(
                draft.selection,
                CompanionPairingGrantSelection(
                    allowsAgentControl: false,
                    allowsTerminalControl: false
                ),
                "\(reason) must return the next offer to view-only"
            )
        }
    }

    func testPairingGrantExpiryIsExactOfferAndGenerationFenced() {
        let expiry = CompanionPairingOfferExpiryFence(
            pairingNonce: "pairing-old",
            expiresAt: 12_000
        )
        XCTAssertTrue(expiry.matches(pairingNonce: "pairing-old", expiresAt: 12_000))
        XCTAssertFalse(expiry.matches(pairingNonce: nil, expiresAt: nil))
        XCTAssertFalse(expiry.matches(pairingNonce: "pairing-new", expiresAt: 12_000))
        XCTAssertFalse(expiry.matches(pairingNonce: "pairing-old", expiresAt: 13_000))
    }

    func testPairingConfirmationRendersOneGatedProgressAndFailureRestartState() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Kaisola/Features/Settings/CompanionSettingsTab.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(
            "@StateObject private var confirmationActivation = CompanionPairingConfirmationActivation()"
        ))
        XCTAssertEqual(
            source.components(separatedBy: ".disabled(confirmationActivation.isConfirming)").count - 1,
            2,
            "both phrase decisions must become inert while one confirmation owns the slot"
        )
        XCTAssertTrue(source.contains(
            "Text(CompanionPairingConfirmationActivation.progressLabel)"
        ))
        XCTAssertTrue(source.contains(
            "let attempt = confirmationActivation.begin(pairingID: phrase.pairingID)"
        ))
        XCTAssertTrue(source.contains(
            "operationError = CompanionPairingConfirmationActivation.failureMessage(error)"
        ))
        XCTAssertTrue(source.contains(
            "guard confirmationActivation.fail(attempt) else { return }\n"
                + "                host.cancelPairing()\n"
                + "                operationError = CompanionPairingConfirmationActivation.failureMessage(error)"
        ))
    }

    @MainActor
    func testPairingConfirmationStaysGatedUntilTheExactPairingSettles() throws {
        let activation = CompanionPairingConfirmationActivation()
        let attempt = try XCTUnwrap(activation.begin(pairingID: "pairing-1"))

        XCTAssertTrue(activation.isConfirming)
        XCTAssertNil(activation.begin(pairingID: "pairing-1"))
        XCTAssertTrue(activation.submitted(
            attempt,
            currentPairingID: "pairing-1"
        ))
        XCTAssertTrue(
            activation.isConfirming,
            "sending the local SAS decision is not success until the phone settles the same pairing"
        )
        XCTAssertNil(activation.begin(pairingID: "pairing-1"))

        activation.reconcile(pairingID: "pairing-1")
        XCTAssertTrue(activation.isConfirming)
        activation.reconcile(pairingID: nil)
        XCTAssertFalse(activation.isConfirming)
    }

    @MainActor
    func testPairingConfirmationFailureCannotCancelANewerPairing() throws {
        let activation = CompanionPairingConfirmationActivation()
        XCTAssertNil(activation.begin(pairingID: ""))
        let stale = try XCTUnwrap(activation.begin(pairingID: "pairing-old"))

        activation.reconcile(pairingID: "pairing-new")
        XCTAssertFalse(activation.isConfirming)
        let current = try XCTUnwrap(activation.begin(pairingID: "pairing-new"))
        XCTAssertFalse(activation.fail(stale))
        XCTAssertTrue(activation.isConfirming)

        // A disconnect can clear the phrase before confirmPairing() reports
        // failure. Keep ownership during submission so that failure still
        // restores a clear new-offer state instead of disappearing silently.
        activation.reconcile(pairingID: nil)
        XCTAssertTrue(activation.isConfirming)
        XCTAssertTrue(activation.fail(current))
        XCTAssertFalse(activation.isConfirming)
        XCTAssertFalse(activation.fail(current))
    }

    @MainActor
    func testPairingConfirmationFailureMessageExplainsTheRestart() {
        let error = NSError(
            domain: "pairing-fixture",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Handshake timed out."]
        )
        XCTAssertEqual(
            CompanionPairingConfirmationActivation.failureMessage(error),
            "Pairing confirmation failed: Handshake timed out. Create a new pairing code to try again."
        )
        XCTAssertEqual(
            CompanionPairingConfirmationActivation.progressLabel,
            "Confirming pairing"
        )
    }

    func testPairingCodePresentationPreservesTheExactDisplayedAndCopiedValue() {
        let code = #"{"accountScope":"acct-1","pairingNonce":"aB-_09","type":"kaisola-companion-pairing"}"#
        let presentation = CompanionPairingCodePresentation(code: code)

        XCTAssertEqual(presentation.displayValue, code)
        XCTAssertEqual(presentation.copyValue, code)
        XCTAssertEqual(presentation.accessibilityValue, code)
        XCTAssertEqual(presentation.title, "Single-use pairing code")
    }

    func testPairingCodePresentationExplainsQRCodeFailureWithoutHidingManualFallback() {
        let code = #"{"pairingNonce":"manual-fallback"}"#
        let presentation = CompanionPairingCodePresentation(code: code)

        XCTAssertNil(presentation.qrFallbackMessage(qrCodeAvailable: true))
        XCTAssertEqual(
            presentation.qrFallbackMessage(qrCodeAvailable: false),
            "QR code unavailable. Copy or select the pairing code instead."
        )
        XCTAssertEqual(presentation.displayValue, code)
        XCTAssertEqual(presentation.copyValue, code)
        XCTAssertTrue(
            CompanionPairingOfferAccessibility.qrFallback.hasPrefix(
                CompanionPairingOfferAccessibility.group + "."
            )
        )
    }

    func testPairingOfferControlsUseOneStableAccessibilityGroup() {
        let identifiers = CompanionPairingOfferAccessibility.allControlIdentifiers

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.allSatisfy {
            $0.hasPrefix(CompanionPairingOfferAccessibility.group + ".")
        })
        XCTAssertTrue(identifiers.contains(CompanionPairingOfferAccessibility.code))
        XCTAssertTrue(identifiers.contains(CompanionPairingOfferAccessibility.qrCode))
        XCTAssertTrue(identifiers.contains(CompanionPairingOfferAccessibility.copy))
        XCTAssertTrue(identifiers.contains(CompanionPairingOfferAccessibility.cancel))
    }

    func testPairingCoordinatorCompletesMutualProofSASAndSecureResume() async throws {
        let fixture = try makePairingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now: Int64 = 1_000_000
        let offer = try await fixture.coordinator.createOffer(
            listenerPort: 49_321,
            requestedCapabilities: [.observe, .terminalControl],
            nowMilliseconds: now,
            nonce: Data(repeating: 9, count: 32)
        )
        let connectionID = "connection-pairing-test"
        let initiator = try NoiseXXInitiator(
            identity: fixture.phone,
            prologue: createNoisePrologue(try offer.handshakeContext(connectionId: connectionID)),
            peerPin: offer.desktopPin
        )
        let message1 = try initiator.writeMessage1()
        let started = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try wire([
                "v": .integer(1),
                "type": .string("pair.start"),
                "qrPayload": try JSONValue.from(offer),
                "connectionId": .string(connectionID),
                "message1": .string(message1.base64URLEncodedString()),
            ]),
            nowMilliseconds: now + 1
        )
        let message2Object = try object(try XCTUnwrap(started.frames.first))
        let sessionID = try XCTUnwrap(message2Object["sessionId"]?.stringValue)
        let message2 = try XCTUnwrap(
            message2Object["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        XCTAssertEqual(message2Object["type"]?.stringValue, "pair.message2")
        try initiator.readMessage2(message2)
        let message3 = try initiator.writeMessage3()
        let phoneResult = try initiator.result()
        let context = CompanionConnectionContext(
            desktopId: fixture.desktop.id,
            deviceId: fixture.phone.id,
            connectionId: connectionID
        )
        let phoneChannel = try SecureFrameChannel(
            result: phoneResult,
            context: context,
            role: .device
        )

        let completed = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try wire([
                "v": .integer(1),
                "type": .string("pair.message3"),
                "sessionId": .string(sessionID),
                "message3": .string(message3.base64URLEncodedString()),
            ]),
            nowMilliseconds: now + 2
        )
        let confirmationObject = try object(try XCTUnwrap(completed.frames.first))
        XCTAssertEqual(confirmationObject["type"]?.stringValue, "pair.confirmation")
        let desktopConfirmation = try decodeSecureFrame(
            try XCTUnwrap(confirmationObject["confirmationFrame"])
        )
        try CompanionKeyConfirmation.verify(
            channel: phoneChannel,
            frame: desktopConfirmation,
            expectedRole: .desktop,
            handshakeHash: phoneResult.handshakeHash
        )
        let phoneConfirmation = try CompanionKeyConfirmation.make(
            channel: phoneChannel,
            role: .device,
            handshakeHash: phoneResult.handshakeHash
        )
        let phrase = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try CanonicalJSON.data(from: phoneConfirmation),
            nowMilliseconds: now + 3
        )
        guard case let .pairingPhrase(pairingID, _, deviceID, displayName, sas) = phrase.event else {
            return XCTFail("Expected the authenticated SAS event")
        }
        XCTAssertEqual(pairingID, offer.pairingNonce)
        XCTAssertEqual(deviceID, fixture.phone.id)
        XCTAssertEqual(displayName, "Michael's iPhone")
        XCTAssertEqual(sas, CompanionSAS.derive(handshakeHash: phoneResult.handshakeHash))

        let locallyConfirmed = try await fixture.coordinator.confirmPairing(
            pairingID: pairingID,
            nowMilliseconds: now + 4
        )
        XCTAssertEqual(locallyConfirmed.frames.count, 1)
        let desktopSAS = try phoneChannel.decryptJSON(
            try decodeSecureFrameData(locallyConfirmed.frames[0])
        )
        XCTAssertEqual(desktopSAS.objectValue?["type"]?.stringValue, "sas-confirm")
        XCTAssertEqual(desktopSAS.objectValue?["role"]?.stringValue, "desktop")

        let phoneSAS: JSONValue = .object([
            "type": .string("sas-confirm"),
            "role": .string("device"),
            "transcriptHash": .string(phoneResult.handshakeHash.base64URLEncodedString()),
        ])
        let paired = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try CanonicalJSON.data(from: phoneChannel.encrypt(phoneSAS)),
            nowMilliseconds: now + 5
        )
        XCTAssertEqual(paired.frames.count, 1)
        let pairedPayload = try phoneChannel.decryptJSON(
            try decodeSecureFrameData(paired.frames[0])
        )
        XCTAssertEqual(pairedPayload.objectValue?["type"]?.stringValue, "paired")
        XCTAssertEqual(pairedPayload.objectValue?["deviceId"]?.stringValue, fixture.phone.id)
        let storedPairedRecord = await fixture.roster.device(fixture.phone.id)
        let pairedRecord = try XCTUnwrap(storedPairedRecord)
        XCTAssertEqual(pairedRecord.displayName, "Michael's iPhone")
        XCTAssertEqual(pairedRecord.capabilities, [.observe, .terminalControl])
        let pairedConnection = await fixture.coordinator.authenticatedConnection(socketID: "socket-pair")
        XCTAssertEqual(pairedConnection?.device, pairedRecord)
        XCTAssertEqual(pairedConnection?.resumed, false)

        let resumeConnectionID = "connection-resume-test"
        let resumeContext: JSONValue = .object([
            "v": .integer(1),
            "mode": .string("resume"),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(fixture.desktop.id),
            "deviceId": .string(fixture.phone.id),
            "connectionId": .string(resumeConnectionID),
            "accountScope": .string(fixture.roster.accountScope.rawValue),
        ])
        let resumeInitiator = try NoiseXXInitiator(
            identity: fixture.phone,
            prologue: createNoisePrologue(resumeContext),
            peerPin: CompanionIdentityPin(
                id: fixture.desktop.id,
                identityPublic: fixture.desktop.identityPublic,
                x25519StaticPublic: fixture.desktop.x25519StaticPublic
            )
        )
        let resumeStarted = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try wire([
                "v": .integer(1),
                "type": .string("resume.start"),
                "deviceId": .string(fixture.phone.id),
                "connectionId": .string(resumeConnectionID),
                "accountScope": .string(fixture.roster.accountScope.rawValue),
                "message1": .string(try resumeInitiator.writeMessage1().base64URLEncodedString()),
            ]),
            nowMilliseconds: now + 10
        )
        let resumeMessage2Object = try object(try XCTUnwrap(resumeStarted.frames.first))
        let resumeSessionID = try XCTUnwrap(resumeMessage2Object["sessionId"]?.stringValue)
        let resumeMessage2 = try XCTUnwrap(
            resumeMessage2Object["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        try resumeInitiator.readMessage2(resumeMessage2)
        let resumeMessage3 = try resumeInitiator.writeMessage3()
        let resumeResult = try resumeInitiator.result()
        let resumePhoneChannel = try SecureFrameChannel(
            result: resumeResult,
            context: CompanionConnectionContext(
                desktopId: fixture.desktop.id,
                deviceId: fixture.phone.id,
                connectionId: resumeConnectionID
            ),
            role: .device
        )
        let resumeCompleted = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try wire([
                "v": .integer(1),
                "type": .string("resume.message3"),
                "sessionId": .string(resumeSessionID),
                "message3": .string(resumeMessage3.base64URLEncodedString()),
            ]),
            nowMilliseconds: now + 11
        )
        let resumeConfirmationObject = try object(try XCTUnwrap(resumeCompleted.frames.first))
        try CompanionKeyConfirmation.verify(
            channel: resumePhoneChannel,
            frame: try decodeSecureFrame(
                try XCTUnwrap(resumeConfirmationObject["confirmationFrame"])
            ),
            expectedRole: .desktop,
            handshakeHash: resumeResult.handshakeHash
        )
        let resumeAuthenticated = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try CanonicalJSON.data(from: CompanionKeyConfirmation.make(
                channel: resumePhoneChannel,
                role: .device,
                handshakeHash: resumeResult.handshakeHash
            )),
            nowMilliseconds: now + 12
        )
        guard case let .authenticated(device, resumed) = resumeAuthenticated.event else {
            return XCTFail("Expected authenticated resume")
        }
        XCTAssertEqual(device.deviceId, fixture.phone.id)
        XCTAssertTrue(resumed)
        let resumedConnection = await fixture.coordinator.authenticatedConnection(socketID: "socket-resume")
        XCTAssertEqual(resumedConnection?.resumed, true)
    }

    func testRevokedDeviceGetsAuthenticatedTerminalFrameAndCannotResume() async throws {
        let fixture = try makePairingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.roster.pair(
            peer: CompanionIdentityPin(
                id: fixture.phone.id,
                identityPublic: fixture.phone.identityPublic,
                x25519StaticPublic: fixture.phone.x25519StaticPublic
            ),
            displayName: fixture.phone.displayName,
            capabilities: [.observe, .terminalControl],
            now: 1_000
        )
        let didRevoke = try await fixture.roster.revoke(fixture.phone.id, now: 1_100)
        XCTAssertTrue(didRevoke)

        let connectionID = "connection-revoked-resume"
        let contextValue: JSONValue = .object([
            "v": .integer(1),
            "mode": .string("resume"),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(fixture.desktop.id),
            "deviceId": .string(fixture.phone.id),
            "connectionId": .string(connectionID),
            "accountScope": .string(fixture.roster.accountScope.rawValue),
        ])
        let initiator = try NoiseXXInitiator(
            identity: fixture.phone,
            prologue: createNoisePrologue(contextValue),
            peerPin: CompanionIdentityPin(
                id: fixture.desktop.id,
                identityPublic: fixture.desktop.identityPublic,
                x25519StaticPublic: fixture.desktop.x25519StaticPublic
            )
        )
        let started = try await fixture.coordinator.receive(
            socketID: "socket-revoked-resume",
            payload: try wire([
                "v": .integer(1),
                "type": .string("resume.start"),
                "deviceId": .string(fixture.phone.id),
                "connectionId": .string(connectionID),
                "accountScope": .string(fixture.roster.accountScope.rawValue),
                "message1": .string(try initiator.writeMessage1().base64URLEncodedString()),
            ]),
            nowMilliseconds: 1_200
        )
        let message2Object = try object(try XCTUnwrap(started.frames.first))
        let sessionID = try XCTUnwrap(message2Object["sessionId"]?.stringValue)
        let message2 = try XCTUnwrap(
            message2Object["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        try initiator.readMessage2(message2)
        let message3 = try initiator.writeMessage3()
        let result = try initiator.result()
        let phoneChannel = try SecureFrameChannel(
            result: result,
            context: CompanionConnectionContext(
                desktopId: fixture.desktop.id,
                deviceId: fixture.phone.id,
                connectionId: connectionID
            ),
            role: .device
        )
        let completed = try await fixture.coordinator.receive(
            socketID: "socket-revoked-resume",
            payload: try wire([
                "v": .integer(1),
                "type": .string("resume.message3"),
                "sessionId": .string(sessionID),
                "message3": .string(message3.base64URLEncodedString()),
            ]),
            nowMilliseconds: 1_201
        )
        let confirmationObject = try object(try XCTUnwrap(completed.frames.first))
        try CompanionKeyConfirmation.verify(
            channel: phoneChannel,
            frame: try decodeSecureFrame(try XCTUnwrap(confirmationObject["confirmationFrame"])),
            expectedRole: .desktop,
            handshakeHash: result.handshakeHash
        )
        let terminal = try await fixture.coordinator.receive(
            socketID: "socket-revoked-resume",
            payload: try CanonicalJSON.data(from: CompanionKeyConfirmation.make(
                channel: phoneChannel,
                role: .device,
                handshakeHash: result.handshakeHash
            )),
            nowMilliseconds: 1_202
        )
        guard case let .revoked(deviceID) = terminal.event else {
            return XCTFail("Expected revoked terminal event")
        }
        XCTAssertEqual(deviceID, fixture.phone.id)
        let terminalPayload = try phoneChannel.decryptJSON(
            try decodeSecureFrameData(try XCTUnwrap(terminal.frames.first))
        )
        XCTAssertEqual(terminalPayload.objectValue?["type"]?.stringValue, "device-revoked")
        XCTAssertEqual(
            terminalPayload.objectValue?["message"]?.stringValue,
            "This iPhone was revoked on the Mac. Pair it again to reconnect."
        )
        let authenticated = await fixture.coordinator.authenticatedConnection(
            socketID: "socket-revoked-resume"
        )
        XCTAssertNil(authenticated)
    }

    func testPairingOfferIsSingleUseEvenWhenClaimingHandshakeIsMalformed() async throws {
        let fixture = try makePairingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let offer = try await fixture.coordinator.createOffer(
            listenerPort: 49_321,
            nowMilliseconds: 1_000,
            nonce: Data(repeating: 7, count: 32)
        )
        let malformed = try wire([
            "v": .integer(1),
            "type": .string("pair.start"),
            "qrPayload": try JSONValue.from(offer),
            "connectionId": .string("connection-single-use"),
            "message1": .string(Data([1]).base64URLEncodedString()),
        ])
        do {
            _ = try await fixture.coordinator.receive(
                socketID: "socket-malformed",
                payload: malformed,
                nowMilliseconds: 1_001
            )
            XCTFail("Expected malformed Noise message to fail")
        } catch {
            XCTAssertNotEqual(error as? CompanionPairingCoordinatorError, .offerUnavailable)
        }
        do {
            _ = try await fixture.coordinator.receive(
                socketID: "socket-replay",
                payload: malformed,
                nowMilliseconds: 1_002
            )
            XCTFail("Expected the claimed QR offer to be unavailable")
        } catch {
            XCTAssertEqual(error as? CompanionPairingCoordinatorError, .offerUnavailable)
        }
    }

    private struct PairingFixture {
        let directory: URL
        let desktop: CompanionIdentity
        let phone: CompanionIdentity
        let roster: CompanionDeviceRosterStore
        let coordinator: CompanionPairingCoordinator
    }

    private func makePairingFixture() throws -> PairingFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-companion-pairing-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let desktop = try CompanionIdentity.testIdentity(
            id: "desktop-pairing-test",
            role: .desktop,
            displayName: "Test Mac",
            signingSeed: desktopSigningSeed,
            agreementSeed: desktopAgreementSeed
        )
        let phone = try CompanionIdentity.testIdentity(
            id: "device-pairing-test",
            role: .device,
            displayName: "Michael's iPhone",
            signingSeed: phoneSigningSeed,
            agreementSeed: phoneAgreementSeed
        )
        let roster = try CompanionDeviceRosterStore(
            fileURL: directory.appendingPathComponent("devices-v3.json"),
            accountScope: try CompanionAccountScope(accountID: "host-foundation-pairing")
        )
        return PairingFixture(
            directory: directory,
            desktop: desktop,
            phone: phone,
            roster: roster,
            coordinator: try CompanionPairingCoordinator(identity: desktop, roster: roster)
        )
    }

    private func wire(_ fields: [String: JSONValue]) throws -> Data {
        try CanonicalJSON.data(from: .object(fields))
    }

    private func object(_ data: Data) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(value.objectValue)
    }

    private func decodeSecureFrame(_ value: JSONValue) throws -> CompanionSecureFrame {
        try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: CanonicalJSON.data(from: value)
        )
    }

    private func decodeSecureFrameData(_ data: Data) throws -> CompanionSecureFrame {
        try JSONDecoder().decode(CompanionSecureFrame.self, from: data)
    }
}
