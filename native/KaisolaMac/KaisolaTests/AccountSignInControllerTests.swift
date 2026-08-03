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
    private let now = Date(timeIntervalSince1970: 1_785_700_000)

    private func caption(inSeconds: TimeInterval) -> String? {
        SubscriptionUsageMeter.resetCaption(
            resetsAt: now.addingTimeInterval(inSeconds).timeIntervalSince1970,
            now: now
        )
    }

    func testMinutesAndHoursCountDown() {
        XCTAssertEqual(caption(inSeconds: 40 * 60), "in 40m")
        XCTAssertEqual(caption(inSeconds: 3 * 3_600), "in 3h")
        XCTAssertEqual(caption(inSeconds: 11 * 3_600), "in 11h")
    }

    /// Past twelve hours a countdown stops helping: "in 2d" covers a span of
    /// forty-eight hours, so the clock takes over.
    func testLongerHorizonsBecomeAClockTime() throws {
        let sameWeek = try XCTUnwrap(caption(inSeconds: 2 * 86_400))
        XCTAssertFalse(sameWeek.hasPrefix("in "), "got \(sameWeek)")
        XCTAssertTrue(sameWeek.contains(":"), "a weekday reset names its time: \(sameWeek)")

        let farOut = try XCTUnwrap(caption(inSeconds: 20 * 86_400))
        XCTAssertFalse(farOut.hasPrefix("in "), "got \(farOut)")
    }

    /// An elapsed or missing reset says nothing rather than counting backwards.
    func testNothingIsSaidWithoutALiveReset() {
        XCTAssertNil(SubscriptionUsageMeter.resetCaption(resetsAt: nil, now: now))
        XCTAssertNil(SubscriptionUsageMeter.resetCaption(resetsAt: 0, now: now))
        XCTAssertNil(caption(inSeconds: -60))
    }
}

/// Locating the provider CLI. A GUI app inherits `/usr/bin:/bin`, and a
/// non-interactive login shell never sources `~/.zshrc` — where nvm, conda,
/// npm-global and mise all write PATH — so the tool has to be found before it
/// can be run.
final class AccountSignInExecutableTests: XCTestCase {
    /// The real answer, alone on a line.
    func testAPlainPathIsTaken() {
        XCTAssertEqual(
            AccountSignInController.firstExecutablePath(in: "/opt/homebrew/bin/claude\n"),
            "/opt/homebrew/bin/claude"
        )
    }

    /// An interactive shell prints whatever the user's startup files print —
    /// conda banners, version-manager notices, MOTDs. The path is the last
    /// absolute token, not the first line.
    func testShellStartupNoiseIsSkipped() {
        let output = """
        Using node v22.3.0 (npm v10.8.1)
        (base) conda environment activated
        /Users/x/miniforge3/bin/claude
        """
        XCTAssertEqual(
            AccountSignInController.firstExecutablePath(in: output),
            "/Users/x/miniforge3/bin/claude"
        )
    }

    /// `command -v` prints nothing when the tool is missing — which is exactly
    /// what the GUI environment produced, and what must now be reported rather
    /// than run as a bare name.
    func testNothingFoundIsNil() {
        XCTAssertNil(AccountSignInController.firstExecutablePath(in: ""))
        XCTAssertNil(AccountSignInController.firstExecutablePath(in: "claude not found\n"))
    }

    /// A shell alias or function prints prose, not a path; it is not a binary
    /// we can exec.
    func testAnAliasLineIsNotMistakenForAPath() {
        XCTAssertNil(
            AccountSignInController.firstExecutablePath(in: "claude: aliased to /usr/bin/env claude")
        )
    }

    func testToolNamesMatchTheProviders() {
        XCTAssertEqual(AccountSignInController.toolName(for: .claude), "claude")
        XCTAssertEqual(AccountSignInController.toolName(for: .codex), "codex")
    }
}
