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
    /// The wrapped, field-by-field reading of the ask. It leads the card so the
    /// decision does not depend on scrolling a JSON blob sideways.
    let summary: AcpPermissionSummary

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
        summary = AcpPermissionSummary(request: request, workspace: workspace, paths: paths)
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

/// A wrapped, field-by-field reading of a permission ask, derived so the card
/// can answer "what exactly am I approving" without the user parsing JSON.
///
/// Two rules hold everywhere in here. Kaisola reads only well-known ACP keys and
/// never guesses a value it was not given: a field the adapter omitted says so
/// in words instead of quietly reading as empty-and-fine. And the escalation
/// flags are a short, named list, so an unflagged request is unreviewed rather
/// than proven safe — `unflaggedIsNotSafeNote` says that on the card.
struct AcpPermissionSummary: Equatable, Sendable {
    struct Field: Equatable, Sendable, Identifiable {
        enum Value: Equatable, Sendable {
            /// A value the adapter actually sent.
            case declared(String)
            /// The adapter sent nothing; the text names what stays unknown.
            case undeclared(String)
        }

        let label: String
        let value: Value
        /// Why this value expands privilege or leaves the workspace, when it does.
        let concern: String?

        var id: String { label }

        var text: String {
            switch value {
            case let .declared(text), let .undeclared(text): text
            }
        }

        var isDeclared: Bool {
            if case .declared = value { return true }
            return false
        }
    }

    struct PathEntry: Equatable, Sendable, Identifiable {
        let path: String
        /// True when the path resolves outside the reviewed workspace — and also
        /// when the workspace is unknown, because containment is then unproven.
        let leavesWorkspace: Bool

        var id: String { path }
    }

    /// Short verb phrase for the whole ask ("Run a command").
    let headline: String
    /// Fixed reading order: action, executable/tool, arguments, working
    /// directory, network target, requested scope.
    let fields: [Field]
    let paths: [PathEntry]

    static let unflaggedIsNotSafeNote =
        "Kaisola flags a short list of escalation patterns. A request with no flag is unreviewed, not proven safe."

    var concerns: [String] { fields.compactMap(\.concern) }
    var undeclaredLabels: [String] { fields.filter { !$0.isDeclared }.map(\.label) }
    var escapingPaths: [PathEntry] { paths.filter(\.leavesWorkspace) }

    /// One deterministic string in the same order the card lays the summary out,
    /// so VoiceOver reads the decision before the raw payload either way.
    var accessibilityReadout: String {
        var parts = [headline]
        parts += fields.map { field in
            var line = "\(field.label): \(field.text)"
            if let concern = field.concern { line += ". Warning: \(concern)" }
            return line
        }
        if paths.isEmpty {
            parts.append("Affected paths: none declared")
        } else {
            parts.append("Affected paths: \(paths.count), \(escapingPaths.count) outside the workspace")
            parts += paths.map { $0.leavesWorkspace ? "\($0.path), outside the workspace" : $0.path }
        }
        parts.append(Self.unflaggedIsNotSafeNote)
        return parts.joined(separator: ". ")
    }

    init(request: AcpPermissionRequest, workspace: String, paths: [String]) {
        let fields = request.rawInput?.objectValue ?? [:]
        let command = Self.command(in: fields)
        headline = Self.headline(for: request.kind)

        var rows: [Field] = []
        rows.append(Self.actionField(kind: request.kind, title: request.title))
        rows.append(Self.executableField(kind: request.kind, command: command, fields: fields))
        rows.append(Self.argumentsField(kind: request.kind, command: command, fields: fields))
        rows.append(Self.workingDirectoryField(fields: fields, workspace: workspace))
        rows.append(Self.networkField(command: command, fields: fields))
        rows.append(Self.scopeField(request: request))
        self.fields = rows
        self.paths = paths.map {
            PathEntry(path: $0, leavesWorkspace: Self.leavesWorkspace(path: $0, workspace: workspace))
        }
    }

    // MARK: - Fields

    private static func headline(for kind: String) -> String {
        switch kind {
        case "execute": "Run a command"
        case "edit": "Change files"
        case "read": "Read files"
        case "delete": "Delete files"
        case "move": "Move files"
        case "search": "Search files"
        case "fetch": "Fetch over the network"
        default: "Unclassified action"
        }
    }

    private static func actionField(kind: String, title: String) -> Field {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let described = trimmedTitle.isEmpty ? "The adapter sent no title." : trimmedTitle
        switch kind {
        case "execute", "edit", "read", "delete", "move", "search", "fetch":
            // The adapter's own title already sits in the card header, so this
            // row carries the machine-readable kind behind the headline instead.
            return Field(label: "Action", value: .declared("\(headline(for: kind)) (ACP kind “\(kind)”)"), concern: nil)
        default:
            let kindText = kind.isEmpty ? "no kind" : "kind “\(kind)”"
            return Field(
                label: "Action",
                value: .undeclared("The adapter sent \(kindText), so Kaisola cannot classify this. Its own words: \(described)"),
                concern: nil
            )
        }
    }

    private static func executableField(kind: String, command: Command?, fields: [String: JSONValue]) -> Field {
        if let executable = command?.executable {
            return Field(
                label: "Executable",
                value: .declared(executable),
                concern: elevationConcern(executable: executable)
            )
        }
        if let tool = text(lookup(fields, ["tool", "toolname", "name"])) {
            return Field(label: "Executable or tool", value: .declared(tool), concern: nil)
        }
        let noun = kind == "execute" ? "command" : "tool"
        return Field(
            label: kind == "execute" ? "Executable" : "Executable or tool",
            value: .undeclared("No \(noun) named in the payload; only the adapter's title describes this."),
            concern: nil
        )
    }

    private static func argumentsField(kind: String, command: Command?, fields: [String: JSONValue]) -> Field {
        let explicit = text(lookup(fields, ["args", "arguments"]))
        let arguments = explicit ?? command?.arguments
        guard let arguments, !arguments.isEmpty else {
            if command != nil {
                return Field(label: "Arguments", value: .declared("None"), concern: nil)
            }
            return Field(
                label: "Arguments",
                value: .undeclared("The adapter declared no arguments and no command to read them from."),
                concern: nil
            )
        }
        return Field(
            label: "Arguments",
            value: .declared(arguments),
            concern: escalationConcern(
                in: [command?.display, arguments].compactMap { $0 }.joined(separator: " "),
                executable: command?.executable
            )
        )
    }

    private static func workingDirectoryField(fields: [String: JSONValue], workspace: String) -> Field {
        guard let directory = text(lookup(fields, ["cwd", "workingdirectory", "workdir", "dir", "directory"])) else {
            let location = workspace.isEmpty ? "the workspace" : workspace
            return Field(
                label: "Working directory",
                value: .undeclared("Not declared. Kaisola cannot confirm this runs inside \(location)."),
                concern: nil
            )
        }
        let escapes = leavesWorkspace(path: directory, workspace: workspace)
        return Field(
            label: "Working directory",
            value: .declared(directory),
            concern: escapes ? "Runs outside the reviewed workspace." : nil
        )
    }

    private static func networkField(command: Command?, fields: [String: JSONValue]) -> Field {
        let declared = text(lookup(fields, ["url", "uri", "host", "hostname", "endpoint", "origin", "address", "remote", "server"]))
        guard let target = declared ?? command.flatMap({ firstURL(in: $0.display) }) else {
            return Field(
                label: "Network target",
                value: .undeclared("None declared. A command can still open a connection Kaisola never sees."),
                concern: nil
            )
        }
        let host = host(in: target)
        if isLocal(host) {
            return Field(label: "Network target", value: .declared("\(target) (this machine)"), concern: nil)
        }
        return Field(
            label: "Network target",
            value: .declared(target),
            concern: "Reaches \(host), a host outside this machine."
        )
    }

    private static func scopeField(request: AcpPermissionRequest) -> Field {
        guard request.allowOnceOption != nil else {
            return Field(
                label: "Requested scope",
                value: .undeclared("The adapter offered no one-time allow, so Kaisola cannot bound an approval here."),
                concern: nil
            )
        }
        return Field(
            label: "Requested scope",
            value: .declared("This answer applies to this request only. Create Rule additionally saves the scope shown below."),
            concern: nil
        )
    }

    // MARK: - Command parsing

    /// The command as the adapter shaped it: a string, or an argv array.
    struct Command: Equatable, Sendable {
        let executable: String
        let arguments: String
        let display: String
    }

    private static func command(in fields: [String: JSONValue]) -> Command? {
        guard let value = lookup(fields, ["command", "cmd", "commandline", "script", "shellcommand", "argv"]) else {
            return nil
        }
        if case let .array(items) = value {
            let words = items.compactMap { text($0) }
            guard let executable = words.first else { return nil }
            let arguments = words.dropFirst().joined(separator: " ")
            return Command(executable: executable, arguments: arguments, display: words.joined(separator: " "))
        }
        guard let line = text(value) else { return nil }
        // First whitespace run splits the executable from everything else. No
        // shell-quoting parse: a wrong split would misreport what runs.
        guard let split = line.firstIndex(where: { $0.isWhitespace }) else {
            return Command(executable: line, arguments: "", display: line)
        }
        return Command(
            executable: String(line[line.startIndex..<split]),
            arguments: String(line[split...]).trimmingCharacters(in: .whitespacesAndNewlines),
            display: line
        )
    }

    // MARK: - Escalation flags

    private static let elevationNames = ["sudo", "su", "doas", "runas"]

    private static func elevationConcern(executable: String) -> String? {
        let name = (executable as NSString).lastPathComponent.lowercased()
        guard elevationNames.contains(name) else { return nil }
        return "Runs as another user with elevated privileges."
    }

    /// A named, deliberately short list. Everything it does not name stays
    /// unflagged, which `unflaggedIsNotSafeNote` tells the reader outright.
    /// `executable` only suppresses a duplicate elevation line already shown on
    /// the Executable row.
    private static func escalationConcern(in text: String, executable: String?) -> String? {
        let lowered = text.lowercased()
        let elevatedExecutable = executable.map { elevationConcern(executable: $0) != nil } ?? false
        var found: [String] = []
        if !elevatedExecutable, lowered.contains("sudo ") || lowered.contains("doas ") {
            found.append("Runs as another user with elevated privileges.")
        }
        if lowered.contains("rm -rf") || lowered.contains("rm -fr") {
            found.append("Deletes recursively without prompting.")
        }
        if lowered.contains("chmod") && (lowered.contains("777") || lowered.contains("+s")) {
            found.append("Widens file permissions.")
        }
        if lowered.contains("chown") {
            found.append("Changes file ownership.")
        }
        if (lowered.contains("curl") || lowered.contains("wget"))
            && (lowered.contains("| sh") || lowered.contains("|sh") || lowered.contains("| bash") || lowered.contains("|bash")) {
            found.append("Pipes downloaded content into a shell.")
        }
        if lowered.contains("launchctl") {
            found.append("Changes launch agents or daemons.")
        }
        if systemLocations.contains(where: { lowered.contains($0) }) {
            found.append("Touches a protected system location.")
        }
        return found.isEmpty ? nil : found.joined(separator: " ")
    }

    private static let systemLocations = ["/etc/", "/usr/bin", "/usr/local/bin", "/system/", "/library/launchagents", "/library/launchdaemons"]

    // MARK: - Workspace containment

    /// Does this path resolve outside `workspace`? An unknown workspace answers
    /// yes: unproven containment is not containment.
    static func leavesWorkspace(path: String, workspace: String) -> Bool {
        let candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        let root = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty, root.hasPrefix("/") else { return true }
        // `~` is the home directory, which is never the workspace itself.
        if candidate.hasPrefix("~") { return true }
        let normalizedRoot = normalize(root)
        let absolute = candidate.hasPrefix("/") ? candidate : normalizedRoot + "/" + candidate
        let normalized = normalize(absolute)
        return normalized != normalizedRoot && !normalized.hasPrefix(normalizedRoot + "/")
    }

    /// Collapse `.` and `..` textually. Deterministic, and it never touches the
    /// filesystem, so a review of another machine's path still reads correctly.
    private static func normalize(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(component))
            }
        }
        return "/" + components.joined(separator: "/")
    }

    // MARK: - Untyped-payload helpers

    /// Key lookup that tolerates adapter spelling (`workingDirectory`,
    /// `working_directory`, `WorkDir`) without inventing meaning for unknown keys.
    private static func lookup(_ fields: [String: JSONValue], _ names: [String]) -> JSONValue? {
        guard !fields.isEmpty else { return nil }
        var normalized: [String: JSONValue] = [:]
        for key in fields.keys.sorted() {
            let folded = key.lowercased().filter { $0.isLetter || $0.isNumber }
            if normalized[folded] == nil { normalized[folded] = fields[key] }
        }
        for name in names {
            if let value = normalized[name], value != .null { return value }
        }
        return nil
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(text):
            return text.isEmpty ? nil : text
        case let .integer(number):
            return String(number)
        case let .number(number):
            return String(number)
        case let .bool(flag):
            return flag ? "true" : "false"
        case let .array(items):
            let words = items.compactMap { text($0) }
            return words.isEmpty ? nil : words.joined(separator: " ")
        case .object, .null:
            return nil
        }
    }

    private static func firstURL(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`,;()")) }
            .first { $0.contains("://") }
    }

    private static func host(in target: String) -> String {
        var rest = target
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[rest.startIndex..<slash]) }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        return rest.isEmpty ? target : rest
    }

    private static func isLocal(_ host: String) -> Bool {
        let name = host.split(separator: ":").first.map(String.init)?.lowercased() ?? host.lowercased()
        return name == "localhost" || name == "127.0.0.1" || name == "::1" || name == "0.0.0.0" || name.hasSuffix(".local")
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
