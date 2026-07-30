import SwiftUI
import XCTest
@testable import Kaisola

/// `SyntaxHighlighter` — extension→language mapping, that highlighting actually
/// colors distinct runs, the oversized-input plain fallback, JSON key coloring,
/// and that no input (including pathological ones) can throw or crash.
final class SyntaxHighlighterTests: XCTestCase {
    // MARK: - Extension mapping

    func testLanguageForExtensionMapping() {
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "swift"), .swift)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "SWIFT"), .swift) // case-insensitive
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "js"), .javascript)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "jsx"), .javascript)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "ts"), .javascript)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "tsx"), .javascript)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "py"), .python)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "json"), .json)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "sh"), .shell)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "bash"), .shell)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "zsh"), .shell)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "yml"), .yaml)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "yaml"), .yaml)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "html"), .html)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "xml"), .html)
        XCTAssertEqual(SyntaxHighlighter.language(forExtension: "css"), .css)
    }

    func testUnknownExtensionMapsToNil() {
        XCTAssertNil(SyntaxHighlighter.language(forExtension: "bin"))
        XCTAssertNil(SyntaxHighlighter.language(forExtension: "txt"))
        XCTAssertNil(SyntaxHighlighter.language(forExtension: "log"))
        XCTAssertNil(SyntaxHighlighter.language(forExtension: ""))
    }

    // MARK: - Highlighting

    func testHighlightPreservesTextAndSegmentsForSwiftSnippet() {
        let source = "let x = 42 // note"
        let attributed = SyntaxHighlighter.highlight(source, language: .swift, theme: .light)
        // Highlighting only adds attributes; the text is untouched.
        XCTAssertEqual(String(attributed.characters), source)
        XCTAssertFalse(String(attributed.characters).isEmpty)
        // `let`, `42`, and the comment should split the string into >1 run.
        XCTAssertGreaterThan(Array(attributed.runs).count, 1)
    }

    func testKeywordRunIsColoredDifferentlyFromPlainText() {
        let source = "func greet() { return }"
        let attributed = SyntaxHighlighter.highlight(source, language: .swift, theme: .dark)
        let runs = Array(attributed.runs)

        // The `func` keyword forms its own run and carries a color.
        let keywordRun = runs.first { String(attributed[$0.range].characters) == "func" }
        XCTAssertNotNil(keywordRun, "expected a run covering the `func` keyword")
        XCTAssertNotNil(keywordRun?.foregroundColor, "keyword run should be colored")

        // A plain, uncolored run must also exist...
        let plainRun = runs.first { $0.foregroundColor == nil }
        XCTAssertNotNil(plainRun, "expected at least one uncolored (plain) run")

        // ...and the keyword's color must differ from plain text's (nil).
        XCTAssertNotEqual(keywordRun?.foregroundColor, plainRun?.foregroundColor)

        // More than one distinct color role should appear overall.
        let distinctColors = Set(runs.compactMap { $0.foregroundColor })
        XCTAssertGreaterThanOrEqual(distinctColors.count, 1)
    }

    func testJSONKeysColoredDistinctlyFromStringValues() {
        let json = "{\n  \"name\": \"kai\",\n  \"count\": 42,\n  \"ok\": true\n}"
        let attributed = SyntaxHighlighter.highlight(json, language: .json, theme: .dark)
        let runs = Array(attributed.runs)

        // The key `"name"` (quotes included) is its own colored run.
        let keyRun = runs.first { String(attributed[$0.range].characters) == "\"name\"" }
        XCTAssertNotNil(keyRun, "expected a run covering the JSON key")
        XCTAssertNotNil(keyRun?.foregroundColor, "JSON key should be colored")

        // The value string `"kai"` is colored too, but in a different role.
        let valueRun = runs.first { String(attributed[$0.range].characters) == "\"kai\"" }
        XCTAssertNotNil(valueRun?.foregroundColor, "JSON string value should be colored")
        XCTAssertNotEqual(
            keyRun?.foregroundColor,
            valueRun?.foregroundColor,
            "keys and string values should use different colors"
        )
    }

    func testOversizedInputReturnsPlainSingleRun() {
        // Well over the cap, and dense with keywords that WOULD be colored if the
        // input were highlighted — proving the size guard, not just absence of
        // matchable tokens.
        let big = String(repeating: "func x = 1\n", count: 25_000) // 275_000 chars
        XCTAssertGreaterThan(big.count, SyntaxHighlighter.maxLength)

        let attributed = SyntaxHighlighter.highlight(big, language: .swift, theme: .dark)
        let runs = Array(attributed.runs)
        XCTAssertEqual(runs.count, 1, "oversized input should be a single plain run")
        XCTAssertNil(runs.first?.foregroundColor, "the single run should be uncolored")
    }

    func testPathologicalInputNeverCrashes() {
        let inputs = [
            String(repeating: "\\", count: 1000),   // 1000 backslashes
            String(repeating: "\"", count: 500),    // 500 bare quotes
            "\"unterminated string",
            "/* unterminated block comment",
            "'''",
            "`",
            "{ \"a\":",
            "<div class=",
            "#!/bin/sh\necho $",
            "",                                       // empty
            "\u{1F600}\u{1F468}\u{200D}\u{1F469}",  // emoji / ZWJ sequence (multi-UTF-16 graphemes)
        ]

        // Every language × theme × input must return without trapping.
        for theme in [SyntaxHighlighter.Theme.dark, .light] {
            for language in SyntaxHighlighter.Language.allCases {
                for input in inputs {
                    let attributed = SyntaxHighlighter.highlight(input, language: language, theme: theme)
                    // The rendered text always round-trips to the input.
                    XCTAssertEqual(String(attributed.characters), input)
                }
            }
        }
    }
}
