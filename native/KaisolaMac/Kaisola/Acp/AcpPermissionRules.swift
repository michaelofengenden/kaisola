import Foundation

/// Client-side permission rules, ported from the Electron renderer's
/// `src/lib/permissionRules.ts` (OpenCode's simplified model): flat
/// `{action, resource}` allow-rules with `*` wildcards, scoped per workspace.
/// The agent keeps asking (we always answer allow_once, never allow_always), so
/// these rules are the single source of truth — auto-answering matched asks and
/// visible/deletable in settings. Sensitive-file asks can never be covered by a
/// rule and always surface a card.
struct PermissionRule: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let workspace: String
    /// ACP tool-call kind: execute / edit / read / delete / fetch / other…
    let action: String
    /// Wildcard pattern over the request title (commands) — "*" = any.
    let resource: String
    let at: Int64
}

enum AcpPermissionRules {
    /// Default sensitive globs, matching the renderer store's seed. A request
    /// touching any of these always prompts and can never be rule-covered.
    static let defaultSensitiveGlobs = [
        "**/.env*", "**/*.pem", "**/*.key", "**/*.cert", "**/*.crt",
        "**/.dev.vars", "**/secrets.yml",
    ]

    /// `*`-only glob, case-insensitive, mirroring OpenCode's ~10-line matcher.
    static func wildcardMatch(pattern: String, value: String) -> Bool {
        let escaped = pattern
            .components(separatedBy: "*")
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: ".*")
        guard let rx = try? NSRegularExpression(
            pattern: "^" + escaped + "$",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return rx.firstMatch(in: value, options: [], range: range) != nil
    }

    private static func action(for kind: String) -> String {
        kind.isEmpty ? "other" : kind
    }

    /// Derive the rule an "Always allow" click should create. Commands get
    /// `firstWord *` (allow the tool, not one exact invocation); everything else
    /// allows the whole kind.
    static func ruleForRequest(kind: String, title: String) -> (action: String, resource: String) {
        let act = action(for: kind)
        if act == "execute" {
            let first = title.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            return (act, first.isEmpty ? "*" : "\(first) *")
        }
        return (act, "*")
    }

    /// Human label for a rule (buttons, settings rows).
    static func ruleLabel(action: String, resource: String) -> String {
        if resource == "*" { return "all \(action)" }
        if resource.hasSuffix(" *") { return String(resource.dropLast(2)) + " …" }
        return resource
    }

    /// The rule covering this request, if any (allow-only → any match allows).
    static func requestMatchesRule(
        _ rules: [PermissionRule],
        workspace: String?,
        kind: String,
        title: String
    ) -> PermissionRule? {
        guard let workspace else { return nil }
        let act = action(for: kind)
        return rules.first {
            $0.workspace == workspace && $0.action == act && wildcardMatch(pattern: $0.resource, value: title)
        }
    }

    /// Does a path (or command line mentioning one) hit a sensitive glob?
    /// `**/x` patterns also match a root-level `x` (no slash).
    static func pathIsSensitive(globs: [String], pathish: String) -> Bool {
        guard !pathish.isEmpty else { return false }
        return globs.contains { g in
            if wildcardMatch(pattern: g, value: pathish) { return true }
            if g.hasPrefix("**/") {
                let tail = String(g.dropFirst(3))
                if wildcardMatch(pattern: tail, value: pathish) { return true }
                if wildcardMatch(pattern: "*" + String(g.dropFirst(2)), value: pathish) { return true }
            }
            return false
        }
    }

    /// A permission request touching sensitive files (title tokens or diff paths).
    static func requestIsSensitive(globs: [String], title: String, paths: [String]) -> Bool {
        if paths.contains(where: { pathIsSensitive(globs: globs, pathish: $0) }) { return true }
        // Commands name their targets in the title — scan its tokens.
        return title.split(whereSeparator: { $0.isWhitespace }).contains { token in
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            return pathIsSensitive(globs: globs, pathish: trimmed)
        }
    }
}
