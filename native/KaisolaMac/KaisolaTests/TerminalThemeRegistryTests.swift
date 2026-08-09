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
        let store = CustomThemeStore(fileURL: directory.appending(path: "terminal-themes.json"))
        addTeardownBlock {
            // The last-good cache is process-wide; a suite that leaves entries
            // behind would let one test's themes answer another test's read.
            LastGoodCustomThemes.shared.forget(store.fileURL)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        return store
    }

    /// Files this build cannot read are preserved as `<name>.corrupt-<stamp>.json`
    /// beside the original, the same convention the workspace archive uses.
    private func preservedCopies(beside store: CustomThemeStore) throws -> [URL] {
        let directory = store.fileURL.deletingLastPathComponent()
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
        XCTAssertNil(store.upsert(validSpec()).validationError)
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
        let result = store.upsert(broken)
        XCTAssertNotNil(result.validationError)
        XCTAssertEqual(result.outcome, .saved)
        XCTAssertEqual(store.specs().count, 1)
        XCTAssertNil(store.specs().first?.asDefinition())
        XCTAssertFalse(TerminalThemeRegistry.all(store: store).contains { $0.id == "broken" })
        XCTAssertEqual(TerminalThemeRegistry.definition(id: "broken", store: store).id, "native")
    }

    func testRemovalIsReversibleAndExact() throws {
        let store = try temporaryStore()
        store.upsert(validSpec(id: "one", title: "One"))
        store.upsert(validSpec(id: "two", title: "Two"))
        XCTAssertEqual(store.remove(id: "one"), .saved)
        XCTAssertEqual(store.specs().map(\.id), ["two"])
        XCTAssertNil(store.remove(id: "one"), "removing twice attempts no write at all")
        store.upsert(validSpec(id: "one", title: "One"))
        XCTAssertEqual(Set(store.specs().map(\.id)), ["one", "two"])
    }

    func testTheStoreIsCapped() throws {
        let store = try temporaryStore()
        store.save((0..<20).map { validSpec(id: "theme-\($0)", title: "Theme \($0)") })
        XCTAssertEqual(store.specs().count, 12, "the cap holds even against a bulk save")
    }

    // MARK: - Damaged registries

    /// A file that stops being readable mid-session must not empty the running
    /// app's theme menu, and the next edit must keep those bytes rather than
    /// rebuild the registry on top of them.
    func testACorruptFileKeepsTheLoadedThemesAndIsPreservedBeforeTheNextWrite() throws {
        let store = try temporaryStore()
        store.upsert(validSpec(id: "midnight", title: "Midnight"))
        XCTAssertEqual(store.specs().map(\.id), ["midnight"])

        let damaged = Data("{ themes: not json".utf8)
        try damaged.write(to: store.fileURL)

        let load = store.load()
        XCTAssertEqual(load.failure, .corruptFile)
        XCTAssertTrue(load.isStale)
        XCTAssertEqual(load.specs.map(\.id), ["midnight"], "the app keeps the themes it already loaded")
        XCTAssertTrue(TerminalThemeRegistry.all(store: store).contains { $0.id == "midnight" })

        let outcome = store.save(load.specs + [validSpec(id: "dawn", title: "Dawn")])
        guard case .savedAfterQuarantine(let preservedCopy) = outcome else {
            return XCTFail("a corrupt file must be preserved before the write, got \(outcome)")
        }
        XCTAssertEqual(try Data(contentsOf: preservedCopy), damaged, "the original bytes survive verbatim")
        XCTAssertEqual(try preservedCopies(beside: store).map(\.lastPathComponent), [preservedCopy.lastPathComponent])

        let reloaded = store.load()
        XCTAssertNil(reloaded.failure)
        XCTAssertEqual(reloaded.specs.map(\.id), ["midnight", "dawn"])
    }

    /// The same damage seen by a process that never read the file: no themes to
    /// show, but an explicit failure rather than a registry that looks empty.
    func testACorruptFileWithNothingLoadedReportsDamageRatherThanEmptiness() throws {
        let store = try temporaryStore()
        try Data("not json".utf8).write(to: store.fileURL)
        LastGoodCustomThemes.shared.forget(store.fileURL)

        let load = store.load()
        XCTAssertEqual(load.specs, [])
        XCTAssertEqual(load.failure, .corruptFile)
        XCTAssertFalse(load.isStale)
        XCTAssertTrue(load.failure?.allowsQuarantine == true)
    }

    /// One malformed record costs that record, not the wardrobe.
    func testOneDamagedRecordKeepsEveryOtherTheme() throws {
        let store = try temporaryStore()
        let encoder = JSONEncoder()
        let one = String(decoding: try encoder.encode(validSpec(id: "one", title: "One")), as: UTF8.self)
        let two = String(decoding: try encoder.encode(validSpec(id: "two", title: "Two")), as: UTF8.self)
        // A record with no palettes at all: the shape a partial write or an
        // older schema leaves behind.
        let file = "{\"schemaVersion\":1,\"themes\":[\(one),{\"id\":\"broken\"},\(two)]}"
        try Data(file.utf8).write(to: store.fileURL)
        LastGoodCustomThemes.shared.forget(store.fileURL)

        let load = store.load()
        XCTAssertEqual(load.specs.map(\.id), ["one", "two"])
        XCTAssertEqual(load.failure, .damagedRecords(kept: 2, dropped: 1))
        XCTAssertFalse(load.isStale)

        let outcome = store.save(load.specs)
        guard case .savedAfterQuarantine(let preservedCopy) = outcome else {
            return XCTFail("the damaged record's bytes must be kept, got \(outcome)")
        }
        XCTAssertTrue(
            String(data: try Data(contentsOf: preservedCopy), encoding: .utf8)?.contains("broken") == true,
            "the record this build dropped is still recoverable from the kept copy"
        )
        XCTAssertNil(store.load().failure)
    }

    /// A registry written by a newer Kaisola is good data this build must not
    /// reinterpret: no quarantine, no write, and the file byte-for-byte intact.
    func testAFutureSchemaIsRefusedAndLeftUntouched() throws {
        let store = try temporaryStore()
        let future = Data("{\"schemaVersion\":99,\"themes\":[]}".utf8)
        try future.write(to: store.fileURL)
        LastGoodCustomThemes.shared.forget(store.fileURL)

        let load = store.load()
        XCTAssertEqual(load.failure, .newerVersion(schemaVersion: 99))
        XCTAssertFalse(load.failure?.allowsQuarantine == true)

        XCTAssertEqual(
            store.upsert(validSpec()).outcome,
            .refused(.newerVersion(schemaVersion: 99))
        )
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future, "the newer version's file is untouched")
        XCTAssertEqual(try preservedCopies(beside: store), [], "good data is never moved aside")
    }

    /// A registry written before the version key existed is schema 1, and the
    /// next write stamps it without disturbing the themes.
    func testAnUnversionedRegistryMigratesInPlace() throws {
        let store = try temporaryStore()
        let legacy = try JSONEncoder().encode(["themes": [validSpec(id: "legacy", title: "Legacy")]])
        try legacy.write(to: store.fileURL)
        LastGoodCustomThemes.shared.forget(store.fileURL)

        let load = store.load()
        XCTAssertNil(load.failure)
        XCTAssertEqual(load.specs.map(\.id), ["legacy"])

        XCTAssertEqual(store.upsert(validSpec(id: "modern", title: "Modern")).outcome, .saved)
        let stamped = try JSONSerialization.jsonObject(with: try Data(contentsOf: store.fileURL)) as? [String: Any]
        XCTAssertEqual(stamped?["schemaVersion"] as? Int, CustomThemeStore.schemaVersion)
        XCTAssertEqual(store.specs().map(\.id), ["legacy", "modern"])
    }

    /// Storage that cannot be written says so instead of pretending the theme
    /// was saved — the settings row's "Not saved" line is this outcome.
    func testAnUnwritableStoreReportsTheFailureAndKeepsWhatIsStored() throws {
        let store = try temporaryStore()
        store.upsert(validSpec(id: "midnight", title: "Midnight"))
        let stored = try Data(contentsOf: store.fileURL)

        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        let result = store.upsert(validSpec(id: "dawn", title: "Dawn"))
        XCTAssertNil(result.validationError)
        guard case .writeFailed(let reason) = result.outcome else {
            return XCTFail("an unwritable directory must report a failed write, got \(result.outcome)")
        }
        XCTAssertFalse(reason.isEmpty, "the settings row shows this reason verbatim")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), stored, "the stored registry is untouched")
        XCTAssertEqual(store.specs().map(\.id), ["midnight"])
    }

    /// The strings the settings recovery row renders. Each failure has to name
    /// what happened to the file, because "your themes are gone" with no
    /// explanation is the state this whole path exists to prevent.
    func testEveryFailureExplainsItselfAndItsRecovery() {
        XCTAssertTrue(CustomThemeStoreFailure.corruptFile.message.contains("keeps a copy"))
        XCTAssertTrue(CustomThemeStoreFailure.damagedRecords(kept: 2, dropped: 1).message.contains("1 of 3"))
        XCTAssertTrue(CustomThemeStoreFailure.newerVersion(schemaVersion: 99).message.contains("aren't being saved"))
        XCTAssertTrue(CustomThemeStoreFailure.unreadable(reason: "the disk is gone").message.contains("the disk is gone"))
        for failure: CustomThemeStoreFailure in [
            .corruptFile,
            .damagedRecords(kept: 1, dropped: 1),
            .newerVersion(schemaVersion: 99),
            .unreadable(reason: "no permission"),
        ] {
            XCTAssertFalse(failure.title.isEmpty)
        }
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
