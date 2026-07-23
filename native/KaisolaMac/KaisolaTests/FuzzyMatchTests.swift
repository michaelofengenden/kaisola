import Foundation
import XCTest
@testable import KaisolaMacPreview

/// The command palette's fuzzy matcher: subsequence matching, ranking, and the
/// boundary/contiguity/prefix bonuses that order results.
final class FuzzyMatchTests: XCTestCase {

    func testEmptyQueryMatchesEverythingWithZeroScore() {
        XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "anything"), 0)
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatch.score(query: "nt", candidate: "New Terminal"))
        XCTAssertNotNil(FuzzyMatch.score(query: "chat", candidate: "Chat with Claude"))
    }

    func testNonSubsequenceDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.score(query: "zzz", candidate: "New Terminal"))
        // Query longer than candidate can never match.
        XCTAssertNil(FuzzyMatch.score(query: "terminal", candidate: "term"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(query: "NEW", candidate: "new terminal"))
        XCTAssertNotNil(FuzzyMatch.score(query: "new", candidate: "NEW TERMINAL"))
    }

    func testWordBoundaryBeatsMidWordMatch() {
        // "op" should rank "Open Project" (both at word starts) above "Stop Loop".
        let boundary = FuzzyMatch.score(query: "op", candidate: "Open Project")
        let midWord = FuzzyMatch.score(query: "op", candidate: "Stop Loop")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(midWord)
        XCTAssertGreaterThan(boundary!, midWord!)
    }

    func testContiguousBeatsScattered() {
        let contiguous = FuzzyMatch.score(query: "chat", candidate: "Chat")
        let scattered = FuzzyMatch.score(query: "chat", candidate: "Cache heater")
        XCTAssertNotNil(contiguous)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(contiguous!, scattered!)
    }

    func testShorterCandidateWinsOnTie() {
        let short = FuzzyMatch.score(query: "new", candidate: "New")
        let long = FuzzyMatch.score(query: "new", candidate: "New Terminal Session")
        XCTAssertNotNil(short)
        XCTAssertNotNil(long)
        XCTAssertGreaterThan(short!, long!)
    }

    func testMatchesHelper() {
        XCTAssertTrue(FuzzyMatch.matches(query: "nt", candidate: "New Terminal"))
        XCTAssertFalse(FuzzyMatch.matches(query: "xy", candidate: "New Terminal"))
    }
}
