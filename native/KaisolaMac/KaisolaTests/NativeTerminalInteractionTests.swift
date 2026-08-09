import AppKit
import SwiftTerm
import XCTest
@testable import Kaisola

/// The Phase 1 interaction rows depend on three wiring facts: the edit menu
/// exposes SwiftTerm's find panel with the exact NSFindPanelAction tags, the
/// read-only surface exposes the retained buffer tail to accessibility, and
/// the surface claims keyboard focus when it joins a window so menu commands
/// reach it without a mouse.
@MainActor
final class NativeTerminalInteractionTests: XCTestCase {
    private func osc133(_ value: String) -> String {
        "\u{1B}]133;\(value)\u{7}"
    }

    func testSurfaceLeavesOptionAvailableToInternationalKeyboardLayouts() {
        let view = OwnedTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.optionAsMetaKey = true
        NativeTerminalSurface.configureKeyboardInput(on: view)
        XCTAssertFalse(view.optionAsMetaKey)
    }

    func testTerminalGeometryIgnoresZeroDeduplicatesLayoutAndFinishesWide() {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = OwnedTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        var delivered: [(columns: Int, rows: Int)] = []
        coordinator.setResizeHandler({ delivered.append(($0, $1)) }, synchronizing: view)

        XCTAssertTrue(delivered.isEmpty, "The representable's zero placeholder is not PTY geometry.")
        view.setFrameSize(NSSize(width: 150, height: 110))
        let narrow = view.getTerminal().getDims()
        coordinator.synchronizeCurrentGeometry(from: view)
        coordinator.synchronizeCurrentGeometry(from: view)
        XCTAssertEqual(delivered.count, 1, "Repeated usable-layout callbacks must be deduplicated.")
        XCTAssertEqual(delivered.last?.columns, narrow.cols)
        XCTAssertEqual(delivered.last?.rows, narrow.rows)

        view.setFrameSize(NSSize(width: 760, height: 360))
        let wide = view.getTerminal().getDims()
        coordinator.synchronizeCurrentGeometry(from: view)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered.last?.columns, wide.cols)
        XCTAssertEqual(delivered.last?.rows, wide.rows)
        XCTAssertGreaterThan(wide.cols, narrow.cols)
    }

    func testResizeCapabilityActivationForceSynchronizesUnchangedCachedGeometry() {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 300),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        var first: [(Int, Int)] = []
        coordinator.setResizeHandler({ first.append(($0, $1)) }, synchronizing: view)
        XCTAssertEqual(first.count, 1)

        coordinator.prepareForRetention()
        var reattached: [(Int, Int)] = []
        coordinator.setResizeHandler({ reattached.append(($0, $1)) }, synchronizing: view)
        let dimensions = view.getTerminal().getDims()
        XCTAssertEqual(reattached.count, 1, "Reattachment must reconcile even when AppKit keeps identical bounds.")
        XCTAssertEqual(reattached.first?.0, dimensions.cols)
        XCTAssertEqual(reattached.first?.1, dimensions.rows)
    }

    func testRepaintHeavyOSCTitlesDebounceAfterTheTerminalFeedTurn() async {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        var delivered: [String] = []
        let deliveredNewest = expectation(description: "newest title delivered after feed")
        coordinator.onTitleChange = { title in
            delivered.append(title)
            deliveredNewest.fulfill()
        }

        view.feed(text:
            "\u{1B}]0;frame-one\u{7}"
                + "\u{1B}]2;frame-two\u{7}"
                + "\u{1B}]0;frame-three\u{7}"
        )

        XCTAssertTrue(delivered.isEmpty, "OSC parsing must not publish during the feed/update turn")
        await fulfillment(of: [deliveredNewest], timeout: 1)
        XCTAssertEqual(delivered, ["frame-three"])
    }

    func testOSCTitleDebounceResetsAcrossRunLoopTurns() {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        var delivered: [String] = []
        coordinator.onTitleChange = { delivered.append($0) }

        coordinator.setTerminalTitle(source: view, title: "frame-one")
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        coordinator.setTerminalTitle(source: view, title: "frame-two")
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))

        XCTAssertTrue(delivered.isEmpty, "the second repaint must reset the pending delivery")
        RunLoop.main.run(until: Date().addingTimeInterval(0.07))
        XCTAssertEqual(delivered, ["frame-two"])
    }

    func testSemanticShellIntegrationIsOptInAndLeavesUserDotfilesUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-semantic-shell-\(UUID().uuidString)", isDirectory: true)
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let integrationRoot = root.appendingPathComponent("integration", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let userRC = userHome.appendingPathComponent(".zshrc")
        let originalRC = "PS1='PROMPT> '\nPS2='CONT> '\nexport KAISOLA_USER_RC_SEEN=1\n"
        try Data(originalRC.utf8).write(to: userRC)

        XCTAssertNil(NativeSemanticShellIntegration.launchShell(
            userShell: "/bin/zsh",
            enabled: false,
            directory: integrationRoot
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrationRoot.path))
        XCTAssertThrowsError(try NativeSemanticShellIntegration.installZsh(
            userShell: "/bin/bash",
            directory: integrationRoot
        ))

        let installation = try NativeSemanticShellIntegration.installZsh(
            userShell: "/bin/zsh",
            directory: integrationRoot
        )
        XCTAssertEqual(try String(contentsOf: userRC, encoding: .utf8), originalRC)
        XCTAssertEqual(
            try permissions(at: installation.launcher),
            0o700
        )
        XCTAssertEqual(
            try permissions(at: installation.startupDirectory.appendingPathComponent(".zshrc")),
            0o600
        )

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let linkedRoot = root.appendingPathComponent("linked-integration", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        XCTAssertThrowsError(try NativeSemanticShellIntegration.installZsh(
            userShell: "/bin/zsh",
            directory: linkedRoot
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("zdot").path
        ))
    }

    func testGeneratedZshIntegrationEmitsLifecycleAndSourcesUserRC() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-semantic-zsh-probe-\(UUID().uuidString)", isDirectory: true)
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let integrationRoot = root.appendingPathComponent("integration", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("PS1='PROMPT> '\nPS2='CONT> '\nexport KAISOLA_USER_RC_SEEN=1\n".utf8)
            .write(to: userHome.appendingPathComponent(".zshrc"))
        let installation = try NativeSemanticShellIntegration.installZsh(
            userShell: "/bin/zsh",
            directory: integrationRoot
        )

        let process = Process()
        process.executableURL = installation.launcher
        process.arguments = [
            "-ic",
            "__kaisola_semantic_precmd; "
                + "print -P -- \"$PS1\"; print -P -- \"$PS2\"; "
                + "__kaisola_semantic_preexec; true; __kaisola_semantic_precmd; "
                + "printf 'probe:%s\\n' \"$KAISOLA_USER_RC_SEEN\"",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = userHome.path
        environment["ZDOTDIR"] = userHome.path
        environment.removeValue(forKey: "KAISOLA_USER_ZDOTDIR")
        environment.removeValue(forKey: "KAISOLA_INTEGRATION_ZDOTDIR")
        environment.removeValue(forKey: "KAISOLA_SEMANTIC_MARKS_ACTIVE")
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let rendered = String(
            data: try output.fileHandleForReading.readToEnd() ?? Data(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(rendered.contains("probe:1"), rendered)
        XCTAssertTrue(rendered.contains(osc133("A")), rendered.debugDescription)
        XCTAssertTrue(rendered.contains(osc133("B")), rendered.debugDescription)
        XCTAssertTrue(rendered.contains(osc133("C")), rendered.debugDescription)
        XCTAssertTrue(rendered.contains(osc133("D;0")), rendered.debugDescription)
    }

    func testGeneratedZshContinuationPromptDoesNotResetCommandStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-semantic-zsh-continuation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = try NativeSemanticShellIntegration.installZsh(
            userShell: "/bin/zsh",
            directory: root
        )
        let integration = try String(
            contentsOf: installation.startupDirectory.appendingPathComponent("kaisola-integration.zsh"),
            encoding: .utf8
        )

        XCTAssertTrue(integration.contains("PS2=\"${__kaisola_mark_a_secondary}${PS2}\""))
        XCTAssertFalse(integration.contains("PS2=\"${__kaisola_mark_a_secondary}${PS2}${__kaisola_mark_b}\""))
    }

    func testGeneratedBashIntegrationPreservesStartupFilesAndEmitsLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-semantic-bash-probe-\(UUID().uuidString)", isDirectory: true)
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let integrationRoot = root.appendingPathComponent("integration", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = userHome.appendingPathComponent(".bash_profile")
        let bashrc = userHome.appendingPathComponent(".bashrc")
        let originalProfile = "export KAISOLA_USER_PROFILE_SEEN=1\n"
        let originalRC = "PS1='PROMPT> '\nPS2='CONT> '\nexport KAISOLA_USER_RC_SEEN=1\nPROMPT_COMMAND='export KAISOLA_USER_PROMPT_SEEN=$?'\n"
        try Data(originalProfile.utf8).write(to: profile)
        try Data(originalRC.utf8).write(to: bashrc)

        XCTAssertNotNil(NativeSemanticShellIntegration.launchShell(
            userShell: "/bin/bash",
            enabled: true,
            directory: integrationRoot
        ))
        let installation = try NativeSemanticShellIntegration.installBash(
            userShell: "/bin/bash",
            directory: integrationRoot
        )
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), originalProfile)
        XCTAssertEqual(try String(contentsOf: bashrc, encoding: .utf8), originalRC)
        XCTAssertEqual(try permissions(at: installation.launcher), 0o700)
        XCTAssertEqual(
            try permissions(at: installation.startupDirectory.appendingPathComponent("kaisola-bashrc")),
            0o600
        )

        let login = try run(
            installation.launcher,
            arguments: ["-lc", "printf 'login:%s leaked:%s\\n' \"$KAISOLA_USER_PROFILE_SEEN\" \"${BASH_ENV-unset}\""],
            home: userHome
        )
        XCTAssertEqual(login.status, 0, login.errors)
        XCTAssertTrue(login.output.contains("login:1 leaked:unset"), login.output)

        let interactive = try run(
            installation.launcher,
            arguments: [
                "-ic",
                "__kaisola_semantic_prompt_command; "
                    + "p0=${PS0//\\\\[/}; p0=${p0//\\\\]/}; printf '%b' \"$p0\"; "
                    + "p1=${PS1//\\\\[/}; p1=${p1//\\\\]/}; printf '%b' \"$p1\"; "
                    + "p2=${PS2//\\\\[/}; p2=${p2//\\\\]/}; printf '%b' \"$p2\"; "
                    + "false; __kaisola_semantic_prompt_command; "
                    + "printf 'probe:%s prompt:%s leaked:%s\\n' \"$KAISOLA_USER_RC_SEEN\" \"$KAISOLA_USER_PROMPT_SEEN\" \"${BASH_ENV-unset}\"",
            ],
            home: userHome
        )
        XCTAssertEqual(interactive.status, 0, interactive.errors)
        XCTAssertTrue(interactive.output.contains("probe:1"), interactive.output)
        XCTAssertTrue(interactive.output.contains("prompt:1"), interactive.output)
        XCTAssertTrue(interactive.output.contains("leaked:unset"), interactive.output)
        XCTAssertTrue(interactive.output.contains(osc133("A")), interactive.output.debugDescription)
        XCTAssertTrue(interactive.output.contains(osc133("A;k=s")), interactive.output.debugDescription)
        XCTAssertTrue(interactive.output.contains(osc133("B")), interactive.output.debugDescription)
        XCTAssertTrue(interactive.output.contains(osc133("C")), interactive.output.debugDescription)
        XCTAssertTrue(interactive.output.contains(osc133("D;1")), interactive.output.debugDescription)
    }

    func testGeneratedFishIntegrationIsPrivateCapabilityGatedAndForwardsArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-semantic-fish-'probe-\(UUID().uuidString)", isDirectory: true)
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let userConfig = userHome.appendingPathComponent(".config/fish", isDirectory: true)
        let integrationRoot = root.appendingPathComponent("integration", isDirectory: true)
        let fakeFish = root.appendingPathComponent("fish", isDirectory: false)
        try FileManager.default.createDirectory(at: userConfig, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configFile = userConfig.appendingPathComponent("config.fish")
        let originalConfig = "set -gx KAISOLA_USER_FISH_CONFIG_SEEN 1\n"
        try Data(originalConfig.utf8).write(to: configFile)
        try Data("#!/bin/sh\nprintf 'integration:%s\\n' \"${KAISOLA_FISH_INTEGRATION-unset}\"\nprintf 'arg:%s\\n' \"$@\"\n".utf8)
            .write(to: fakeFish)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeFish.path
        )

        XCTAssertNotNil(NativeSemanticShellIntegration.launchShell(
            userShell: fakeFish.path,
            enabled: true,
            directory: integrationRoot
        ))
        let installation = try NativeSemanticShellIntegration.installFish(
            userShell: fakeFish.path,
            directory: integrationRoot
        )
        XCTAssertEqual(try String(contentsOf: configFile, encoding: .utf8), originalConfig)
        XCTAssertEqual(try permissions(at: installation.launcher), 0o700)
        let startupFile = installation.startupDirectory
            .appendingPathComponent("kaisola-integration.fish")
        XCTAssertEqual(try permissions(at: startupFile), 0o600)

        let launched = try run(
            installation.launcher,
            arguments: ["-ilc", "printf probe"],
            home: userHome
        )
        XCTAssertEqual(launched.status, 0, launched.errors)
        XCTAssertTrue(
            launched.output.contains("integration:\(startupFile.path)"),
            launched.output
        )
        XCTAssertTrue(launched.output.contains("arg:--init-command"), launched.output)
        XCTAssertTrue(
            launched.output.contains("arg:source \"$KAISOLA_FISH_INTEGRATION\"; set -e KAISOLA_FISH_INTEGRATION"),
            launched.output
        )
        XCTAssertTrue(launched.output.contains("arg:-ilc"), launched.output)
        XCTAssertTrue(launched.output.contains("arg:printf probe"), launched.output)

        let integration = try String(contentsOf: startupFile, encoding: .utf8)
        let nativeDetection = try XCTUnwrap(integration.range(of: "forward-char-passive"))
        let fallbackDefinition = try XCTUnwrap(integration.range(of: "function __kaisola_semantic_preexec"))
        XCTAssertLessThan(nativeDetection.lowerBound, fallbackDefinition.lowerBound)
        XCTAssertTrue(integration.contains("--on-event fish_preexec"))
        XCTAssertTrue(integration.contains("--on-event fish_postexec"))
        XCTAssertTrue(integration.contains("--on-event fish_cancel"))
        XCTAssertTrue(integration.contains("--on-event fish_posterror"))
        XCTAssertTrue(integration.contains("functions --copy fish_prompt __kaisola_user_fish_prompt"))
        XCTAssertTrue(integration.contains("functions --copy fish_mode_prompt __kaisola_user_fish_mode_prompt"))
        XCTAssertTrue(integration.contains("__kaisola_semantic_osc A"))
        XCTAssertTrue(integration.contains("__kaisola_semantic_osc B"))
        XCTAssertTrue(integration.contains("__kaisola_semantic_osc C"))
        XCTAssertTrue(integration.contains("__kaisola_semantic_osc D $command_status"))
        XCTAssertFalse(integration.contains("cmdline_url"))
    }

    func testGeneratedFishIntegrationExecutesWhenFishRuntimeIsAvailable() throws {
        guard let fishPath = ProcessInfo.processInfo.environment["KAISOLA_TEST_FISH"],
              FileManager.default.isExecutableFile(atPath: fishPath) else {
            throw XCTSkip("Set KAISOLA_TEST_FISH to exercise the generated launcher with a real Fish runtime")
        }
        guard URL(fileURLWithPath: fishPath).lastPathComponent == "fish" else {
            XCTFail("KAISOLA_TEST_FISH must point to an executable named fish")
            return
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-semantic-fish-runtime-\(UUID().uuidString)", isDirectory: true)
        let userHome = root.appendingPathComponent("user", isDirectory: true)
        let integrationRoot = root.appendingPathComponent("integration", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installation = try NativeSemanticShellIntegration.installFish(
            userShell: fishPath,
            directory: integrationRoot
        )
        let startupFile = installation.startupDirectory
            .appendingPathComponent("kaisola-integration.fish")

        let syntax = try run(
            URL(fileURLWithPath: fishPath),
            arguments: ["-n", startupFile.path],
            home: userHome
        )
        XCTAssertEqual(syntax.status, 0, syntax.errors)

        let modern = try run(
            installation.launcher,
            arguments: ["-N", "-ic", "printf modern-path-ok"],
            home: userHome
        )
        XCTAssertEqual(modern.status, 0, modern.errors)
        XCTAssertTrue(modern.output.contains("modern-path-ok"), modern.output)

        let generated = try String(contentsOf: startupFile, encoding: .utf8)
        let capabilityGate = "bind --function-names | string match -q -- forward-char-passive; and return 0"
        XCTAssertTrue(generated.contains(capabilityGate))
        let forcedLegacy = generated.replacingOccurrences(
            of: capabilityGate,
            with: "false; and return 0"
        )
        try Data(forcedLegacy.utf8).write(to: startupFile, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: startupFile.path
        )

        let legacy = try run(
            installation.launcher,
            arguments: [
                "-N",
                "-ic",
                "__kaisola_semantic_prompt_start; "
                    + "__kaisola_semantic_command_start; "
                    + "__kaisola_semantic_preexec; "
                    + "false; __kaisola_semantic_postexec; "
                    + "functions --query __kaisola_semantic_cancel "
                    + "__kaisola_semantic_posterror __kaisola_semantic_wrap_prompt; "
                    + "and printf functions-ok",
            ],
            home: userHome
        )
        XCTAssertEqual(legacy.status, 0, legacy.errors)
        XCTAssertTrue(legacy.output.contains(osc133("A")), legacy.output.debugDescription)
        XCTAssertTrue(legacy.output.contains(osc133("B")), legacy.output.debugDescription)
        XCTAssertTrue(legacy.output.contains(osc133("C")), legacy.output.debugDescription)
        XCTAssertTrue(legacy.output.contains(osc133("D;1")), legacy.output.debugDescription)
        XCTAssertTrue(legacy.output.contains("functions-ok"), legacy.output)
    }

    func testBashAndFishIntegrationsRejectWrongShellAndSymlinkRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-semantic-bash-safety-\(UUID().uuidString)", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let linkedRoot = root.appendingPathComponent("linked-integration", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try NativeSemanticShellIntegration.installBash(
            userShell: "/bin/zsh",
            directory: root.appendingPathComponent("wrong-shell")
        ))
        XCTAssertThrowsError(try NativeSemanticShellIntegration.installFish(
            userShell: "/bin/zsh",
            directory: root.appendingPathComponent("wrong-fish")
        ))
        XCTAssertThrowsError(try NativeSemanticShellIntegration.installBash(
            userShell: "/bin/bash",
            directory: linkedRoot
        ))
        XCTAssertThrowsError(try NativeSemanticShellIntegration.installFish(
            userShell: "/opt/homebrew/bin/fish",
            directory: linkedRoot
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("bash").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("fish").path
        ))
    }

    private func run(
        _ executable: URL,
        arguments: [String],
        home: URL
    ) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment.removeValue(forKey: "BASH_ENV")
        environment.removeValue(forKey: "KAISOLA_BASH_LOGIN")
        environment.removeValue(forKey: "KAISOLA_BASH_STARTUP_ACTIVE")
        environment.removeValue(forKey: "KAISOLA_SEMANTIC_MARKS_ACTIVE")
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: try output.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8) ?? "",
            String(data: try errors.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8) ?? ""
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testAgentDraftTrackerHandlesEditingContinuationAndSubmit() {
        var tracker = TerminalAgentDraftTracker()
        XCTAssertTrue(tracker.apply("draft 张").userInteracted)
        _ = tracker.apply("\u{7F}")
        XCTAssertEqual(tracker.text, "draft ")

        _ = tracker.apply("line one\\\rline two")
        XCTAssertEqual(tracker.text, "draft line one\nline two")
        let submitted = tracker.apply("\r")
        XCTAssertTrue(submitted.submitted)
        XCTAssertEqual(tracker.text, "")

        _ = tracker.apply("cancel me")
        _ = tracker.apply("\u{3}")
        XCTAssertEqual(tracker.text, "")
    }

    func testAgentDraftTrackerPreservesBracketedPasteAndIgnoresTerminalReplies() {
        var tracker = TerminalAgentDraftTracker(text: "before")
        let report = tracker.apply("\u{1B}[12;40R\u{1B}]11;rgb:ffff/ffff/ffff\u{7}")
        XCTAssertFalse(report.userInteracted)
        XCTAssertFalse(report.textChanged)

        let paste = tracker.apply(
            "\u{1B}[200~first\r\n\nsecond 张\tvalue\u{1B}[201~"
        )
        XCTAssertTrue(paste.userInteracted)
        XCTAssertEqual(tracker.text, "beforefirst\n\nsecond 张\tvalue")

        let navigation = tracker.apply("\u{1B}[D")
        XCTAssertTrue(navigation.userInteracted)
        XCTAssertFalse(navigation.textChanged)
    }

    func testAgentDraftTrackerBoundsPersistenceAndEncodesMultilineRetype() {
        var tracker = TerminalAgentDraftTracker()
        _ = tracker.apply(String(repeating: "x", count: TerminalAgentDraftTracker.maximumBytes + 1))
        XCTAssertEqual(tracker.text.utf8.count, TerminalAgentDraftTracker.maximumBytes)
        XCTAssertEqual(
            TerminalAgentDraftTracker.retypePayload(for: "first\nsecond 张"),
            "first\\\rsecond 张"
        )
    }

    func testBuiltInAgentContinuationCommandsMatchInstalledCLISurfaces() {
        XCTAssertEqual(AgentRegistry.profile(id: "claude-code")?.resumeCommand, "claude --continue")
        XCTAssertEqual(AgentRegistry.profile(id: "codex")?.resumeCommand, "codex resume --last")
        XCTAssertEqual(
            AgentRegistry.profile(id: "opencode")?.resumeCommand,
            "opencode --continue --mini --replay-limit 60"
        )
        XCTAssertEqual(AgentRegistry.profile(id: "gemini")?.resumeCommand, "gemini --resume latest")
    }

    func testDraftRestoreWaitsForQuietPromptAndExpiresBoundedly() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            TerminalDraftRestorePolicy.decision(
                startedAt: start,
                lastOutputAt: start,
                now: start.addingTimeInterval(2.9)
            ),
            .wait
        )
        XCTAssertEqual(
            TerminalDraftRestorePolicy.decision(
                startedAt: start,
                lastOutputAt: start.addingTimeInterval(2.5),
                now: start.addingTimeInterval(4)
            ),
            .wait
        )
        XCTAssertEqual(
            TerminalDraftRestorePolicy.decision(
                startedAt: start,
                lastOutputAt: start.addingTimeInterval(1),
                now: start.addingTimeInterval(3)
            ),
            .restore
        )
        XCTAssertEqual(
            TerminalDraftRestorePolicy.decision(
                startedAt: start,
                lastOutputAt: start.addingTimeInterval(29),
                now: start.addingTimeInterval(30.1)
            ),
            .expire
        )
    }

    private func contrastRatio(_ color: SwiftTerm.Color, background: (Double, Double, Double)) -> Double {
        func luminance(_ components: (Double, Double, Double)) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(components.0)
                + 0.7152 * linear(components.1)
                + 0.0722 * linear(components.2)
        }
        let foreground = luminance((
            Double(color.red) / 65_535,
            Double(color.green) / 65_535,
            Double(color.blue) / 65_535
        ))
        let backdrop = luminance(background)
        return (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
    }

    private func editMenu(in mainMenu: NSMenu) throws -> NSMenu {
        let editItem = try XCTUnwrap(mainMenu.items.first { $0.submenu?.title == "Edit" })
        return try XCTUnwrap(editItem.submenu)
    }

    func testTerminalLineSpacingMatchesTerminalAppDefault() {
        XCTAssertEqual(NativeTerminalSurface.comfortableLineSpacing, 1.0, accuracy: 0.001)
    }

    func testTerminalLinksUseVisibleOneClickHoverInteraction() {
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.configureLinkInteraction()

        switch view.linkReporting {
        case .implicit:
            break
        default:
            XCTFail("Terminal must detect explicit URLs and implicit file paths")
        }
        switch view.linkHighlightMode {
        case .hover:
            break
        default:
            XCTFail("Links must underline on hover and open without a hidden modifier")
        }
    }

    func testHighContrastANSIRolesRemainReadableOnTerminalSurfaces() {
        let light = TerminalTheme.nativeLight.ansi
        let dark = TerminalTheme.nativeDark.ansi
        XCTAssertEqual(light.count, 16)
        XCTAssertEqual(dark.count, 16)

        // ANSI cyan is the conventional role used by Codex/Claude for links
        // and file citations. On a light surface it is intentionally blue.
        XCTAssertEqual(light[6].red, 0x00 * 257)
        XCTAssertEqual(light[6].green, 0x77 * 257)
        XCTAssertEqual(light[6].blue, 0xB6 * 257)

        for (index, color) in light.enumerated() {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(color, background: (1, 1, 1)),
                4.5,
                "light ANSI slot \(index) falls below readable text contrast"
            )
        }
        // Slot zero is intentionally true black for terminal background/block
        // semantics. Every text-bearing dark slot clears the same threshold.
        for index in 1..<dark.count {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(dark[index], background: (30 / 255, 30 / 255, 30 / 255)),
                4.5,
                "dark ANSI slot \(index) falls below readable text contrast"
            )
        }
    }

    func testTerminalPaneChromeUsesTheActiveOpaqueTerminalPalette() {
        for definition in TerminalThemeRegistry.shipped {
            for light in [false, true] {
                let palette = TerminalTheme.palette(light: light, themeID: definition.id)
                let chrome = TerminalTheme.paneChrome(light: light, themeID: definition.id)

                XCTAssertTrue(chrome.background.isEqual(palette.background))
                XCTAssertTrue(chrome.foreground.isEqual(palette.foreground))
                XCTAssertGreaterThan(chrome.headerTintOpacity, 0)
                XCTAssertLessThan(chrome.headerTintOpacity, 0.1)
                XCTAssertGreaterThan(chrome.ruleOpacity, chrome.headerTintOpacity)
                XCTAssertLessThan(chrome.ruleOpacity, 0.25)
                XCTAssertEqual(chrome.background.alphaComponent, 1, accuracy: 0.001)
            }
        }
    }

    func testEditMenuCarriesFindPanelActionsWithSwiftTermTags() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil,
            updateAction: nil,
            updateEnabled: false,
            updateDetail: nil
        )
        let edit = try editMenu(in: menu)
        let findAction = #selector(NSTextView.performFindPanelAction(_:))

        let find = try XCTUnwrap(edit.items.first { $0.title == "Find…" })
        XCTAssertEqual(find.action, findAction)
        XCTAssertEqual(find.tag, Int(NSFindPanelAction.showFindPanel.rawValue))
        XCTAssertEqual(find.keyEquivalent, "f")

        let next = try XCTUnwrap(edit.items.first { $0.title == "Find Next" })
        XCTAssertEqual(next.tag, Int(NSFindPanelAction.next.rawValue))
        XCTAssertEqual(next.keyEquivalent, "g")

        let previous = try XCTUnwrap(edit.items.first { $0.title == "Find Previous" })
        XCTAssertEqual(previous.tag, Int(NSFindPanelAction.previous.rawValue))
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.command, .shift])

        let useSelection = try XCTUnwrap(edit.items.first { $0.title == "Use Selection for Find" })
        XCTAssertEqual(useSelection.tag, Int(NSFindPanelAction.setFindString.rawValue))
    }

    func testEditMenuKeepsStandardUndoRedoCutCopyPasteAndSelectAll() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil,
            updateAction: nil,
            updateEnabled: false,
            updateDetail: nil
        )
        let edit = try editMenu(in: menu)
        let undo = try XCTUnwrap(edit.items.first { $0.title == "Undo" })
        XCTAssertEqual(undo.action, Selector(("undo:")))
        XCTAssertEqual(undo.keyEquivalent, "z")

        let redo = try XCTUnwrap(edit.items.first { $0.title == "Redo" })
        XCTAssertEqual(redo.action, Selector(("redo:")))
        XCTAssertEqual(redo.keyEquivalent, "z")
        XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])

        let cut = try XCTUnwrap(edit.items.first { $0.title == "Cut" })
        XCTAssertEqual(cut.action, #selector(NSText.cut(_:)))
        XCTAssertEqual(cut.keyEquivalent, "x")
        XCTAssertNotNil(edit.items.first { $0.title == "Copy" && $0.keyEquivalent == "c" })
        let paste = try XCTUnwrap(edit.items.first { $0.title == "Paste" })
        XCTAssertEqual(paste.action, #selector(NSText.paste(_:)))
        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertNotNil(edit.items.first { $0.title == "Select All" && $0.keyEquivalent == "a" })
    }

    func testOwnedTerminalDoesNotAdvertiseSixelImagePreviewCapability() {
        let coordinator = NativeTerminalSurface.Coordinator()
        var response = ""
        coordinator.onInput = { response += $0 }
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        coordinator.setInputAuthorized(true)
        view.setInputAuthorized(true)

        XCTAssertTrue(
            view.getTerminal().options.enableSixelReported,
            "Upstream defaults to advertising Sixel; Kaisola must opt out explicitly."
        )
        view.configureAdvertisedGraphicsCapabilities()
        XCTAssertFalse(view.getTerminal().options.enableSixelReported)

        // Primary device attributes parameter 4 means Sixel. Codex probes this
        // response before choosing its inline clipboard-image renderer.
        view.feed(text: "\u{1B}[c")
        XCTAssertTrue(response.hasPrefix("\u{1B}[?65;"), "got \(response.debugDescription)")
        XCTAssertFalse(response.split(separator: ";").contains("4"))
    }

    func testOwnedTerminalPasteUsesCodexBracketedPasteProtocol() {
        let coordinator = NativeTerminalSurface.Coordinator()
        var captured: [String] = []
        coordinator.onInput = { captured.append($0) }
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        coordinator.setInputAuthorized(true)
        view.setInputAuthorized(true)
        // Codex enables DEC private mode 2004 while its prompt is active.
        view.feed(text: "\u{1B}[?2004h")
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)

        let pasteboard = NSPasteboard.general
        let priorItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy.types.isEmpty ? nil : copy
        }
        defer {
            pasteboard.clearContents()
            if let priorItems, !priorItems.isEmpty { pasteboard.writeObjects(priorItems) }
        }
        pasteboard.clearContents()
        pasteboard.setString("first line\nsecond line 张", forType: .string)

        view.paste(NSNull())

        XCTAssertEqual(
            captured,
            ["\u{1B}[200~first line\nsecond line 张\u{1B}[201~"],
            "A bracketed paste must cross the ownership-epoch boundary as one packet."
        )
    }

    func testCommandPasteForwardsImageOnlyClipboardToCodexControlV() throws {
        let coordinator = NativeTerminalSurface.Coordinator()
        var captured = ""
        coordinator.onInput = { captured += $0 }
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        coordinator.setInputAuthorized(true)
        view.setInputAuthorized(true)
        view.agentLaunchCommand = "codex"

        let pasteboard = NSPasteboard.general
        let priorItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy.types.isEmpty ? nil : copy
        }
        defer {
            pasteboard.clearContents()
            if let priorItems, !priorItems.isEmpty { pasteboard.writeObjects(priorItems) }
        }

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        view.paste(NSNull())

        XCTAssertEqual(Array(captured.utf8), [0x16])
    }

    func testTerminalContextMenusExposeNativeCopyPasteControls() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        let rightClick = try XCTUnwrap(event)
        let readOnly = ReadOnlyTerminalView(frame: .zero, font: font)
        XCTAssertEqual(readOnly.menu(for: rightClick)?.items.map(\.title), ["Copy", "", "Select All"])

        let owned = OwnedTerminalView(frame: .zero, font: font)
        XCTAssertEqual(
            owned.menu(for: rightClick)?.items.map(\.title),
            ["Copy", "", "Select All"],
            "A controller-capable view starts sealed and must not advertise Paste."
        )
        owned.setInputAuthorized(true)
        XCTAssertEqual(owned.menu(for: rightClick)?.items.map(\.title), ["Copy", "Paste", "", "Select All"])
    }

    func testTerminalContextMenuExposesSemanticCommandNavigationWhenMarked() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = ReadOnlyTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240), font: font)
        view.changeScrollback(100)
        view.getTerminal().resize(cols: 40, rows: 5)
        view.configureSemanticPromptMarks()
        for index in 0..<3 {
            view.getTerminal().feed(text:
                osc133("A") + "$ " + osc133("B") + "command-\(index)" + osc133("C")
                    + "\r\n" + (0..<6).map { "output-\(index)-\($0)\r\n" }.joined()
                    + osc133("D;0")
            )
        }
        view.scrollToLiveBottom()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let items = try XCTUnwrap(view.menu(for: event)?.items)

        XCTAssertEqual(items.map(\.title), ["Copy", "", "Previous Command", "Next Command", "", "Select All"])
        XCTAssertEqual(items.first(where: { $0.title == "Previous Command" })?.isEnabled, true)
        XCTAssertEqual(items.first(where: { $0.title == "Next Command" })?.isEnabled, false)
    }

    func testSemanticDecorationOverlayIsPassiveAndOnlyVisibleForMarkedRows() {
        let overlay = TerminalSemanticDecorationView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240)
        )
        overlay.update(decorations: [], rowCount: 12)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 4, y: 4)))
        XCTAssertFalse(overlay.isAccessibilityElement())

        overlay.update(
            decorations: [
                TerminalSemanticDecoration(
                    startViewportRow: 2,
                    endViewportRow: 4,
                    phase: .succeeded
                ),
            ],
            rowCount: 12
        )
        XCTAssertFalse(overlay.isHidden)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 4, y: 40)))
    }

    func testReadOnlySurfaceExposesBufferTailToAccessibility() {
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.updateAccessibilityValue(from: "alpha\r\nbravo\r\ncharlie")

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        let value = view.accessibilityValue() as? String
        XCTAssertEqual(value, "alpha\nbravo\ncharlie")
    }

    func testAccessibilityValueUsesRenderedGridInsteadOfRawControlStream() {
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let raw = "\u{1B}[2J\u{1B}[Halpha\r\n\u{1B}[31mbravo\u{1B}[0m"
        view.updateAccessibilityValue(from: raw)
        view.feed(text: raw)

        let value = view.accessibilityValue() as? String
        XCTAssertTrue(value?.contains("alpha") ?? false)
        XCTAssertTrue(value?.contains("bravo") ?? false)
        XCTAssertFalse(value?.contains("\u{1B}") ?? true)
        XCTAssertFalse(value?.contains("[31m") ?? true)
    }

    func testAccessibilityValueIsBoundedToTail() {
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let filler = String(repeating: "x", count: ReadOnlyTerminalView.accessibilityTailLimit)
        view.updateAccessibilityValue(from: filler + "tail-marker")

        let value = try? XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertEqual(value?.count, ReadOnlyTerminalView.accessibilityTailLimit)
        XCTAssertTrue(value?.hasSuffix("tail-marker") ?? false)
    }

    func testTerminalAccessibilityAnnouncementPolicyHandlesAppendScrollAndRepaint() {
        XCTAssertEqual(TerminalAccessibilityAnnouncementPolicy.throttleInterval, 0.8)
        XCTAssertEqual(
            TerminalAccessibilityAnnouncementPolicy.announcement(
                previous: "prompt\nfirst",
                current: "prompt\nfirst\nsecond"
            ),
            "second"
        )
        XCTAssertEqual(
            TerminalAccessibilityAnnouncementPolicy.announcement(
                previous: "one\ntwo\nthree",
                current: "two\nthree\nfour"
            ),
            "four"
        )
        XCTAssertEqual(
            TerminalAccessibilityAnnouncementPolicy.announcement(
                previous: "Working 10%",
                current: "Working 20%"
            ),
            "Working 20%"
        )
        let bounded = TerminalAccessibilityAnnouncementPolicy.announcement(
            previous: "",
            current: String(repeating: "x", count: 900)
        )
        XCTAssertEqual(bounded?.count, TerminalAccessibilityAnnouncementPolicy.maximumCharacters)
    }

    func testTerminalOutputAnnouncementsThrottleAndNeverSpeakBackgroundBacklog() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = root
        let view = ReadOnlyTerminalView(
            frame: root.bounds,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        root.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))

        var announcements: [String] = []
        view.accessibilityAnnouncementVoiceOverEnabled = { true }
        view.accessibilityAnnouncementPoster = { announcements.append($0) }
        view.updateAccessibilityValue(from: "ready")
        view.seedAccessibilityAnnouncementBaseline()

        view.updateAccessibilityValue(from: "ready\none")
        view.noteLiveOutputForAccessibility()
        view.updateAccessibilityValue(from: "ready\none\ntwo")
        view.noteLiveOutputForAccessibility()

        XCTAssertTrue(view.accessibilityAnnouncementIsScheduled)
        XCTAssertEqual(view.accessibilityAnnouncementScheduleCount, 1)
        view.deliverAccessibilityAnnouncementNow()
        XCTAssertEqual(announcements, ["one\ntwo"])

        let backgroundControl = NSButton(title: "Background", target: nil, action: nil)
        root.addSubview(backgroundControl)
        XCTAssertTrue(window.makeFirstResponder(backgroundControl))
        view.updateAccessibilityValue(from: "ready\none\ntwo\nbackground backlog")
        view.noteLiveOutputForAccessibility()
        XCTAssertFalse(view.accessibilityAnnouncementIsScheduled)

        XCTAssertTrue(window.makeFirstResponder(view))
        view.updateAccessibilityValue(from: "ready\none\ntwo\nbackground backlog\nresume baseline")
        view.noteLiveOutputForAccessibility()
        XCTAssertFalse(view.accessibilityAnnouncementIsScheduled)
        view.updateAccessibilityValue(from: "ready\none\ntwo\nbackground backlog\nresume baseline\nlive")
        view.noteLiveOutputForAccessibility()
        view.deliverAccessibilityAnnouncementNow()
        XCTAssertEqual(announcements, ["one\ntwo", "live"])
    }

    // First-responder claims cannot be asserted end to end on a headless CI
    // runner (windows never become key), so the decision is a pure function:
    // claim focus only from the window or its bare content view, and never
    // steal it from a control the user is in — the sidebar or the find bar.
    func testFocusClaimDecisionClaimsOnlyIdleWindows() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // NSWindow defaults to release-when-closed; under ARC that would
        // double-release when the test also owns the reference.
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertTrue(ReadOnlyTerminalView.shouldClaimFocus(currentFirstResponder: nil, window: window))
        XCTAssertTrue(ReadOnlyTerminalView.shouldClaimFocus(currentFirstResponder: window, window: window))
        XCTAssertTrue(ReadOnlyTerminalView.shouldClaimFocus(currentFirstResponder: window.contentView, window: window))

        let findBarField = NSTextField(frame: .zero)
        window.contentView?.addSubview(findBarField)
        XCTAssertFalse(ReadOnlyTerminalView.shouldClaimFocus(currentFirstResponder: findBarField, window: window))
    }

    func testOwnedSurfaceForwardsKeyboardBytesToInputCallback() {
        let coordinator = NativeTerminalSurface.Coordinator()
        var captured: [String] = []
        let view = OwnedTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        NativeTerminalSurface.configureAuthority(
            .localController(active: true),
            on: view,
            coordinator: coordinator,
            onInput: { captured.append($0) },
            onResize: nil,
            onTitleChange: nil
        )

        // SwiftTerm's ordinary keyboard path calls this inherited overload
        // directly; it does not pass through OwnedTerminalView's terminal-query
        // reply override.
        view.send(data: ArraySlice(Array("ls -la\r".utf8)))
        XCTAssertEqual(captured, ["ls -la\r"])
    }

    func testObserverSurfaceCannotBePromotedByMismatchedAuthority() {
        let coordinator = NativeTerminalSurface.Coordinator()
        var captured: [String] = []
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator

        NativeTerminalSurface.configureAuthority(
            .localController(active: true),
            on: view,
            coordinator: coordinator,
            onInput: { captured.append($0) },
            onResize: nil,
            onTitleChange: nil
        )
        view.send(data: ArraySlice(Array("must-stay-observed".utf8)))
        coordinator.send(
            source: view,
            data: ArraySlice(Array("delegate-mismatch".utf8))
        )

        XCTAssertTrue(captured.isEmpty)
        XCTAssertFalse(view.allowMouseReporting)
        XCTAssertEqual(view.accessibilityLabel(), "Read-only terminal output")
    }

    func testSealedOwnedSurfaceBlocksEveryOutboundInputPath() throws {
        let coordinator = NativeTerminalSurface.Coordinator()
        var captured: [String] = []
        var resizeCalls: [(Int, Int)] = []
        var titleCalls: [String] = []
        coordinator.onInput = { captured.append($0) }
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        let terminal = view.getTerminal()
        let droppedURL = URL(fileURLWithPath: "/tmp/Kaisola ownership flap.txt")
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        XCTAssertFalse(view.isInputAuthorized, "Controller-capable views must start fail-closed.")
        XCTAssertFalse(view.allowMouseReporting)
        XCTAssertEqual(view.accessibilityLabel(), "Read-only terminal output")
        view.send(data: ArraySlice(Array("sealed-keyboard".utf8)))
        view.send(source: terminal, data: ArraySlice(Array("sealed-reply".utf8)))
        coordinator.send(source: view, data: ArraySlice(Array("delegate-bypass".utf8)))
        view.paste(view)
        XCTAssertFalse(view.handleControlVIfImagePresent())
        XCTAssertFalse(view.sendShiftEnter())
        XCTAssertFalse(view.performFileDrop(urls: [droppedURL]))
        XCTAssertFalse(view.menu(for: rightClick)?.items.contains { $0.title == "Paste" } == true)
        XCTAssertTrue(captured.isEmpty)

        NativeTerminalSurface.configureAuthority(
            .localController(active: true),
            on: view,
            coordinator: coordinator,
            onInput: { captured.append($0) },
            onResize: { resizeCalls.append(($0, $1)) },
            onTitleChange: { titleCalls.append($0) }
        )
        XCTAssertTrue(view.isInputAuthorized)
        XCTAssertTrue(view.allowMouseReporting)
        XCTAssertEqual(view.accessibilityLabel(), "Terminal")
        view.send(data: ArraySlice(Array("live".utf8)))
        XCTAssertTrue(view.sendShiftEnter())
        XCTAssertTrue(view.performFileDrop(urls: [droppedURL]))
        XCTAssertTrue(view.menu(for: rightClick)?.items.contains { $0.title == "Paste" } == true)
        XCTAssertEqual(captured.first, "live")
        XCTAssertEqual(Array(captured.dropFirst().first?.utf8 ?? "".utf8), [0x1B, 0x0D])
        XCTAssertTrue(captured.joined().contains("Kaisola ownership flap.txt"))

        let countBeforeRevocation = captured.count
        let resizeCountBeforeRevocation = resizeCalls.count
        coordinator.setTerminalTitle(source: view, title: "queued-before-revocation")
        NativeTerminalSurface.configureAuthority(
            .localController(active: false),
            on: view,
            coordinator: coordinator,
            onInput: { captured.append($0) },
            onResize: { resizeCalls.append(($0, $1)) },
            onTitleChange: { titleCalls.append($0) }
        )
        view.send(data: ArraySlice(Array("stale-keyboard".utf8)))
        view.send(source: terminal, data: ArraySlice(Array("stale-reply".utf8)))
        coordinator.send(source: view, data: ArraySlice(Array("stale-delegate".utf8)))
        coordinator.sizeChanged(source: view, newCols: 91, newRows: 37)
        view.paste(view)
        XCTAssertFalse(view.handleControlVIfImagePresent())
        XCTAssertFalse(view.sendShiftEnter())
        XCTAssertFalse(view.performFileDrop(urls: [droppedURL]))
        XCTAssertEqual(captured.count, countBeforeRevocation)
        XCTAssertEqual(resizeCalls.count, resizeCountBeforeRevocation)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(titleCalls.isEmpty, "Revocation must cancel a title still waiting in the debounce.")
        XCTAssertFalse(view.allowMouseReporting)
        XCTAssertEqual(view.accessibilityLabel(), "Read-only terminal output")
    }

    func testDismantleSealsOwnedSurfaceBeforeCaching() throws {
        let cache = TerminalSurfaceCache.shared
        cache.removeAll()
        defer { cache.removeAll() }
        let coordinator = NativeTerminalSurface.Coordinator()
        coordinator.retainedSessionID = "retained-owned"
        var captured: [String] = []
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        NativeTerminalSurface.configureAuthority(
            .localController(active: true),
            on: view,
            coordinator: coordinator,
            onInput: { captured.append($0) },
            onResize: nil,
            onTitleChange: nil
        )
        XCTAssertTrue(view.isInputAuthorized)

        NativeTerminalSurface.dismantleNSView(view, coordinator: coordinator)
        view.send(data: ArraySlice(Array("parked-keyboard".utf8)))
        coordinator.send(source: view, data: ArraySlice(Array("parked-delegate".utf8)))

        XCTAssertFalse(view.isInputAuthorized)
        XCTAssertFalse(view.allowMouseReporting)
        XCTAssertEqual(view.accessibilityLabel(), "Read-only terminal output")
        XCTAssertTrue(captured.isEmpty)
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertFalse(view.menu(for: rightClick)?.items.contains { $0.title == "Paste" } == true)
        XCTAssertTrue(cache.claim(
            sessionID: "retained-owned",
            controllerCapable: true
        )?.view === view)
    }

    func testShiftEnterRequiresExactlyShift() {
        XCTAssertTrue(OwnedTerminalView.shouldHandleShiftEnter(
            keyCode: 36,
            modifierFlags: .shift
        ))
        XCTAssertFalse(OwnedTerminalView.shouldHandleShiftEnter(
            keyCode: 36,
            modifierFlags: [.shift, .command]
        ))
        XCTAssertFalse(OwnedTerminalView.shouldHandleShiftEnter(
            keyCode: 36,
            modifierFlags: [.shift, .control]
        ))
        XCTAssertFalse(OwnedTerminalView.shouldHandleShiftEnter(
            keyCode: 36,
            modifierFlags: [.shift, .option]
        ))
        XCTAssertFalse(OwnedTerminalView.shouldHandleShiftEnter(
            keyCode: 76,
            modifierFlags: .shift
        ), "The keypad Enter key keeps its native terminal behavior.")
    }

    func testBellCooldownCollapsesOneTUIPromptBurst() {
        let cooldown = NativeTerminalSurface.Coordinator.bellNotificationCooldown
        XCTAssertTrue(NativeTerminalSurface.Coordinator.shouldDeliverBell(
            lastDeliveredAt: nil,
            now: 10
        ))
        XCTAssertFalse(NativeTerminalSurface.Coordinator.shouldDeliverBell(
            lastDeliveredAt: 10,
            now: 10 + cooldown / 2
        ))
        XCTAssertTrue(NativeTerminalSurface.Coordinator.shouldDeliverBell(
            lastDeliveredAt: 10,
            now: 10 + cooldown
        ))
    }

    func testHistoricalBellReplayIsSilentAndLiveBellIsDeliveredOnce() {
        let coordinator = NativeTerminalSurface.Coordinator()
        var bellCount = 0
        coordinator.onBell = { bellCount += 1 }
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator

        coordinator.apply(output: "\u{7}", epoch: "bell", endOffset: 1, to: view)
        XCTAssertEqual(bellCount, 0, "Retained BEL bytes must never create a fresh alert.")

        coordinator.apply(output: "\u{7}\u{7}", epoch: "bell", endOffset: 2, to: view)
        XCTAssertEqual(bellCount, 1)
        coordinator.apply(output: "\u{7}\u{7}\u{7}", epoch: "bell", endOffset: 3, to: view)
        XCTAssertEqual(bellCount, 1, "A rapid BEL repaint burst should remain one attention signal.")
    }

    /// A pane with no agent — a plain shell — keeps receiving shell-quoted
    /// paths, which is what `cp`/`open` need. Image *attachment* behaviour for
    /// agent panes is covered by `TerminalImageDropTests`.
    func testTerminalFileDropQuotesPathsForCLIBracketedPaste() {
        let urls = [
            URL(fileURLWithPath: "/tmp/Screenshot 2026-07-24.png"),
            URL(fileURLWithPath: "/tmp/researcher's-chart.jpg"),
        ]

        XCTAssertEqual(
            OwnedTerminalView.droppedFileText(urls, agentLaunchCommand: nil),
            "'/tmp/Screenshot 2026-07-24.png' '/tmp/researcher'\\''s-chart.jpg' "
        )
        XCTAssertEqual(
            OwnedTerminalView.droppedFileText(
                [URL(string: "https://example.com/a.png")!],
                agentLaunchCommand: nil
            ),
            ""
        )
    }

    func testHistoricalTerminalQueriesNeverLeakRepliesIntoLiveShell() {
        let coordinator = NativeTerminalSurface.Coordinator()
        var captured: [String] = []
        coordinator.onInput = { captured.append($0) }
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        coordinator.setInputAuthorized(true)
        view.setInputAuthorized(true)
        view.configureTerminalTheme(light: true, themeID: "native")

        // These are the exact families seen in the corrupted prompt screenshot:
        // cursor position plus foreground/background color queries. Replaying a
        // retained snapshot must render them without writing their answers back
        // into the shell that produced the snapshot earlier.
        coordinator.apply(
            output: "prompt % \u{1B}[6n\u{1B}]10;?\u{7}\u{1B}]11;?\u{7}",
            epoch: "epoch-a",
            endOffset: 29,
            to: view
        )
        XCTAssertTrue(captured.isEmpty)
    }

    func testInitialReplayWaitsUntilTerminalHasRealGeometry() {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        coordinator.apply(output: "one\ntwo\n", epoch: "epoch-a", endOffset: 8, to: view)
        XCTAssertTrue(coordinator.isAwaitingInitialLayout)

        view.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        coordinator.flushPendingInitialRender(to: view)
        XCTAssertFalse(coordinator.isAwaitingInitialLayout)
    }

    func testFinalFrameAssignmentFlushesDeferredInitialReplay() {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.onUsableLayout = { coordinator.flushPendingInitialRender(to: view) }
        coordinator.apply(output: "ready\r\n", epoch: "epoch-a", endOffset: 7, to: view)
        XCTAssertTrue(coordinator.isAwaitingInitialLayout)

        view.setFrameSize(NSSize(width: 640, height: 320))

        XCTAssertFalse(coordinator.isAwaitingInitialLayout)
    }

    func testLargeInitialReplayYieldsInsteadOfBlockingPaneActivation() async {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let output = String(
            repeating: "0123456789abcdef\r\n",
            count: NativeTerminalSurface.Coordinator.progressiveReplayThresholdBytes / 16
        )

        coordinator.apply(
            output: output,
            epoch: "large-epoch",
            endOffset: Int64(output.utf8.count),
            to: view
        )

        XCTAssertTrue(coordinator.isProgressivelyReplaying)
        for _ in 0..<500 where coordinator.isProgressivelyReplaying {
            await Task.yield()
        }
        XCTAssertFalse(coordinator.isProgressivelyReplaying)
    }

    func testFreshTerminalQueryStillReceivesAReply() {
        let coordinator = NativeTerminalSurface.Coordinator()
        var captured: [String] = []
        coordinator.onInput = { captured.append($0) }
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        coordinator.setInputAuthorized(true)
        view.setInputAuthorized(true)
        view.configureTerminalTheme(light: true, themeID: "native")

        coordinator.apply(output: "", epoch: "epoch-a", endOffset: 0, to: view)
        let query = "\u{1B}[6n"
        coordinator.apply(
            output: query,
            epoch: "epoch-a",
            endOffset: Int64(query.utf8.count),
            to: view
        )

        XCTAssertFalse(captured.isEmpty)
        XCTAssertTrue(captured.joined().contains("R"))
    }

    func testContiguousPublishedDeltaFeedsSwiftTermWithoutScanningFullDocument() throws {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let initial = "ready\r\n"
        coordinator.apply(
            output: initial,
            epoch: "delta-epoch",
            endOffset: Int64(initial.utf8.count),
            to: view
        )
        let delta = try XCTUnwrap(TerminalSurfaceDelta(
            epoch: "delta-epoch",
            startOffset: Int64(initial.utf8.count),
            endOffset: Int64(initial.utf8.count + 6),
            data: "next\r\n"
        ))

        // Deliberately avoid placing the suffix in this reconstruction value:
        // the exact broker delta must be sufficient when cursors are aligned.
        coordinator.apply(
            output: "retained reconstruction is not scanned on this path",
            epoch: "delta-epoch",
            endOffset: delta.endOffset,
            surfaceDelta: delta,
            to: view
        )

        XCTAssertEqual(coordinator.directDeltaApplyCount, 1)
        let rendered = String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
        XCTAssertTrue(rendered.contains("ready"))
        XCTAssertTrue(rendered.contains("next"))
    }

    func testPagedScrollbackNeverFlattensForReconstructionOrDeltas() throws {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        var scrollback = TerminalScrollback("ready\r\n")
        coordinator.apply(
            scrollback: scrollback,
            epoch: "paged-epoch",
            endOffset: Int64(scrollback.byteCount),
            to: view
        )
        XCTAssertEqual(coordinator.scrollbackFlattenCount, 0)

        // Layout/theme-only SwiftUI updates reuse the rendered byte cursor.
        coordinator.apply(
            scrollback: scrollback,
            epoch: "paged-epoch",
            endOffset: Int64(scrollback.byteCount),
            to: view
        )
        XCTAssertEqual(coordinator.scrollbackFlattenCount, 0)

        let start = Int64(scrollback.byteCount)
        let data = "next\r\n"
        scrollback.append(data)
        let delta = try XCTUnwrap(TerminalSurfaceDelta(
            epoch: "paged-epoch",
            startOffset: start,
            endOffset: Int64(scrollback.byteCount),
            data: data
        ))
        coordinator.apply(
            scrollback: scrollback,
            epoch: "paged-epoch",
            endOffset: delta.endOffset,
            surfaceDelta: delta,
            to: view
        )

        XCTAssertEqual(coordinator.scrollbackFlattenCount, 0)
        XCTAssertEqual(coordinator.directDeltaApplyCount, 1)
    }

    func testOwnedTerminalSelectionSurvivesStreamingLinefeedsWithoutDisablingMouseReporting() {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.allowMouseReporting = true
        let initial = "alpha\r\nbeta"
        coordinator.apply(
            output: initial,
            epoch: "selection-epoch",
            endOffset: Int64(initial.utf8.count),
            to: view
        )
        view.selectAll(nil)
        XCTAssertGreaterThan(view.selectedRange().length, 0)

        let complete = initial + "\r\ngamma"
        coordinator.apply(
            output: complete,
            epoch: "selection-epoch",
            endOffset: Int64(complete.utf8.count),
            to: view
        )

        XCTAssertGreaterThan(view.selectedRange().length, 0)
        XCTAssertTrue(view.allowMouseReporting)
    }

    // MARK: - Clear Terminal and jump to live output

    private func scrolledUpFixture(
        lineCount: Int = 400
    ) -> (coordinator: NativeTerminalSurface.Coordinator, view: ReadOnlyTerminalView, output: String) {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.changeScrollback(2_000)
        view.configureJumpToLiveBottomAffordance()
        view.terminalDelegate = coordinator
        let output = (0..<lineCount).map { "clear-fixture-\($0)\r\n" }.joined()
        coordinator.apply(
            output: output,
            epoch: "clear-epoch",
            endOffset: Int64(output.utf8.count),
            to: view
        )
        return (coordinator, view, output)
    }

    private func visibleText(_ view: ReadOnlyTerminalView) -> String {
        let terminal = view.getTerminal()
        return terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: terminal.cols, row: Int.max)
        )
    }

    func testClearTerminalDropsTheRendererScrollbackWithoutTouchingThePTY() {
        let fixture = scrolledUpFixture()
        XCTAssertTrue(fixture.view.canScroll)
        XCTAssertTrue(visibleText(fixture.view).contains("clear-fixture-0"))

        fixture.view.clearLiveScrollback()

        XCTAssertFalse(fixture.view.canScroll, "Clearing must leave no scrollback behind.")
        let remaining = visibleText(fixture.view).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(remaining.isEmpty, "Unexpected residue: \(remaining.prefix(120))")
        XCTAssertTrue(fixture.coordinator.isFollowingLiveOutput)
    }

    func testClearTerminalKeepsTheIncrementalDeltaPathIntact() throws {
        let fixture = scrolledUpFixture()
        let appliedBefore = fixture.coordinator.directDeltaApplyCount
        fixture.view.clearLiveScrollback()

        // The broker cursor is unchanged by a renderer-local clear, so the very
        // next frame must still append rather than force a full re-feed (which
        // would silently repaint everything the user just cleared).
        let addition = "after-clear\r\n"
        let combined = fixture.output + addition
        let delta = try XCTUnwrap(TerminalSurfaceDelta(
            epoch: "clear-epoch",
            startOffset: Int64(fixture.output.utf8.count),
            endOffset: Int64(combined.utf8.count),
            data: addition
        ))
        fixture.coordinator.apply(
            output: combined,
            epoch: "clear-epoch",
            endOffset: Int64(combined.utf8.count),
            surfaceDelta: delta,
            to: fixture.view
        )

        XCTAssertEqual(fixture.coordinator.directDeltaApplyCount, appliedBefore + 1)
        let visible = visibleText(fixture.view)
        XCTAssertTrue(visible.contains("after-clear"))
        XCTAssertFalse(
            visible.contains("clear-fixture-0"),
            "A cleared renderer must not resurrect earlier output from an incremental frame."
        )
    }

    /// Clearing while a retained transcript is still being fed in
    /// progressively must refuse rather than half-apply: the next replay
    /// chunk would otherwise repaint straight over an "erased" screen.
    func testClearDuringProgressiveReplayIsRefusedNotHalfUndone() async {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator
        let output = String(
            repeating: "0123456789abcdef\r\n",
            count: NativeTerminalSurface.Coordinator.progressiveReplayThresholdBytes / 16
        )
        coordinator.apply(
            output: output,
            epoch: "large-epoch",
            endOffset: Int64(output.utf8.count),
            to: view
        )
        XCTAssertTrue(coordinator.isProgressivelyReplaying)

        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        XCTAssertFalse(
            view.clearLiveScrollback(),
            "clearing mid-replay must be refused, not applied and then half-undone by the next chunk"
        )
        XCTAssertEqual(ToastCenter.shared.toasts.last?.message, TerminalClearCommand.noTerminalMessage)

        for _ in 0..<500 where coordinator.isProgressivelyReplaying {
            await Task.yield()
        }
        XCTAssertFalse(coordinator.isProgressivelyReplaying)
    }

    func testJumpToBottomIsOfferedOnlyWhileGenuinelyScrolledUp() {
        XCTAssertTrue(TerminalJumpToBottomPolicy.isVisible(
            canScroll: true,
            isAtLiveBottom: false,
            isAlternateBuffer: false
        ))
        XCTAssertFalse(TerminalJumpToBottomPolicy.isVisible(
            canScroll: true,
            isAtLiveBottom: true,
            isAlternateBuffer: false
        ))
        XCTAssertFalse(TerminalJumpToBottomPolicy.isVisible(
            canScroll: false,
            isAtLiveBottom: false,
            isAlternateBuffer: false
        ))
        // A full-screen TUI pins scrollPosition to 0 on the alternate buffer;
        // "the bottom" is meaningless there and the pill must stay away.
        XCTAssertFalse(TerminalJumpToBottomPolicy.isVisible(
            canScroll: true,
            isAtLiveBottom: false,
            isAlternateBuffer: true
        ))
    }

    func testJumpToBottomPillSitsInsideTheTrailingBottomCornerInBothGeometries() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        let size = NSSize(width: 90, height: 20)

        let unflipped = TerminalJumpToBottomPolicy.frame(in: bounds, size: size, flipped: false)
        XCTAssertEqual(unflipped.minY, TerminalJumpToBottomPolicy.bottomInset, accuracy: 0.001)
        let flipped = TerminalJumpToBottomPolicy.frame(in: bounds, size: size, flipped: true)
        XCTAssertEqual(
            flipped.maxY,
            bounds.maxY - TerminalJumpToBottomPolicy.bottomInset,
            accuracy: 0.001
        )
        for frame in [unflipped, flipped] {
            XCTAssertTrue(bounds.contains(frame))
            XCTAssertLessThan(frame.maxX, bounds.maxX - TerminalJumpToBottomPolicy.scrollerInset)
        }

        // A pane narrower than the pill must still produce an on-screen frame.
        let cramped = TerminalJumpToBottomPolicy.frame(
            in: NSRect(x: 0, y: 0, width: 40, height: 40),
            size: size,
            flipped: false
        )
        XCTAssertEqual(cramped.minX, 0, accuracy: 0.001)
    }

    func testJumpToBottomPillAppearsOnScrollUpAndRepinsWhenUsed() {
        let fixture = scrolledUpFixture()
        XCTAssertFalse(
            fixture.view.jumpToLiveBottomIsVisible,
            "A freshly pinned terminal has nothing to jump back to."
        )

        fixture.view.scrollUp(lines: 40)
        fixture.view.updateJumpToLiveBottomVisibility()
        XCTAssertTrue(fixture.view.jumpToLiveBottomIsVisible)

        XCTAssertTrue(fixture.view.performJumpToLiveBottom())
        XCTAssertTrue(fixture.view.isViewportAtLiveBottom)
        XCTAssertTrue(fixture.coordinator.isFollowingLiveOutput)
        XCTAssertFalse(fixture.view.jumpToLiveBottomIsVisible)
        // Using the pill must not be a one-shot: following resumes, so the next
        // output frame stays glued to the bottom.
        XCTAssertFalse(fixture.view.performJumpToLiveBottom())
    }

    func testFocusedTerminalPrefersThePaneTheModelRings() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        let first = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 400),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        first.paneSessionID = "terminal:a"
        let second = OwnedTerminalView(
            frame: NSRect(x: 300, y: 0, width: 300, height: 400),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        second.paneSessionID = "terminal:b"
        root.addSubview(first)
        root.addSubview(second)

        XCTAssertTrue(
            TerminalFocusResolver.focusedTerminal(in: window, paneID: "terminal:b") === second
        )
        // No pane id (a chat or Mesh is focused): fall back to the responder.
        window.makeFirstResponder(second)
        XCTAssertTrue(TerminalFocusResolver.focusedTerminal(in: window, paneID: nil) === second)
        // An id that is not on screen must not silently retarget another pane's
        // terminal through the pane lane, but a live responder is still valid.
        XCTAssertTrue(
            TerminalFocusResolver.focusedTerminal(in: window, paneID: "terminal:gone") === second
        )
        XCTAssertNil(TerminalFocusResolver.focusedTerminal(in: nil, paneID: "terminal:a"))
    }

    /// The bug this guards: a chat or Mesh pane focused while an unrelated
    /// terminal exists elsewhere in the window must never silently become
    /// ⌥⌘K's (or Scroll to Latest's) target. Refuse instead of reaching for
    /// "any terminal in the tree".
    func testFocusedTerminalRefusesRatherThanGrabbingAnUnrelatedTerminal() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        let terminal = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 400),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        terminal.paneSessionID = "terminal:a"
        root.addSubview(terminal)

        let chatField = NSTextView(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        root.addSubview(chatField)
        window.makeFirstResponder(chatField)

        // The model rings a chat pane and the keyboard genuinely sits in its
        // text view. A terminal exists elsewhere in the window, but the user
        // cannot see it being targeted.
        XCTAssertNil(TerminalFocusResolver.focusedTerminal(in: window, paneID: "chat:z"))
    }

    func testViewMenuCarriesClearTerminalAndScrollToLatestWithSafeShortcuts() throws {
        let action = #selector(NSResponder.doCommand(by:))
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            viewTarget: nil,
            layoutAction: action,
            appearanceAction: action,
            terminalCommandTarget: nil,
            clearTerminalAction: action,
            scrollToLatestOutputAction: action
        )
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let clear = try XCTUnwrap(viewMenu.items.first { $0.title == "Clear Terminal" })
        XCTAssertEqual(clear.keyEquivalent, "k")
        XCTAssertEqual(clear.keyEquivalentModifierMask, [.command, .option])
        let latest = try XCTUnwrap(viewMenu.items.first { $0.title == "Scroll to Latest Output" })
        XCTAssertEqual(latest.keyEquivalent, "\u{F701}")
        XCTAssertEqual(latest.keyEquivalentModifierMask, [.command, .option])

        // Command-K belongs to the palette; nothing in the bar may claim it.
        let plainCommandK = menu.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.keyEquivalent == "k" && $0.keyEquivalentModifierMask == [.command] }
        XCTAssertTrue(plainCommandK.isEmpty)
    }

    // MARK: - Consented OSC 52 clipboard writes

    private func clipboardPayload(_ text: String) -> Data {
        Data(text.utf8)
    }

    func testClipboardWriteIsRefusedUntilTheUserGrantsIt() {
        let payload = clipboardPayload("git push --force-with-lease")

        XCTAssertEqual(
            TerminalClipboardWriteRequest.decide(
                content: payload,
                consentGranted: false,
                hasShownGuidance: false
            ),
            .refused(showsGuidance: true)
        )
        // Only the first blocked attempt earns a toast; a chatty program must
        // not be able to turn a refusal into a wall of notifications.
        XCTAssertEqual(
            TerminalClipboardWriteRequest.decide(
                content: payload,
                consentGranted: false,
                hasShownGuidance: true
            ),
            .refused(showsGuidance: false)
        )
        XCTAssertEqual(
            TerminalClipboardWriteRequest.decide(
                content: payload,
                consentGranted: true,
                hasShownGuidance: true
            ),
            .copy("git push --force-with-lease")
        )
    }

    func testClipboardWriteDropsTheTrailingNewlineThatWouldAutoExecute() {
        XCTAssertEqual(
            TerminalClipboardWriteRequest.decide(
                content: clipboardPayload("rm -rf ~/work\n"),
                consentGranted: true,
                hasShownGuidance: true
            ),
            .copy("rm -rf ~/work")
        )
        // Interior newlines are ordinary multi-line text and must survive.
        XCTAssertEqual(
            TerminalClipboardWriteRequest.decide(
                content: clipboardPayload("first\nsecond\r\n"),
                consentGranted: true,
                hasShownGuidance: true
            ),
            .copy("first\nsecond")
        )
    }

    func testClipboardWriteIgnoresPayloadsNobodyCouldHaveMeantToPaste() {
        for content in [
            Data(),
            clipboardPayload("\n\n"),
            // Escape and NUL hide part of a payload from whatever renders it.
            clipboardPayload("safe\u{1B}[2Kmalicious"),
            clipboardPayload("nul\u{0}byte"),
            Data([0xFF, 0xFE, 0xFD]),
            clipboardPayload(String(repeating: "x", count: TerminalClipboardWriteRequest.maximumPayloadBytes + 1)),
        ] {
            XCTAssertEqual(
                TerminalClipboardWriteRequest.decide(
                    content: content,
                    consentGranted: true,
                    hasShownGuidance: true
                ),
                .ignored
            )
            // An unusable payload must not spend the one guidance toast either.
            XCTAssertEqual(
                TerminalClipboardWriteRequest.decide(
                    content: content,
                    consentGranted: false,
                    hasShownGuidance: false
                ),
                .ignored
            )
        }
        // Tabs are ordinary pasteboard text.
        XCTAssertEqual(
            TerminalClipboardWriteRequest.decide(
                content: clipboardPayload("a\tb"),
                consentGranted: true,
                hasShownGuidance: true
            ),
            .copy("a\tb")
        )
    }

    /// A retained transcript can contain an old OSC 52 write. Replaying it
    /// (initial or progressive reconstruction) must render the bytes without
    /// ever reaching the live pasteboard — the same non-negotiable rule
    /// `bell` and terminal-query replies already follow for reconstructed
    /// history.
    func testHistoricalOSC52ClipboardWritesAreNeverReplayed() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kaisola-osc52-replay-tests"))
        pasteboard.clearContents()
        pasteboard.setString("kaisola-untouched", forType: .string)
        defer { pasteboard.releaseGlobally() }

        let coordinator = NativeTerminalSurface.Coordinator()
        coordinator.clipboard = pasteboard
        coordinator.allowsClipboardWrite = true
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator

        let encoded = Data("stolen-from-history".utf8).base64EncodedString()
        coordinator.apply(
            output: "prompt % \u{1B}]52;c;\(encoded)\u{7}",
            epoch: "epoch-a",
            endOffset: 40,
            to: view
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "kaisola-untouched")
    }

    func testTerminalStreamCannotWriteTheClipboardWithoutConsent() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kaisola-osc52-tests"))
        pasteboard.clearContents()
        pasteboard.setString("kaisola-untouched", forType: .string)
        defer { pasteboard.releaseGlobally() }

        let coordinator = NativeTerminalSurface.Coordinator()
        coordinator.clipboard = pasteboard
        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.terminalDelegate = coordinator

        // OSC 52 as a hostile program would actually emit it.
        let encoded = Data("stolen".utf8).base64EncodedString()
        view.feed(text: "\u{1B}]52;c;\(encoded)\u{7}")
        XCTAssertEqual(pasteboard.string(forType: .string), "kaisola-untouched")

        coordinator.allowsClipboardWrite = true
        view.feed(text: "\u{1B}]52;c;\(encoded)\u{7}")
        XCTAssertEqual(pasteboard.string(forType: .string), "stolen")

        // Reading is refused regardless of the write setting: a reply here
        // would hand the user's clipboard to whatever is running in the pane.
        XCTAssertNil(coordinator.clipboardRead(source: view))
    }

    func testClipboardWriteConsentDefaultsOffAndPersists() throws {
        let suite = "kaisola-clipboard-consent-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = NativePreviewSettings(defaults: defaults)
        XCTAssertFalse(settings.terminalClipboardWriteAllowed)
        settings.terminalClipboardWriteAllowed = true
        XCTAssertTrue(NativePreviewSettings(defaults: defaults).terminalClipboardWriteAllowed)
    }

    // MARK: - Focus synchronization

    private func twoPaneWindow() -> (window: NSWindow, a: OwnedTerminalView, b: OwnedTerminalView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let a = OwnedTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 400), font: font)
        a.paneSessionID = "terminal:a"
        let b = OwnedTerminalView(frame: NSRect(x: 300, y: 0, width: 300, height: 400), font: font)
        b.paneSessionID = "terminal:b"
        root.addSubview(a)
        root.addSubview(b)
        return (window, a, b)
    }

    func testClickingIntoATerminalReportsKeyboardFocusForItsPane() throws {
        let panes = twoPaneWindow()
        var reported: [String] = []
        panes.a.onKeyboardFocus = { reported.append("terminal:a") }
        panes.b.onKeyboardFocus = { reported.append("terminal:b") }
        panes.window.makeFirstResponder(panes.a)

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 400, y: 200),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panes.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        panes.b.mouseDown(with: click)

        XCTAssertEqual(reported, ["terminal:b"])
    }

    /// Mounting into a window (a restored window, a project switch
    /// reattaching a retained view) still needs an AppKit first responder,
    /// but mounting is not a user action: it must not publish keyboard focus
    /// to the model, or a mounting pane could steal the ring — and the
    /// broker observer role that follows it — from whatever pane the model
    /// had already restored. Only a genuine user gesture (a click) publishes.
    func testMountingIntoAWindowClaimsFirstResponderWithoutPublishingKeyboardFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root

        let view = OwnedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.paneSessionID = "terminal:mounting"
        var published: [String] = []
        view.onKeyboardFocus = { published.append("terminal:mounting") }

        root.addSubview(view)

        XCTAssertTrue(window.firstResponder === view, "mounting must still claim the AppKit first responder")
        XCTAssertTrue(published.isEmpty, "mounting must not publish keyboard focus to the model")

        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 200, y: 150),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        view.mouseDown(with: click)
        XCTAssertEqual(published, ["terminal:mounting"], "a genuine user click must still publish")
    }

    func testFocusingASurfaceMovesTheAppKitFirstResponderToItsTerminal() {
        let panes = twoPaneWindow()
        panes.window.makeFirstResponder(panes.a)
        XCTAssertTrue(panes.window.firstResponder === panes.a)

        XCTAssertTrue(TerminalKeyboardFocus.moveFirstResponder(
            toSessionID: "terminal:b",
            in: panes.window
        ))
        XCTAssertTrue(panes.window.firstResponder === panes.b)

        // Already there: nothing to do, and no redundant AppKit churn.
        XCTAssertFalse(TerminalKeyboardFocus.moveFirstResponder(
            toSessionID: "terminal:b",
            in: panes.window
        ))
        // A surface with no terminal on screen (a chat, a closed pane) leaves
        // keyboard focus exactly where it was.
        XCTAssertFalse(TerminalKeyboardFocus.moveFirstResponder(
            toSessionID: "chat:z",
            in: panes.window
        ))
        XCTAssertTrue(panes.window.firstResponder === panes.b)
    }

    func testFocusMoveNeverStealsTheKeyboardFromSomewhereTheUserIsTyping() {
        XCTAssertTrue(TerminalKeyboardFocus.canClaimFocus(from: nil))
        let button = NSButton(title: "Focus", target: nil, action: nil)
        XCTAssertTrue(TerminalKeyboardFocus.canClaimFocus(from: button))
        // Every editable NSTextField hands its window an NSTextView field
        // editor as the first responder while the user types in it.
        XCTAssertFalse(TerminalKeyboardFocus.canClaimFocus(from: NSTextView()))

        let panes = twoPaneWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        panes.window.contentView?.addSubview(field)
        panes.window.makeFirstResponder(field)
        let editing = panes.window.firstResponder
        XCTAssertFalse(TerminalKeyboardFocus.moveFirstResponder(
            toSessionID: "terminal:a",
            in: panes.window
        ))
        XCTAssertTrue(panes.window.firstResponder === editing)
    }

    func testViewMenuCarriesPaneFocusCyclingClearOfTheFileTabShortcuts() throws {
        let action = #selector(NSResponder.doCommand(by:))
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            viewTarget: nil,
            layoutAction: action,
            appearanceAction: action,
            fileTabTarget: nil,
            previousFileTabAction: action,
            nextFileTabAction: action,
            paneFocusTarget: nil,
            focusNextPaneAction: action,
            focusPreviousPaneAction: action
        )
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let next = try XCTUnwrap(viewMenu.items.first { $0.title == "Focus Next Pane" })
        XCTAssertEqual(next.keyEquivalent, "\u{F703}")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command, .control])
        let previous = try XCTUnwrap(viewMenu.items.first { $0.title == "Focus Previous Pane" })
        XCTAssertEqual(previous.keyEquivalent, "\u{F702}")
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.command, .control])

        // Option-Command-arrows still belong to the editor tabs; the two pairs
        // must stay distinct or one of the commands becomes unreachable.
        for item in [
            try XCTUnwrap(viewMenu.items.first { $0.title == "Next File Tab" }),
            try XCTUnwrap(viewMenu.items.first { $0.title == "Previous File Tab" }),
        ] {
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        }
        let duplicates = Dictionary(
            grouping: viewMenu.items.filter { !$0.keyEquivalent.isEmpty },
            by: { "\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)" }
        ).filter { $0.value.count > 1 }
        XCTAssertTrue(duplicates.isEmpty, "Conflicting View shortcuts: \(duplicates.keys)")
    }

    func testReadOnlyViewStillDropsAllPTYBoundBytes() {
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        // Device-status query would normally produce a reply back to the PTY;
        // the read-only override must swallow it. Crashing or sending would
        // fail the test harness, and selection stays available regardless.
        view.feed(text: "\u{1b}[5n")
        view.selectAll(nil)
        XCTAssertNoThrow(view.copy(NSNull()))
    }
}
