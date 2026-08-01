import Foundation
import KaisolaCore

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
    /// Wildcard pattern over the request's policy resource (raw command when
    /// available, otherwise the adapter title) — "*" = any.
    let resource: String
    let at: Int64
}

/// The exact three fields Kaisola will persist and later require to match.
/// Keeping this as a value shared by review and execution prevents the card
/// from describing a friendlier/wider scope than the rule store receives.
struct AcpPermissionRuleScope: Equatable, Sendable {
    let workspace: String
    let action: String
    let resource: String
}

/// A decision-grade, adapter-agnostic projection of an ACP permission ask.
/// `rawInput` is arbitrary JSON in ACP v1, so it is rendered losslessly as a
/// string or deterministic JSON rather than interpreted through guessed keys.
struct AcpPermissionReview: Equatable, Sendable {
    let title: String
    let rawInput: String
    let rawInputIsTitleFallback: Bool
    let paths: [String]
    let ruleScope: AcpPermissionRuleScope
    let allowOnceOptionID: String?
    let denyOnceOptionID: String?
    /// Adapter-owned persistent and unknown options do not have an inspectable
    /// scope, so the safe card discloses their omission instead of relabeling
    /// one as Kaisola's reviewed Create Rule action.
    let omittedOptions: [AcpPermissionRequest.Option]

    init(request: AcpPermissionRequest, workspace: String) {
        title = request.title
        if let input = request.rawInput, input != .null {
            rawInput = Self.render(input)
            rawInputIsTitleFallback = false
        } else {
            rawInput = request.title
            rawInputIsTitleFallback = true
        }
        paths = Self.deduplicated(request.paths)
        let derived = AcpPermissionRules.ruleForRequest(kind: request.kind, resource: request.ruleMatchValue)
        ruleScope = AcpPermissionRuleScope(
            workspace: workspace,
            action: derived.action,
            resource: derived.resource
        )

        let allowOnce = request.options.first { $0.kind == "allow_once" }
        let denyOnce = request.options.first { $0.kind == "reject_once" }
        allowOnceOptionID = allowOnce?.id
        denyOnceOptionID = denyOnce?.id
        let selectedIDs = Set([allowOnce?.id, denyOnce?.id].compactMap { $0 })
        omittedOptions = request.options
            .filter { !selectedIDs.contains($0.id) }
    }

    private static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func render(_ value: JSONValue) -> String {
        if case let .string(text) = value {
            return text.isEmpty ? "\"\"" : text
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "Unavailable (invalid JSON input)"
        }
        return text
    }
}

extension AcpPermissionRequest {
    /// Stable value used by local wildcard rules. ACP raw input is untyped, but
    /// command requests from current adapters expose a top-level `command`;
    /// string raw inputs are already the resource. Everything else falls back
    /// to the human title, preserving compatibility without guessing deeply.
    var ruleMatchValue: String {
        AcpPermissionRules.requestMatchValue(kind: kind, title: title, rawInput: rawInput)
    }

    var allowOnceOption: Option? {
        options.first { $0.kind == "allow_once" }
    }

    var denyOnceOption: Option? {
        options.first { $0.kind == "reject_once" }
    }
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

    static func requestMatchValue(kind: String, title: String, rawInput: JSONValue?) -> String {
        guard kind == "execute", let rawInput else { return title }
        switch rawInput {
        case let .string(command) where !command.isEmpty:
            return command
        case let .object(fields):
            if let command = fields["command"]?.stringValue, !command.isEmpty {
                return command
            }
            return title
        default:
            return title
        }
    }

    /// Derive the rule an "Always allow" click should create. Commands get
    /// `firstWord *` (allow the tool, not one exact invocation); everything else
    /// allows the whole kind.
    static func ruleForRequest(kind: String, resource: String) -> (action: String, resource: String) {
        let act = action(for: kind)
        if act == "execute" {
            let first = resource.trimmingCharacters(in: .whitespacesAndNewlines)
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
        resource: String
    ) -> PermissionRule? {
        guard let workspace else { return nil }
        let act = action(for: kind)
        return rules.first {
            $0.workspace == workspace && $0.action == act && wildcardMatch(pattern: $0.resource, value: resource)
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
    static func requestIsSensitive(
        globs: [String],
        title: String,
        paths: [String],
        rawInput: JSONValue? = nil
    ) -> Bool {
        if paths.contains(where: { pathIsSensitive(globs: globs, pathish: $0) }) { return true }
        // Commands/resources may name targets in either the title or arbitrary
        // raw input. Scan every string leaf so a human-friendly title cannot
        // hide a protected path present in the actual request payload.
        let inputs = [title] + stringLeaves(in: rawInput)
        return inputs.contains { input in
            input.split(whereSeparator: { $0.isWhitespace }).contains { token in
                let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                return pathIsSensitive(globs: globs, pathish: trimmed)
            }
        }
    }

    private static func stringLeaves(in value: JSONValue?) -> [String] {
        guard let value else { return [] }
        switch value {
        case let .string(text):
            return [text]
        case let .array(values):
            return values.flatMap { stringLeaves(in: $0) }
        case let .object(values):
            return values.keys.sorted().flatMap { stringLeaves(in: values[$0]) }
        default:
            return []
        }
    }
}
