import AppKit
import Darwin
import XCTest
@testable import Kaisola

/// The theme registry: shipped themes must mean exactly what the old
/// hardcoded modes meant, custom themes must be validated with named reasons,
/// and every failure must degrade to a disabled row rather than a broken
/// terminal.
final class TerminalThemeRegistryTests: XCTestCase {
    private func sRGB(_ color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
    }

    private func temporaryStore() throws -> CustomThemeStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-themes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CustomThemeStore(fileURL: directory.appending(path: "terminal-themes.json"))
    }

    private func validSpec(id: String = "midnight", title: String = "Midnight") -> CustomThemeSpec {
        let palette = CustomThemeSpec.PaletteSpec(
            background: "#101418",
            foreground: "#E8EAF0",
            cursor: "#E8EAF0",
            selection: "#3A4A6A80",
            ansi: [
                "#14161C", "#E16A6A", "#54C08A", "#D8A44A",
                "#5AA9E6", "#A88752", "#5EC5C0", "#C4C8D2",
                "#5A5F6B", "#E16A6A", "#54C08A", "#D8A44A",
                "#5AA9E6", "#A88752", "#5EC5C0", "#F3F4F6",
            ]
        )
        return CustomThemeSpec(id: id, title: title, light: palette, dark: palette)
    }

    // MARK: - Shipped parity

    /// The registry's shipped entries are the old `TerminalPaletteMode` pair,
    /// under the same ids and with the same palettes — an existing install's
    /// persisted "native"/"kaisola" keeps meaning the identical colors.
    func testShippedThemesMatchTheHistoricalPalettes() {
        XCTAssertEqual(TerminalThemeRegistry.shipped.map(\.id), ["native", "kaisola"])
        let native = TerminalThemeRegistry.definition(id: "native")
        XCTAssertTrue(native.dark.background.isEqual(TerminalTheme.nativeDark.background))
        XCTAssertTrue(native.light.background.isEqual(TerminalTheme.nativeLight.background))
        let kaisola = TerminalThemeRegistry.definition(id: "kaisola")
        XCTAssertTrue(kaisola.dark.background.isEqual(TerminalTheme.dark.background))
        XCTAssertTrue(kaisola.light.background.isEqual(TerminalTheme.light.background))
        XCTAssertEqual(kaisola.dark.ansi.count, 16)
    }

    /// The shipped Kaisola light palette owns the terminal canvas. The
    /// historical #E9EBEF canvas rendered visibly grey, and the pane chrome
    /// repeats the canvas around SwiftTerm. Keep both literal white without
    /// conflating the ANSI black text role with the canvas.
    func testShippedKaisolaLightTerminalCanvasAndChromeAreExactWhite() {
        let colors = [
            TerminalTheme.light.background,
            TerminalTheme.paneChrome(light: true, themeID: "kaisola").background,
        ]

        for color in colors {
            let channels = sRGB(color)
            XCTAssertEqual(channels.red, 1, accuracy: 0.0001)
            XCTAssertEqual(channels.green, 1, accuracy: 0.0001)
            XCTAssertEqual(channels.blue, 1, accuracy: 0.0001)
        }
    }

    /// The white-canvas rule belongs to the two shipped themes only. A user
    /// theme's light background is authored content and must not be normalized.
    func testCustomLightTerminalCanvasKeepsItsAuthoredColor() throws {
        let store = try temporaryStore()
        XCTAssertNil(try store.upsert(validSpec()))
        let custom = TerminalThemeRegistry.definition(id: "midnight", store: store)
        let channels = sRGB(custom.light.background)

        XCTAssertEqual(channels.red, CGFloat(0x10) / 255, accuracy: 0.0001)
        XCTAssertEqual(channels.green, CGFloat(0x14) / 255, accuracy: 0.0001)
        XCTAssertEqual(channels.blue, CGFloat(0x18) / 255, accuracy: 0.0001)
    }

    /// This is a light-only correction. The dark canvases remain the shipped
    /// near-black values rather than being routed through the white contract.
    func testDarkTerminalCanvasesRemainUnchanged() {
        let native = sRGB(TerminalTheme.nativeDark.background)
        XCTAssertEqual(native.red, CGFloat(0x1E) / 255, accuracy: 0.0001)
        XCTAssertEqual(native.green, CGFloat(0x1E) / 255, accuracy: 0.0001)
        XCTAssertEqual(native.blue, CGFloat(0x1E) / 255, accuracy: 0.0001)

        let kaisola = sRGB(TerminalTheme.dark.background)
        XCTAssertEqual(kaisola.red, CGFloat(0x0D) / 255, accuracy: 0.0001)
        XCTAssertEqual(kaisola.green, CGFloat(0x0F) / 255, accuracy: 0.0001)
        XCTAssertEqual(kaisola.blue, CGFloat(0x13) / 255, accuracy: 0.0001)
    }

    /// An unknown or removed id falls back to the shipped default — a stale
    /// preference can never produce a blank terminal.
    func testAnUnknownThemeIDResolvesToTheShippedDefault() throws {
        let store = try temporaryStore()
        let resolved = TerminalThemeRegistry.definition(id: "no-such-theme", store: store)
        XCTAssertEqual(resolved.id, "native")
    }

    // MARK: - Custom themes

    func testAValidCustomThemeInstallsAndResolvesByID() throws {
        let store = try temporaryStore()
        XCTAssertNil(try store.upsert(validSpec()))
        let resolved = TerminalThemeRegistry.definition(id: "midnight", store: store)
        XCTAssertEqual(resolved.id, "midnight")
        XCTAssertEqual(resolved.title, "Midnight")
        XCTAssertEqual(resolved.dark.ansi.count, 16)
        XCTAssertTrue(TerminalThemeRegistry.all(store: store).contains { $0.id == "midnight" })
    }

    /// Every invalid shape names its reason — the settings row's explanation
    /// is this string, so "nil would also fail" is not good enough.
    func testInvalidSpecsNameTheirReason() {
        var spec = validSpec(id: "native")
        XCTAssertTrue(spec.validationError?.contains("built-in") == true)

        spec = validSpec(id: "bad id!")
        XCTAssertTrue(spec.validationError?.contains("letters, numbers") == true)

        spec = validSpec()
        spec.title = ""
        XCTAssertEqual(spec.validationError, "The theme has no title.")

        spec = validSpec()
        spec.dark.ansi.removeLast()
        XCTAssertTrue(spec.validationError?.contains("15 ANSI colors") == true)

        spec = validSpec()
        spec.light.background = "1E1E1E"
        XCTAssertTrue(spec.validationError?.contains("#RRGGBB") == true)

        spec = validSpec()
        spec.dark.ansi[3] = "#XYZ123"
        XCTAssertTrue(spec.validationError?.contains("ANSI color") == true)

        XCTAssertNil(validSpec().validationError)
    }

    /// An invalid theme is kept, skipped by the registry, and its stored form
    /// still carries the reason — disabled with an explanation, not vanished.
    func testAnInvalidThemeIsKeptButNeverInstalled() throws {
        let store = try temporaryStore()
        var broken = validSpec(id: "broken")
        broken.dark.ansi.removeLast()
        let reason = try store.upsert(broken)
        XCTAssertNotNil(reason)
        XCTAssertEqual(store.specs().count, 1)
        XCTAssertNil(store.specs().first?.asDefinition())
        XCTAssertFalse(TerminalThemeRegistry.all(store: store).contains { $0.id == "broken" })
        XCTAssertEqual(TerminalThemeRegistry.definition(id: "broken", store: store).id, "native")
    }

    func testRemovalIsReversibleAndExact() throws {
        let store = try temporaryStore()
        try store.upsert(validSpec(id: "one", title: "One"))
        try store.upsert(validSpec(id: "two", title: "Two"))
        XCTAssertTrue(try store.remove(id: "one"))
        XCTAssertEqual(store.specs().map(\.id), ["two"])
        XCTAssertFalse(try store.remove(id: "one"), "removing twice reports nothing happened")
        try store.upsert(validSpec(id: "one", title: "One"))
        XCTAssertEqual(Set(store.specs().map(\.id)), ["one", "two"])
    }

    func testTheStoreRejectsAnOversizedBulkSaveWithoutReplacingTheRegistry() throws {
        let store = try temporaryStore()
        let baseline = validSpec(id: "baseline", title: "Baseline")
        try store.save([baseline])
        let before = try Data(contentsOf: store.fileURL)

        XCTAssertThrowsError(
            try store.save((0..<20).map { validSpec(id: "theme-\($0)", title: "Theme \($0)") })
        )
        XCTAssertEqual(store.specs(), [baseline])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testMissingVersionedAndLegacyStatesAreDistinctAndMigrateOnSave() throws {
        let store = try temporaryStore()
        XCTAssertEqual(store.load(), .init(specs: [], state: .missing))

        let legacySpec = validSpec(id: "legacy", title: "Legacy")
        let legacy = try JSONEncoder().encode(["themes": [legacySpec]])
        try legacy.write(to: store.fileURL)
        XCTAssertEqual(
            store.load(),
            .init(specs: [legacySpec], state: .ready(schemaVersion: 0))
        )

        try store.upsert(validSpec(id: "new", title: "New"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, CustomThemeStore.schemaVersion)
        XCTAssertEqual((object["themes"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(store.load().state, .ready(schemaVersion: CustomThemeStore.schemaVersion))
    }

    func testMalformedRegistryIsPreservedAndLastKnownGoodThemeStaysLiveUntilReset() throws {
        let store = try temporaryStore()
        let baseline = validSpec(id: "baseline", title: "Baseline")
        try store.upsert(baseline)
        XCTAssertEqual(store.load().specs, [baseline], "prime the process-scoped last-known-good set")

        let malformed = Data(#"{"version":1,"themes":[{"id":7}]}"#.utf8)
        try malformed.write(to: store.fileURL)

        let first = store.load()
        guard case let .corrupt(.preserved(copyURL)) = first.state else {
            return XCTFail("Expected corrupt preserved state, got \(first.state)")
        }
        XCTAssertEqual(first.specs, [baseline], "the running terminal must retain its last-known-good theme")
        XCTAssertEqual(TerminalThemeRegistry.definition(id: baseline.id, store: store).id, baseline.id)
        XCTAssertEqual(try Data(contentsOf: copyURL), malformed)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
        let recoveryMode = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: copyURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(recoveryMode.intValue & 0o777, 0o600)
        XCTAssertEqual(store.load(), first, "content-addressed preservation must be idempotent")

        XCTAssertThrowsError(try store.upsert(validSpec(id: "replacement", title: "Replacement")))
        XCTAssertThrowsError(try store.remove(id: baseline.id))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)

        let reset = try store.resetUnreadableRegistry()
        XCTAssertEqual(reset, .init(specs: [], state: .ready(schemaVersion: CustomThemeStore.schemaVersion)))
        XCTAssertEqual(try Data(contentsOf: copyURL), malformed, "explicit reset must retain the recovery copy")
        XCTAssertNil(try store.upsert(validSpec(id: "replacement", title: "Replacement")))
    }

    func testDamagedRecoveryCopyFailsClosedAndCannotAuthorizeReset() throws {
        let store = try temporaryStore()
        let baseline = validSpec(id: "baseline", title: "Baseline")
        try store.upsert(baseline)
        _ = store.load()
        let malformed = Data("not-json".utf8)
        try malformed.write(to: store.fileURL)
        let first = store.load()
        let copyURL = try XCTUnwrap(first.state.preservedCopyURL)
        try Data("different".utf8).write(to: copyURL)

        let second = store.load()
        guard case .corrupt(.failed) = second.state else {
            return XCTFail("A mismatched recovery copy must fail closed, got \(second.state)")
        }
        XCTAssertEqual(second.specs, [baseline])
        XCTAssertFalse(second.state.canReset)
        XCTAssertThrowsError(try store.resetUnreadableRegistry())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
    }

    func testOneUndecodableRecordQuarantinesTheWholeRegistryWithoutDroppingRuntimeThemes() throws {
        let store = try temporaryStore()
        let baseline = validSpec(id: "baseline", title: "Baseline")
        try store.upsert(baseline)
        _ = store.load()

        let encoded = try JSONEncoder().encode(validSpec(id: "decodable", title: "Decodable"))
        let validObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let partial: [String: Any] = [
            "version": CustomThemeStore.schemaVersion,
            "themes": [validObject, ["id": "structurally-broken"]],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: partial, options: [.sortedKeys])
        try bytes.write(to: store.fileURL)

        let snapshot = store.load()
        guard case let .corrupt(.preserved(copyURL)) = snapshot.state else {
            return XCTFail("One undecodable record must quarantine the complete registry")
        }
        XCTAssertEqual(snapshot.specs, [baseline])
        XCTAssertEqual(try Data(contentsOf: copyURL), bytes)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

    func testFutureSchemaIsPreservedAndCannotDowngradeTheRuntimeThemeSet() throws {
        let store = try temporaryStore()
        let baseline = validSpec(id: "baseline", title: "Baseline")
        try store.upsert(baseline)
        _ = store.load()

        let future = Data(#"{"version":42,"themes":[],"futurePolicy":{"mode":"sealed"}}"#.utf8)
        try future.write(to: store.fileURL)
        let snapshot = store.load()
        guard case let .newerVersion(version, .preserved(copyURL)) = snapshot.state else {
            return XCTFail("Expected newer-version preserved state, got \(snapshot.state)")
        }
        XCTAssertEqual(version, 42)
        XCTAssertEqual(snapshot.specs, [baseline])
        XCTAssertEqual(try Data(contentsOf: copyURL), future)
        XCTAssertThrowsError(try store.save([]))
        XCTAssertThrowsError(try store.remove(id: baseline.id))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
    }

    func testIOReadFailureKeepsRuntimeThemeButCannotOfferDestructiveRecovery() throws {
        let store = try temporaryStore()
        let baseline = validSpec(id: "baseline", title: "Baseline")
        try store.upsert(baseline)
        _ = store.load()
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)

        let snapshot = store.load()
        guard case .ioFailure = snapshot.state else {
            return XCTFail("A directory at the registry path must be an I/O failure")
        }
        XCTAssertEqual(snapshot.specs, [baseline])
        XCTAssertFalse(snapshot.state.canReset)
        XCTAssertThrowsError(try store.resetUnreadableRegistry())
        XCTAssertThrowsError(try store.upsert(validSpec(id: "blocked", title: "Blocked")))
    }

    func testWriteFailureIsVisibleAndLeavesRegistryAndLastKnownGoodUntouched() throws {
        let store = try temporaryStore()
        let baseline = validSpec(id: "baseline", title: "Baseline")
        try store.upsert(baseline)
        let before = try Data(contentsOf: store.fileURL)
        let directory = store.fileURL.deletingLastPathComponent()

        XCTAssertEqual(chmod(directory.path, 0o500), 0)
        defer { _ = chmod(directory.path, 0o700) }
        XCTAssertThrowsError(try store.upsert(validSpec(id: "lost", title: "Lost"))) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Kaisola could not save terminal themes. The existing registry was left unchanged."
            )
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(store.specs(), [baseline])
    }

    /// The hex parser is strict: a leading # is required, lengths are exact,
    /// and 8 digits carry alpha.
    func testHexParsing() {
        XCTAssertNil(CustomThemeSpec.parseHex("1E1E1E"))
        XCTAssertNil(CustomThemeSpec.parseHex("#1E1E1"))
        XCTAssertNil(CustomThemeSpec.parseHex("#GGGGGG"))
        let opaque = CustomThemeSpec.parseHex("#FF8000")
        XCTAssertEqual(opaque?.red ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(opaque?.green ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(opaque?.alpha ?? 0, 1, accuracy: 0.001)
        let translucent = CustomThemeSpec.parseHex("#FF800080")
        XCTAssertEqual(translucent?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
    }
}
