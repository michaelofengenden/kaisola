import Darwin
import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

/// The rich tool-artifact path: AcpDiff line diffing and AcpClient's ToolCallContent
/// parsing (diff / content / terminal), which feed the chat's inline diff cards.
final class AcpToolArtifactsTests: XCTestCase {

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

    // MARK: - Agent-owned filesystem descriptor boundaries

    func testAgentReadRejectsGrowthAfterDescriptorReview() throws {
        let fixture = try agentWriteFixture()
        let target = fixture.workspace.appendingPathComponent("growing.txt")
        try Data("small".utf8).write(to: target)

        XCTAssertThrowsError(
            try AcpWorkspaceFileReader.readTextFile(
                at: target.path,
                maximumBytes: 8,
                afterOpen: {
                    let handle = try FileHandle(forWritingTo: target)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("-overflow".utf8))
                    try handle.close()
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? AcpClientError,
                .requestFailed("Text file exceeds the 8-byte ACP limit")
            )
        }
    }

    func testAgentReadReturnsTruncatedDescriptorSnapshot() throws {
        let fixture = try agentWriteFixture()
        let target = fixture.workspace.appendingPathComponent("truncated.txt")
        try Data("truncate me".utf8).write(to: target)

        let content = try AcpWorkspaceFileReader.readTextFile(
            at: target.path,
            maximumBytes: 32,
            afterOpen: {
                guard Darwin.truncate(target.path, 4) == 0 else { throw self.posixError() }
            }
        )

        XCTAssertEqual(content, "trun")
    }

    func testAgentReadKeepsOpenedFileWhenPathIsReplaced() throws {
        let fixture = try agentWriteFixture()
        let target = fixture.workspace.appendingPathComponent("reviewed.txt")
        let parked = fixture.workspace.appendingPathComponent("reviewed-open.txt")
        let replacement = fixture.workspace.appendingPathComponent("replacement.txt")
        try Data("opened snapshot".utf8).write(to: target)
        try Data("replacement path".utf8).write(to: replacement)

        let content = try AcpWorkspaceFileReader.readTextFile(
            at: target.path,
            maximumBytes: 32,
            afterOpen: {
                try FileManager.default.moveItem(at: target, to: parked)
                try FileManager.default.moveItem(at: replacement, to: target)
            }
        )

        XCTAssertEqual(content, "opened snapshot")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "replacement path")
    }

    func testAgentReadCountsMultibyteUTF8BytesAtExactBoundary() throws {
        let fixture = try agentWriteFixture()
        let exact = fixture.workspace.appendingPathComponent("exact-utf8.txt")
        let oversized = fixture.workspace.appendingPathComponent("oversized-utf8.txt")
        try Data("😀😀".utf8).write(to: exact)
        try Data("😀😀x".utf8).write(to: oversized)

        XCTAssertEqual(
            try AcpWorkspaceFileReader.readTextFile(at: exact.path, maximumBytes: 8),
            "😀😀"
        )
        XCTAssertThrowsError(
            try AcpWorkspaceFileReader.readTextFile(at: oversized.path, maximumBytes: 8)
        ) { error in
            XCTAssertEqual(
                error as? AcpClientError,
                .requestFailed("Text file exceeds the 8-byte ACP limit")
            )
        }
    }

    func testAgentWriteUpdatesRegularFilesAndCreatesSafeParents() throws {
        let fixture = try agentWriteFixture()
        let existing = fixture.workspace.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: existing.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "old".write(to: existing, atomically: true, encoding: .utf8)

        try AcpWorkspaceFileWriter.write(
            Data("updated".utf8),
            to: existing.path,
            workspaceRoot: fixture.workspace.path
        )
        let created = fixture.workspace.appendingPathComponent("Generated/Nested/new.txt")
        try AcpWorkspaceFileWriter.write(
            Data("created".utf8),
            to: created.path,
            workspaceRoot: fixture.workspace.path
        )

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "updated")
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "created")
    }

    func testAgentWritePreservesExecutableOrdinaryModesAndOwnership() throws {
        let fixture = try agentWriteFixture()
        for (name, mode) in [("executable.sh", mode_t(0o755)), ("ordinary.txt", mode_t(0o640))] {
            let target = fixture.workspace.appendingPathComponent(name)
            try "old".write(to: target, atomically: true, encoding: .utf8)
            XCTAssertEqual(Darwin.chmod(target.path, mode), 0)
            let before = try fileMetadata(at: target)

            try AcpWorkspaceFileWriter.write(
                Data("updated".utf8),
                to: target.path,
                workspaceRoot: fixture.workspace.path
            )

            let after = try fileMetadata(at: target)
            XCTAssertEqual(mode_t(after.st_mode & 0o777), mode)
            XCTAssertEqual(after.st_uid, before.st_uid)
            XCTAssertEqual(after.st_gid, before.st_gid)
        }
    }

    func testAgentWritePreservesAllowedXattrsAndDropsContentCoupledMetadata() throws {
        let fixture = try agentWriteFixture()
        let target = fixture.workspace.appendingPathComponent("metadata.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        let preservedName = "com.kaisola.acp.metadata"
        let preservedValue = Data("preserve me".utf8)
        let removedAttributes = [
            (XATTR_RESOURCEFORK_NAME, Data("stale fork".utf8)),
            ("com.apple.cs.CodeDirectory", Data("stale signature".utf8)),
        ]
        try setExtendedAttribute(preservedName, value: preservedValue, at: target)
        for (name, value) in removedAttributes {
            try setExtendedAttribute(name, value: value, at: target)
        }

        XCTAssertEqual(
            AcpWorkspaceFileWriter.extendedAttributeDisposition(for: preservedName),
            .preserve
        )
        XCTAssertEqual(
            AcpWorkspaceFileWriter.extendedAttributeDisposition(for: "com.apple.quarantine"),
            .preserve,
            "dropping quarantine would weaken an existing security policy"
        )
        XCTAssertEqual(
            AcpWorkspaceFileWriter.extendedAttributeDisposition(for: "com.apple.system.Security"),
            .remove,
            "ACL bytes are restored only through the dedicated descriptor API"
        )

        try AcpWorkspaceFileWriter.write(
            Data("updated".utf8),
            to: target.path,
            workspaceRoot: fixture.workspace.path
        )

        XCTAssertEqual(try extendedAttribute(preservedName, at: target), preservedValue)
        for (name, _) in removedAttributes {
            XCTAssertNil(try extendedAttribute(name, at: target))
            XCTAssertEqual(
                AcpWorkspaceFileWriter.extendedAttributeDisposition(for: name),
                .remove
            )
        }
    }

    func testAgentWritePreservesExtendedACLWhenSupported() throws {
        let fixture = try agentWriteFixture()
        let target = fixture.workspace.appendingPathComponent("acl.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try installTestACL(at: target)
        let before = try XCTUnwrap(extendedACLText(at: target))

        try AcpWorkspaceFileWriter.write(
            Data("updated".utf8),
            to: target.path,
            workspaceRoot: fixture.workspace.path
        )

        XCTAssertEqual(try extendedACLText(at: target), before)
    }

    func testAgentWriteCreatesNewFilesWithSafeDefaults() throws {
        let fixture = try agentWriteFixture()
        let target = fixture.workspace.appendingPathComponent("new.txt")

        try AcpWorkspaceFileWriter.write(
            Data("created".utf8),
            to: target.path,
            workspaceRoot: fixture.workspace.path
        )

        let metadata = try fileMetadata(at: target)
        let parentMetadata = try fileMetadata(at: fixture.workspace)
        XCTAssertEqual(mode_t(metadata.st_mode & 0o777), mode_t(0o644))
        XCTAssertEqual(metadata.st_uid, Darwin.geteuid())
        XCTAssertEqual(metadata.st_gid, parentMetadata.st_gid)
        XCTAssertNil(try extendedACLText(at: target))
    }

    func testAgentWriteRollsBackContentAndMetadataWhenReplacementCommitFails() throws {
        let fixture = try agentWriteFixture()
        let target = fixture.workspace.appendingPathComponent("rollback.txt")
        try "original".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(Darwin.chmod(target.path, 0o751), 0)
        let attributeName = "com.kaisola.acp.rollback"
        let attributeValue = Data("original metadata".utf8)
        try setExtendedAttribute(attributeName, value: attributeValue, at: target)
        let before = try fileMetadata(at: target)

        XCTAssertThrowsError(
            try AcpWorkspaceFileWriter.write(
                Data("replacement".utf8),
                to: target.path,
                workspaceRoot: fixture.workspace.path,
                beforeReplacementCommit: {
                    throw NSError(domain: "AcpWorkspaceFileWriterTests", code: 487)
                }
            )
        )

        let after = try fileMetadata(at: target)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(mode_t(after.st_mode & 0o777), mode_t(0o751))
        XCTAssertEqual(after.st_uid, before.st_uid)
        XCTAssertEqual(after.st_gid, before.st_gid)
        XCTAssertEqual(try extendedAttribute(attributeName, at: target), attributeValue)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path)
                .contains(where: { $0.hasPrefix(".kaisola-acp-write-") })
        )
    }

    func testAgentWriteRejectsSymbolicLinkLeafBeforeMutation() throws {
        let fixture = try agentWriteFixture()
        let real = fixture.workspace.appendingPathComponent("real.txt")
        let linked = fixture.workspace.appendingPathComponent("linked.txt")
        try "unchanged".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

        assertAgentWriteRejected(containing: "symbolic-link targets") {
            try AcpWorkspaceFileWriter.write(
                Data("redirected".utf8),
                to: linked.path,
                workspaceRoot: fixture.workspace.path
            )
        }

        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "unchanged")
        XCTAssertTrue((try? linked.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    }

    func testAgentWriteRejectsSymbolicLinkParentBeforeMutation() throws {
        let fixture = try agentWriteFixture()
        let linkedParent = fixture.workspace.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: fixture.outside
        )
        let outsideTarget = fixture.outside.appendingPathComponent("new.txt")

        assertAgentWriteRejected(containing: "symbolic-link parents") {
            try AcpWorkspaceFileWriter.write(
                Data("redirected".utf8),
                to: linkedParent.appendingPathComponent("new.txt").path,
                workspaceRoot: fixture.workspace.path
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget.path))
    }

    func testAgentWriteRejectsOutOfRootTargetBeforeMutation() throws {
        let fixture = try agentWriteFixture()
        let outsideTarget = fixture.outside.appendingPathComponent("escape.txt")

        assertAgentWriteRejected(containing: "escapes the session project") {
            try AcpWorkspaceFileWriter.write(
                Data("redirected".utf8),
                to: outsideTarget.path,
                workspaceRoot: fixture.workspace.path
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideTarget.path))
    }

    func testAgentWriteRejectsLeafSwapAfterReviewWithoutTouchingEitherFile() throws {
        let fixture = try agentWriteFixture()
        let target = fixture.workspace.appendingPathComponent("reviewed.txt")
        let parked = fixture.workspace.appendingPathComponent("reviewed-parked.txt")
        let outsideTarget = fixture.outside.appendingPathComponent("reviewed.txt")
        try "authorized".write(to: target, atomically: true, encoding: .utf8)
        try "outside".write(to: outsideTarget, atomically: true, encoding: .utf8)

        assertAgentWriteRejected(containing: "symbolic-link targets") {
            try AcpWorkspaceFileWriter.write(
                Data("redirected".utf8),
                to: target.path,
                workspaceRoot: fixture.workspace.path,
                beforeMutation: {
                    try FileManager.default.moveItem(at: target, to: parked)
                    try FileManager.default.createSymbolicLink(
                        at: target,
                        withDestinationURL: outsideTarget
                    )
                }
            )
        }

        XCTAssertEqual(try String(contentsOf: parked, encoding: .utf8), "authorized")
        XCTAssertEqual(try String(contentsOf: outsideTarget, encoding: .utf8), "outside")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path)
                .contains(where: { $0.hasPrefix(".kaisola-acp-write-") })
        )
    }

    func testAgentWriteRejectsParentSwapAfterReviewWithoutWritingOutside() throws {
        let fixture = try agentWriteFixture()
        let parent = fixture.workspace.appendingPathComponent("reviewed-parent", isDirectory: true)
        let parked = fixture.workspace.appendingPathComponent("reviewed-parent-parked", isDirectory: true)
        let target = parent.appendingPathComponent("reviewed.txt")
        let parkedTarget = parked.appendingPathComponent("reviewed.txt")
        let outsideTarget = fixture.outside.appendingPathComponent("reviewed.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try "authorized".write(to: target, atomically: true, encoding: .utf8)
        try "outside".write(to: outsideTarget, atomically: true, encoding: .utf8)

        assertAgentWriteRejected(containing: "symbolic-link parents") {
            try AcpWorkspaceFileWriter.write(
                Data("redirected".utf8),
                to: target.path,
                workspaceRoot: fixture.workspace.path,
                beforeMutation: {
                    try FileManager.default.moveItem(at: parent, to: parked)
                    try FileManager.default.createSymbolicLink(
                        at: parent,
                        withDestinationURL: fixture.outside
                    )
                }
            )
        }

        XCTAssertEqual(try String(contentsOf: parkedTarget, encoding: .utf8), "authorized")
        XCTAssertEqual(try String(contentsOf: outsideTarget, encoding: .utf8), "outside")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: parked.path)
                .contains(where: { $0.hasPrefix(".kaisola-acp-write-") })
        )
    }

    private func agentWriteFixture() throws -> (workspace: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-agent-write-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (workspace, outside)
    }

    private func fileMetadata(at url: URL) throws -> stat {
        var metadata = stat()
        let result = url.path.withCString { Darwin.lstat($0, &metadata) }
        guard result == 0 else { throw posixError() }
        return metadata
    }

    private func setExtendedAttribute(_ name: String, value: Data, at url: URL) throws {
        let result = value.withUnsafeBytes { bytes in
            url.path.withCString { path in
                name.withCString { attributeName in
                    Darwin.setxattr(
                        path,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        XATTR_NOFOLLOW
                    )
                }
            }
        }
        guard result == 0 else { throw posixError() }
    }

    private func extendedAttribute(_ name: String, at url: URL) throws -> Data? {
        let size = url.path.withCString { path in
            name.withCString { attributeName in
                Darwin.getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        if size < 0, errno == ENOATTR { return nil }
        guard size >= 0 else { throw posixError() }
        if size == 0 { return Data() }
        var value = Data(count: Int(size))
        let readSize = value.withUnsafeMutableBytes { bytes in
            url.path.withCString { path in
                name.withCString { attributeName in
                    Darwin.getxattr(
                        path,
                        attributeName,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        XATTR_NOFOLLOW
                    )
                }
            }
        }
        guard readSize == size else { throw posixError() }
        return value
    }

    private func installTestACL(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("extended ACLs are unavailable on this filesystem")
        }
    }

    private func extendedACLText(at url: URL) throws -> String? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        errno = 0
        guard let accessControlList = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return nil }
            if errno == ENOTSUP {
                throw XCTSkip("extended ACLs are unavailable on this filesystem")
            }
            throw posixError()
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(accessControlList)) }
        var length: ssize_t = 0
        guard let text = Darwin.acl_to_text(accessControlList, &length) else {
            throw posixError()
        }
        defer { _ = acl_free(text) }
        return String(cString: text)
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func assertAgentWriteRejected(
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("expected the agent write to be rejected", file: file, line: line)
        } catch let AcpClientError.requestFailed(message) {
            XCTAssertTrue(message.contains(expected), message, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
