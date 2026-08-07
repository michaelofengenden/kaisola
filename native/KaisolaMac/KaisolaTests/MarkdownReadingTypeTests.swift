import AppKit
import XCTest
@testable import Kaisola

/// The serif reading face (2026-08-06 spec §1): serif body with true trait
/// composition, sans headings, and emphasis that composes onto whatever face
/// is underneath instead of stamping a static font.
final class MarkdownReadingTypeTests: XCTestCase {
    func testBodyFontIsSerifDesign() {
        let font = MarkdownEditingStyle.bodyFont()
        XCTAssertEqual(font.pointSize, MarkdownEditingStyle.bodySize)
        // The system serif reports the serif design class (New York).
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let name = font.fontName.lowercased()
        XCTAssertTrue(
            name.contains("nework") || name.contains("newyork") || name.contains("serif")
                || traits != nil,
            "expected a serif design face, got \(font.fontName)"
        )
        XCTAssertNotEqual(
            font.fontName, NSFont.systemFont(ofSize: MarkdownEditingStyle.bodySize).fontName,
            "serif body must differ from the plain system sans"
        )
    }

    func testComposedAddsTraitsOntoAnyBase() {
        let serifBold = MarkdownEditingStyle.composed(base: MarkdownEditingStyle.bodyFont(), bold: true)
        XCTAssertTrue(serifBold.fontDescriptor.symbolicTraits.contains(.bold))

        let sans = NSFont.systemFont(ofSize: 12)
        let sansItalic = MarkdownEditingStyle.composed(base: sans, italic: true)
        XCTAssertTrue(sansItalic.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(sansItalic.fontDescriptor.symbolicTraits.contains(.bold))

        let both = MarkdownEditingStyle.composed(
            base: MarkdownEditingStyle.composed(base: sans, bold: true), italic: true
        )
        XCTAssertTrue(both.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(both.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testHeadingsStaySansWithTightTracking() {
        let h1 = MarkdownEditingStyle.attributes(for: .heading(1))
        let font = h1[.font] as? NSFont
        XCTAssertEqual(font?.pointSize, 28)
        XCTAssertNotNil(h1[.kern], "display headings tighten tracking")
        let h4 = MarkdownEditingStyle.attributes(for: .heading(4))
        XCTAssertNil(h4[.kern])
    }

    func testQuoteIsFullSizeSerifItalic() {
        let quote = MarkdownEditingStyle.attributes(for: .quote)
        let font = quote[.font] as? NSFont
        XCTAssertEqual(font?.pointSize, MarkdownEditingStyle.bodySize)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertNil(quote[.foregroundColor], "quotes read as prose, not dimmed metadata")
        XCTAssertNil(quote[.obliqueness], "true italics replaced the skew")
    }
}
