import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

/// The permission-rules engine and store, mirroring the Electron renderer's
/// `permissionRules.ts` semantics: wildcard matching, rule derivation, sensitive
/// globs that can never be rule-covered, and persisted allow-rules.
final class AcpPermissionRulesTests: XCTestCase {

    // MARK: - Wildcard matching

    func testWildcardMatchesStarAndIsCaseInsensitive() {
        XCTAssertTrue(AcpPermissionRules.wildcardMatch(pattern: "*", value: "anything"))
        XCTAssertTrue(AcpPermissionRules.wildcardMatch(pattern: "git *", value: "git status"))
        XCTAssertTrue(AcpPermissionRules.wildcardMatch(pattern: "GIT *", value: "git commit -m x"))
        XCTAssertFalse(AcpPermissionRules.wildcardMatch(pattern: "git *", value: "npm install"))
    }

    func testWildcardEscapesRegexMetacharacters() {
        XCTAssertTrue(AcpPermissionRules.wildcardMatch(pattern: "a.b", value: "a.b"))
        XCTAssertFalse(AcpPermissionRules.wildcardMatch(pattern: "a.b", value: "axb"))
    }

    // MARK: - Rule derivation

    func testRuleForExecuteUsesFirstWord() {
        let rule = AcpPermissionRules.ruleForRequest(kind: "execute", resource: "git commit -m 'x'")
        XCTAssertEqual(rule.action, "execute")
        XCTAssertEqual(rule.resource, "git *")
    }

    func testRuleForNonExecuteAllowsWholeKind() {
        let rule = AcpPermissionRules.ruleForRequest(kind: "edit", resource: "Edit src/app.ts")
        XCTAssertEqual(rule.action, "edit")
        XCTAssertEqual(rule.resource, "*")
    }

    func testEmptyKindBecomesOther() {
        let rule = AcpPermissionRules.ruleForRequest(kind: "", resource: "do a thing")
        XCTAssertEqual(rule.action, "other")
    }

    func testRuleLabel() {
        XCTAssertEqual(AcpPermissionRules.ruleLabel(action: "edit", resource: "*"), "all edit")
        XCTAssertEqual(AcpPermissionRules.ruleLabel(action: "execute", resource: "git *"), "git …")
        XCTAssertEqual(AcpPermissionRules.ruleLabel(action: "execute", resource: "exact"), "exact")
    }

    func testPermissionReviewDisclosesRawInputEveryUniquePathAndExactRuleScope() throws {
        let rawInput = JSONValue.object([
            "command": .string("git status --short"),
            "target": .string("Sources/App.swift"),
        ])
        let options = [
            AcpPermissionRequest.Option(id: "allow", name: "Proceed once", kind: "allow_once"),
            AcpPermissionRequest.Option(id: "deny", name: "Reject once", kind: "reject_once"),
            AcpPermissionRequest.Option(id: "always", name: "Always proceed", kind: "allow_always"),
        ]
        let request = AcpPermissionRequest(
            id: 7,
            sessionID: "s",
            title: "Inspect repository status",
            options: options,
            rawInput: rawInput,
            kind: "execute",
            paths: ["Sources/App.swift", "Sources/App.swift", "Tests/Odd\nName.swift"]
        )

        let review = AcpPermissionReview(request: request, workspace: "/work/project")

        XCTAssertFalse(review.rawInputIsTitleFallback)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: Data(review.rawInput.utf8)),
            rawInput
        )
        XCTAssertEqual(review.paths, ["Sources/App.swift", "Tests/Odd\nName.swift"])
        XCTAssertEqual(review.ruleScope, AcpPermissionRuleScope(
            workspace: "/work/project",
            action: "execute",
            resource: "git *"
        ))
        XCTAssertEqual(review.allowOnceOptionID, "allow")
        XCTAssertEqual(review.denyOnceOptionID, "deny")
        XCTAssertEqual(review.omittedOptions.map(\.id), ["always"])
    }

    func testPermissionReviewLabelsTitleFallbackInsteadOfInventingRawInput() {
        let request = AcpPermissionRequest(
            id: 1,
            sessionID: "s",
            title: "Human-readable adapter title",
            options: []
        )

        let review = AcpPermissionReview(request: request, workspace: "/work")

        XCTAssertTrue(review.rawInputIsTitleFallback)
        XCTAssertEqual(review.rawInput, "Human-readable adapter title")
        XCTAssertNil(review.allowOnceOptionID)
        XCTAssertNil(review.denyOnceOptionID)
    }

    // MARK: - Rule matching

    func testRequestMatchesRuleByWorkspaceActionAndResource() {
        let rules = [
            PermissionRule(id: "1", workspace: "/w", action: "execute", resource: "git *", at: 0),
        ]
        XCTAssertNotNil(AcpPermissionRules.requestMatchesRule(rules, workspace: "/w", kind: "execute", resource: "git push"))
        // Wrong workspace, wrong action, and non-matching resource all miss.
        XCTAssertNil(AcpPermissionRules.requestMatchesRule(rules, workspace: "/other", kind: "execute", resource: "git push"))
        XCTAssertNil(AcpPermissionRules.requestMatchesRule(rules, workspace: "/w", kind: "edit", resource: "git push"))
        XCTAssertNil(AcpPermissionRules.requestMatchesRule(rules, workspace: "/w", kind: "execute", resource: "npm test"))
    }

    func testNilWorkspaceNeverMatches() {
        let rules = [PermissionRule(id: "1", workspace: "/w", action: "execute", resource: "*", at: 0)]
        XCTAssertNil(AcpPermissionRules.requestMatchesRule(rules, workspace: nil, kind: "execute", resource: "anything"))
    }

    @MainActor
    func testCreateRulePersistsTheScopeShownInReview() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-reviewed-rule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PermissionRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        let conversation = AcpConversation(
            title: "Permission",
            command: "unused",
            arguments: [],
            cwd: "/work/project",
            ruleStore: store,
            sensitiveGlobs: []
        )
        conversation.receivePermissionForTesting(AcpPermissionRequest(
            id: 1,
            sessionID: "s",
            title: "Inspect repository status",
            options: [
                .init(id: "allow", name: "Allow once", kind: "allow_once"),
                .init(id: "deny", name: "Reject once", kind: "reject_once"),
            ],
            rawInput: .string("git status --short"),
            kind: "execute"
        ))
        let displayedScope = try XCTUnwrap(conversation.pendingPermissionReview?.ruleScope)
        XCTAssertEqual(displayedScope.resource, "git *")

        conversation.answerPermissionAlways()

        let stored = try XCTUnwrap(store.rules().first)
        XCTAssertEqual(stored.workspace, displayedScope.workspace)
        XCTAssertEqual(stored.action, displayedScope.action)
        XCTAssertEqual(stored.resource, displayedScope.resource)
        XCTAssertNil(conversation.pendingPermission)
    }

    @MainActor
    func testMatchingRuleCannotEscalateToAdapterOwnedAlwaysAllow() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-no-always-escalation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PermissionRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        _ = store.add(PermissionRule(
            id: "existing",
            workspace: "/work/project",
            action: "execute",
            resource: "git *",
            at: 0
        ))
        let conversation = AcpConversation(
            title: "Permission",
            command: "unused",
            arguments: [],
            cwd: "/work/project",
            ruleStore: store,
            sensitiveGlobs: []
        )
        conversation.receivePermissionForTesting(AcpPermissionRequest(
            id: 2,
            sessionID: "s",
            title: "git push",
            options: [
                .init(id: "always", name: "Always allow", kind: "allow_always"),
                .init(id: "deny", name: "Reject once", kind: "reject_once"),
            ],
            kind: "execute"
        ))

        XCTAssertEqual(conversation.pendingPermission?.id, 2)
        XCTAssertFalse(conversation.pendingPermissionAllowsRule)
    }

    // MARK: - Sensitive files

    func testDefaultGlobsFlagSecrets() {
        let globs = AcpPermissionRules.defaultSensitiveGlobs
        XCTAssertTrue(AcpPermissionRules.pathIsSensitive(globs: globs, pathish: "config/.env.local"))
        XCTAssertTrue(AcpPermissionRules.pathIsSensitive(globs: globs, pathish: "certs/server.pem"))
        XCTAssertTrue(AcpPermissionRules.pathIsSensitive(globs: globs, pathish: "id_rsa.key"))
        XCTAssertFalse(AcpPermissionRules.pathIsSensitive(globs: globs, pathish: "src/app.ts"))
    }

    func testRootLevelDotEnvIsSensitiveViaDoubleStar() {
        // `**/.env*` must also match a root-level `.env` with no directory.
        XCTAssertTrue(AcpPermissionRules.pathIsSensitive(globs: ["**/.env*"], pathish: ".env"))
        XCTAssertTrue(AcpPermissionRules.pathIsSensitive(globs: ["**/.env*"], pathish: ".env.production"))
    }

    func testRequestIsSensitiveFromPathsOrTitleTokens() {
        let globs = AcpPermissionRules.defaultSensitiveGlobs
        XCTAssertTrue(AcpPermissionRules.requestIsSensitive(globs: globs, title: "Edit file", paths: ["app/.env"]))
        XCTAssertTrue(AcpPermissionRules.requestIsSensitive(globs: globs, title: "cat 'secrets.yml'", paths: []))
        XCTAssertTrue(AcpPermissionRules.requestIsSensitive(
            globs: globs,
            title: "Read configuration",
            paths: [],
            rawInput: .object(["command": .string("cat .env")])
        ))
        XCTAssertFalse(AcpPermissionRules.requestIsSensitive(globs: globs, title: "ls -la", paths: ["src/main.swift"]))
    }

    func testSensitiveGlobSettingsRejectUnsupportedOrDangerouslyBroadPatterns() {
        XCTAssertNil(SensitiveGlobPolicy.validationMessage(
            " **/*.p12 ",
            existing: AcpPermissionRules.defaultSensitiveGlobs
        ))
        XCTAssertEqual(
            SensitiveGlobPolicy.validationMessage("**/[Ss]ecret", existing: []),
            "Only * and ** wildcards are supported; ?, brackets, and braces are not."
        )
        XCTAssertEqual(
            SensitiveGlobPolicy.validationMessage("**/*", existing: []),
            "Name at least part of a sensitive file; a wildcard-only pattern is too broad."
        )
        XCTAssertEqual(
            SensitiveGlobPolicy.validationMessage("**/.ENV*", existing: ["**/.env*"]),
            "That sensitive-file pattern already exists."
        )
    }
}

/// PermissionRuleStore file persistence.
final class PermissionRuleStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: PermissionRuleStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-rules-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("permission-rules.json")
        store = PermissionRuleStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func rule(_ id: String, _ resource: String, workspace: String = "/w", action: String = "execute") -> PermissionRule {
        PermissionRule(id: id, workspace: workspace, action: action, resource: resource, at: 0)
    }

    func testAddAndPersistAcrossInstances() {
        _ = store.add(rule("1", "git *"))
        let reopened = PermissionRuleStore(fileURL: fileURL)
        XCTAssertEqual(reopened.rules().count, 1)
        XCTAssertEqual(reopened.rules().first?.resource, "git *")
    }

    func testAddIsIdempotentByWorkspaceActionResource() {
        _ = store.add(rule("1", "git *"))
        _ = store.add(rule("2", "git *"))     // same trio, different id → no dup
        XCTAssertEqual(store.rules().count, 1)
        _ = store.add(rule("3", "npm *"))
        XCTAssertEqual(store.rules().count, 2)
    }

    func testRemoveByID() {
        _ = store.add(rule("1", "git *"))
        _ = store.add(rule("2", "npm *"))
        store.remove(id: "1")
        XCTAssertEqual(store.rules().map(\.resource), ["npm *"])
    }

    func testCorruptFileDegradesToEmpty() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(store.rules().isEmpty)
    }
}
