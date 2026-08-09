import XCTest
@testable import Kaisola

/// Signing in happens inside Settings, which is only possible because the
/// provider CLIs' flow is predictable: print an OAuth URL, then block on stdin
/// for a pasted code. These cover the two readings that drive the sheet.
final class AccountSignInControllerTests: XCTestCase {
    /// The real first lines of `claude auth login --claudeai`, captured from
    /// the CLI. The URL must come back whole — a truncated `code_challenge`
    /// produces a sign-in page that fails at the end rather than the start.
    func testTheOAuthURLIsLiftedWholeOutOfTheClaudeBanner() throws {
        let output = """
        Opening browser to sign in…
        If the browser didn't open, visit: \
        https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&\
        response_type=code&scope=org%3Acreate_api_key+user%3Aprofile&\
        code_challenge=07J1eR7wXRb0WXREhNtNHpClCE0XWlBvqbTlhVoqGBo&\
        code_challenge_method=S256&state=GFNgPs8Yr5UxmyrO7A1VIlprWr0AY8y2F
        Paste code here if prompted >
        """
        let url = try XCTUnwrap(AccountSignInController.signInURL(in: output))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "claude.com")
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("code_challenge_method=S256"))
        XCTAssertTrue(query.contains("state=GFNgPs8Yr5UxmyrO7A1VIlprWr0AY8y2F"))
    }

    func testTrailingSentencePunctuationIsNotPartOfTheURL() throws {
        let url = try XCTUnwrap(
            AccountSignInController.signInURL(in: "Visit https://example.com/auth?a=1.")
        )
        XCTAssertEqual(url.absoluteString, "https://example.com/auth?a=1")
    }

    func testOutputWithNoURLYieldsNone() {
        XCTAssertNil(AccountSignInController.signInURL(in: "Opening browser to sign in…"))
    }

    /// The code field unlocks on this and nothing else. Codex runs a local
    /// callback and never prints it, which is why the field must stay locked
    /// rather than inviting a paste that would go nowhere.
    func testTheCodePromptIsWhatUnlocksTheCodeField() {
        XCTAssertTrue(AccountSignInController.promptsForCode("Paste code here if prompted > "))
        XCTAssertTrue(AccountSignInController.promptsForCode("PASTE CODE"))
        XCTAssertFalse(AccountSignInController.promptsForCode("Opening browser to sign in…"))
        XCTAssertFalse(
            AccountSignInController.promptsForCode("Waiting for the browser to finish…"),
            "Codex's callback flow never asks for a code"
        )
    }

    /// A failure should say what the CLI said. An exit code alone tells the
    /// user nothing they can act on.
    func testFailureQuotesTheCLIRatherThanAnExitCode() {
        XCTAssertEqual(
            AccountSignInController.failureMessage(
                transcript: "Opening browser…\nOAuth error: invalid_grant\n",
                status: 1
            ),
            "OAuth error: invalid_grant"
        )
    }

    func testFailureFallsBackToTheStatusWhenTheCLISaidNothingUseful() {
        let message = AccountSignInController.failureMessage(
            transcript: "Paste code here if prompted > ",
            status: 130
        )
        XCTAssertEqual(message, "Sign-in did not complete (exit code 130).")
    }

    // The sheet reads the CLI over a pipe, and a pipe read ends wherever the
    // kernel filled it, not on a character boundary. The rest of this class
    // pins the reading down at every boundary there is, because the failure it
    // replaced was silent: the chunk holding half a `…` was dropped whole,
    // taking the OAuth URL or the error line with it.

    /// The shape of a real `claude auth login` banner, carrying a character of
    /// every width: `…` and `✓` at three bytes, `é` at two, `🔐` at four.
    private let banner = """
    Opening browser to sign in…
    If the browser didn't open, visit: \
    https://claude.com/cai/oauth/authorize?code=true&\
    code_challenge=07J1eR7wXRb0WXREhNtNHpClCE0XWlBvqbTlhVoqGBo&state=GFNgPs8Yr5Ux
    Signed in as café ✓ 🔐
    Paste code here if prompted >
    """

    /// Feed `text` through the loop that actually ships, one `chunkSize` read at
    /// a time, and collect what it hands over.
    private func drained(_ text: String, chunkSize: Int) throws -> [String] {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        var received: [String] = []
        AccountSignInController.drain(pipe.fileHandleForReading, chunkSize: chunkSize) {
            received.append($0)
        }
        try pipe.fileHandleForReading.close()
        return received
    }

    /// Every chunk size from one byte upwards, which is every place a multibyte
    /// character can be cut in two.
    func testTheBannerSurvivesAReadEndingAtEveryByteBoundary() throws {
        for chunkSize in 1...Data(banner.utf8).count {
            let text = try drained(banner, chunkSize: chunkSize).joined()
            XCTAssertEqual(text, banner, "lost text at a \(chunkSize)-byte read")
        }
    }

    /// The two readings that drive the sheet have to survive the same cuts:
    /// a truncated `code_challenge` produces a sign-in page that fails at the
    /// end, and a lost prompt leaves the code field locked forever.
    func testTheURLAndTheCodePromptSurviveEveryByteBoundary() throws {
        let whole = try XCTUnwrap(AccountSignInController.signInURL(in: banner))
        for chunkSize in 1...Data(banner.utf8).count {
            let text = try drained(banner, chunkSize: chunkSize).joined()
            XCTAssertEqual(
                AccountSignInController.signInURL(in: text)?.absoluteString,
                whole.absoluteString,
                "the OAuth URL did not come back whole at a \(chunkSize)-byte read"
            )
            XCTAssertTrue(
                AccountSignInController.promptsForCode(text),
                "the code prompt was lost at a \(chunkSize)-byte read"
            )
        }
    }

    /// Split every character at every one of its internal byte boundaries,
    /// straight through the decoder, so the guarantee is stated on the type and
    /// not only on the loop that uses it.
    func testTheDecoderRejoinsACharacterCutAtAnyPointInIt() {
        let bytes = Array(banner.utf8)
        for split in 1..<bytes.count {
            var decoder = IncrementalUTF8Decoder()
            let head = decoder.decode(Data(bytes[..<split]))
            let tail = decoder.decode(Data(bytes[split...]))
            XCTAssertEqual(head + tail + decoder.flush(), banner, "split at byte \(split)")
        }
    }

    /// A character the CLI never finished sending is broken input, and broken
    /// input should be visible. Dropping it is how a truncated URL used to look
    /// like a working one.
    func testACharacterTruncatedAtEOFIsMarkedRatherThanDropped() {
        var decoder = IncrementalUTF8Decoder()
        // "ok " followed by the first two bytes of a three-byte "…".
        let truncated = Data([0x6F, 0x6B, 0x20, 0xE2, 0x80])
        XCTAssertEqual(decoder.decode(truncated), "ok ")
        XCTAssertEqual(decoder.flush(), "\u{FFFD}")
        XCTAssertEqual(decoder.flush(), "", "the carry is spent once")
    }

    /// A byte that can never start a character is not an unfinished one, so it
    /// must not be held back — carrying it would stall everything after it.
    func testAnImpossibleByteDoesNotStallTheStream() {
        var decoder = IncrementalUTF8Decoder()
        let text = decoder.decode(Data([0x41, 0xFF, 0x42]))
        XCTAssertTrue(text.hasPrefix("A"), text)
        XCTAssertTrue(text.hasSuffix("B"), "text after a bad byte still arrives now: \(text)")
        XCTAssertEqual(decoder.flush(), "")
    }

    /// Nothing carried, nothing said.
    func testAnEmptyStreamSaysNothing() throws {
        XCTAssertEqual(try drained("", chunkSize: 8_192), [])
        var decoder = IncrementalUTF8Decoder()
        XCTAssertEqual(decoder.decode(Data()), "")
        XCTAssertEqual(decoder.flush(), "")
    }
}

/// A reset time is said the way its horizon is useful: a countdown when you
/// might wait for it, a clock time when you would plan around it.
final class SubscriptionResetCaptionTests: XCTestCase {
    /// A fixed calendar so the assertions do not move with the runner's zone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Monday 3 August 2026, 09:00 UTC.
    private lazy var now = calendar.date(from: DateComponents(
        year: 2026, month: 8, day: 3, hour: 9, minute: 0
    ))!

    private func caption(at date: Date) -> String? {
        SubscriptionUsageMeter.resetCaption(
            resetsAt: date.timeIntervalSince1970, now: now, calendar: calendar
        )
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    /// Under twelve hours you are deciding whether to wait, so it counts down.
    func testNearTermResetsCountDown() {
        XCTAssertEqual(caption(at: now.addingTimeInterval(40 * 60)), "in 40m")
        XCTAssertEqual(caption(at: now.addingTimeInterval(3 * 3_600)), "in 3h")
        XCTAssertEqual(caption(at: now.addingTimeInterval(11 * 3_600)), "in 11h")
    }

    /// Later today needs no day name — the time is the whole answer.
    func testLaterTodayIsJustTheTime() throws {
        let text = try XCTUnwrap(caption(at: date(8, 3, 23)))
        XCTAssertFalse(text.hasPrefix("in "), text)
        XCTAssertFalse(text.contains("Mon"), "today does not need naming: \(text)")
        XCTAssertTrue(text.contains("11") || text.contains("23"), text)
    }

    /// Within the week the weekday carries it.
    func testThisWeekNamesTheDay() throws {
        let text = try XCTUnwrap(caption(at: date(8, 5, 15)))
        XCTAssertTrue(text.contains("Wed"), text)
    }

    /// "3:00 PM" spends four characters saying nothing. A reset on the hour
    /// says the hour; one at 11:59 keeps its minutes.
    func testMinutesAppearOnlyWhenTheyCarryInformation() throws {
        let onTheHour = try XCTUnwrap(caption(at: date(8, 5, 15)))
        XCTAssertFalse(onTheHour.contains(":"), "an on-the-hour reset needs no minutes: \(onTheHour)")

        let awkward = try XCTUnwrap(caption(at: date(8, 5, 23, 59)))
        XCTAssertTrue(awkward.contains(":59"), "a reset at 11:59 must keep its minutes: \(awkward)")
    }

    /// Beyond the week a weekday stops locating anything, so the date does.
    func testFarOutResetsUseTheDate() throws {
        let text = try XCTUnwrap(caption(at: date(8, 20, 12)))
        XCTAssertTrue(text.contains("20"), text)
        XCTAssertFalse(text.hasPrefix("in "), text)
    }

    /// The row is narrow, so the caption must stay short enough to fit its
    /// column — this is what stopped it truncating away entirely.
    func testEveryCaptionStaysShort() {
        let samples = [
            now.addingTimeInterval(40 * 60),
            now.addingTimeInterval(11 * 3_600),
            date(8, 3, 23),
            date(8, 5, 15),
            date(8, 5, 23, 59),
            date(8, 20, 12),
        ]
        for sample in samples {
            let text = caption(at: sample) ?? ""
            XCTAssertLessThanOrEqual(text.count, 12, "too wide for its column: \(text)")
        }
    }

    /// An elapsed or missing reset says nothing rather than counting backwards.
    func testNothingIsSaidWithoutALiveReset() {
        XCTAssertNil(SubscriptionUsageMeter.resetCaption(resetsAt: nil, now: now, calendar: calendar))
        XCTAssertNil(SubscriptionUsageMeter.resetCaption(resetsAt: 0, now: now, calendar: calendar))
        XCTAssertNil(caption(at: now.addingTimeInterval(-60)))
    }

    /// The shorthand is for the row; the full sentence is one hover away.
    func testTheTooltipSpellsItOut() throws {
        let text = try XCTUnwrap(SubscriptionUsageMeter.resetDescription(
            resetsAt: date(8, 5, 15).timeIntervalSince1970, now: now, calendar: calendar
        ))
        XCTAssertTrue(text.hasPrefix("Resets "), text)
        XCTAssertTrue(text.contains("Wednesday"), "the tooltip is unabbreviated: \(text)")
        XCTAssertTrue(text.contains("—"), "it also says how far off that is: \(text)")
    }

    func testNoTooltipForAnElapsedReset() {
        XCTAssertNil(SubscriptionUsageMeter.resetDescription(
            resetsAt: now.addingTimeInterval(-60).timeIntervalSince1970, now: now, calendar: calendar
        ))
    }
}
