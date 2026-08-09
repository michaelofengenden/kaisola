import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

/// The rich tool-artifact path: AcpDiff line diffing and AcpClient's ToolCallContent
/// parsing (diff / content / terminal), which feed the chat's inline diff cards.
final class AcpToolArtifactsTests: XCTestCase {

    // MARK: - Checkpoint menu accessibility

    func testCheckpointMenuAccessibilityNamesPurposeAndAvailableCount() {
        XCTAssertEqual(CheckpointMenuAccessibility.label, "Restore checkpoint")
        XCTAssertEqual(
            CheckpointMenuAccessibility.value(checkpointCount: 1),
            "1 checkpoint available"
        )
        XCTAssertEqual(
            CheckpointMenuAccessibility.value(checkpointCount: 3),
            "3 checkpoints available"
        )
        XCTAssertEqual(
            CheckpointMenuAccessibility.hint,
            "Choose a snapshot taken before a turn. Restoring replaces current working tree files after confirmation."
        )
        XCTAssertEqual(CheckpointMenuAccessibility.identifier, "acp.checkpoints.restore")
    }

    func testCheckpointChoiceAccessibilityExplainsTurnTimeAndDestructiveConsequence() {
        XCTAssertEqual(
            CheckpointMenuAccessibility.choiceLabel(turn: 7, time: "3:14 PM"),
            "Restore checkpoint before turn 7 at 3:14 PM"
        )
        XCTAssertEqual(
            CheckpointMenuAccessibility.choiceHint,
            "Replaces current working tree files with this snapshot after confirmation."
        )
    }

    // MARK: - Tool call accessibility

    func testToolCallAccessibilityNamesEveryTypedStatusAndDisclosureState() {
        let expectedStatuses: [(AcpToolCall.Status, String)] = [
            (.pending, "Pending"),
            (.inProgress, "In progress"),
            (.completed, "Completed"),
            (.failed, "Failed"),
        ]

        for (status, statusLabel) in expectedStatuses {
            let call = AcpToolCall(
                id: "tool-\(status.rawValue)",
                title: "Inspect native project",
                kind: "read",
                status: status,
                content: [.text("one"), .terminal(id: "terminal-1")]
            )

            let collapsed = ToolCallAccessibility(call: call, expanded: false)
            XCTAssertEqual(collapsed.label, "Show details for Inspect native project")
            XCTAssertEqual(
                collapsed.value,
                "read tool, \(statusLabel), 2 artifacts, Collapsed"
            )
            XCTAssertEqual(collapsed.actionName, "Show details")
            XCTAssertEqual(collapsed.identifier, "acp.tool.tool-\(status.rawValue)")

            let expanded = ToolCallAccessibility(call: call, expanded: true)
            XCTAssertEqual(expanded.label, "Hide details for Inspect native project")
            XCTAssertEqual(
                expanded.value,
                "read tool, \(statusLabel), 2 artifacts, Expanded"
            )
            XCTAssertEqual(expanded.actionName, "Hide details")
        }
    }

    func testToolCallAccessibilityDoesNotExposeDisclosureActionWithoutArtifacts() {
        let call = AcpToolCall(
            id: "tool-empty",
            title: "Check status",
            kind: "inspect",
            status: .completed
        )

        let accessibility = ToolCallAccessibility(call: call, expanded: false)
        XCTAssertEqual(accessibility.label, "Check status")
        XCTAssertEqual(accessibility.value, "inspect tool, Completed, 0 artifacts")
        XCTAssertNil(accessibility.actionName)
        XCTAssertEqual(accessibility.identifier, "acp.tool.tool-empty")
    }

    // MARK: - Tool-call density

    private var densityFixture: AcpToolCall {
        AcpToolCall(
            id: "density-tool",
            title: "Update project files",
            kind: "edit",
            status: .failed,
            content: [
                .diff(path: "Sources/App.swift", oldText: "old", newText: "new"),
                .text("permission decision: allowed once"),
                .terminal(id: "terminal-1"),
            ],
            locations: ["Tests/AppTests.swift", "Sources/App.swift"]
        )
    }

    func testEveryToolCallDensityRetainsCriticalEvidenceAndExpandability() {
        for density in ToolCallDensity.allCases {
            let presentation = ToolCallDensityPresentation(
                call: densityFixture,
                density: density
            )
            XCTAssertEqual(presentation.statusLabel, "Failed", density.title)
            XCTAssertEqual(presentation.affectedFiles, [
                "Tests/AppTests.swift", "Sources/App.swift",
            ], density.title)
            XCTAssertEqual(presentation.artifactCount, 3, density.title)
            XCTAssertTrue(presentation.hasExpandableContent, density.title)
            XCTAssertEqual(presentation.accessibilityOrder, [
                "Failed",
                "Update project files",
                "edit",
                "Affected files: Tests/AppTests.swift, Sources/App.swift",
                "3 expandable artifacts",
            ], density.title)
        }
    }

    func testNamedDensitiesExposeIncreasingDetailWithoutExpandingUnboundedOutput() {
        let presentations = ToolCallDensity.allCases.map {
            ToolCallDensityPresentation(call: densityFixture, density: $0)
        }

        XCTAssertEqual(presentations.map(\.visibleDetailLevel), [1, 2, 3])
        XCTAssertEqual(presentations.map(\.showsArtifactSummary), [false, true, true])
        XCTAssertEqual(presentations.map(\.wrapsAffectedFiles), [false, false, true])
        XCTAssertTrue(presentations.allSatisfy { !$0.expandsArtifactsByDefault })
    }

    func testDensityProjectionNeverMutatesTranscriptRowsOrStableIdentity() {
        let row = AcpTranscriptRow.tool(densityFixture)
        let baseline = row
        for density in ToolCallDensity.allCases {
            _ = ToolCallDensityPresentation(call: densityFixture, density: density)
            XCTAssertEqual(row, baseline)
            XCTAssertEqual(row.id, "tool-density-tool")
        }
    }

    func testDensityChangeKeepsStableReadingAnchorIdentity() {
        let rows: [AcpTranscriptRow] = [
            .message(id: "before", text: "Before"),
            .tool(densityFixture),
            .message(id: "after", text: "After"),
        ]
        let readingAnchor = rows[1].id

        for density in ToolCallDensity.allCases {
            _ = ToolCallDensityPresentation(call: densityFixture, density: density)
            XCTAssertEqual(rows[1].id, readingAnchor, density.title)
            XCTAssertEqual(rows.map(\.id), ["msg-before", "tool-density-tool", "msg-after"])
        }
    }

    func testLargeChatProjectionIsMeasuredWithinBudgetForEveryDensity() {
        let calls = (0..<20_000).map { index in
            AcpToolCall(
                id: "tool-\(index)",
                title: "Read source \(index)",
                kind: index.isMultiple(of: 2) ? "read" : "edit",
                status: index.isMultiple(of: 7) ? .failed : .completed,
                content: [.text("bounded output")],
                locations: ["Sources/File\(index).swift"]
            )
        }
        let clock = ContinuousClock()
        for density in ToolCallDensity.allCases {
            var checksum = 0
            let elapsed = clock.measure {
                for call in calls {
                    let presentation = ToolCallDensityPresentation(call: call, density: density)
                    checksum &+= presentation.accessibilityOrder.count
                }
            }
            XCTAssertEqual(checksum, calls.count * 5, density.title)
            XCTAssertLessThan(elapsed, .seconds(2), "\(density.title) projection: \(elapsed)")
        }
    }

    // MARK: - AcpDiff

    func testFreshFileIsAllAdditions() {
        let lines = AcpDiff.lines(old: "", new: "alpha\nbeta\n")
        XCTAssertEqual(lines.map(\.kind), [.added, .added])
        XCTAssertEqual(lines.map(\.text), ["alpha", "beta"])
    }

    func testDeletedFileIsAllRemovals() {
        let lines = AcpDiff.lines(old: "gone\n", new: "")
        XCTAssertEqual(lines.map(\.kind), [.removed])
    }

    func testSingleLineChangeKeepsContext() {
        let old = "one\ntwo\nthree\n"
        let new = "one\nTWO\nthree\n"
        let lines = AcpDiff.lines(old: old, new: new)
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(lines.first(where: { $0.kind == .removed })?.text, "two")
        XCTAssertEqual(lines.first(where: { $0.kind == .added })?.text, "TWO")
    }

    func testInsertionInMiddle() {
        let lines = AcpDiff.lines(old: "a\nc\n", new: "a\nb\nc\n")
        XCTAssertEqual(lines.map(\.kind), [.context, .added, .context])
        XCTAssertEqual(lines.first(where: { $0.kind == .added })?.text, "b")
    }

    func testIdenticalTextIsAllContext() {
        let lines = AcpDiff.lines(old: "same\nlines\n", new: "same\nlines\n")
        XCTAssertEqual(lines.map(\.kind), [.context, .context])
    }

    func testLinePrefixes() {
        XCTAssertEqual(AcpDiff.LineKind.context.prefix, "  ")
        XCTAssertEqual(AcpDiff.LineKind.removed.prefix, "- ")
        XCTAssertEqual(AcpDiff.LineKind.added.prefix, "+ ")
    }

    // MARK: - Tool content parsing

    func testParsesDiffContent() {
        let value = JSONValue.array([
            .object([
                "type": .string("diff"),
                "path": .string("/src/app.ts"),
                "oldText": .string("old"),
                "newText": .string("new"),
            ]),
        ])
        let content = AcpClient.parseToolContent(value)
        XCTAssertEqual(content.count, 1)
        guard case let .diff(path, oldText, newText) = content[0] else {
            return XCTFail("expected diff")
        }
        XCTAssertEqual(path, "/src/app.ts")
        XCTAssertEqual(oldText, "old")
        XCTAssertEqual(newText, "new")
    }

    func testParsesTextContentBlock() {
        let value = JSONValue.array([
            .object([
                "type": .string("content"),
                "content": .object(["type": .string("text"), "text": .string("output line")]),
            ]),
        ])
        let content = AcpClient.parseToolContent(value)
        XCTAssertEqual(content, [.text("output line")])
    }

    func testTerminalReferenceParsesToLiveTerminalContent() {
        let value = JSONValue.array([
            .object(["type": .string("terminal"), "terminalId": .string("term-9")]),
        ])
        let content = AcpClient.parseToolContent(value)
        XCTAssertEqual(content, [.terminal(id: "term-9")])
    }

    func testNilOrEmptyContentYieldsNoArtifacts() {
        XCTAssertTrue(AcpClient.parseToolContent(nil).isEmpty)
        XCTAssertTrue(AcpClient.parseToolContent(.array([])).isEmpty)
    }

    func testDeclaredFilePathsPreserveStructuredOrderAndIgnoreProse() {
        let call = AcpToolCall(
            id: "tool-1",
            title: "Editing README.md and prose/decoy.swift",
            kind: "edit",
            status: .inProgress,
            content: [
                .text("Pretend output mentions prose/another-decoy.swift"),
                .diff(path: "Sources/App.swift", oldText: "old", newText: "new"),
                .diff(path: "README.md", oldText: nil, newText: "docs"),
            ],
            locations: ["README.md", "", "Tests/AppTests.swift", "README.md"]
        )

        XCTAssertEqual(call.declaredFilePaths, [
            "README.md",
            "Tests/AppTests.swift",
            "Sources/App.swift",
        ])
    }

    @MainActor
    func testConversationRetriesRejectedPathsAndPublishesAcceptedPathsOnlyOnce() {
        let conversation = AcpConversation(
            title: "Test",
            command: "/usr/bin/true",
            arguments: [],
            cwd: "/tmp"
        )
        var activities: [AcpFileActivity] = []
        var attemptedPaths: [String] = []
        var rejectsFirstSourceAttempt = true
        conversation.onFileActivity = { activity in
            attemptedPaths.append(activity.path)
            if activity.path == "Sources/App.swift", rejectsFirstSourceAttempt {
                rejectsFirstSourceAttempt = false
                return false
            }
            activities.append(activity)
            return true
        }

        conversation.receiveTurnItemForTesting(.toolCall(AcpToolCall(
            id: "tool-1",
            title: "Read",
            kind: "read",
            status: .inProgress,
            locations: ["Sources/App.swift"]
        )))
        conversation.receiveTurnItemForTesting(.toolCall(AcpToolCall(
            id: "tool-1",
            title: "Edit",
            kind: "edit",
            status: .completed,
            content: [
                .diff(path: "Sources/App.swift", oldText: "old", newText: "new"),
                .diff(path: "Tests/AppTests.swift", oldText: nil, newText: "test"),
            ]
        )))
        conversation.receiveTurnItemForTesting(.toolCall(AcpToolCall(
            id: "tool-1",
            title: "Completed",
            kind: "edit",
            status: .completed,
            content: [
                .diff(path: "Sources/App.swift", oldText: "old", newText: "new"),
                .diff(path: "Tests/AppTests.swift", oldText: nil, newText: "test"),
            ]
        )))

        XCTAssertEqual(attemptedPaths, [
            "Sources/App.swift",
            "Sources/App.swift",
            "Tests/AppTests.swift",
        ])
        XCTAssertEqual(activities, [
            AcpFileActivity(toolCallID: "tool-1", kind: "edit", path: "Sources/App.swift"),
            AcpFileActivity(toolCallID: "tool-1", kind: "edit", path: "Tests/AppTests.swift"),
        ])
    }

    func testPermissionWireParserKeepsRawInputAndEveryDeclaredPath() throws {
        let rawInput = JSONValue.object([
            "command": .string("swift test"),
            "cwd": .string("/work/project"),
        ])
        let params = JSONValue.object([
            "toolCall": .object([
                "toolCallId": .string("tool-1"),
                "title": .string("Run tests"),
                "kind": .string("execute"),
                "rawInput": rawInput,
                "locations": .array([
                    .object(["path": .string("/work/project/Package.swift")]),
                    .object(["path": .string("/work/project/Package.swift")]),
                    .object(["path": .string("/work/project/Tests/Odd\nName.swift")]),
                ]),
                "content": .array([
                    .object([
                        "type": .string("diff"),
                        "path": .string("/work/project/Sources/App.swift"),
                        "oldText": .string("old"),
                        "newText": .string("new"),
                    ]),
                ]),
            ]),
            "options": .array([
                .object([
                    "optionId": .string("allow"),
                    "name": .string("Proceed once"),
                    "kind": .string("allow_once"),
                ]),
                .object([
                    "optionId": .string("extension"),
                    "name": .string("Adapter extension"),
                ]),
            ]),
        ])

        let request = try XCTUnwrap(AcpClient.parsePermissionRequest(
            localID: 42,
            sessionID: "session-1",
            params: params
        ))

        XCTAssertEqual(request.id, 42)
        XCTAssertEqual(request.sessionID, "session-1")
        XCTAssertEqual(request.rawInput, rawInput)
        XCTAssertEqual(request.kind, "execute")
        XCTAssertEqual(request.paths, [
            "/work/project/Package.swift",
            "/work/project/Tests/Odd\nName.swift",
            "/work/project/Sources/App.swift",
        ])
        XCTAssertEqual(request.options.map(\.kind), ["allow_once", "other"])
    }

    func testPartialPermissionRequestMergesPriorToolCallDisclosure() throws {
        let rawInput = JSONValue.object(["operation": .string("replace")])
        let initial = AcpClient.mergeToolCallReviewContext(nil, update: [
            "toolCallId": .string("file-change-1"),
            "title": .string("Editing files"),
            "kind": .string("edit"),
            "rawInput": rawInput,
            "locations": .array([
                .object(["path": .string("/work/Sources/App.swift")]),
            ]),
            "content": .array([
                .object([
                    "type": .string("diff"),
                    "path": .string("/work/Sources/App.swift"),
                    "oldText": .string("old"),
                    "newText": .string("new"),
                ]),
                .object([
                    "type": .string("diff"),
                    "path": .string("/work/Tests/AppTests.swift"),
                    // Path disclosure must survive even if artifact rendering
                    // cannot parse an incomplete diff body.
                ]),
            ]),
        ])
        let updated = AcpClient.mergeToolCallReviewContext(initial, update: [
            "toolCallId": .string("file-change-1"),
            "status": .string("pending"),
        ])
        let params = JSONValue.object([
            "toolCall": .object([
                "toolCallId": .string("file-change-1"),
                "status": .string("pending"),
            ]),
            "options": .array([
                .object([
                    "optionId": .string("allow"),
                    "name": .string("Allow once"),
                    "kind": .string("allow_once"),
                ]),
                .object([
                    "optionId": .string("deny"),
                    "name": .string("Reject"),
                    "kind": .string("reject_once"),
                ]),
            ]),
        ])

        let request = try XCTUnwrap(AcpClient.parsePermissionRequest(
            localID: 9,
            sessionID: "session",
            params: params,
            priorContext: updated
        ))

        XCTAssertEqual(request.title, "Editing files")
        XCTAssertEqual(request.kind, "edit")
        XCTAssertEqual(request.rawInput, rawInput)
        XCTAssertEqual(request.paths, [
            "/work/Sources/App.swift",
            "/work/Tests/AppTests.swift",
        ])
    }

    func testPresentToolCallFieldsReplaceCachedDisclosureCollections() {
        let prior = AcpToolCallReviewContext(
            title: "Old title",
            kind: "edit",
            rawInput: .string("old"),
            locationPaths: ["/old/location"],
            diffPaths: ["/old/diff"]
        )

        let replaced = AcpClient.mergeToolCallReviewContext(prior, update: [
            "toolCallId": .string("tool"),
            "rawInput": .null,
            "locations": .array([]),
            "content": .array([
                .object(["type": .string("diff"), "path": .string("/new/diff")]),
            ]),
        ])

        XCTAssertEqual(replaced.title, "Old title")
        XCTAssertEqual(replaced.kind, "edit")
        XCTAssertNil(replaced.rawInput)
        XCTAssertTrue(replaced.locationPaths.isEmpty)
        XCTAssertEqual(replaced.diffPaths, ["/new/diff"])
    }

    // MARK: - Workspace confinement (symlink resolution)

    func testNearestExistingAncestorResolvesSymlinksForUncreatedPaths() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-sym-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // workspace/link → outside. A write target under the link must resolve
        // to the OUTSIDE real path even though the file doesn't exist yet.
        let link = workspace.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escape = link.appendingPathComponent("new-dir/secret.txt").path
        let real = AcpClient.realPathViaNearestExistingAncestor(escape)
        let realOutside = outside.resolvingSymlinksInPath().path
        XCTAssertTrue(real.hasPrefix(realOutside + "/"),
                      "resolution must surface the symlink's real target: \(real)")
        let realWorkspace = workspace.resolvingSymlinksInPath().path
        XCTAssertFalse(real.hasPrefix(realWorkspace + "/"),
                       "the escape must not still look workspace-contained")
    }

    func testNearestExistingAncestorKeepsHonestPathsInPlace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-honest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("sub/new.txt").path
        let real = AcpClient.realPathViaNearestExistingAncestor(target)
        XCTAssertTrue(real.hasPrefix(workspace.resolvingSymlinksInPath().path + "/"))
        XCTAssertTrue(real.hasSuffix("/sub/new.txt"))
    }
}
