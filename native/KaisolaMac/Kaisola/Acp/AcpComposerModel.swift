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
}

enum AcpModelPicker {
    /// Filter and order the adapter's declared models.
    ///
    /// Ordering is deliberately stable rather than relevance-ranked: a row that
    /// moves between keystrokes is worse than a perfect sort. Favourites float
    /// to the top keeping their declared order among themselves, and everything
    /// else follows in the order the adapter sent it.
    static func choices(
        models: [AcpSessionInfo.Model],
        currentID: String?,
        favorites: Set<String>,
        query: String
    ) -> [AcpModelChoice] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = models.filter { model in
            guard !trimmedQuery.isEmpty else { return true }
            return FuzzyMatch.matches(query: trimmedQuery, candidate: model.name)
                || FuzzyMatch.matches(query: trimmedQuery, candidate: model.id)
        }
        let ordered = matching.filter { favorites.contains($0.id) }
            + matching.filter { !favorites.contains($0.id) }

        return ordered.map { model in
            AcpModelChoice(
                id: model.id,
                name: model.name,
                subtitle: subtitle(id: model.id, name: model.name),
                isFavorite: favorites.contains(model.id),
                isCurrent: model.id == currentID
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
    /// The reasoning-effort option, by the adapter's own classification when it
    /// declares one and by its wording when it does not.
    ///
    /// ACP's `category` is the only non-guessing answer: two adapters name this
    /// setting differently but both file it under `thought_level`. The word
    /// search stays as the fallback for adapters that omit the field.
    static func effortOption(_ options: [AcpConfigOption]) -> AcpConfigOption? {
        if let declared = options.first(where: { $0.category?.lowercased() == "thought_level" }) {
            return declared
        }
        let effortWords = ["effort", "reasoning", "thinking", "think"]
        return options.first { option in
            let haystack = (option.id + " " + option.name).lowercased()
            return effortWords.contains { haystack.contains($0) }
        }
    }

    /// The adapter option worth a chip. Reasoning effort is the one people
    /// change mid-task; anything else is a preset they set once, so it stays in
    /// the chip's menu rather than on its face.
    static func primaryOption(_ options: [AcpConfigOption]) -> AcpConfigOption? {
        effortOption(options) ?? options.first
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

// MARK: - Adapter surface

/// One adapter's declared settings, reduced so each setting is stated once.
///
/// Codex declares reasoning effort three times over: as a `reasoning_effort`
/// config option, as a suffix on every model id (`gpt-5.6-sol[max]`), and again
/// inside every model's display name ("GPT-5.6-Sol (max)"). It declares the
/// model twice — the 33-entry model × effort cross product in `models`, and the
/// seven base models in a `model` config option — and the permission mode twice,
/// once in `modes` and once in a `mode` config option the permission chip is
/// already rendering. Rendered raw, the settings menu reads
///
///     Agent  Codex · Model  GPT-5.6-Sol (max) · Mode  Agent
///     Collaboration mode  Default · Model  GPT-5.6-Sol · Effort  Max
///
/// and the pill reads "GPT-5.6-Sol (max)  Max".
///
/// The repetition is only half of it. The copies also drift: setting
/// `reasoning_effort` to Low leaves `models.currentModelId` at
/// `gpt-5.6-sol[max]` — the adapter sends no model update — so two rows of the
/// same menu end up disagreeing about the effort in force. There is no ordering
/// of rows that makes that read as anything but a bug.
///
/// So the payload is reconciled exactly once, here, into the one model list and
/// the one option list the menu renders. Measured against
/// `@agentclientprotocol/codex-acp` 1.1.8 and `claude-agent-acp`, whose payload
/// has none of this and passes through untouched.
struct AcpComposerSurface: Equatable, Sendable {
    /// How choosing a model row has to reach the adapter. Which one applies is
    /// decided by where the surviving model list came from, so a caller can
    /// never pair an id with the wrong request.
    enum ModelTarget: Equatable, Sendable {
        /// ACP `session/set_model`, with the row's id as `modelId`.
        case setModel
        /// ACP `session/set_config_option` on this option id, with the row's id
        /// as the value.
        case configOption(String)
    }

    var models: [AcpSessionInfo.Model] = []
    var currentModelID: String?
    var modelTarget: ModelTarget = .setModel
    /// The options that still have something of their own to say.
    var options: [AcpConfigOption] = []

    /// Reduce one `session/new` payload to the settings the menu shows.
    static func reconciled(
        models: [AcpSessionInfo.Model],
        currentModelID: String?,
        modes: [AcpSessionInfo.Mode],
        configOptions: [AcpConfigOption]
    ) -> AcpComposerSurface {
        // An option with nothing to choose is not a setting; it is a label the
        // menu would open onto a blank panel.
        var options = configOptions.filter { !$0.choices.isEmpty }

        // The permission chip already renders `modes`. An option offering those
        // very ids is that chip written out a second time.
        let modeIDs = Set(modes.map { folded($0.id) })
        if !modeIDs.isEmpty {
            options.removeAll { option in
                classified(option, as: "mode", fallbackWords: ["mode", "approval"])
                    && option.choices.allSatisfy { modeIDs.contains(folded($0.value)) }
            }
        }

        // A base-model option supersedes an `availableModels` list it covers:
        // the option names each model once, the list names it once per effort.
        // Choosing through the option also leaves the effort alone, which is
        // the behaviour the separate Effort row promises.
        if let modelOption = options.first(where: {
            classified($0, as: "model", fallbackWords: ["model"]) && covers($0, models: models)
        }) {
            options.removeAll { $0.id == modelOption.id }
            return AcpComposerSurface(
                models: modelOption.choices.map { AcpSessionInfo.Model(id: $0.value, name: $0.name) },
                currentModelID: modelOption.currentValue ?? modelOption.choices.first?.value,
                modelTarget: .configOption(modelOption.id),
                options: options
            )
        }

        let collapsed = collapsingEffortVariants(
            models: models,
            currentModelID: currentModelID,
            effort: AcpComposerMetrics.effortOption(options)
        )
        return AcpComposerSurface(
            models: collapsed.models,
            currentModelID: collapsed.currentModelID,
            modelTarget: .setModel,
            options: options
        )
    }

    // MARK: Effort variants

    /// Fold `<model>` × `<effort>` rows back into one row per model.
    ///
    /// Only when a separate effort option exists. When effort lives *only* in
    /// the model names there is no second row for them to contradict, so the
    /// names keep it and the model row carries the setting alone.
    ///
    /// The row that survives each group is the variant at the effort currently
    /// in force, so the id handed to `session/set_model` preserves the effort
    /// the Effort row is showing, and `Advanced` quotes an id that is true.
    private static func collapsingEffortVariants(
        models: [AcpSessionInfo.Model],
        currentModelID: String?,
        effort: AcpConfigOption?
    ) -> (models: [AcpSessionInfo.Model], currentModelID: String?) {
        guard let effort, !effort.choices.isEmpty else { return (models, currentModelID) }
        // Longest first, so `[xhigh]` is never read as a stray `high`.
        let values = effort.choices.map(\.value).sorted { $0.count > $1.count }
        let inForce = folded(effort.currentValue ?? effort.choices[0].value)

        var order: [String] = []
        var variants: [String: [(model: AcpSessionInfo.Model, effort: String?)]] = [:]
        var names: [String: String] = [:]

        for model in models {
            let fromID = effortSuffix(model.id, values: values)
            let fromName = effortSuffix(model.name, values: values)
            let key = folded(fromID?.base ?? model.id)
            if variants[key] == nil {
                order.append(key)
                names[key] = fromName?.base ?? model.name
            }
            variants[key, default: []].append((model, fromID?.effort ?? fromName?.effort))
        }

        func survivor(_ group: [(model: AcpSessionInfo.Model, effort: String?)]) -> AcpSessionInfo.Model {
            if let atEffort = group.first(where: { $0.effort.map { folded($0) == inForce } ?? false }) {
                return atEffort.model
            }
            // No variant at this effort (Codex's Luna stops short of `ultra`).
            // The selected one, else the adapter's first, keeps the row
            // truthful; the adapter reports whatever effort it lands on and the
            // Effort row follows it.
            return group.first { $0.model.id == currentModelID }?.model ?? group[0].model
        }

        let collapsed = order.map { key in
            AcpSessionInfo.Model(id: survivor(variants[key] ?? []).id, name: names[key] ?? key)
        }
        let currentKey = currentModelID.flatMap { id in
            order.first { key in (variants[key] ?? []).contains { $0.model.id == id } }
        }
        return (collapsed, currentKey.flatMap { key in survivor(variants[key] ?? []).id })
    }

    /// Split a trailing effort qualifier off an id or a display name:
    /// `gpt-5.6-sol[max]` → (`gpt-5.6-sol`, `max`), `GPT-5.6-Sol (max)` →
    /// (`GPT-5.6-Sol`, `max`), `sonnet-high` → (`sonnet`, `high`).
    ///
    /// The values come from the effort option's own choices rather than a word
    /// list of ours, which is what stops this from amputating a model whose
    /// name merely rhymes with an effort level.
    static func effortSuffix(_ text: String, values: [String]) -> (base: String, effort: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        for value in values where !value.isEmpty {
            for wrapper in ["[\(value)]", "(\(value))"] where lowered.hasSuffix(wrapper.lowercased()) {
                let base = String(trimmed.dropLast(wrapper.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
                if !base.isEmpty { return (base, value) }
            }
            for separator in ["-", "_", " "] where lowered.hasSuffix((separator + value).lowercased()) {
                let base = String(trimmed.dropLast(value.count + 1))
                if !base.isEmpty { return (base, value) }
            }
        }
        return nil
    }

    // MARK: Classification

    /// Does this option describe the given ACP category?
    ///
    /// A declared `category` decides alone — that is the whole point of the
    /// field, and it is why Codex's `collaboration_mode` is not mistaken for
    /// its `mode` despite the word. Only an adapter that declares nothing falls
    /// back to reading the id and name.
    private static func classified(
        _ option: AcpConfigOption,
        as category: String,
        fallbackWords: [String]
    ) -> Bool {
        if let declared = option.category?.lowercased(), !declared.isEmpty {
            return declared == category
        }
        let haystack = folded(option.id) + " " + folded(option.name)
        return fallbackWords.contains { haystack.contains($0) }
    }

    /// Is every declared model a variant of one of this option's choices? Only
    /// then is the option the same list said more briefly, rather than a
    /// different list that happens to be about models.
    private static func covers(_ option: AcpConfigOption, models: [AcpSessionInfo.Model]) -> Bool {
        guard !models.isEmpty else { return true }
        let bases = option.choices.map { folded($0.value) }.filter { !$0.isEmpty }
        guard !bases.isEmpty else { return false }
        return models.allSatisfy { model in
            let id = folded(model.id)
            return bases.contains { id.hasPrefix($0) }
        }
    }

    private static func folded(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
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
    /// A short consequence statement shown above the choices when changing
    /// this setting has timing semantics the user needs before committing.
    var note: String? = nil

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

    /// The menu, from a reconciled surface rather than a raw payload — the one
    /// place effort could still be said twice is if a caller fed this
    /// `session/new` directly, so the type system does not let it.
    static func rows(agentName: String, surface: AcpComposerSurface) -> [AcpComposerMenuRow] {
        var rows = [AcpComposerMenuRow(target: .agent, label: "Agent", value: agentName)]
        if let model = currentModel(surface) {
            rows.append(AcpComposerMenuRow(target: .model, label: "Model", value: model.name))
        }
        for option in surface.options where !option.choices.isEmpty {
            let value = AcpComposerMetrics.optionLabel(option) ?? option.choices[0].name
            rows.append(AcpComposerMenuRow(
                target: .option(option.id),
                label: shortLabel(name: option.name, id: option.id),
                value: value
            ))
        }
        return rows
    }

    static func currentModel(_ surface: AcpComposerSurface) -> AcpSessionInfo.Model? {
        currentModel(models: surface.models, currentModelID: surface.currentModelID)
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
        surface: AcpComposerSurface,
        favorites: Set<String>,
        query: String
    ) -> AcpComposerSubmenu {
        let selectedID = currentModel(surface)?.id
        let options = AcpModelPicker.choices(
            models: surface.models,
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
            },
            note: AcpComposerMetrics.effortOption([option]) == nil
                ? nil
                : "Applies to the next message in this chat."
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
    static func advancedLines(usage: AcpUsage?, surface: AcpComposerSurface) -> [String] {
        var lines: [String] = []
        if let usage, usage.max > 0 {
            lines.append(
                "Context used: \(AcpComposerMetrics.compactTokens(usage.used))"
                    + " of \(AcpComposerMetrics.compactTokens(usage.max))"
            )
        }
        if let model = currentModel(surface), folded(model.id) != folded(model.name) {
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
