import Darwin
import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

/// Drives the ACP client through a scripted in-memory transport so the wire
/// protocol (initialize → session/new → session/prompt → session/update
/// stream, plus a permission callback) is verified without spawning a process.
final class AcpClientTests: XCTestCase {
    func testCustomAdapterLaunchUsesSeatbeltAndAProviderScopedEnvironment() throws {
        let fixture = try CustomContainmentFixture()
        let containment = CustomAdapterContainment(
            agentID: "custom-probe",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: CustomAdapterApproval(
                credentials: .claude,
                privileges: [.network, .workspaceRead]
            ),
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            sandboxExecutableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            stateRoot: fixture.stateRoot
        )
        let source = [
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
            "ANTHROPIC_MODEL": "sonnet",
            "CLAUDE_CODE_OAUTH_TOKEN": "oauth-secret",
            "CLAUDE_CONFIG_DIR": fixture.claudeConfig.path,
            "OPENAI_API_KEY": "unrelated-openai-secret",
            "CODEX_HOME": fixture.codexHome.path,
            "AWS_SECRET_ACCESS_KEY": "cloud-secret",
            "GITHUB_TOKEN": "github-secret",
            "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock",
            "DYLD_INSERT_LIBRARIES": "/private/tmp/inject.dylib",
            "NODE_OPTIONS": "--require=/private/tmp/inject.js",
            "PATH": "/attacker/bin:/usr/bin",
            "SHELL": "/attacker/shell",
            "HOME": "/host-home",
            "CFFIXED_USER_HOME": "/host-fixed-home",
            "TMPDIR": "/host-tmp/",
            "XDG_CONFIG_HOME": "/host-config",
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            "KAISOLA": "1",
            "KAISOLA_SESSION_ID": "chat-26",
        ]

        let launch = try containment.prepare(environment: source, cwd: fixture.workspace.path)

        XCTAssertEqual(launch.command, "/usr/bin/sandbox-exec")
        XCTAssertEqual(
            Array(launch.arguments.suffix(2)),
            [try fixture.canonicalPath(fixture.runtime), try fixture.canonicalPath(fixture.adapter)]
        )
        XCTAssertFalse(launch.arguments.joined(separator: "\n").contains("anthropic-secret"))
        XCTAssertFalse(launch.arguments.joined(separator: "\n").contains("github-secret"))
        XCTAssertEqual(launch.environment["ANTHROPIC_API_KEY"], "anthropic-secret")
        XCTAssertEqual(launch.environment["CLAUDE_CODE_OAUTH_TOKEN"], "oauth-secret")
        XCTAssertEqual(
            launch.environment["CLAUDE_CONFIG_DIR"],
            try fixture.canonicalPath(fixture.claudeConfig)
        )
        XCTAssertNil(launch.environment["OPENAI_API_KEY"])
        XCTAssertNil(launch.environment["CODEX_HOME"])
        XCTAssertNil(launch.environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(launch.environment["GITHUB_TOKEN"])
        XCTAssertNil(launch.environment["SSH_AUTH_SOCK"])
        XCTAssertNil(launch.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(launch.environment["NODE_OPTIONS"])
        XCTAssertNil(launch.environment["SHELL"])
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(launch.environment["HOME"], try fixture.canonicalPath(fixture.privateHome))
        XCTAssertEqual(launch.environment["CFFIXED_USER_HOME"], try fixture.canonicalPath(fixture.privateHome))
        XCTAssertEqual(launch.environment["TMPDIR"], try fixture.canonicalPath(fixture.privateTemporary) + "/")
        XCTAssertEqual(launch.environment["KAISOLA_ACP_CONTAINMENT"], "1")
        XCTAssertEqual(
            Set(launch.environment.keys),
            Set([
                "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL",
                "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "LANG", "TERM",
                "KAISOLA", "KAISOLA_SESSION_ID", "KAISOLA_ACP_CONTAINMENT", "PATH",
                "HOME", "CFFIXED_USER_HOME", "TMPDIR", "XDG_CACHE_HOME",
                "XDG_CONFIG_HOME", "XDG_DATA_HOME", "NPM_CONFIG_CACHE",
                "NODE_REPL_HISTORY", "NO_UPDATE_NOTIFIER",
            ])
        )
        XCTAssertTrue(launch.access.workspaceRead)
        XCTAssertFalse(launch.access.workspaceWrite)
        XCTAssertTrue(launch.access.network)
        XCTAssertFalse(launch.access.childProcess)
        XCTAssertFalse(launch.access.hostTerminal)

        let profile = try XCTUnwrap(launch.sandboxProfile)
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertTrue(profile.contains("(system-network)"))
        XCTAssertTrue(profile.contains("(subpath (param \"KAISOLA_WORKSPACE\"))"))
        XCTAssertFalse(profile.contains("(allow process-fork)"))
        XCTAssertFalse(profile.contains("(allow file-write* (subpath (param \"KAISOLA_WORKSPACE\")))"))
    }

    func testCustomAdapterProfileOpensOnlyReviewedCapabilities() {
        let minimal = CustomAdapterContainment.profile(privileges: [])
        XCTAssertTrue(minimal.contains("(deny default)"))
        XCTAssertTrue(minimal.contains("(deny network-outbound (literal \"/private/var/run/syslog\"))"))
        XCTAssertFalse(minimal.contains("(system-network)"))
        XCTAssertFalse(minimal.contains("(allow file-read* (subpath (param \"KAISOLA_WORKSPACE\")))"))
        XCTAssertFalse(minimal.contains("(allow process-fork)"))

        let reviewed = CustomAdapterContainment.profile(
            privileges: [.network, .workspaceRead, .workspaceWrite, .childProcess]
        )
        XCTAssertTrue(reviewed.contains("(system-network)"))
        XCTAssertTrue(reviewed.contains("(allow network-outbound"))
        XCTAssertTrue(reviewed.contains("(allow file-read* (subpath (param \"KAISOLA_WORKSPACE\")))"))
        XCTAssertTrue(reviewed.contains("(allow file-write* (subpath (param \"KAISOLA_WORKSPACE\")))"))
        XCTAssertTrue(reviewed.contains("(allow process-fork)"))
        XCTAssertTrue(reviewed.contains("(allow process-exec)"))
    }

    func testCustomAdapterContainmentFailsClosedWithActionableReasons() throws {
        let fixture = try CustomContainmentFixture()
        let approval = CustomAdapterApproval(credentials: .claude, privileges: [])

        XCTAssertThrowsError(try CustomAdapterContainment(
            agentID: "custom-probe",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: approval,
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            sandboxExecutableURL: fixture.root.appending(path: "missing-sandbox"),
            stateRoot: fixture.stateRoot
        ).prepare(environment: ["CLAUDE_CONFIG_DIR": fixture.claudeConfig.path], cwd: fixture.workspace.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("sandbox-exec"), error.localizedDescription)
        }

        XCTAssertThrowsError(try CustomAdapterContainment(
            agentID: "custom-probe",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: approval,
            runtime: .fixed(
                executableURL: fixture.root.appending(path: "missing-runtime"),
                trustedRoot: fixture.runtimeRoot
            ),
            stateRoot: fixture.stateRoot
        ).prepare(environment: ["CLAUDE_CONFIG_DIR": fixture.claudeConfig.path], cwd: fixture.workspace.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("runtime"), error.localizedDescription)
        }

        XCTAssertThrowsError(try CustomAdapterContainment(
            agentID: "custom-probe",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: approval,
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            stateRoot: fixture.stateRoot
        ).prepare(
            environment: ["CLAUDE_CONFIG_DIR": FileManager.default.homeDirectoryForCurrentUser.path],
            cwd: fixture.workspace.path
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("too broad"), error.localizedDescription)
        }

        XCTAssertThrowsError(try CustomAdapterContainment(
            agentID: "custom-probe",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: approval,
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            stateRoot: fixture.stateRoot
        ).prepare(
            environment: ["CLAUDE_CONFIG_DIR": fixture.installRoot.path],
            cwd: fixture.workspace.path
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("overlaps protected"), error.localizedDescription)
        }

        XCTAssertThrowsError(try CustomAdapterContainment(
            agentID: "custom-probe",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: CustomAdapterApproval(credentials: .none, privileges: []),
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            stateRoot: fixture.workspace.appending(path: "adapter-state", directoryHint: .isDirectory)
        ).prepare(environment: [:], cwd: fixture.workspace.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("overlaps"), error.localizedDescription)
        }
    }

    func testSeatbeltRuntimeBlocksUnreviewedFilesAndProcesses() throws {
        let fixture = try CustomContainmentFixture(scriptedProbe: true)
        let minimal = CustomAdapterContainment(
            agentID: "custom-probe",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: CustomAdapterApproval(credentials: .none, privileges: []),
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            stateRoot: fixture.stateRoot
        )
        let minimalResult = try fixture.run(minimal.prepare(environment: [:], cwd: fixture.workspace.path))
        XCTAssertNotEqual(minimalResult.status, 0)
        XCTAssertTrue(minimalResult.stdout.contains("private-home=allowed"), minimalResult.stdout)
        XCTAssertTrue(minimalResult.stderr.contains("fork failed"), minimalResult.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceOutput.path))

        let fileRestricted = CustomAdapterContainment(
            agentID: "custom-probe-files-restricted",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: CustomAdapterApproval(credentials: .none, privileges: [.childProcess]),
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            stateRoot: fixture.fileRestrictedStateRoot
        )
        let fileRestrictedResult = try fixture.run(
            fileRestricted.prepare(environment: [:], cwd: fixture.workspace.path)
        )
        XCTAssertEqual(fileRestrictedResult.status, 0, fileRestrictedResult.stderr)
        XCTAssertTrue(fileRestrictedResult.stdout.contains("secret=blocked"), fileRestrictedResult.stdout)
        XCTAssertTrue(fileRestrictedResult.stdout.contains("install-symlink=blocked"), fileRestrictedResult.stdout)
        XCTAssertTrue(fileRestrictedResult.stdout.contains("workspace-read=blocked"), fileRestrictedResult.stdout)
        XCTAssertTrue(fileRestrictedResult.stdout.contains("workspace-list=blocked"), fileRestrictedResult.stdout)
        XCTAssertTrue(fileRestrictedResult.stdout.contains("workspace-write=blocked"), fileRestrictedResult.stdout)
        XCTAssertTrue(fileRestrictedResult.stdout.contains("process=allowed"), fileRestrictedResult.stdout)
        XCTAssertTrue(fileRestrictedResult.stdout.contains("private-home=allowed"), fileRestrictedResult.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceOutput.path))

        let reviewed = CustomAdapterContainment(
            agentID: "custom-probe-reviewed",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: CustomAdapterApproval(
                credentials: .none,
                privileges: [.workspaceRead, .workspaceWrite, .childProcess]
            ),
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            stateRoot: fixture.reviewedStateRoot
        )
        let reviewedResult = try fixture.run(reviewed.prepare(environment: [:], cwd: fixture.workspace.path))
        XCTAssertEqual(reviewedResult.status, 0, reviewedResult.stderr)
        XCTAssertTrue(reviewedResult.stdout.contains("secret=blocked"), reviewedResult.stdout)
        XCTAssertTrue(reviewedResult.stdout.contains("install-symlink=blocked"), reviewedResult.stdout)
        XCTAssertTrue(reviewedResult.stdout.contains("workspace-read=allowed"), reviewedResult.stdout)
        XCTAssertTrue(reviewedResult.stdout.contains("workspace-list=allowed"), reviewedResult.stdout)
        XCTAssertTrue(reviewedResult.stdout.contains("workspace-write=allowed"), reviewedResult.stdout)
        XCTAssertTrue(reviewedResult.stdout.contains("process=allowed"), reviewedResult.stdout)
    }

    func testSeatbeltNetworkGrantControlsOutboundIPConnections() throws {
        let listener = try LoopbackListener()
        let fixture = try CustomContainmentFixture(networkProbePort: listener.port)
        let denied = CustomAdapterContainment(
            agentID: "custom-network-denied",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: CustomAdapterApproval(credentials: .none, privileges: [.childProcess]),
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            stateRoot: fixture.stateRoot
        )
        let deniedResult = try fixture.run(denied.prepare(environment: [:], cwd: fixture.workspace.path))
        XCTAssertEqual(deniedResult.status, 0, deniedResult.stderr)
        XCTAssertTrue(deniedResult.stdout.contains("network=blocked"), deniedResult.stdout)

        let allowed = CustomAdapterContainment(
            agentID: "custom-network-allowed",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: CustomAdapterApproval(
                credentials: .none,
                privileges: [.childProcess, .network]
            ),
            runtime: .fixed(executableURL: fixture.runtime, trustedRoot: fixture.runtimeRoot),
            stateRoot: fixture.reviewedStateRoot
        )
        let allowedResult = try fixture.run(allowed.prepare(environment: [:], cwd: fixture.workspace.path))
        XCTAssertEqual(allowedResult.status, 0, allowedResult.stderr)
        XCTAssertTrue(allowedResult.stdout.contains("network=allowed"), allowedResult.stdout)
    }

    func testPinnedNodeRuntimeExecutesJavaScriptInsideTheBoundary() throws {
        let configuredRuntime = ProcessInfo.processInfo.environment["KAISOLA_TEST_NODE_RUNTIME"]
            .map { URL(fileURLWithPath: $0) }
        let repositoryRuntime = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ".artifacts/node-v22.23.1-darwin-arm64/bin/node")
        let runtime = configuredRuntime ?? repositoryRuntime
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw XCTSkip("checksum-pinned Node fixture is unavailable; run download-native-node-runtime.cjs")
        }
        let canonicalRuntime = runtime.resolvingSymlinksInPath()

        let fixture = try CustomContainmentFixture(javascriptProbe: true)
        let containment = CustomAdapterContainment(
            agentID: "custom-node-probe",
            executableURL: fixture.adapter,
            installRoot: fixture.installRoot,
            approval: CustomAdapterApproval(credentials: .none, privileges: []),
            runtime: .fixed(
                executableURL: canonicalRuntime,
                trustedRoot: canonicalRuntime.deletingLastPathComponent()
            ),
            stateRoot: fixture.stateRoot
        )
        let launch = try containment.prepare(
            environment: ["GITHUB_TOKEN": "must-not-reach-node"],
            cwd: fixture.workspace.path
        )
        let result = try fixture.run(launch)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("secret=blocked"), result.stdout)
        XCTAssertTrue(result.stdout.contains("workspace-read=blocked"), result.stdout)
        XCTAssertTrue(result.stdout.contains("private-home=allowed"), result.stdout)
        XCTAssertTrue(result.stdout.contains("github-token=absent"), result.stdout)
    }

    func testContainedClientAdvertisesAndEnforcesOnlyReviewedHostBridges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-acp-contained-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("readable".utf8).write(to: directory.appending(path: "input.txt"))

        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        _ = try await client.start(
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: directory.path,
            mcpServers: [
                .object(["name": .string("local"), "command": .string("tool")]),
                .object(["type": .string("http"), "name": .string("remote"), "url": .string("https://example.com")]),
                .object(["type": .string("future"), "name": .string("unknown")]),
            ],
            access: .contained(privileges: [.workspaceRead, .childProcess])
        )

        let receivedCapabilities = await transport.receivedClientCapabilities()
        let advertised = try XCTUnwrap(receivedCapabilities?.objectValue)
        XCTAssertEqual(advertised["fs"]?.objectValue?["readTextFile"], .bool(true))
        XCTAssertEqual(advertised["fs"]?.objectValue?["writeTextFile"], .bool(false))
        XCTAssertEqual(advertised["terminal"], .bool(false))
        let receivedMCPServers = await transport.receivedSessionMcpServers()
        XCTAssertEqual(receivedMCPServers.map { $0.objectValue?["name"]?.stringValue }, ["local"])

        await transport.sendAgentRequest(
            id: 901,
            method: "fs/write_text_file",
            params: .object(["path": .string("blocked.txt"), "content": .string("blocked")])
        )
        let writeResponse = try await transport.waitForClientResponse(id: 901)
        XCTAssertTrue(
            writeResponse.objectValue?["error"]?.objectValue?["message"]?.stringValue?
                .contains("workspace write was not approved") == true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "blocked.txt").path))

        await transport.sendAgentRequest(
            id: 902,
            method: "terminal/create",
            params: .object(["command": .string("/usr/bin/env")])
        )
        let terminalResponse = try await transport.waitForClientResponse(id: 902)
        XCTAssertTrue(
            terminalResponse.objectValue?["error"]?.objectValue?["message"]?.stringValue?
                .contains("host terminals are unavailable") == true
        )
        await client.stop()
    }

    @MainActor
    func testOwnedConversationCanRestartAfterAdapterExit() async {
        let conversation = AcpConversation(
            title: "Restart", command: "/usr/bin/true", arguments: [], cwd: "/tmp"
        )

        // `true` exits before the ACP initialize handshake. A restart must
        // replace the dead Process transport and complete another bounded
        // attempt instead of reusing its closed handles or hanging.
        await conversation.start()
        XCTAssertFalse(conversation.isConnected)
        XCTAssertTrue(conversation.canRestart)

        await conversation.restart()
        XCTAssertFalse(conversation.isConnected)
        XCTAssertFalse(conversation.isReconnecting)
        XCTAssertTrue(conversation.canRestart)
        XCTAssertNotNil(conversation.statusMessage)
    }

    @MainActor
    func testRestartResumesOnlyNeverDispatchedFollowUpsInExactFIFOOrder() async throws {
        let crashedTransport = ScriptedAcpTransport(crashOnFirstPrompt: true)
        let recoveredTransport = ScriptedAcpTransport()
        let clients = [
            AcpClient(transport: crashedTransport),
            AcpClient(transport: recoveredTransport),
        ]
        var clientIndex = 0
        let conversation = AcpConversation(
            title: "Queue recovery",
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: "/tmp",
            clientFactory: {
                let client = clients[clientIndex]
                clientIndex += 1
                return client
            }
        )
        await conversation.start()

        XCTAssertTrue(conversation.send("ambiguous in-flight prompt"))
        XCTAssertTrue(conversation.send("oldest never-dispatched follow-up"))
        XCTAssertTrue(conversation.send("newest never-dispatched follow-up"))

        var deadline = Date().addingTimeInterval(5)
        while conversation.isConnected || conversation.isRunning {
            if Date() > deadline { XCTFail("scripted adapter did not crash"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            conversation.queued.map(\.text),
            ["oldest never-dispatched follow-up", "newest never-dispatched follow-up"]
        )
        XCTAssertTrue(conversation.rows.contains { row in
            if case let .user(_, text, failed) = row {
                return text == "ambiguous in-flight prompt" && failed
            }
            return false
        })

        await conversation.restart()

        deadline = Date().addingTimeInterval(5)
        while conversation.isRunning || !conversation.queued.isEmpty {
            if Date() > deadline { XCTFail("preserved queue did not drain after restart"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let crashedPrompts = await crashedTransport.receivedPromptTexts()
        let recoveredPrompts = await recoveredTransport.receivedPromptTexts()
        let recoveredSessionMethods = await recoveredTransport.receivedSessionMethods()
        XCTAssertTrue(conversation.isConnected)
        XCTAssertEqual(crashedPrompts, ["ambiguous in-flight prompt"])
        XCTAssertEqual(
            recoveredPrompts,
            ["oldest never-dispatched follow-up", "newest never-dispatched follow-up"]
        )
        XCTAssertFalse(
            recoveredPrompts.contains("ambiguous in-flight prompt"),
            "an interrupted prompt has ambiguous delivery and must require explicit Retry"
        )
        XCTAssertTrue(
            recoveredSessionMethods.contains("session/load"),
            "restart should offer the prior provider session before draining its queue"
        )
        _ = await conversation.stop()
    }

    @MainActor
    func testInjectingQueuedMessageLeavesTheTurnAndItsPermissionsAlone() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let ruleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-steer-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ruleDirectory) }
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client,
            ruleStore: PermissionRuleStore(fileURL: ruleDirectory.appendingPathComponent("rules.json"))
        )
        await conversation.start()
        conversation.send("current")
        conversation.send("steer me")
        let options = [
            AcpPermissionRequest.Option(id: "allow", name: "Allow", kind: "allow_once"),
            AcpPermissionRequest.Option(id: "reject", name: "Reject", kind: "reject_once"),
        ]
        conversation.receivePermissionForTesting(AcpPermissionRequest(
            id: 101, sessionID: "session", title: "First", options: options
        ))
        conversation.receivePermissionForTesting(AcpPermissionRequest(
            id: 102, sessionID: "session", title: "Second", options: options
        ))
        XCTAssertEqual(conversation.pendingPermissionCount, 2)

        let queuedID = try XCTUnwrap(conversation.queued.first?.id)
        conversation.injectQueued(queuedID)

        // Injection joins the running turn instead of interrupting it, so the
        // asks that turn already raised stay exactly where they were. (The old
        // cancel-based steer had to discard them.)
        XCTAssertEqual(conversation.pendingPermissionCount, 2)
        XCTAssertEqual(conversation.pendingPermission?.title, "First")
    }

    func testSteeringCapabilityIsReadFromTheResponsesOwnMeta() {
        // Both adapters advertise steering on the InitializeResponse's own
        // `_meta`, a SIBLING of `agentCapabilities`. Reading it from inside the
        // capability block would leave the action permanently hidden.
        let advertised = AcpClient.parseCapabilities(.object([
            "protocolVersion": .integer(1),
            "agentCapabilities": .object(["loadSession": .bool(true)]),
            "_meta": .object(["steering": .object(["supported": .bool(true)])]),
        ]))
        XCTAssertTrue(advertised.steering)
        XCTAssertTrue(advertised.loadSession)

        // Nested in the wrong place is not an advertisement.
        let misplaced = AcpClient.parseCapabilities(.object([
            "agentCapabilities": .object([
                "_meta": .object(["steering": .object(["supported": .bool(true)])]),
            ]),
        ]))
        XCTAssertFalse(misplaced.steering)

        XCTAssertFalse(AcpClient.parseCapabilities(.object([:])).steering)
    }

    func testSteerRequestIsShapedLikeAPromptWithTheIdleOptIn() throws {
        let params = try XCTUnwrap(
            AcpSteering.requestParams(sessionID: "sess-1", text: "use tabs").objectValue
        )
        XCTAssertEqual(params["sessionId"], .string("sess-1"))
        XCTAssertEqual(params["prompt"], .array([.object([
            "type": .string("text"),
            "text": .string("use tabs"),
        ])]))
        // The opt-in keeps an idle session from starting a DETACHED turn whose
        // `session/prompt` response this client would never see.
        XCTAssertEqual(
            params["_meta"],
            .object(["steering": .object(["idleBehavior": .string("promptRequired")])])
        )
    }

    func testSteerOutcomeParsingTreatsAnythingUnknownAsRejected() {
        XCTAssertEqual(AcpSteering.parseOutcome(.object(["outcome": .string("injected")])), .injected)
        XCTAssertEqual(
            AcpSteering.parseOutcome(.object(["outcome": .string("startedNewTurn")])),
            .startedNewTurn
        )
        XCTAssertEqual(
            AcpSteering.parseOutcome(.object([
                "outcome": .string("promptRequired"),
                "reason": .string("noRunningTurn"),
            ])),
            .promptRequired
        )
        // Codex's own refusal vocabulary.
        guard case .rejected = AcpSteering.parseOutcome(.object(["outcome": .string("failed")])) else {
            return XCTFail("\"failed\" must not read as delivered")
        }
        guard case .rejected = AcpSteering.parseOutcome(.object(["outcome": .string("teleported")])) else {
            return XCTFail("an unknown outcome must not read as delivered")
        }
        guard case .rejected = AcpSteering.parseOutcome(.object([:])) else {
            return XCTFail("a missing outcome must not read as delivered")
        }
        guard case .rejected = AcpSteering.parseOutcome(nil) else {
            return XCTFail("no body must not read as delivered")
        }
    }

    func testInjectActionIsOfferedOnlyWhenItCanWork() {
        XCTAssertTrue(AcpSteering.canInject(supportsSteering: true, isConnected: true, isRunning: true))
        XCTAssertFalse(AcpSteering.canInject(supportsSteering: false, isConnected: true, isRunning: true))
        XCTAssertFalse(AcpSteering.canInject(supportsSteering: true, isConnected: false, isRunning: true))
        XCTAssertFalse(AcpSteering.canInject(supportsSteering: true, isConnected: true, isRunning: false))
    }

    func testSteerOutcomesMapToQueueTransitions() {
        XCTAssertEqual(AcpSteering.decide(.injected), .delivered)
        guard case .deliveredAsNewTurn = AcpSteering.decide(.startedNewTurn) else {
            return XCTFail("a turn the adapter started is already sent and must leave the queue")
        }
        guard case .keptQueued = AcpSteering.decide(.promptRequired) else {
            return XCTFail("nothing was sent, so the message must stay queued")
        }
        guard case let .keptQueued(notice) = AcpSteering.decide(.rejected("busy")) else {
            return XCTFail("a refusal must never lose the message")
        }
        XCTAssertTrue(notice.contains("busy"), "the user must be told why: \(notice)")
    }

    @MainActor
    func testInjectedQueuedMessageLeavesTheQueueAndJoinsTheTranscript() async throws {
        let transport = ScriptedAcpTransport(steerOutcome: "injected")
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        XCTAssertTrue(conversation.supportsSteering)
        XCTAssertFalse(conversation.canInjectQueued, "no turn is running yet")

        conversation.send("first")
        conversation.send("actually use tabs")
        XCTAssertTrue(conversation.canInjectQueued)
        let queuedID = try XCTUnwrap(conversation.queued.first?.id)
        conversation.injectQueued(queuedID)

        try await Self.until("the injected message left the queue") {
            conversation.queued.isEmpty && conversation.injectingQueuedIDs.isEmpty
        }
        let steerTexts = await transport.receivedSteerRequests().compactMap {
            $0.objectValue?["prompt"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        }
        XCTAssertEqual(steerTexts, ["actually use tabs"])
        // It rode the running turn, not a second `session/prompt` — checked once
        // the turn has fully settled so an unsent prompt cannot pass by being
        // merely late.
        try await Self.until("the turn settled") { !conversation.isRunning }
        let prompts = await transport.receivedPromptTexts()
        XCTAssertEqual(prompts, ["first"])
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "actually use tabs"])
    }

    @MainActor
    func testRefusedInjectionKeepsTheMessageAndTellsTheUser() async throws {
        let transport = ScriptedAcpTransport(steerErrorMessage: "Session not found")
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("actually use tabs")
        let queuedID = try XCTUnwrap(conversation.queued.first?.id)
        conversation.injectQueued(queuedID)

        try await Self.until("the refusal was reported") {
            conversation.injectingQueuedIDs.isEmpty && conversation.statusMessage != nil
        }
        // Nothing was delivered, so nothing was lost: the message is still
        // queued and the ordinary flush will send it as its own turn.
        XCTAssertEqual(conversation.queued.map(\.text), ["actually use tabs"])
        XCTAssertTrue(
            conversation.statusMessage?.contains("Session not found") == true,
            "the user must be told: \(conversation.statusMessage ?? "nil")"
        )
        XCTAssertFalse(conversation.rows.contains { row in
            if case let .user(_, text, _) = row { return text == "actually use tabs" }
            return false
        }, "an undelivered message must not appear as if it had been said")
    }

    @MainActor
    func testTurnEndingMidInjectionSendsTheMessageExactlyOnce() async throws {
        // The Claude adapter answers `promptRequired` when the turn it was asked
        // to steer has already finished — the content stays host-owned, so the
        // queue must send it in the ordinary way and MUST NOT send it twice.
        let transport = ScriptedAcpTransport(steerOutcome: "promptRequired")
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("actually use tabs")
        let queuedID = try XCTUnwrap(conversation.queued.first?.id)
        conversation.injectQueued(queuedID)

        try await Self.until("the queue drained normally") {
            conversation.queued.isEmpty && !conversation.isRunning
        }
        let prompts = await transport.receivedPromptTexts()
        XCTAssertEqual(prompts, ["first", "actually use tabs"])
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "actually use tabs"])
    }

    @MainActor
    func testUnsupportedAdapterNeverOffersTheInjectAction() async {
        let transport = ScriptedAcpTransport(steeringSupported: false)
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("actually use tabs")
        XCTAssertFalse(conversation.supportsSteering)
        XCTAssertFalse(conversation.canInjectQueued)

        // Even called directly it must not put an unanswerable request on the
        // wire; the message simply stays queued.
        conversation.injectQueued(conversation.queued[0].id)
        XCTAssertTrue(conversation.injectingQueuedIDs.isEmpty)
        XCTAssertEqual(conversation.queued.map(\.text), ["actually use tabs"])
        let steers = await transport.receivedSteerRequests()
        XCTAssertTrue(steers.isEmpty)
    }

    // MARK: - Resumed sessions show the user's own prompts

    @MainActor
    func testResumedSessionRestoresTheUsersOwnPromptsWithoutDuplicatingThem() async throws {
        // `session/load` replays the whole thread. "already asked" is a prompt
        // this chat persisted locally, so its replay must be absorbed; "asked
        // before the store was pruned" is history only the adapter still has,
        // so it must appear.
        let transport = ScriptedAcpTransport(loadReplay: [
            (messageID: "m1", text: "already asked"),
            (messageID: "m2", text: "asked before the store was pruned"),
        ])
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Resume", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client,
            resumeSessionID: "sess-persisted",
            initialRows: [
                .user(id: "1", text: "already asked", failed: false),
                .message(id: "1", text: "An answer."),
            ]
        )
        await conversation.start()

        try await Self.until("the replay reached the transcript") {
            conversation.rows.contains { row in
                if case let .user(_, text, _) = row {
                    return text == "asked before the store was pruned"
                }
                return false
            }
        }
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["already asked", "asked before the store was pruned"])
    }

    func testLedgerAbsorbsAReplayOnlyAsOftenAsTheTranscriptAlreadyShowsIt() {
        var ledger = AcpUserMessageLedger(rows: [
            .user(id: "1", text: "continue", failed: false),
            .user(id: "2", text: "continue", failed: false),
            .message(id: "1", text: "…"),
        ])
        // Two local rows absorb exactly two replayed copies.
        XCTAssertEqual(ledger.reconcile(text: "continue", adapterMessageID: "a"), .drop)
        XCTAssertEqual(ledger.reconcile(text: "continue", adapterMessageID: "b"), .drop)
        // A third is history this transcript does not have, so it is shown.
        XCTAssertEqual(
            ledger.reconcile(text: "continue", adapterMessageID: "c"),
            .append(id: "acp:c")
        )
        // …and recognized by id the next time the thread is loaded, without
        // needing the text to be unique.
        XCTAssertEqual(ledger.reconcile(text: "continue", adapterMessageID: "c"), .drop)
    }

    func testLedgerRecognizesItsOwnEarlierReplayAcrossARestart() {
        // The row an earlier replay appended was persisted under its adapter id,
        // so a later load matches on that id and shows it once.
        var ledger = AcpUserMessageLedger(rows: [
            .user(id: "acp:m2", text: "asked before the store was pruned", failed: false),
        ])
        XCTAssertEqual(
            ledger.reconcile(text: "asked before the store was pruned", adapterMessageID: "m2"),
            .drop
        )
    }

    func testLedgerGivesUnkeyedReplayChunksDistinctRowIdentities() {
        // Codex's rollout-file fallback replays user messages with no messageId.
        var ledger = AcpUserMessageLedger()
        XCTAssertEqual(ledger.reconcile(text: "one", adapterMessageID: nil), .append(id: "acp:anon-1"))
        XCTAssertEqual(ledger.reconcile(text: "two", adapterMessageID: nil), .append(id: "acp:anon-2"))
    }

    @MainActor
    func testLocallySentPromptIsNotShownTwiceWhenTheAdapterEchoesIt() async throws {
        // Claude echoes any prompt that carried more than one content block
        // (every attachment send) straight back as `user_message_chunk`.
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Echo", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("look at this")
        try await Self.until("the send landed") {
            conversation.rows.contains { if case .user = $0 { return true } else { return false } }
        }
        conversation.receiveTurnItemForTesting(.userMessage(id: "echo-1", text: "look at this"))

        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["look at this"])
    }

    @MainActor
    func testMultiBlockReplayFoldsIntoOneRowInsteadOfLeakingItsContext() {
        // A file attachment replays as several chunks sharing one messageId:
        // the prompt text, a link, then a `<context>` dump. They are one message
        // and must render as one row.
        let conversation = AcpConversation(
            title: "Replay", command: "mock", arguments: [], environment: [:], cwd: "/tmp"
        )
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: "review this"))
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: " [notes.txt]"))
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: "\n<context>…</context>"))

        let userRows = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userRows, ["review this [notes.txt]\n<context>…</context>"])
    }

    @MainActor
    func testSuppressedMultiBlockReplayDoesNotLeakItsRemainingChunks() {
        // When the first chunk is recognized as one the transcript already
        // shows, the rest of that message must stay suppressed with it —
        // otherwise the context dump would appear as a user row of its own.
        let conversation = AcpConversation(
            title: "Replay", command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            initialRows: [.user(id: "1", text: "review this", failed: false)]
        )
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: "review this"))
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: "\n<context>…</context>"))

        let userRows = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userRows, ["review this"])
    }

    /// Poll until `condition` holds, failing with `description` on timeout.
    @MainActor
    private static func until(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testConversationStopReturnsFinalDebouncedDraft() async {
        let key = "stop-draft-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "chatDraft.\(key)") }
        let conversation = AcpConversation(
            title: "Draft", command: "unused", arguments: [], cwd: "/tmp", draftKey: key
        )
        conversation.saveDraft("unfinished thought")

        let finalDraft = await conversation.stop()

        XCTAssertEqual(finalDraft, "unfinished thought")
    }
    func testRejectsUnsupportedNegotiatedProtocol() async throws {
        let transport = ScriptedAcpTransport(protocolVersion: 2)
        let client = AcpClient(transport: transport)
        do {
            _ = try await client.start(
                command: "mock", arguments: [], environment: [:], cwd: "/tmp",
                mcpServers: []
            )
            XCTFail("Expected the ACP protocol mismatch to fail before session/new")
        } catch let AcpClientError.unsupportedProtocol(version) {
            XCTAssertEqual(version, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let terminationCount = await transport.terminationCount()
        let sessionServers = await transport.receivedSessionMcpServers()
        XCTAssertEqual(terminationCount, 1)
        XCTAssertTrue(sessionServers.isEmpty)
    }

    func testMcpServersAreFilteredAgainstNegotiatedCapabilities() async throws {
        let transport = ScriptedAcpTransport(mcpHTTP: true, mcpSSE: false)
        let client = AcpClient(transport: transport)
        let configured: [JSONValue] = [
            .object([
                "name": .string("local"), "command": .string("mcp-local"),
                "args": .array([]), "env": .array([]),
            ]),
            .object([
                "type": .string("http"), "name": .string("remote"),
                "url": .string("https://example.com/mcp"), "headers": .array([]),
            ]),
            .object([
                "type": .string("sse"), "name": .string("stream"),
                "url": .string("https://example.com/sse"), "headers": .array([]),
            ]),
        ]

        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: configured
        )

        let sent = await transport.receivedSessionMcpServers()
        XCTAssertEqual(sent.compactMap { $0.objectValue?["name"]?.stringValue }, ["local", "remote"])
        XCTAssertNil(sent.first?.objectValue?["type"], "stdio must use the ACP untagged wire shape")
        XCTAssertEqual(sent.last?.objectValue?["type"], .string("http"))
    }

    func testInvalidMcpParamsRetrySessionWithoutTools() async throws {
        let transport = ScriptedAcpTransport(rejectFirstMcpSession: true)
        let client = AcpClient(transport: transport)
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [.object([
                "name": .string("local"), "command": .string("mcp-local"),
                "args": .array([]), "env": .array([]),
            ])]
        )
        let attempts = await transport.receivedSessionMcpAttempts()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first?.count, 1)
        XCTAssertTrue(attempts.last?.isEmpty == true)
    }

    func testRestartContinuityLoadsPriorAgentSessionWhenAdvertised() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let info = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [], resumeSessionID: "sess-persisted"
        )

        XCTAssertEqual(info.sessionID, "sess-persisted")
        let methods = await transport.receivedSessionMethods()
        XCTAssertEqual(methods, ["session/load"])
    }

    func testRestartContinuityPrefersStableResumeThenFallsBackFresh() async throws {
        let resumedTransport = ScriptedAcpTransport(resumeCapability: true)
        let resumedClient = AcpClient(transport: resumedTransport)
        let resumed = try await resumedClient.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [], resumeSessionID: "sess-stable"
        )
        XCTAssertEqual(resumed.sessionID, "sess-stable")
        let resumedMethods = await resumedTransport.receivedSessionMethods()
        XCTAssertEqual(resumedMethods, ["session/resume"])

        let staleTransport = ScriptedAcpTransport(rejectRestoration: true)
        let staleClient = AcpClient(transport: staleTransport)
        let fresh = try await staleClient.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [], resumeSessionID: "sess-pruned"
        )
        XCTAssertEqual(fresh.sessionID, "sess-1")
        let staleMethods = await staleTransport.receivedSessionMethods()
        XCTAssertEqual(staleMethods, ["session/load", "session/new"])
    }

    func testHandshakeAndStreamedTurn() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { event in collector.append(event) }

        let info = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: []
        )
        XCTAssertEqual(info.sessionID, "sess-1")
        XCTAssertEqual(info.models.map(\.id), ["opus", "sonnet"])
        // Nested SessionModeState parses; current mode carried through.
        XCTAssertEqual(info.modes.map(\.id), ["default", "plan"])
        XCTAssertEqual(info.currentModeID, "default")
        // Config options (effort levels) parse with their choices.
        XCTAssertEqual(info.configOptions.map(\.id), ["reasoning_effort"])
        XCTAssertEqual(info.configOptions.first?.currentValue, "low")
        XCTAssertEqual(info.configOptions.first?.choices.map(\.value), ["low", "high"])

        // The scripted transport streams a thought, a plan, two message chunks,
        // a tool call + completion, and a usage update when it sees the prompt.
        try await client.prompt("hello")

        let events = collector.events
        XCTAssertTrue(events.contains { if case .turnItem(.thought) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .turnItem(.plan) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case let .turnItem(.toolCall(c)) = $0 { return c.id == "t1" } else { return false } })
        XCTAssertTrue(events.contains {
            if case let .toolCallUpdate(id, status, _, locations, _) = $0 {
                return id == "t1"
                    && status == .completed
                    && locations == ["Sources/App.swift"]
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case let .usage(u) = $0 {
                return u.used == 5000
                    && u.max == 200000
                    && u.costAmount == 0.42
                    && u.costCurrency == "USD"
            }
            return false
        })
        XCTAssertTrue(events.contains { if case .turnEnded = $0 { return true } else { return false } })
        // Slash commands stream in via available_commands_update.
        XCTAssertTrue(events.contains { event in
            if case let .commands(list) = event { return list.map(\.name) == ["compact", "review"] }
            return false
        })

        // set_config_option returns the adapter-confirmed normalized option set.
        let confirmed = try await client.setConfigOption(id: "reasoning_effort", value: "high")
        XCTAssertEqual(confirmed.first?.currentValue, "high")
    }

    func testCancellingACallerFailsItsPendingRequestInsteadOfWaitingOnTheAdapter() async throws {
        // Closing a chat view cancels the task awaiting `session/prompt`. That
        // request must fail with its caller instead of sitting in `pending`
        // until the adapter answers — prompts are sent with no timeout, so the
        // wait is otherwise unbounded.
        let transport = ScriptedAcpTransport(withholdFirstPromptReply: true)
        let client = AcpClient(transport: transport)
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        let outcome = CallOutcome()
        let abandoned = Task {
            do {
                try await client.prompt("abandoned")
                await outcome.record(.success(()))
            } catch {
                await outcome.record(.failure(error))
            }
        }
        try await Self.untilAsync("the prompt to reach the adapter") {
            await transport.hasWithheldPrompt()
        }

        abandoned.cancel()

        let returned = try await Self.untilAsync("the cancelled prompt to return") {
            await outcome.isSettled()
        }
        guard returned else { return }
        guard case let .failure(error)? = await outcome.settled() else {
            return XCTFail("a cancelled prompt must fail, not report a finished turn")
        }
        XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
    }

    func testLateResponseCannotEndATurnTheCallerAlreadyAbandoned() async throws {
        // The adapter answers on its own schedule, so a cancelled request's
        // response still arrives. With nothing waiting on it, it must be
        // dropped rather than ending a turn the surface has moved on from.
        let transport = ScriptedAcpTransport(withholdFirstPromptReply: true)
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { event in collector.append(event) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        let outcome = CallOutcome()
        let abandoned = Task {
            do {
                try await client.prompt("abandoned")
                await outcome.record(.success(()))
            } catch {
                await outcome.record(.failure(error))
            }
        }
        try await Self.untilAsync("the prompt to reach the adapter") {
            await transport.hasWithheldPrompt()
        }
        abandoned.cancel()
        let returned = try await Self.untilAsync("the cancelled prompt to return") {
            await outcome.isSettled()
        }
        guard returned else { return }

        await transport.deliverWithheldPromptReply()
        try await client.prompt("the turn that counts")

        let endings = collector.events.filter {
            if case .turnEnded = $0 { return true } else { return false }
        }
        XCTAssertEqual(
            endings.count, 1,
            "the abandoned request's late response ended a turn of its own"
        )
        // The replacement request still gets its own answer: ids are never
        // reused, so the stale response cannot resolve it.
        let prompts = await transport.receivedPromptTexts()
        XCTAssertEqual(prompts, ["abandoned", "the turn that counts"])
    }

    /// Poll an async condition until it holds, failing after `timeout` and
    /// reporting whether it held so a caller can stop before asserting on state
    /// that never arrived. A regression here must fail, never hang the suite.
    @discardableResult
    private static func untilAsync(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () async -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline {
                XCTFail("timed out waiting for \(description)")
                return false
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    @MainActor
    func testConversationAccumulatesStreamingChunks() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        XCTAssertTrue(conversation.isConnected)

        conversation.send("hello")
        // Generous deadline: dispatch awaits a pre-turn git checkpoint before the
        // prompt is even sent, and a loaded CI runner can make that first git
        // spawn slow. A too-tight bound flakes on latency, not on a real stall.
        let deadline = Date().addingTimeInterval(15)
        while conversation.isRunning || !conversation.rows.contains(where: { if case .message = $0 { return true } else { return false } }) {
            if Date() > deadline { XCTFail("stream did not complete"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // The two "Hello" / " world" chunks accumulate into ONE message row.
        let messages = conversation.rows.compactMap { row -> String? in
            if case let .message(_, text) = row { return text } else { return nil }
        }
        XCTAssertEqual(messages, ["Hello world"])
        XCTAssertTrue(conversation.rows.contains { if case .user = $0 { return true } else { return false } })
        XCTAssertTrue(conversation.rows.contains { if case .tool = $0 { return true } else { return false } })
    }

    @MainActor
    func testFollowUpQueuedWhileRunningDispatchesAfterTurn() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let ruleFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-q-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("rules.json")
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client, ruleStore: PermissionRuleStore(fileURL: ruleFile)
        )
        defer { try? FileManager.default.removeItem(at: ruleFile.deletingLastPathComponent()) }
        await conversation.start()

        conversation.send("first")
        conversation.send("second")   // a turn is running → this queues
        XCTAssertTrue(conversation.isRunning)
        XCTAssertEqual(conversation.queued.map(\.text), ["second"])

        // Both turns complete: "second" dispatches when "first" ends, and the
        // queue drains.
        let deadline = Date().addingTimeInterval(5)
        while conversation.isRunning || !conversation.queued.isEmpty
            || conversation.rows.filter({ if case .user = $0 { return true } else { return false } }).count < 2 {
            if Date() > deadline { XCTFail("queued follow-up did not dispatch"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "second"])
        XCTAssertTrue(conversation.queued.isEmpty)
    }

    @MainActor
    func testInjectingOneQueuedMessageLeavesTheRestOfTheQueueInOrder() async throws {
        // Steering is per-message: the one the user picked reaches the running
        // turn, and every other follow-up keeps its place in the FIFO.
        let transport = ScriptedAcpTransport(steerOutcome: "injected")
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("second")
        conversation.send("third")
        XCTAssertEqual(conversation.queued.map(\.text), ["second", "third"])

        let steerID = try XCTUnwrap(conversation.queued.last?.id)
        conversation.injectQueued(steerID)

        try await Self.until("the queue drained") {
            !conversation.isRunning && conversation.queued.isEmpty
                && conversation.injectingQueuedIDs.isEmpty
        }
        let prompts = await transport.receivedPromptTexts()
        XCTAssertEqual(prompts, ["first", "second"], "\"third\" was steered, not prompted")
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "third", "second"])
    }

    @MainActor
    func testRemoveQueuedDropsPendingFollowUp() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("drop me")
        let id = try XCTUnwrap(conversation.queued.first?.id)
        conversation.removeQueued(id)
        XCTAssertTrue(conversation.queued.isEmpty)
    }

    @MainActor
    func testConversationCheckpointEvictionDropsOnlyTheExactTypedOwnerRef() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-checkpoint-menu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        @discardableResult
        func git(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = workspace
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        func refExists(_ ref: String) -> Bool {
            (try? git(["show-ref", "--verify", "--quiet", ref])) == 0
        }

        XCTAssertEqual(try git(["init", "-q", "-b", "main"]), 0)
        XCTAssertEqual(try git(["config", "user.email", "test@example.com"]), 0)
        XCTAssertEqual(try git(["config", "user.name", "Test"]), 0)
        try "base\n".write(
            to: workspace.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(try git(["add", "file.txt"]), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "base"]), 0)
        try "dirty\n".write(
            to: workspace.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let transport = ScriptedAcpTransport()
        let conversation = AcpConversation(
            title: "Checkpoint eviction",
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: workspace.path,
            client: AcpClient(transport: transport),
            draftKey: "durable-chat",
            checkpointIncarnationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        )
        await conversation.start()

        var first: AcpConversation.TurnCheckpoint?
        for turn in 1...21 {
            XCTAssertTrue(conversation.send("turn \(turn)"))
            try await Self.until("checkpoint for turn \(turn)", timeout: 15) {
                !conversation.isRunning && conversation.checkpoints.last?.turn == turn
            }
            if turn == 1 { first = conversation.checkpoints.first }
        }

        let evicted = try XCTUnwrap(first)
        XCTAssertEqual(conversation.checkpoints.count, 20)
        XCTAssertFalse(conversation.checkpoints.contains(where: { $0.id == evicted.id }))
        let retained = try XCTUnwrap(conversation.checkpoints.last)
        try await Self.until("the evicted checkpoint ref to be deleted") {
            !refExists(evicted.checkpoint.keepAliveRef)
        }
        XCTAssertTrue(refExists(retained.checkpoint.keepAliveRef))
        _ = await conversation.stop()
    }

    // MARK: - Malformed permission asks

    /// A permission request that lands between `session/new` and its reply has
    /// no session to belong to. Silence there wedges the adapter on a decision
    /// no review card can present, so it gets invalid-params instead.
    func testPermissionRequestWithNoSessionIsAnsweredWithInvalidParams() async throws {
        let transport = PermissionProbeTransport(preSessionPermissionID: .string("pre-session"))
        let client = AcpClient(transport: transport)
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        let error = try await Self.errorResponse(from: transport, id: .string("pre-session"))
        XCTAssertEqual(error["code"]?.intValue, -32602)
        XCTAssertEqual(error["message"]?.stringValue?.isEmpty, false)
    }

    /// `params` that are not an object at all: nothing to decode, still owed a
    /// response.
    func testPermissionRequestWithNonObjectParamsIsAnsweredWithInvalidParams() async throws {
        let transport = PermissionProbeTransport()
        let client = AcpClient(transport: transport)
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        await transport.requestPermission(id: .string("bad-params"), params: .string("not an object"))

        let error = try await Self.errorResponse(from: transport, id: .string("bad-params"))
        XCTAssertEqual(error["code"]?.intValue, -32602)
    }

    /// Options with no `optionId` leave the card with nothing to click, which
    /// blocks the adapter exactly like a dropped ask.
    func testPermissionRequestWithNoUsableOptionIsAnsweredWithInvalidParams() async throws {
        let transport = PermissionProbeTransport()
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { event in collector.append(event) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        await transport.requestPermission(id: .string("no-options"), params: .object([
            "sessionId": .string("sess-1"),
            "toolCall": .object([
                "toolCallId": .string("t-1"),
                "title": .string("Delete the checkout"),
                "kind": .string("execute"),
            ]),
            // Present but unusable: no `optionId` on either entry.
            "options": .array([
                .object(["name": .string("Allow once")]),
                .string("reject"),
            ]),
        ]))

        let error = try await Self.errorResponse(from: transport, id: .string("no-options"))
        XCTAssertEqual(error["code"]?.intValue, -32602)
        XCTAssertTrue(
            Self.permissionRequests(collector).isEmpty,
            "an unanswerable ask must not reach the review card"
        )
    }

    /// A missing `toolCall` is legal — partial asks fall back to whatever an
    /// earlier `session/update` disclosed — so this one must still reach the
    /// user and still be answered with the ACP `selected` outcome.
    func testPermissionRequestWithoutAToolCallStillReachesTheUserAndIsAnswered() async throws {
        let transport = PermissionProbeTransport()
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { event in collector.append(event) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        await transport.requestPermission(id: .string("no-tool-call"), params: .object([
            "sessionId": .string("sess-1"),
            "options": .array([
                .object([
                    "optionId": .string("allow"),
                    "name": .string("Allow once"),
                    "kind": .string("allow_once"),
                ]),
            ]),
        ]))
        try await Self.untilPermissions(collector, reach: 1)

        let request = try XCTUnwrap(Self.permissionRequests(collector).first)
        XCTAssertEqual(request.title, "Permission requested")
        XCTAssertEqual(request.kind, "other")
        await client.resolvePermission(id: request.id, optionID: "allow")

        let result = try await Self.resultResponse(from: transport, id: .string("no-tool-call"))
        XCTAssertEqual(
            result["outcome"]?.objectValue?["outcome"]?.stringValue, "selected"
        )
        XCTAssertEqual(result["outcome"]?.objectValue?["optionId"]?.stringValue, "allow")
    }

    /// `rawInput` is arbitrary JSON in ACP v1. A bare string is kept for
    /// disclosure and an explicit null is dropped; neither shape may cost the
    /// adapter its response.
    func testPermissionRequestWithMalformedRawInputIsSurfacedAndAnswered() async throws {
        let transport = PermissionProbeTransport()
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { event in collector.append(event) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        func ask(id: String, rawInput: JSONValue) -> JSONValue {
            .object([
                "sessionId": .string("sess-1"),
                "toolCall": .object([
                    "toolCallId": .string(id),
                    "title": .string("Run a command"),
                    "kind": .string("execute"),
                    "rawInput": rawInput,
                ]),
                "options": .array([
                    .object([
                        "optionId": .string("allow"),
                        "name": .string("Allow once"),
                        "kind": .string("allow_once"),
                    ]),
                ]),
            ])
        }
        await transport.requestPermission(
            id: .string("string-raw-input"), params: ask(id: "t-2", rawInput: .string("rm -rf ~/.ssh"))
        )
        await transport.requestPermission(
            id: .string("null-raw-input"), params: ask(id: "t-3", rawInput: .null)
        )
        try await Self.untilPermissions(collector, reach: 2)

        let asks = Self.permissionRequests(collector)
        XCTAssertEqual(asks[0].rawInput, .string("rm -rf ~/.ssh"))
        XCTAssertNil(asks[1].rawInput)

        await client.cancelPermission(id: asks[0].id)
        await client.resolvePermission(id: asks[1].id, optionID: "allow")

        let cancelled = try await Self.resultResponse(from: transport, id: .string("string-raw-input"))
        XCTAssertEqual(cancelled["outcome"]?.objectValue?["outcome"]?.stringValue, "cancelled")
        let selected = try await Self.resultResponse(from: transport, id: .string("null-raw-input"))
        XCTAssertEqual(selected["outcome"]?.objectValue?["outcome"]?.stringValue, "selected")
    }

    private static func permissionRequests(_ collector: EventCollector) -> [AcpPermissionRequest] {
        collector.events.compactMap {
            if case let .permission(request) = $0 { return request } else { return nil }
        }
    }

    /// Wait for the review card to be offered `count` asks.
    private static func untilPermissions(
        _ collector: EventCollector,
        reach count: Int,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while permissionRequests(collector).count < count {
            if Date() > deadline {
                return XCTFail("timed out waiting for \(count) permission ask(s)")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct MissingPermissionResponse: Error {}

    /// The `error` object the client wrote for `id`, once it has written one.
    private static func errorResponse(
        from transport: PermissionProbeTransport,
        id: JSONValue,
        timeout: TimeInterval = 5
    ) async throws -> [String: JSONValue] {
        let response = try await responseFrame(from: transport, id: id, timeout: timeout)
        XCTAssertNil(response["result"], "a malformed ask must not be answered with a result")
        return try XCTUnwrap(response["error"]?.objectValue)
    }

    /// The `result` object the client wrote for `id`, once it has written one.
    private static func resultResponse(
        from transport: PermissionProbeTransport,
        id: JSONValue,
        timeout: TimeInterval = 5
    ) async throws -> [String: JSONValue] {
        let response = try await responseFrame(from: transport, id: id, timeout: timeout)
        XCTAssertNil(response["error"])
        return try XCTUnwrap(response["result"]?.objectValue)
    }

    private static func responseFrame(
        from transport: PermissionProbeTransport,
        id: JSONValue,
        timeout: TimeInterval
    ) async throws -> [String: JSONValue] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let response = await transport.response(for: id)?.objectValue { return response }
            if Date() > deadline {
                XCTFail("the client never answered permission request \(id)")
                throw MissingPermissionResponse()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Request timeout bookkeeping

    /// The synchronous `until` above cannot await the client actor, so the
    /// in-flight timer count needs its own poll.
    private static func untilClient(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func connectedClient() async throws -> (AcpClient, ControllableAcpTransport) {
        let transport = ControllableAcpTransport()
        let client = AcpClient(transport: transport)
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        return (client, transport)
    }

    func testAnsweredRequestLeavesNoTimeoutTaskBehind() async throws {
        let (client, transport) = try await Self.connectedClient()

        // The handshake's own two requests (initialize, session/new) already
        // settled, so nothing may still be sleeping on them.
        var outstanding = await client.outstandingRequestTimeoutCountForTesting()
        XCTAssertEqual(outstanding, 0, "the handshake left timeout tasks running")

        let response = Task {
            try await client.requestForTesting("session/set_model", timeoutNanoseconds: 30_000_000_000)
        }
        try await Self.untilClient("the request to go in flight") {
            await client.outstandingRequestTimeoutCountForTesting() == 1
        }
        let inFlight = await transport.unansweredRequestIDs()
        await transport.answer(id: try XCTUnwrap(inFlight.first))
        _ = try await response.value

        outstanding = await client.outstandingRequestTimeoutCountForTesting()
        XCTAssertEqual(outstanding, 0, "a successful response left its timeout task running")
        await client.stop()
    }

    func testSendFailureCancelsThatRequestsTimeout() async throws {
        let (client, transport) = try await Self.connectedClient()
        await transport.failSends(true)

        do {
            _ = try await client.requestForTesting("session/set_mode", timeoutNanoseconds: 30_000_000_000)
            XCTFail("a failed send must surface to the caller")
        } catch {
            XCTAssertEqual(error as? AcpClientError, .notRunning)
        }

        let outstanding = await client.outstandingRequestTimeoutCountForTesting()
        XCTAssertEqual(outstanding, 0, "a failed send left its timeout task running")
        await client.stop()
    }

    func testAdapterExitCancelsEveryInFlightTimeout() async throws {
        let (client, transport) = try await Self.connectedClient()

        let first = Task { () -> (any Error)? in
            do {
                _ = try await client.requestForTesting("session/set_model", timeoutNanoseconds: 30_000_000_000)
                return nil
            } catch { return error }
        }
        let second = Task { () -> (any Error)? in
            do {
                _ = try await client.requestForTesting("session/set_mode", timeoutNanoseconds: 30_000_000_000)
                return nil
            } catch { return error }
        }
        try await Self.untilClient("both requests to go in flight") {
            await client.outstandingRequestTimeoutCountForTesting() == 2
        }

        await transport.closeOutput(exitCode: 9)
        let firstError = await first.value
        let secondError = await second.value
        XCTAssertEqual(firstError as? AcpClientError, .adapterExited(code: 9))
        XCTAssertEqual(secondError as? AcpClientError, .adapterExited(code: 9))

        let outstanding = await client.outstandingRequestTimeoutCountForTesting()
        XCTAssertEqual(outstanding, 0, "an adapter exit left timeout tasks running")
        await client.stop()
    }

    func testFiredTimeoutClearsItsOwnTask() async throws {
        let (client, _) = try await Self.connectedClient()

        do {
            _ = try await client.requestForTesting("session/set_model", timeoutNanoseconds: 40_000_000)
            XCTFail("an unanswered request must time out")
        } catch let AcpClientError.requestFailed(message) {
            XCTAssertTrue(message.contains("timed out"), message)
        }

        let outstanding = await client.outstandingRequestTimeoutCountForTesting()
        XCTAssertEqual(outstanding, 0, "a fired timeout left its own task in the table")
        await client.stop()
    }

    func testCancellingTheCallerSettlesTheRequestAndItsTimeout() async throws {
        let (client, _) = try await Self.connectedClient()

        let response = Task { () -> (any Error)? in
            do {
                _ = try await client.requestForTesting("session/set_model", timeoutNanoseconds: 30_000_000_000)
                return nil
            } catch { return error }
        }
        try await Self.untilClient("the request to go in flight") {
            await client.outstandingRequestTimeoutCountForTesting() == 1
        }

        // A cancelled caller settles now; before, it (and its sleeper) waited
        // out the whole 30s window against an adapter that never answers.
        let cancelledAt = Date()
        response.cancel()
        let error = await response.value
        XCTAssertTrue(error is CancellationError, String(describing: error))
        XCTAssertLessThan(
            Date().timeIntervalSince(cancelledAt), 5,
            "a cancelled caller waited out the request timeout"
        )

        let outstanding = await client.outstandingRequestTimeoutCountForTesting()
        XCTAssertEqual(outstanding, 0, "a cancelled caller left its timeout task running")
        await client.stop()
    }

    func testStopCancelsTimeoutsForRequestsItAborts() async throws {
        let (client, _) = try await Self.connectedClient()

        let response = Task { () -> (any Error)? in
            do {
                _ = try await client.requestForTesting("session/set_model", timeoutNanoseconds: 30_000_000_000)
                return nil
            } catch { return error }
        }
        try await Self.untilClient("the request to go in flight") {
            await client.outstandingRequestTimeoutCountForTesting() == 1
        }

        await client.stop()
        // Stop terminates the transport before it drains its own table, so the
        // read loop usually reports the abort as an adapter exit. Either way the
        // caller settles and its timer goes with it.
        let stopError = await response.value
        XCTAssertNotNil(stopError as? AcpClientError, String(describing: stopError))
        let outstanding = await client.outstandingRequestTimeoutCountForTesting()
        XCTAssertEqual(outstanding, 0, "stop left timeout tasks running")
    }
}

/// Records how a call finished so a test can poll for it. Awaiting the task
/// itself would hang forever on the very regression under test.
private actor CallOutcome {
    private var result: Result<Void, any Error>?
    func record(_ result: Result<Void, any Error>) { self.result = result }
    func settled() -> Result<Void, any Error>? { result }
    func isSettled() -> Bool { result != nil }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AcpEvent] = []
    func append(_ event: AcpEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [AcpEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// A transport that answers the handshake and then hands the test direct
/// control over `session/request_permission`, keeping every frame the client
/// writes back so a malformed ask can be checked for the reply it still owes.
private actor PermissionProbeTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var clientFrames: [JSONValue] = []
    /// Sent between the `session/new` request and its reply — the one window
    /// where the client is live but has no session id yet.
    private let preSessionPermissionID: JSONValue?

    init(preSessionPermissionID: JSONValue? = nil) {
        self.preSessionPermissionID = preSessionPermissionID
    }

    private static let allowOnce: JSONValue = .array([
        .object([
            "optionId": .string("allow"),
            "name": .string("Allow once"),
            "kind": .string("allow_once"),
        ]),
    ])

    /// The response frame the client wrote for `id`, if it wrote one. Responses
    /// carry no `method`, which is what separates them from the client's own
    /// requests.
    func response(for id: JSONValue) -> JSONValue? {
        clientFrames.first {
            $0.objectValue?["id"] == id && $0.objectValue?["method"] == nil
        }
    }

    func requestPermission(id: JSONValue, params: JSONValue) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string("session/request_permission"),
            "params": params,
        ]))
    }

    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws {}

    func send(_ data: Data) async throws {
        let frame = data.last == 0x0A ? data.dropLast() : data
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame),
              let object = value.objectValue else { return }
        clientFrames.append(value)
        switch object["method"]?.stringValue {
        case "initialize":
            reply(id: object["id"], result: .object([
                "protocolVersion": .integer(Int64(AcpWire.protocolVersion)),
            ]))
        case "session/new":
            if let preSessionPermissionID {
                requestPermission(
                    id: preSessionPermissionID,
                    params: .object(["options": Self.allowOnce])
                )
            }
            reply(id: object["id"], result: .object(["sessionId": .string("sess-1")]))
        default:
            break
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        return await withCheckedContinuation { continuation in waiter = continuation }
    }

    func terminate() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { 0 }

    private func reply(id: JSONValue?, result: JSONValue) {
        guard let id else { return }
        enqueue(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func enqueue(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }
}

/// A transport that answers the ACP handshake and, on a prompt, streams a
/// scripted `session/update` sequence, a permission request, then resolves.
private actor ScriptedAcpTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var started = false
    private let protocolVersion: Int64
    private let mcpHTTP: Bool
    private let mcpSSE: Bool
    private let rejectFirstMcpSession: Bool
    private let resumeCapability: Bool
    private let rejectRestoration: Bool
    private let crashOnFirstPrompt: Bool
    /// Answers the first prompt only when the test says so, standing in for an
    /// adapter that is still thinking while the caller walks away.
    private let withholdFirstPromptReply: Bool
    private var withheldPromptID: JSONValue?
    private var didWithholdPrompt = false
    private let steeringSupported: Bool
    private let steerOutcome: String?
    private let steerErrorMessage: String?
    private let loadReplay: [(messageID: String?, text: String)]
    private var sessionMcpServers: [JSONValue] = []
    private var sessionMcpAttempts: [[JSONValue]] = []
    private var sessionMethods: [String] = []
    private var promptTexts: [String] = []
    private var steerRequests: [JSONValue] = []
    private var didCrashPrompt = false
    private var recordedExitCode: Int32 = 0
    private var terminations = 0
    private var clientCapabilities: JSONValue?
    private var clientResponses: [Int64: JSONValue] = [:]

    init(
        protocolVersion: Int64 = 1,
        mcpHTTP: Bool = true,
        mcpSSE: Bool = false,
        rejectFirstMcpSession: Bool = false,
        resumeCapability: Bool = false,
        rejectRestoration: Bool = false,
        crashOnFirstPrompt: Bool = false,
        withholdFirstPromptReply: Bool = false,
        steeringSupported: Bool = true,
        steerOutcome: String? = "injected",
        steerErrorMessage: String? = nil,
        loadReplay: [(messageID: String?, text: String)] = []
    ) {
        self.protocolVersion = protocolVersion
        self.mcpHTTP = mcpHTTP
        self.mcpSSE = mcpSSE
        self.rejectFirstMcpSession = rejectFirstMcpSession
        self.resumeCapability = resumeCapability
        self.rejectRestoration = rejectRestoration
        self.crashOnFirstPrompt = crashOnFirstPrompt
        self.withholdFirstPromptReply = withholdFirstPromptReply
        self.steeringSupported = steeringSupported
        self.steerOutcome = steerOutcome
        self.steerErrorMessage = steerErrorMessage
        self.loadReplay = loadReplay
    }

    func receivedSessionMcpServers() -> [JSONValue] { sessionMcpServers }
    func receivedSessionMcpAttempts() -> [[JSONValue]] { sessionMcpAttempts }
    func receivedSessionMethods() -> [String] { sessionMethods }
    func receivedPromptTexts() -> [String] { promptTexts }
    func receivedSteerRequests() -> [JSONValue] { steerRequests }
    func terminationCount() -> Int { terminations }
    func receivedClientCapabilities() -> JSONValue? { clientCapabilities }

    func sendAgentRequest(id: Int64, method: String, params: JSONValue) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
            "params": params,
        ]))
    }

    func waitForClientResponse(id: Int64) async throws -> JSONValue {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let response = clientResponses[id] { return response }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AcpClientError.requestFailed("Timed out waiting for contained client response \(id)")
    }

    func hasWithheldPrompt() -> Bool { withheldPromptID != nil }

    /// Answer the prompt this transport deliberately left open, as an adapter
    /// does when it finishes long after the caller stopped listening.
    func deliverWithheldPromptReply() {
        guard let id = withheldPromptID else { return }
        withheldPromptID = nil
        reply(id: id, result: .object(["stopReason": .string("end_turn")]))
    }

    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        started = true
    }

    func send(_ data: Data) async throws {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: trimmed(data)).objectValue else { return }
        if object["method"] == nil, let id = object["id"]?.intValue {
            clientResponses[id] = .object(object)
            return
        }
        let id = object["id"]
        switch object["method"]?.stringValue {
        case "initialize":
            clientCapabilities = object["params"]?.objectValue?["clientCapabilities"]
            reply(id: id, result: .object([
                "protocolVersion": .integer(protocolVersion),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "sessionCapabilities": .object([
                        "resume": .bool(resumeCapability),
                        "close": .bool(true),
                    ]),
                    "mcpCapabilities": .object([
                        "http": .bool(mcpHTTP),
                        "sse": .bool(mcpSSE),
                    ]),
                ]),
                // Sibling of `agentCapabilities`, exactly where both shipping
                // adapters advertise the steering extension.
                "_meta": .object(["steering": .object(["supported": .bool(steeringSupported)])]),
            ]))
        case "session/new":
            sessionMethods.append("session/new")
            sessionMcpServers = object["params"]?.objectValue?["mcpServers"]?.arrayValue ?? []
            sessionMcpAttempts.append(sessionMcpServers)
            if rejectFirstMcpSession, sessionMcpAttempts.count == 1, !sessionMcpServers.isEmpty {
                replyError(id: id, message: "Invalid params: unsupported MCP server")
                return
            }
            reply(id: id, result: .object([
                "sessionId": .string("sess-1"),
                // Flat models shape (exercises the fallback parse path).
                "models": .array([
                    .object(["modelId": .string("opus"), "name": .string("Opus")]),
                    .object(["modelId": .string("sonnet"), "name": .string("Sonnet")]),
                ]),
                // Nested modes shape (the ACP standard SessionModeState).
                "modes": .object([
                    "currentModeId": .string("default"),
                    "availableModes": .array([
                        .object(["id": .string("default"), "name": .string("Default")]),
                        .object(["id": .string("plan"), "name": .string("Plan")]),
                    ]),
                ]),
                "configOptions": .array([
                    .object([
                        "id": .string("reasoning_effort"),
                        "name": .string("Reasoning effort"),
                        "type": .string("select"),
                        "currentValue": .string("low"),
                        "options": .array([
                            .object(["value": .string("low"), "name": .string("Low")]),
                            .object(["value": .string("high"), "name": .string("High")]),
                        ]),
                    ]),
                ]),
            ]))
        case "session/load", "session/resume":
            let method = object["method"]?.stringValue ?? ""
            sessionMethods.append(method)
            if rejectRestoration {
                replyError(id: id, message: "Unknown session")
            } else {
                let restoredID = object["params"]?.objectValue?["sessionId"]?.stringValue ?? "sess-restored"
                // Both shipping adapters replay a loaded thread's whole history
                // as `session/update`s BEFORE answering the load.
                if method == "session/load" {
                    for entry in loadReplay {
                        var update: [String: JSONValue] = [
                            "sessionUpdate": .string("user_message_chunk"),
                            "content": .object([
                                "type": .string("text"),
                                "text": .string(entry.text),
                            ]),
                        ]
                        if let messageID = entry.messageID {
                            update["messageId"] = .string(messageID)
                        }
                        notify(update: .object(update))
                    }
                }
                reply(id: id, result: .object(["sessionId": .string(restoredID)]))
            }
        case AcpSteering.method:
            steerRequests.append(object["params"] ?? .null)
            if let steerErrorMessage {
                replyError(id: id, message: steerErrorMessage)
            } else if let steerOutcome {
                reply(id: id, result: .object(["outcome": .string(steerOutcome)]))
            } else {
                reply(id: id, result: .object([:]))
            }
        case "session/set_config_option":
            reply(id: id, result: .object([
                "configOptions": .array([
                    .object([
                        "id": .string("reasoning_effort"),
                        "name": .string("Reasoning effort"),
                        "currentValue": .string("high"),
                        "options": .array([
                            .object(["value": .string("low"), "name": .string("Low")]),
                            .object(["value": .string("high"), "name": .string("High")]),
                        ]),
                    ]),
                ]),
            ]))
        case "session/prompt":
            if let text = object["params"]?.objectValue?["prompt"]?.arrayValue?
                .first?.objectValue?["text"]?.stringValue {
                promptTexts.append(text)
            }
            if crashOnFirstPrompt, !didCrashPrompt {
                didCrashPrompt = true
                recordedExitCode = 17
                started = false
                waiter?.resume(returning: nil)
                waiter = nil
                return
            }
            if withholdFirstPromptReply, !didWithholdPrompt {
                didWithholdPrompt = true
                withheldPromptID = id
                return
            }
            streamTurn()
            reply(id: id, result: .object(["stopReason": .string("end_turn")]))
        default:
            if let id { reply(id: id, result: .null) }
        }
    }

    private func streamTurn() {
        notify(update: .object(["sessionUpdate": .string("agent_thought_chunk"), "content": .object(["type": .string("text"), "text": .string("thinking…")])]))
        notify(update: .object(["sessionUpdate": .string("plan"), "entries": .array([
            .object(["content": .string("step one"), "priority": .string("high"), "status": .string("pending")]),
        ])]))
        notify(update: .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Hello")])]))
        notify(update: .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string(" world")])]))
        notify(update: .object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("t1"), "title": .string("run echo"), "kind": .string("execute"), "status": .string("pending")]))
        notify(update: .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("t1"),
            "status": .string("completed"),
            "locations": .array([
                .object(["path": .string("Sources/App.swift")]),
            ]),
        ]))
        notify(update: .object(["sessionUpdate": .string("available_commands_update"), "availableCommands": .array([
            .object(["name": .string("compact"), "description": .string("Compact the conversation")]),
            .object(["name": .string("review"), "description": .string("Review changes")]),
        ])]))
        // Current ACP schema: `used` + `size`, with optional cumulative cost.
        notify(update: .object([
            "sessionUpdate": .string("usage_update"),
            "used": .integer(5000),
            "size": .integer(200000),
            "cost": .object(["amount": .number(0.42), "currency": .string("USD")]),
        ]))
    }

    private func reply(id: JSONValue?, result: JSONValue) {
        guard let id else { return }
        enqueue(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func replyError(id: JSONValue?, message: String) {
        guard let id else { return }
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(-32602), "message": .string(message)]),
        ]))
    }

    private func notify(update: JSONValue) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object(["sessionId": .string("sess-1"), "update": update]),
        ]))
    }

    private func enqueue(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        return await withCheckedContinuation { continuation in waiter = continuation }
    }

    func terminate() async {
        terminations += 1
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { recordedExitCode }

    private func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}

/// A transport that answers only the handshake. Every later request is recorded
/// and left unanswered, so a test settles it deliberately — a reply, a send
/// failure, or the adapter closing its output — and inspects what that leaves
/// behind on the client.
private actor ControllableAcpTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var unanswered: [Int64] = []
    private var sendFails = false
    private var closed = false
    private var recordedExitCode: Int32 = 0

    func failSends(_ failing: Bool) { sendFails = failing }
    func unansweredRequestIDs() -> [Int64] { unanswered }

    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        closed = false
    }

    func send(_ data: Data) async throws {
        if sendFails { throw AcpClientError.notRunning }
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: trimmed(data)).objectValue,
              let id = object["id"]?.intValue else { return }
        switch object["method"]?.stringValue {
        case "initialize":
            reply(id: id, result: .object([
                "protocolVersion": .integer(Int64(AcpWire.protocolVersion)),
            ]))
        case "session/new":
            reply(id: id, result: .object(["sessionId": .string("sess-1")]))
        default:
            unanswered.append(id)
        }
    }

    /// Answer a request the client is still waiting on.
    func answer(id: Int64) {
        unanswered.removeAll { $0 == id }
        reply(id: id, result: .object(["ok": .bool(true)]))
    }

    /// Close the adapter's stdout, which is how a dead agent reaches the read
    /// loop.
    func closeOutput(exitCode: Int32) {
        recordedExitCode = exitCode
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { continuation in waiter = continuation }
    }

    func terminate() async {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { recordedExitCode }

    private func reply(id: Int64, result: JSONValue) {
        guard var data = try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "result": result,
        ])) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }

    private func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}

private final class CustomContainmentFixture {
    let root: URL
    let installRoot: URL
    let adapter: URL
    let runtime: URL
    let runtimeRoot: URL
    let stateRoot: URL
    let fileRestrictedStateRoot: URL
    let reviewedStateRoot: URL
    let workspace: URL
    let workspaceInput: URL
    let workspaceOutput: URL
    let secret: URL
    let claudeConfig: URL
    let codexHome: URL

    var privateHome: URL { stateRoot.appending(path: "home", directoryHint: .isDirectory) }
    var privateTemporary: URL { stateRoot.appending(path: "tmp", directoryHint: .isDirectory) }

    init(
        scriptedProbe: Bool = false,
        networkProbePort: UInt16? = nil,
        javascriptProbe: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-custom-containment-\(UUID().uuidString)", directoryHint: .isDirectory)
        installRoot = root.appending(path: "install", directoryHint: .isDirectory)
        adapter = installRoot.appending(path: javascriptProbe ? "adapter.js" : "adapter.zsh")
        runtime = URL(fileURLWithPath: "/bin/zsh")
        runtimeRoot = URL(fileURLWithPath: "/bin", isDirectory: true)
        stateRoot = root.appending(path: "state", directoryHint: .isDirectory)
        fileRestrictedStateRoot = root.appending(path: "file-restricted-state", directoryHint: .isDirectory)
        reviewedStateRoot = root.appending(path: "reviewed-state", directoryHint: .isDirectory)
        workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        workspaceInput = workspace.appending(path: "input.txt")
        workspaceOutput = workspace.appending(path: "output.txt")
        secret = root.appending(path: "host-secret.txt")
        claudeConfig = root.appending(path: "claude-account", directoryHint: .isDirectory)
        codexHome = root.appending(path: "codex-account", directoryHint: .isDirectory)

        for directory in [installRoot, workspace, claudeConfig, codexHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("workspace-input\n".utf8).write(to: workspaceInput)
        try Data("host-secret\n".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: installRoot.appending(path: "escape-to-secret"),
            withDestinationURL: secret
        )
        let script: String
        if javascriptProbe {
            script = """
            #!/usr/bin/env node
            const fs = require('node:fs')
            function readable(path) {
              try { fs.readFileSync(path); return 'allowed' } catch { return 'blocked' }
            }
            let privateHome = 'blocked'
            try { fs.writeFileSync(process.env.HOME + '/node-probe.txt', 'state'); privateHome = 'allowed' } catch {}
            console.log('secret=' + readable('\(secret.path)'))
            console.log('workspace-read=' + readable('\(workspaceInput.path)'))
            console.log('private-home=' + privateHome)
            console.log('github-token=' + (process.env.GITHUB_TOKEN === undefined ? 'absent' : 'leaked'))
            """
        } else if let networkProbePort {
            script = """
            #!/bin/zsh
            if /usr/bin/nc -n -z -w 1 127.0.0.1 \(networkProbePort); then print -r -- 'network=allowed'; else print -r -- 'network=blocked'; fi
            exit 0
            """
        } else if scriptedProbe {
            script = """
            #!/bin/zsh
            if print -r -- state > "$HOME/probe.txt"; then print -r -- 'private-home=allowed'; else print -r -- 'private-home=blocked'; fi
            if /usr/bin/true; then print -r -- 'process=allowed'; else print -r -- 'process=blocked'; fi
            if /bin/cat '\(secret.path)' >/dev/null; then print -r -- 'secret=allowed'; else print -r -- 'secret=blocked'; fi
            if /bin/cat '\(installRoot.appending(path: "escape-to-secret").path)' >/dev/null; then print -r -- 'install-symlink=allowed'; else print -r -- 'install-symlink=blocked'; fi
            if /bin/cat '\(workspaceInput.path)' >/dev/null; then print -r -- 'workspace-read=allowed'; else print -r -- 'workspace-read=blocked'; fi
            if /bin/ls '\(workspace.path)' >/dev/null; then print -r -- 'workspace-list=allowed'; else print -r -- 'workspace-list=blocked'; fi
            if /bin/sh -c 'printf "%s\\n" output > "$1"' probe '\(workspaceOutput.path)'; then print -r -- 'workspace-write=allowed'; else print -r -- 'workspace-write=blocked'; fi
            exit 0
            """
        } else {
            script = "#!/bin/zsh\nexit 0\n"
        }
        try Data(script.utf8).write(to: adapter)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adapter.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func run(_ launch: AcpAdapterLaunch) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.command)
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: launch.cwd, isDirectory: true)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    func canonicalPath(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private final class LoopbackListener {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError() }
        self.descriptor = descriptor

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 2) == 0 else {
            let error = Self.posixError()
            Darwin.close(descriptor)
            throw error
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            let error = Self.posixError()
            Darwin.close(descriptor)
            throw error
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { Darwin.close(descriptor) }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
