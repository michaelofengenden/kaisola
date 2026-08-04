import XCTest
@testable import Kaisola

/// Custom grammars: validated with named reasons, scanned by the same
/// never-crash pass as shipped languages, and never able to take over a
/// shipped extension.
final class CustomGrammarRegistryTests: XCTestCase {
    private func temporaryStore() throws -> CustomGrammarStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-grammars-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CustomGrammarStore(fileURL: directory.appending(path: "custom-grammars.json"))
    }

    private func tomlGrammar() -> CustomGrammarSpec {
        CustomGrammarSpec(
            id: "toml",
            title: "TOML",
            extensions: ["toml"],
            fences: ["toml"],
            rules: [
                .init(pattern: "#[^\\n]*", role: "comment", context: true),
                .init(pattern: "\"(?:\\\\.|[^\"\\\\\\n])*\"", role: "string", context: true),
                .init(pattern: "^\\s*\\[[^\\]\\n]*\\]", role: "tag", anchorsMatchLines: true),
                .init(pattern: "^[A-Za-z0-9_.-]+(?=\\s*=)", role: "keyword", anchorsMatchLines: true),
                .init(pattern: "\\b\\d[\\d_]*(?:\\.\\d+)?\\b", role: "number"),
            ]
        )
    }

    /// The guard that keeps `shippedExtensions` honest: it must contain
    /// exactly the extensions the shipped table answers for.
    func testShippedExtensionsMatchTheShippedTable() {
        for ext in SyntaxHighlighter.shippedExtensions {
            XCTAssertNotNil(
                SyntaxHighlighter.language(forExtension: ext),
                "\(ext) is declared shipped but the table does not answer for it"
            )
        }
        for probe in ["toml", "rs", "go", "rb", "unknown"] {
            XCTAssertNil(SyntaxHighlighter.language(forExtension: probe))
            XCTAssertFalse(SyntaxHighlighter.shippedExtensions.contains(probe))
        }
    }

    func testACustomGrammarHighlightsItsOwnExtensionAndFence() throws {
        let store = try temporaryStore()
        XCTAssertNil(store.upsert(tomlGrammar()))

        let byExtension = SyntaxHighlighter.grammar(forExtension: "TOML", store: store)
        XCTAssertEqual(byExtension, .custom(id: "toml", rules: []))
        let byFence = SyntaxHighlighter.grammar(forFence: "toml", store: store)
        XCTAssertEqual(byFence, .custom(id: "toml", rules: []))

        let source = """
        # config
        [server]
        port = 8080
        name = "kaisola"
        """
        let spans = SyntaxHighlighter.spans(in: source, rules: byExtension?.rules ?? [])
        XCTAssertTrue(spans.contains { $0.role == .comment }, "the comment rule never fired")
        XCTAssertTrue(spans.contains { $0.role == .tag }, "the table-header rule never fired")
        XCTAssertTrue(spans.contains { $0.role == .keyword }, "the key rule never fired")
        XCTAssertTrue(spans.contains { $0.role == .string }, "the string rule never fired")
    }

    /// The shipped table always wins: a custom grammar claiming "swift" is
    /// invalid, and even a stale cache can never shadow a shipped language
    /// because resolution checks shipped first.
    func testShippedExtensionsCannotBeTakenOver() throws {
        let store = try temporaryStore()
        var greedy = tomlGrammar()
        greedy.extensions = ["swift"]
        let reason = store.upsert(greedy)
        XCTAssertTrue(reason?.contains("built-in") == true, String(describing: reason))
        XCTAssertEqual(SyntaxHighlighter.grammar(forExtension: "swift", store: store), .shipped(.swift))
    }

    func testInvalidGrammarsNameTheirReason() {
        var spec = tomlGrammar()
        spec.rules[0].pattern = "([unclosed"
        XCTAssertTrue(spec.validationError?.contains("does not compile") == true)

        spec = tomlGrammar()
        spec.rules[0].role = "rainbow"
        XCTAssertTrue(spec.validationError?.contains("not a color role") == true)

        spec = tomlGrammar()
        spec.extensions = []
        XCTAssertEqual(spec.validationError, "The grammar claims no file extensions.")

        spec = tomlGrammar()
        spec.rules = Array(repeating: spec.rules[0], count: CustomGrammarSpec.maximumRules + 1)
        XCTAssertTrue(spec.validationError?.contains("at most") == true)

        XCTAssertNil(tomlGrammar().validationError)
    }

    /// An invalid grammar is kept for the settings roster and skipped by the
    /// cache — its extension resolves to plain text, not to a half-working
    /// grammar.
    func testAnInvalidGrammarIsKeptButNeverInstalled() throws {
        let store = try temporaryStore()
        var broken = tomlGrammar()
        broken.rules[0].pattern = "([unclosed"
        XCTAssertNotNil(store.upsert(broken))
        XCTAssertEqual(store.specs().count, 1)
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
    }

    /// The cache re-reads when the store file changes, so an import or
    /// removal is visible without a relaunch.
    func testTheCacheFollowsStoreChanges() throws {
        let store = try temporaryStore()
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
        store.upsert(tomlGrammar())
        XCTAssertNotNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
        store.remove(id: "toml")
        XCTAssertNil(SyntaxHighlighter.grammar(forExtension: "toml", store: store))
    }
}
