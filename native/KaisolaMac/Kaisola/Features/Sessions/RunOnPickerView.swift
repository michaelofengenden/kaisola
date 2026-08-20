import SwiftUI

/// How the Run On sheet ended. `chooseFolder` is a detour, not a terminal
/// answer: the presenter reopens the picker on the chosen directory with the
/// in-flight subscription selection restored.
enum RunOnPickerOutcome {
    case start
    case cancel
    case chooseFolder
}

/// Presentation state for the Run On sheet, kept out of the view so the
/// launch contract — what is selected, what the router suggested, what Start
/// is allowed to do — stays testable without driving a window.
@MainActor
final class RunOnPickerViewModel: ObservableObject {
    struct AccountOption: Identifiable, Equatable {
        /// Stable row identity; the Project default row uses the sticky
        /// sentinel so it is distinct from "no row".
        let id: String
        /// nil means Project default.
        let profileID: String?
        let title: String
        let caption: String?
        let symbol: String
    }

    @Published private(set) var picker: RunOnPickerModel
    @Published private(set) var selectedProfileID: String?
    /// Why the router preselected an account. Hidden the moment the user
    /// picks a different row — a suggestion the user overrode has been heard.
    @Published private(set) var showsRoutingReason: Bool
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            picker.updateQuery(query)
        }
    }

    let profiles: [UsageAccountProfile]
    let provider: UsageAccountProfile.Provider?
    let routingReason: String?
    /// Static per presentation: controls that pop in and out while the user
    /// types read as layout glitches inside a fixed-size sheet.
    let showsSearch: Bool
    let targetListHeight: CGFloat
    private let usageCaptions: [String: String]
    private let removeRecentAction: (String) -> Void

    init(
        picker: RunOnPickerModel,
        profiles: [UsageAccountProfile],
        provider: UsageAccountProfile.Provider?,
        restoredSelection: RunOnPickerSelection? = nil,
        preferNamedAccount: Bool = false,
        routedVerdict: AccountRouter.Verdict? = nil,
        usageCaptions: [String: String] = [:],
        removeRecent: @escaping (String) -> Void
    ) {
        self.picker = picker
        self.profiles = profiles
        self.provider = provider
        self.usageCaptions = usageCaptions
        self.removeRecentAction = removeRecent
        // An explicit choice the user already made outranks any policy; the
        // router's suggestion outranks the fixture's deterministic pick.
        if let restoredSelection {
            selectedProfileID = restoredSelection.accountProfileID.flatMap { id in
                profiles.first { $0.id == id }?.id
            }
            routingReason = nil
            showsRoutingReason = false
        } else if let routedVerdict,
                  profiles.contains(where: { $0.id == routedVerdict.profileID }) {
            selectedProfileID = routedVerdict.profileID
            routingReason = routedVerdict.reason
            showsRoutingReason = true
        } else if preferNamedAccount, let first = profiles.first {
            selectedProfileID = first.id
            routingReason = nil
            showsRoutingReason = false
        } else {
            selectedProfileID = nil
            routingReason = nil
            showsRoutingReason = false
        }
        showsSearch = picker.targets.count > 6
        // Sized to the fullest scope so switching scopes never resizes the
        // sheet; the list scrolls past four rows.
        let widestScope = RunOnScope.allCases.map { scope in
            picker.targets.filter { $0.scope == scope }.count
        }.max() ?? 0
        let rows = CGFloat(min(max(widestScope, 1), 4))
        targetListHeight = rows * 46 + (rows - 1) * 6
    }

    var accountOptions: [AccountOption] {
        var options = [
            AccountOption(
                id: AccountRouter.projectDefaultSelection,
                profileID: nil,
                title: provider.map { "Project default · \($0.displayName)" } ?? "Project default",
                caption: provider.map { "Uses this project's effective \($0.environmentKey)" },
                symbol: "person.crop.circle.dashed"
            ),
        ]
        for profile in profiles {
            options.append(AccountOption(
                id: profile.id,
                profileID: profile.id,
                title: RunOnPickerPresentation.accountTitle(profile, among: profiles),
                caption: usageCaptions[profile.id],
                symbol: "person.crop.circle"
            ))
        }
        return options
    }

    func selectProfile(_ profileID: String?) {
        guard selectedProfileID != profileID else { return }
        selectedProfileID = profileID
        showsRoutingReason = false
    }

    var selectedProfile: UsageAccountProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var selection: RunOnPickerSelection {
        RunOnPickerSelection(accountProfileID: selectedProfileID)
    }

    var populatedScopes: [RunOnScope] {
        RunOnScope.allCases.filter { scope in
            picker.targets.contains { $0.scope == scope }
        }
    }

    var showsScopePicker: Bool { populatedScopes.count > 1 }

    func scopeCount(for scope: RunOnScope) -> Int {
        picker.targets.filter { $0.scope == scope }.count
    }

    var selectedScope: RunOnScope { picker.selectedScope }

    func selectScope(_ scope: RunOnScope) {
        picker.selectScope(scope)
        query = ""
    }

    var filteredTargets: [RunOnTarget] { picker.filteredTargets }

    var selectedTarget: RunOnTarget? { picker.selectedTarget }

    func selectTarget(_ id: String) {
        picker.selectTarget(id)
    }

    var canStart: Bool { picker.selectedTarget?.canStart == true }

    var selectedTargetIsRecent: Bool { picker.selectedTarget?.isRecent == true }

    func removeSelectedRecent() {
        guard let target = picker.selectedTarget,
              let path = picker.removeRecent(targetID: target.id) else { return }
        removeRecentAction(path)
    }

    var accountDisplayName: String {
        selectedProfile?.label ?? "Project default"
    }

    var confirmation: String {
        RunOnPickerPresentation.confirmation(
            target: picker.selectedTarget,
            accountName: accountDisplayName
        )
    }

    /// Per-account headroom captions from the readings Kaisola already takes.
    /// Same binding-window rule as the router: the fullest window is the
    /// constraint. Accounts without a fresh signed-in reading get no caption
    /// rather than a guess; a signed-out one says so.
    static func usageCaptions(
        profiles: [UsageAccountProfile],
        readings: [UsageCenter.ProviderPlanUsage],
        now: Date = Date()
    ) -> [String: String] {
        var captions: [String: String] = [:]
        for profile in profiles {
            guard let reading = readings.first(where: {
                $0.provider == profile.provider.rawValue && $0.profileID == profile.id
            }) else { continue }
            if reading.authRequired == true {
                captions[profile.id] = "Needs sign-in"
                continue
            }
            guard reading.ok, reading.isFresh(at: now) else { continue }
            var binding: (used: Double, label: String)?
            for window in reading.windows {
                guard let used = window.reportedUsedPercent else { continue }
                if binding.map({ used > $0.used }) ?? true {
                    binding = (used, window.label)
                }
            }
            guard let binding else { continue }
            captions[profile.id] =
                "\(UsageCenter.PlanWindow.percentCaption(binding.used)) used · \(binding.label) limit"
        }
        return captions
    }
}

/// The Run On sheet: the same visual grammar as the Start a Session chooser —
/// one header, selectable card rows with the shared hover/focus ladder — with
/// exactly two decisions: which subscription, and where the session runs.
struct RunOnPickerView: View {
    let title: String
    let subtitle: String
    let startTitle: String
    @ObservedObject var viewModel: RunOnPickerViewModel
    let complete: @MainActor (RunOnPickerOutcome) -> Void

    @FocusState private var focusedRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.kaisolaSecondary)
            }
            if viewModel.provider != nil {
                accountSection
            }
            locationSection
            footer
        }
        .padding(24)
        .frame(width: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run-on-picker")
        .accessibilityLabel(title)
        .onExitCommand { complete(.cancel) }
        .onAppear {
            // Initial keyboard focus lands on the row that is already
            // selected; otherwise the sheet opens with the focus ring on the
            // first row and the selection stroke on another, which reads as
            // two selections.
            DispatchQueue.main.async {
                if viewModel.provider != nil {
                    focusedRowID = "account:\(viewModel.selectedProfileID ?? AccountRouter.projectDefaultSelection)"
                } else if let target = viewModel.selectedTarget {
                    focusedRowID = "target:\(target.id)"
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Subscription")
            accountRows
            if let reason = viewModel.routingReason, viewModel.showsRoutingReason {
                Label(reason, systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                    .accessibilityLabel("Why this subscription is suggested: \(reason)")
            }
        }
    }

    @ViewBuilder
    private var accountRows: some View {
        let options = viewModel.accountOptions
        if options.count > 5 {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(options) { accountRow($0) }
                }
            }
            .frame(height: 5 * 36 + 4 * 6)
        } else {
            VStack(spacing: 6) {
                ForEach(options) { accountRow($0) }
            }
        }
    }

    private func accountRow(_ option: RunOnPickerViewModel.AccountOption) -> some View {
        let selected = viewModel.selectedProfileID == option.profileID
        let focusID = "account:\(option.id)"
        return Button {
            viewModel.selectProfile(option.profileID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.symbol)
                    .foregroundStyle(
                        selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.kaisolaSecondary)
                    )
                    .frame(width: 18)
                Text(option.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    // The account's name wins the line; a crowded row drops
                    // caption characters, never identity characters.
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let caption = option.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                        .lineLimit(1)
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(RunOnSelectableRowStyle(
            isSelected: selected,
            isFocused: focusedRowID == focusID
        ))
        .focusable()
        .focused($focusedRowID, equals: focusID)
        // The style draws its own focus rung; the system halo on top of it
        // reads as a second selection.
        .focusEffectDisabled()
        .accessibilityIdentifier("run-on-account-\(option.profileID ?? "default")")
        .accessibilityLabel(option.title)
        .accessibilityValue(option.caption ?? "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(option.caption ?? option.title)
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                sectionLabel("Run in")
                Spacer()
                if viewModel.selectedTargetIsRecent {
                    inlineAction("Remove from Recents") {
                        viewModel.removeSelectedRecent()
                    }
                    .accessibilityLabel("Remove selected target from recents")
                }
                inlineAction("Choose another folder…") {
                    complete(.chooseFolder)
                }
                .accessibilityLabel("Choose another folder")
            }
            if viewModel.showsScopePicker {
                Picker("Execution location", selection: Binding(
                    get: { viewModel.selectedScope },
                    set: { viewModel.selectScope($0) }
                )) {
                    ForEach(viewModel.populatedScopes, id: \.self) { scope in
                        Text("\(scope.sectionTitle) · \(viewModel.scopeCount(for: scope))")
                            .tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if viewModel.showsSearch {
                searchField
            }
            targetList
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.kaisolaTertiary)
            TextField("Search projects, folders, and branches", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityLabel("Search selected execution location")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: KaisolaVisualSystem.controlRadius,
                        style: .continuous
                    )
                    .stroke(
                        Color.primary.opacity(NewSessionChoiceButtonStyle.restStroke),
                        lineWidth: KaisolaVisualSystem.hairline
                    )
                }
        }
    }

    @ViewBuilder
    private var targetList: some View {
        let targets = viewModel.filteredTargets
        if targets.isEmpty {
            Text("No project or worktree in this location matches the search.")
                .font(.callout)
                .foregroundStyle(.kaisolaSecondary)
                .frame(maxWidth: .infinity, minHeight: viewModel.targetListHeight)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(targets) { targetRow($0) }
                }
            }
            .frame(height: viewModel.targetListHeight)
        }
    }

    private func targetRow(_ target: RunOnTarget) -> some View {
        let selected = viewModel.selectedTarget?.id == target.id
        let focusID = "target:\(target.id)"
        return Button {
            viewModel.selectTarget(target.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: target.scope.systemImage)
                    .foregroundStyle(
                        selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.kaisolaSecondary)
                    )
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if let branch = target.branch {
                            Text(branch)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.kaisolaSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                }
                        }
                    }
                    Text(target.path)
                        .font(.caption)
                        .foregroundStyle(.kaisolaTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(RunOnSelectableRowStyle(
            isSelected: selected,
            isFocused: focusedRowID == focusID
        ))
        .focusable()
        .focused($focusedRowID, equals: focusID)
        .focusEffectDisabled()
        .accessibilityLabel("\(target.name), \(target.branch ?? "not a Git repository")")
        .accessibilityValue(target.path)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help([target.path, target.branch].compactMap { $0 }.joined(separator: " — "))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .opacity(0.5)
            HStack(alignment: .center, spacing: 12) {
                summary
                Spacer(minLength: 16)
                Button("Cancel", role: .cancel) { complete(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button(startTitle) { complete(.start) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canStart)
                    .accessibilityIdentifier("run-on-start")
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let target = viewModel.selectedTarget {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(target.name) · \(target.branch ?? "Not a Git repository") · \(target.host)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(target.path)
                    .font(.caption)
                    .foregroundStyle(.kaisolaTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Execution confirmation: \(viewModel.confirmation)")
        } else {
            Text("Pick a location before starting.")
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.kaisolaSecondary)
    }

    private func inlineAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
    }
}

/// The Start a Session card ladder with one extra rung: a persistent selected
/// state (accent stroke plus the hover-level fill), because these rows are a
/// choice that stays made, not a one-shot action.
struct RunOnSelectableRowStyle: ButtonStyle {
    var isSelected = false
    var isFocused = false

    func makeBody(configuration: Configuration) -> some View {
        StyledRow(configuration: configuration, isSelected: isSelected, isFocused: isFocused)
    }

    private struct StyledRow: View {
        let configuration: Configuration
        let isSelected: Bool
        let isFocused: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let hovering = hovered && isEnabled
            let fill = configuration.isPressed
                ? NewSessionChoiceButtonStyle.pressFill
                : (isSelected || hovering
                    ? NewSessionChoiceButtonStyle.hoverFill
                    : NewSessionChoiceButtonStyle.restFill)
            configuration.label
                .background {
                    RoundedRectangle(
                        cornerRadius: KaisolaVisualSystem.controlRadius,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(fill))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: KaisolaVisualSystem.controlRadius,
                            style: .continuous
                        )
                        .stroke(
                            isSelected
                                ? AnyShapeStyle(Color.accentColor.opacity(0.8))
                                : AnyShapeStyle(Color.primary.opacity(
                                    hovering
                                        ? NewSessionChoiceButtonStyle.hoverStroke
                                        : NewSessionChoiceButtonStyle.restStroke
                                )),
                            lineWidth: isSelected
                                ? KaisolaVisualSystem.focusStroke
                                : KaisolaVisualSystem.hairline
                        )
                    }
                    .overlay {
                        if isFocused, isEnabled {
                            RoundedRectangle(
                                cornerRadius: KaisolaVisualSystem.controlRadius,
                                style: .continuous
                            )
                            .stroke(Color.accentColor, lineWidth: KaisolaVisualSystem.focusStroke)
                        }
                    }
                }
                .opacity(configuration.isPressed ? 0.88 : 1)
                .animation(
                    .easeOut(duration: KaisolaVisualSystem.hoverDuration),
                    value: hovering
                )
                .onHover { hovered = $0 }
        }
    }
}
