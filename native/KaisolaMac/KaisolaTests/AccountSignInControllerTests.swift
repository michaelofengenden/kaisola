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
