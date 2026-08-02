import Foundation

/// The decisions behind the ACP composer card, kept as plain value transforms.
///
/// The composer looks like Claude Code's and Codex's — one rounded surface, a
/// row of chips under the text, a filled send disc — and every one of those
/// chips answers a question that has a wrong answer: *may this agent write to
/// my disk right now?*, *which model am I about to spend?*. So the mapping from
/// what an adapter actually declared to the word shown on a chip lives here,
/// under test, rather than inside a `ViewBuilder`.

// MARK: - Send enablement

/// What the primary composer button will do when pressed.
enum AcpComposerAction: Equatable, Sendable {
    case send
    case queue
}

enum AcpComposerSendPolicy {
    static func action(isRunning: Bool) -> AcpComposerAction {
        isRunning ? .queue : .send
    }

    /// Enabled when there is something to deliver. While a turn runs the press
    /// becomes a queued follow-up, and a queued follow-up cannot carry
    /// attachments (see `AcpConversation.send`), so text is required then;
    /// idle, either text or a staged attachment is enough.
    static func isEnabled(
        draft: String,
        isConnected: Bool,
        isRunning: Bool,
        hasAttachments: Bool
    ) -> Bool {
        guard isConnected else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isRunning ? hasText : (hasText || hasAttachments)
    }
}

// MARK: - Permission posture

/// How much of the machine the agent may touch without stopping to ask, said
/// in the composer's own words rather than the adapter's identifiers.
struct AcpPermissionPosture: Equatable, Sendable, Identifiable {
    /// Ordered from most to least restrained. Only the top rung is treated as
    /// permissive, and only it earns a warning colour.
    enum Level: Int, Comparable, Sendable {
        case readOnly
        case ask
        case acceptEdits
        case fullAccess

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The ACP mode id this posture stands for, so selecting it round-trips.
    let id: String
    let label: String
    let symbol: String
    let level: Level

    var isPermissive: Bool { level == .fullAccess }
}

enum AcpPermissionPostureMap {
    /// Map one ACP session mode onto the composer's vocabulary.
    ///
    /// Matching runs over the id and the name together, folded to lowercase
    /// letters and digits, so `bypassPermissions`, `bypass-permissions`, and
    /// "Bypass Permissions" are one case. An unrecognized mode is never
    /// relabelled: it keeps the adapter's own wording and the cautious rung,
    /// because inventing "Full access" for a mode we cannot read would be the
    /// one mistake this table exists to prevent.
    static func posture(id: String, name: String) -> AcpPermissionPosture {
        let haystack = normalized(id) + " " + normalized(name)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackLabel = trimmedName.isEmpty ? id : trimmedName

        if contains(haystack, ["bypass", "yolo", "danger", "fullaccess", "acceptall", "autoapprove"]) {
            return AcpPermissionPosture(id: id, label: "Full access", symbol: "lock.open.fill", level: .fullAccess)
        }
        if contains(haystack, ["plan", "readonly", "reviewonly"]) {
            return AcpPermissionPosture(id: id, label: "Read only", symbol: "eye", level: .readOnly)
        }
        if contains(haystack, ["acceptedit", "autoedit", "editsonly", "autoaccept"]) {
            return AcpPermissionPosture(id: id, label: "Accept edits", symbol: "lock.open", level: .acceptEdits)
        }
        if contains(haystack, ["default", "ask", "prompt", "manual", "normal", "confirm"]) {
            return AcpPermissionPosture(id: id, label: "Ask each time", symbol: "lock.fill", level: .ask)
        }
        return AcpPermissionPosture(id: id, label: fallbackLabel, symbol: "lock.fill", level: .ask)
    }

    static func postures(_ modes: [AcpSessionInfo.Mode]) -> [AcpPermissionPosture] {
        modes.map { posture(id: $0.id, name: $0.name) }
    }

    /// The posture in force. Adapters may report modes before naming a current
    /// one; the first declared mode is the selected one until they do.
    static func current(modes: [AcpSessionInfo.Mode], currentID: String?) -> AcpPermissionPosture? {
        let all = postures(modes)
        guard let currentID else { return all.first }
        return all.first { $0.id == currentID } ?? all.first
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Model picker

/// One row of the model picker.
struct AcpModelChoice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// The raw model identifier, shown under the name only when it says
    /// something the name does not (`claude-sonnet-4-5-20250929` under
    /// "Sonnet 4.5"; nothing under "GPT-5.6-Sol").
    let subtitle: String?
    let isFavorite: Bool
    let isCurrent: Bool
    /// 1…9, the ⌘-digit that selects this row. Assigned over the *visible*
    /// order so the digits stay dense as the query narrows the list.
    let shortcut: Int?
}

enum AcpModelPicker {
    static let maximumShortcuts = 9

    /// Filter, order, and number the adapter's declared models.
    ///
    /// Ordering is deliberately stable rather than relevance-ranked: a ⌘-digit
    /// that moves between keystrokes is worse than a perfect sort. Favourites
    /// float to the top keeping their declared order among themselves, and
    /// everything else follows in the order the adapter sent it.
    static func choices(
        models: [AcpSessionInfo.Model],
        currentID: String?,
        favorites: Set<String>,
        query: String,
        favoritesOnly: Bool = false
    ) -> [AcpModelChoice] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = models.filter { model in
            if favoritesOnly, !favorites.contains(model.id) { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return FuzzyMatch.matches(query: trimmedQuery, candidate: model.name)
                || FuzzyMatch.matches(query: trimmedQuery, candidate: model.id)
        }
        let ordered = matching.filter { favorites.contains($0.id) }
            + matching.filter { !favorites.contains($0.id) }

        return ordered.enumerated().map { index, model in
            AcpModelChoice(
                id: model.id,
                name: model.name,
                subtitle: subtitle(id: model.id, name: model.name),
                isFavorite: favorites.contains(model.id),
                isCurrent: model.id == currentID,
                shortcut: index < maximumShortcuts ? index + 1 : nil
            )
        }
    }

    static func toggledFavorites(_ favorites: Set<String>, modelID: String) -> Set<String> {
        var updated = favorites
        if updated.contains(modelID) {
            updated.remove(modelID)
        } else {
            updated.insert(modelID)
        }
        return updated
    }

    private static func subtitle(id: String, name: String) -> String? {
        let foldedID = id.lowercased().filter { $0.isLetter || $0.isNumber }
        let foldedName = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return foldedID == foldedName ? nil : id
    }
}

/// Per-agent favourite models, in the native app-support directory alongside
/// the permission rules. Atomic writes, corrupt file → empty, capped so a
/// pathological adapter cannot grow the file without bound.
struct AcpModelFavoritesStore: Sendable {
    private struct Payload: Codable {
        var byAgent: [String: [String]]
    }

    let fileURL: URL
    private let capPerAgent = 64

    init(
        fileURL: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("acp-model-favorites-v1.json", isDirectory: false)
    ) {
        self.fileURL = fileURL
    }

    func favorites(agentKey: String) -> Set<String> {
        Set(read()?.byAgent[agentKey] ?? [])
    }

    @discardableResult
    func toggle(_ modelID: String, agentKey: String) -> Set<String> {
        var payload = read() ?? Payload(byAgent: [:])
        var updated = AcpModelPicker.toggledFavorites(Set(payload.byAgent[agentKey] ?? []), modelID: modelID)
        if updated.count > capPerAgent {
            updated = Set(updated.sorted().prefix(capPerAgent))
        }
        payload.byAgent[agentKey] = updated.sorted()
        write(payload)
        return updated
    }

    private func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let temporary = directory
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}

// MARK: - Effort · context chip

enum AcpComposerMetrics {
    /// The adapter option worth a chip. Reasoning effort is the one people
    /// change mid-task; anything else is a preset they set once, so it stays in
    /// the chip's menu rather than on its face.
    static func primaryOption(_ options: [AcpConfigOption]) -> AcpConfigOption? {
        let effortWords = ["effort", "reasoning", "thinking", "think"]
        return options.first { option in
            let haystack = (option.id + " " + option.name).lowercased()
            return effortWords.contains { haystack.contains($0) }
        } ?? options.first
    }

    /// The chosen value in the adapter's own display wording, falling back to
    /// the raw value when the option declares no matching choice.
    static func optionLabel(_ option: AcpConfigOption?) -> String? {
        guard let option, let value = option.currentValue, !value.isEmpty else { return nil }
        return option.choices.first { $0.value == value }?.name ?? value
    }

    /// The context window, not the amount consumed — the chip states capacity
    /// the way the references do ("1M"); live consumption stays in the header.
    static func contextLabel(_ usage: AcpUsage?) -> String? {
        guard let usage, usage.max > 0 else { return nil }
        return compactTokens(usage.max)
    }

    static func chipLabel(option: AcpConfigOption?, usage: AcpUsage?) -> String? {
        let parts = [optionLabel(option), contextLabel(usage)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func compactTokens(_ value: Int) -> String {
        func trim(_ scaled: Double, _ suffix: String) -> String {
            let rounded = (scaled * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? "\(Int(rounded))\(suffix)"
                : String(format: "%.1f%@", rounded, suffix)
        }
        if value >= 1_000_000 { return trim(Double(value) / 1_000_000, "M") }
        if value >= 1_000 { return trim(Double(value) / 1_000, "k") }
        return "\(value)"
    }
}

// MARK: - Settings menu

/// One top-level row of the composer's settings menu: `Label … value ›`.
///
/// The menu is a *disclosure* list, not a list of controls: every row states
/// the setting's name, the value in force, and that there is more behind it.
/// Nothing is chosen at this level, so nothing here needs a widget.
struct AcpComposerMenuRow: Equatable, Sendable, Identifiable {
    enum Target: Equatable, Sendable {
        case agent
        case model
        /// An adapter-declared configuration option, by its ACP id.
        case option(String)
    }

    let target: Target
    let label: String
    let value: String

    var id: String {
        switch target {
        case .agent: return "agent"
        case .model: return "model"
        case .option(let id): return "option.\(id)"
        }
    }
}

/// One row of a submenu panel: a name, an optional grey caption under it, and
/// a checkmark when it is the value in force.
struct AcpComposerMenuOption: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// The small grey line the reference puts under a row that needs a
    /// sentence — the model's raw identifier, or what choosing an agent will
    /// actually do. `nil` for the overwhelming majority of rows.
    let caption: String?
    let isSelected: Bool
    /// A row that cannot be chosen is still listed and still spoken. An agent
    /// with no ACP adapter is a fact about the app; omitting it would read as
    /// a bug, and greying it with the reason reads as the truth.
    var isEnabled = true
}

/// A submenu panel: a grey section header over its options.
struct AcpComposerSubmenu: Equatable, Sendable {
    let title: String
    let options: [AcpComposerMenuOption]

    /// Search is a cost, not a feature. It appears only once a panel is long
    /// enough that reading it top to bottom stops working.
    var showsSearch: Bool { options.count > AcpComposerMenu.searchThreshold }
}

enum AcpComposerMenu {
    static let searchThreshold = 8

    /// Leading words that qualify a setting rather than name it. The reference
    /// menu's rows are one word wide — "Model", "Effort", "Speed" — because the
    /// panel is already the context; "Reasoning effort" spends a line saying so
    /// again.
    private static let qualifiers: Set<String> = ["reasoning", "agent", "model", "session"]

    static func rows(
        agentName: String,
        models: [AcpSessionInfo.Model],
        currentModelID: String?,
        configOptions: [AcpConfigOption]
    ) -> [AcpComposerMenuRow] {
        var rows = [AcpComposerMenuRow(target: .agent, label: "Agent", value: agentName)]
        if let model = currentModel(models: models, currentModelID: currentModelID) {
            rows.append(AcpComposerMenuRow(target: .model, label: "Model", value: model.name))
        }
        for option in configOptions where !option.choices.isEmpty {
            let value = AcpComposerMetrics.optionLabel(option) ?? option.choices[0].name
            rows.append(AcpComposerMenuRow(
                target: .option(option.id),
                label: shortLabel(name: option.name, id: option.id),
                value: value
            ))
        }
        return rows
    }

    /// Adapters may report models before naming a current one; the first
    /// declared model is the one in force until they do, exactly as with modes.
    static func currentModel(
        models: [AcpSessionInfo.Model],
        currentModelID: String?
    ) -> AcpSessionInfo.Model? {
        guard let currentModelID else { return models.first }
        return models.first { $0.id == currentModelID } ?? models.first
    }

    static func shortLabel(name: String, id: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return capitalizedFirst(id) }
        var words = trimmed.split(separator: " ").map(String.init)
        if words.count > 1, qualifiers.contains(words[0].lowercased()) {
            words.removeFirst()
        }
        return capitalizedFirst(words.joined(separator: " "))
    }

    // MARK: Submenus

    static func modelSubmenu(
        models: [AcpSessionInfo.Model],
        currentModelID: String?,
        favorites: Set<String>,
        query: String
    ) -> AcpComposerSubmenu {
        let selectedID = currentModel(models: models, currentModelID: currentModelID)?.id
        let options = AcpModelPicker.choices(
            models: models,
            currentID: selectedID,
            favorites: favorites,
            query: query
        ).map { choice in
            AcpComposerMenuOption(
                id: choice.id,
                name: choice.name,
                caption: choice.subtitle,
                isSelected: choice.isCurrent
            )
        }
        return AcpComposerSubmenu(title: "Model", options: options)
    }

    static func optionSubmenu(_ option: AcpConfigOption) -> AcpComposerSubmenu {
        let selected = option.currentValue ?? option.choices.first?.value
        return AcpComposerSubmenu(
            title: shortLabel(name: option.name, id: option.id),
            options: option.choices.map { choice in
                AcpComposerMenuOption(
                    id: choice.value,
                    name: choice.name,
                    caption: nil,
                    isSelected: choice.value == selected
                )
            }
        )
    }

    /// The agent list, in registry order, with the one driving this chat
    /// checked.
    ///
    /// Every other row carries a caption, because the single thing this menu
    /// must never imply is that the conversation moves. An ACP session is bound
    /// to one adapter process for its whole life — see `AcpAgentSwitch`.
    static func agentSubmenu(
        agents: [AgentProfile],
        currentAgentID: String,
        isChatCapable: (String) -> Bool
    ) -> AcpComposerSubmenu {
        let options = agents.map { agent -> AcpComposerMenuOption in
            let isCurrent = agent.id == currentAgentID
            let capable = isCurrent || isChatCapable(agent.id)
            return AcpComposerMenuOption(
                id: agent.id,
                name: agent.name,
                caption: isCurrent
                    ? nil
                    : (capable ? "Starts a new chat" : "Terminal only — no chat adapter"),
                isSelected: isCurrent,
                isEnabled: capable
            )
        }
        return AcpComposerSubmenu(title: "Agent", options: options)
    }

    // MARK: Advanced disclosure

    /// What the pill cannot hold and no row can change: statements, not
    /// controls. An empty result hides the disclosure entirely rather than
    /// opening onto a blank panel.
    static func advancedLines(
        usage: AcpUsage?,
        currentModelID: String?,
        models: [AcpSessionInfo.Model]
    ) -> [String] {
        var lines: [String] = []
        if let usage, usage.max > 0 {
            lines.append(
                "Context used: \(AcpComposerMetrics.compactTokens(usage.used))"
                    + " of \(AcpComposerMetrics.compactTokens(usage.max))"
            )
        }
        if let model = currentModel(models: models, currentModelID: currentModelID),
           folded(model.id) != folded(model.name) {
            lines.append("Model id: \(model.id)")
        }
        return lines
    }

    // MARK: Chip

    /// The pill's face: `<primary> <secondary in grey> ⌄`, matching the
    /// reference's `5.6 Sol Light`. The model leads because it is what the
    /// message will be spent on; the effort follows because it is the setting
    /// most likely to have been changed since.
    static func chipValues(
        agentName: String,
        modelName: String?,
        option: AcpConfigOption?
    ) -> (primary: String, secondary: String?) {
        let model = (modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (model.isEmpty ? agentName : model, AcpComposerMetrics.optionLabel(option))
    }

    // MARK: Keyboard

    /// Move a highlight by one row, wrapping. `nil` enters the list from the
    /// end the arrow came from.
    static func move(from index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return delta > 0 ? 0 : count - 1 }
        return ((index + delta) % count + count) % count
    }

    /// The same walk, refusing to park the highlight on a row Return cannot
    /// activate.
    static func move(from index: Int?, by delta: Int, enabled: [Bool]) -> Int? {
        guard enabled.contains(true) else { return nil }
        var candidate = index
        for _ in 0..<enabled.count {
            guard let next = move(from: candidate, by: delta, count: enabled.count) else { return nil }
            if enabled[next] { return next }
            candidate = next
        }
        return nil
    }

    private static func capitalizedFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private static func folded(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// What choosing an agent in the composer can actually do.
///
/// An ACP conversation is one adapter process holding one session: the
/// protocol has no move, and `AcpConversation` fixes its command, arguments,
/// and cwd at construction. So a "switch" is a new chat beside the old one —
/// never a silent handoff, and never a discarded transcript.
enum AcpAgentSwitchDecision: Equatable, Sendable {
    case alreadyCurrent
    /// The agent has no ACP adapter, so it cannot drive a chat at all.
    case unavailable
    case startNewChat(String)
}

enum AcpAgentSwitch {
    static func decision(
        agentID: String,
        currentAgentID: String,
        isChatCapable: (String) -> Bool
    ) -> AcpAgentSwitchDecision {
        if agentID == currentAgentID { return .alreadyCurrent }
        guard isChatCapable(agentID) else { return .unavailable }
        return .startNewChat(agentID)
    }
}

// MARK: - Agent identity

enum AcpAgentIdentity {
    /// Chats are titled `"<Agent> · <folder>"` by `AppModel`, so the leading
    /// segment is the agent's display name. A renamed chat keeps whatever the
    /// user typed, which is why `identity` does not stop here.
    static func agentName(fromChatTitle title: String) -> String {
        let lead = title.components(separatedBy: " · ").first ?? title
        let trimmed = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    /// The brand mark for a chat. The leading segment decides it when it names
    /// a first-class agent; otherwise the whole title is scanned before falling
    /// back to the initial, so "Rewrite the parser with Claude" still wears the
    /// coral starburst.
    static func identity(fromChatTitle title: String) -> QuietIdentity {
        let lead = QuietIdentity.identity(agentName: agentName(fromChatTitle: title), processName: nil)
        switch lead {
        case .claude, .openai, .mesh:
            return lead
        default:
            return QuietIdentity.identity(agentName: title, processName: nil)
        }
    }

    /// The model chip's text. The reference reads "Claude Fable 5" — brand then
    /// model — but an adapter that already prefixes its brand must not be made
    /// to say it twice.
    static func chipLabel(agentName: String, modelName: String?) -> String {
        let model = (modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return agentName }
        guard !agentName.isEmpty else { return model }
        return model.range(of: agentName, options: .caseInsensitive) == nil
            ? "\(agentName) \(model)"
            : model
    }
}

// MARK: - Empty state

enum AcpEmptyState {
    /// The heading, split so the project name can carry its dotted underline
    /// while the sentence around it stays plain.
    struct Heading: Equatable, Sendable {
        let lead: String
        let project: String
        let tail: String

        /// One string for VoiceOver, which must not hear three fragments.
        var spoken: String { lead + project + tail }
    }

    static func projectName(for url: URL?) -> String {
        guard let url else { return "" }
        return url.lastPathComponent
    }

    static func heading(projectName: String) -> Heading {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Heading(lead: "What should we build?", project: "", tail: "")
        }
        return Heading(lead: "What should we build in ", project: trimmed, tail: "?")
    }
}
