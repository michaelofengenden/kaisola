import Foundation
import XCTest
@testable import KaisolaMacPreview

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
        let rule = AcpPermissionRules.ruleForRequest(kind: "execute", title: "git commit -m 'x'")
        XCTAssertEqual(rule.action, "execute")
        XCTAssertEqual(rule.resource, "git *")
    }

    func testRuleForNonExecuteAllowsWholeKind() {
        let rule = AcpPermissionRules.ruleForRequest(kind: "edit", title: "Edit src/app.ts")
        XCTAssertEqual(rule.action, "edit")
        XCTAssertEqual(rule.resource, "*")
    }

    func testEmptyKindBecomesOther() {
        let rule = AcpPermissionRules.ruleForRequest(kind: "", title: "do a thing")
        XCTAssertEqual(rule.action, "other")
    }

    func testRuleLabel() {
        XCTAssertEqual(AcpPermissionRules.ruleLabel(action: "edit", resource: "*"), "all edit")
        XCTAssertEqual(AcpPermissionRules.ruleLabel(action: "execute", resource: "git *"), "git …")
        XCTAssertEqual(AcpPermissionRules.ruleLabel(action: "execute", resource: "exact"), "exact")
    }

    // MARK: - Rule matching

    func testRequestMatchesRuleByWorkspaceActionAndResource() {
        let rules = [
            PermissionRule(id: "1", workspace: "/w", action: "execute", resource: "git *", at: 0),
        ]
        XCTAssertNotNil(AcpPermissionRules.requestMatchesRule(rules, workspace: "/w", kind: "execute", title: "git push"))
        // Wrong workspace, wrong action, and non-matching resource all miss.
        XCTAssertNil(AcpPermissionRules.requestMatchesRule(rules, workspace: "/other", kind: "execute", title: "git push"))
        XCTAssertNil(AcpPermissionRules.requestMatchesRule(rules, workspace: "/w", kind: "edit", title: "git push"))
        XCTAssertNil(AcpPermissionRules.requestMatchesRule(rules, workspace: "/w", kind: "execute", title: "npm test"))
    }

    func testNilWorkspaceNeverMatches() {
        let rules = [PermissionRule(id: "1", workspace: "/w", action: "execute", resource: "*", at: 0)]
        XCTAssertNil(AcpPermissionRules.requestMatchesRule(rules, workspace: nil, kind: "execute", title: "anything"))
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
        XCTAssertFalse(AcpPermissionRules.requestIsSensitive(globs: globs, title: "ls -la", paths: ["src/main.swift"]))
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
