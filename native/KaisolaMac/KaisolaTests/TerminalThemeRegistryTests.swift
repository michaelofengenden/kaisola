import XCTest
@testable import Kaisola

/// The theme registry: shipped themes must mean exactly what the old
/// hardcoded modes meant, custom themes must be validated with named reasons,
/// and every failure must degrade to a disabled row rather than a broken
/// terminal.
final class TerminalThemeRegistryTests: XCTestCase {
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
        XCTAssertNil(store.upsert(validSpec()))
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
        let reason = store.upsert(broken)
        XCTAssertNotNil(reason)
        XCTAssertEqual(store.specs().count, 1)
        XCTAssertNil(store.specs().first?.asDefinition())
        XCTAssertFalse(TerminalThemeRegistry.all(store: store).contains { $0.id == "broken" })
        XCTAssertEqual(TerminalThemeRegistry.definition(id: "broken", store: store).id, "native")
    }

    func testRemovalIsReversibleAndExact() throws {
        let store = try temporaryStore()
        store.upsert(validSpec(id: "one", title: "One"))
        store.upsert(validSpec(id: "two", title: "Two"))
        XCTAssertTrue(store.remove(id: "one"))
        XCTAssertEqual(store.specs().map(\.id), ["two"])
        XCTAssertFalse(store.remove(id: "one"), "removing twice reports nothing happened")
        store.upsert(validSpec(id: "one", title: "One"))
        XCTAssertEqual(Set(store.specs().map(\.id)), ["one", "two"])
    }

    func testTheStoreIsCappedAndSurvivesCorruption() throws {
        let store = try temporaryStore()
        store.save((0..<20).map { validSpec(id: "theme-\($0)", title: "Theme \($0)") })
        XCTAssertEqual(store.specs().count, 12, "the cap holds even against a bulk save")

        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.specs(), [], "a corrupt file reads as empty, never a crash")
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
