import Darwin
import XCTest
@testable import Kaisola

/// Signing in happens inside Settings, which is only possible because the
/// provider CLIs' flow is predictable: print an OAuth URL, then block on stdin
/// for a pasted code. These cover the two readings that drive the sheet.
final class AccountSignInControllerTests: XCTestCase {
    private func accountDirectory(_ suffix: String = UUID().uuidString) -> URL {
        URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("kaisola-account-tests-\(suffix)", isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        return value.intValue & 0o777
    }

    func testExistingAccountDirectoryIsTightenedToOwnerOnly() throws {
        let directory = accountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path
        )

        let prepared = try AccountSignInController.prepareAccountDirectory(at: directory)

        XCTAssertEqual(prepared.path, directory.path)
        XCTAssertEqual(try permissions(at: directory), 0o700)
    }

    func testEveryNewAccountDirectoryComponentIsOwnerOnly() throws {
        let root = accountDirectory()
        let parent = root.appendingPathComponent("profiles", isDirectory: true)
        let directory = parent.appendingPathComponent("work", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try AccountSignInController.prepareAccountDirectory(at: directory)

        XCTAssertEqual(try permissions(at: root), 0o700)
        XCTAssertEqual(try permissions(at: parent), 0o700)
        XCTAssertEqual(try permissions(at: directory), 0o700)
    }

    func testAccountDirectoryOwnedByAnotherUserIsRejected() throws {
        let directory = accountDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let userID = geteuid()
        let differentUserID = userID == uid_t.max ? userID - 1 : userID + 1

        XCTAssertThrowsError(
            try AccountSignInController.prepareAccountDirectory(
                at: directory,
                currentUserID: differentUserID
            )
        ) { error in
            XCTAssertEqual(
                error as? AccountSignInController.AccountDirectoryError,
                .wrongOwner(directory.path)
            )
        }
    }

    func testSymlinkInAccountDirectoryPathIsRejected() throws {
        let root = accountDirectory()
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("linked", isDirectory: true)
        let account = link.appendingPathComponent("work", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDirectory)

        XCTAssertThrowsError(
            try AccountSignInController.prepareAccountDirectory(at: account)
        ) { error in
            XCTAssertEqual(
                error as? AccountSignInController.AccountDirectoryError,
                .symbolicLink(link.path)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: realDirectory.appendingPathComponent("work").path)
        )
    }

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
        let url = try XCTUnwrap(
            AccountSignInController.signInURL(in: output, for: .claude)
        )
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "claude.com")
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("code_challenge_method=S256"))
        XCTAssertTrue(query.contains("state=GFNgPs8Yr5UxmyrO7A1VIlprWr0AY8y2F"))
    }

    func testTrailingSentencePunctuationIsNotPartOfTheURL() throws {
        let url = try XCTUnwrap(
            AccountSignInController.signInURL(
                in: "Visit https://claude.com/auth?a=1.",
                for: .claude
            )
        )
        XCTAssertEqual(url.absoluteString, "https://claude.com/auth?a=1")
    }

    func testOutputWithNoURLYieldsNone() {
        XCTAssertNil(
            AccountSignInController.signInURL(
                in: "Opening browser to sign in…",
                for: .claude
            )
        )
    }

    func testProviderSignInURLSkipsMisleadingURLsBeforeAndAfterTheRealURL() throws {
        let real = try XCTUnwrap(
            URL(string: "https://claude.com/cai/oauth/authorize?state=real")
        )
        let misleading = "https://claude.com.evil.example/cai/oauth/authorize?state=phish"

        XCTAssertEqual(
            AccountSignInController.signInURL(
                in: "Debug \(misleading)\nOpen \(real.absoluteString)",
                for: .claude
            ),
            real
        )
        XCTAssertEqual(
            AccountSignInController.signInURL(
                in: "Open \(real.absoluteString)\nDebug https://evil.example/after",
                for: .claude
            ),
            real
        )
    }

    func testProviderSignInURLRejectsLookalikeAndOtherProviderHosts() throws {
        let codexURL = try XCTUnwrap(
            URL(string: "https://auth.openai.com/oauth/authorize?state=codex")
        )
        let output = """
        https://claude.com.evil.example/cai/oauth/authorize
        https://auth.openai.com/oauth/authorize?state=codex
        """

        XCTAssertNil(AccountSignInController.signInURL(in: output, for: .claude))
        XCTAssertEqual(AccountSignInController.signInURL(in: output, for: .codex), codexURL)
        XCTAssertNil(
            AccountSignInController.signInURL(
                in: "https://claude.com/cai/oauth/authorize",
                for: .codex
            )
        )
        XCTAssertNil(
            AccountSignInController.signInURL(
                in: "https://attacker@claude.com/cai/oauth/authorize",
                for: .claude
            )
        )
        XCTAssertNil(
            AccountSignInController.signInURL(
                in: "https://claude.com:8443/cai/oauth/authorize",
                for: .claude
            )
        )
    }

    func testProviderSignInURLAcceptsCurrentClaudeAuthorizeHosts() {
        XCTAssertNotNil(
            AccountSignInController.signInURL(
                in: "https://claude.com/cai/oauth/authorize",
                for: .claude
            )
        )
        XCTAssertNotNil(
            AccountSignInController.signInURL(
                in: "https://platform.claude.com/oauth/authorize",
                for: .claude
            )
        )
    }

    func testIncrementalUTF8DecoderPreservesEveryScalarAcrossEveryByteBoundary() throws {
        let expected = """
        Opening browser to sign in… café 研究 🙂
        Visit https://claude.com/oauth?state=été&emoji=✅
        Paste code here if prompted >
        OAuth error: accès refusé
        """
        let bytes = Data(expected.utf8)

        for split in 0 ... bytes.count {
            var decoder = AccountSignInUTF8Decoder()
            var decoded = decoder.decode(Data(bytes[..<split]))
            decoded += decoder.decode(Data(bytes[split...]))
            decoded += decoder.finish()

            XCTAssertEqual(decoded, expected, "UTF-8 split at byte \(split)")
            XCTAssertEqual(
                try XCTUnwrap(
                    AccountSignInController.signInURL(in: decoded, for: .claude)
                ).absoluteString,
                "https://claude.com/oauth?state=%C3%A9t%C3%A9&emoji=%E2%9C%85"
            )
            XCTAssertTrue(AccountSignInController.promptsForCode(decoded))
        }

        var bytewiseDecoder = AccountSignInUTF8Decoder()
        let bytewise = bytes.reduce(into: "") { output, byte in
            output += bytewiseDecoder.decode(Data([byte]))
        } + bytewiseDecoder.finish()
        XCTAssertEqual(bytewise, expected)
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

    func testOutputAfterSubmitDoesNotReopenTheOldCodePrompt() throws {
        let url = try XCTUnwrap(URL(string: "https://claude.com/oauth"))
        var tracker = AccountSignInController.OutputPhaseTracker()
        tracker.reset(for: .claude)
        tracker.beginSubmission()
        let transcript = """
        Visit https://claude.com/oauth
        Paste code here if prompted >
        Verifying your code…
        """

        XCTAssertEqual(
            tracker.phaseAfterOutput(
                current: .submitting,
                transcript: transcript,
                newOutput: "Verifying your code…\n"
            ),
            .submitting
        )
        XCTAssertEqual(
            AccountSignInController.signInURL(in: transcript, for: .claude),
            url
        )
    }

    func testOutputPhaseTrackerUsesTheSelectedProviderHost() throws {
        let codexURL = try XCTUnwrap(
            URL(string: "https://auth.openai.com/oauth/authorize?state=codex")
        )
        let transcript = """
        Debug https://claude.com/cai/oauth/authorize?state=wrong-provider
        Open https://auth.openai.com/oauth/authorize?state=codex
        """
        var tracker = AccountSignInController.OutputPhaseTracker()
        tracker.reset(for: .codex)

        XCTAssertEqual(
            tracker.phaseAfterOutput(
                current: .launching,
                transcript: transcript,
                newOutput: transcript
            ),
            .awaitingBrowser(codexURL)
        )
    }

    func testAnExplicitNewCodePromptCanReopenSubmissionAcrossOutputChunks() throws {
        let url = try XCTUnwrap(URL(string: "https://claude.com/oauth"))
        var tracker = AccountSignInController.OutputPhaseTracker()
        tracker.reset(for: .claude)
        tracker.beginSubmission()
        let oldTranscript = """
        Visit https://claude.com/oauth
        Paste code here if prompted >
        """
        let firstChunk = "That code expired. Paste "

        XCTAssertEqual(
            tracker.phaseAfterOutput(
                current: .submitting,
                transcript: oldTranscript + firstChunk,
                newOutput: firstChunk
            ),
            .submitting
        )

        let outputSinceSubmission = firstChunk + "code here if prompted >\n"
        XCTAssertEqual(
            tracker.phaseAfterOutput(
                current: .submitting,
                transcript: oldTranscript + outputSinceSubmission,
                newOutput: "code here if prompted >\n"
            ),
            .awaitingCode(url)
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

    // MARK: - Finding the CLI
    //
    // Discovery runs someone's interactive shell startup, which is unbounded
    // work: a `.zshrc` that waits on a prompt never returns. These pin the
    // bound, because the lookup used to run synchronously on the main actor and
    // took the whole Settings window down with the shell.

    /// A shell that ignores the question and sits there, standing in for a
    /// startup file blocked on input. `exec` so the sleeping process is the one
    /// the probe holds a pid for, and a finite sleep so a broken terminate
    /// fails the test instead of wedging the runner.
    private func hangingShell(seconds: Int) throws -> String {
        try fakeShell(named: "hanging", body: "exec sleep \(seconds)\n")
    }

    private func fakeShell(named name: String, body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-\(name)-shell-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// The one the issue is about: a shell that never exits must come back as a
    /// timeout, in about the time it was given rather than never.
    func testAShellThatNeverAnswersTimesOutRatherThanHanging() async throws {
        let shellPath = try hangingShell(seconds: 15)
        let started = Date()
        let lookup = await AccountSignInController.resolveExecutable(
            "claude", shell: shellPath, timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(lookup, .timedOut)
        XCTAssertLessThan(elapsed, 5, "the watchdog did not stop the shell: \(elapsed)s")
    }

    /// Dismissing the sheet has to take the shell with it, rather than leaving
    /// a zsh alive until a deadline it was never going to reach. The wait is an
    /// expectation rather than `await task.value` so a lookup that ignores
    /// cancellation fails the test instead of wedging the runner.
    func testCancellingStopsTheShellInsteadOfServingOutTheTimeout() async throws {
        let shellPath = try hangingShell(seconds: 30)
        let returned = expectation(description: "the lookup came back")
        let box = LookupBox()
        let lookup = Task.detached {
            box.value = await AccountSignInController.resolveExecutable(
                "claude", shell: shellPath, timeout: 60
            )
            returned.fulfill()
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let cancelled = Date()
        lookup.cancel()
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertEqual(box.value, .cancelled)
        let elapsed = Date().timeIntervalSince(cancelled)
        XCTAssertLessThan(elapsed, 5, "cancelling did not stop the shell: \(elapsed)s")
    }

    /// A shell that answers still answers. The noise line is the reason the
    /// parser takes the last absolute path rather than the first.
    func testAShellThatAnswersYieldsThePathItPrinted() async throws {
        let shellPath = try fakeShell(
            named: "answering",
            body: "echo 'nvm: using node 22'\necho /opt/kaisola-test/bin/claude\n"
        )
        let lookup = await AccountSignInController.resolveExecutable("claude", shell: shellPath)
        XCTAssertEqual(lookup, .found("/opt/kaisola-test/bin/claude"))
    }

    func testAShellThatFindsNothingIsMissingRatherThanTimedOut() async throws {
        let shellPath = try fakeShell(named: "empty", body: "exit 1\n")
        let lookup = await AccountSignInController.resolveExecutable("claude", shell: shellPath)
        XCTAssertEqual(lookup, .missing)
    }

    func testAShellThatCannotBeRunSaysSoRatherThanBlamingTheCLI() async {
        let lookup = await AccountSignInController.resolveExecutable(
            "claude", shell: "/nonexistent/kaisola/shell"
        )
        guard case .couldNotStart = lookup else {
            return XCTFail("expected a start failure, got \(lookup)")
        }
    }

    /// The diagnosis is the point of separating the outcomes: a timeout must
    /// send someone to their shell startup, not to a CLI they already have.
    func testTheTimeoutMessageBlamesTheShellAndSaysHowLongItWaited() throws {
        let message = try XCTUnwrap(AccountSignInController.lookupFailureMessage(
            tool: "claude", lookup: .timedOut, timeout: 12
        ))
        XCTAssertTrue(message.contains("12 seconds"), message)
        XCTAssertTrue(message.lowercased().contains("shell"), message)
        XCTAssertTrue(message.contains("command -v claude"), message)

        let missing = try XCTUnwrap(AccountSignInController.lookupFailureMessage(
            tool: "codex", lookup: .missing
        ))
        XCTAssertNotEqual(missing, message)
        XCTAssertTrue(missing.contains("codex"), missing)
    }

    /// Nothing to report when there is nothing wrong, and nothing to report to
    /// a sheet the user already closed.
    func testThereIsNoMessageForASuccessfulOrAbandonedLookup() {
        XCTAssertNil(AccountSignInController.lookupFailureMessage(
            tool: "claude", lookup: .found("/usr/local/bin/claude")
        ))
        XCTAssertNil(AccountSignInController.lookupFailureMessage(
            tool: "claude", lookup: .cancelled
        ))
    }
}

/// Carries one lookup out of a detached task. The expectation it is paired with
/// orders the write before the read.
private final class LookupBox: @unchecked Sendable {
    var value: AccountSignInController.ExecutableLookup?
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
