import AppKit
import SwiftUI

/// The composer's settings menu: a compact disclosure list — `Label  value ›` —
/// with the choosing done in a panel beside it.
///
/// This replaces the provider rail, search field, and ⌘-numbered column the
/// round-3 picker used. Those were three affordances answering one question,
/// and that question ("which model?") is now one row among the settings a chat
/// actually has. Nothing at this level is a control: every row states a name,
/// the value in force, and that there is more behind it.
///
/// Both panels live inside one popover. A second floating window would match
/// the reference's overlapping cards more literally, but a submenu drawn in the
/// composer's own coordinate space is clipped by the chat pane, and a nested
/// `NSPopover` dismisses its parent the moment the pointer enters it. One
/// popover that grows a second column keeps the parent row on screen beside its
/// choices, which is what the nesting was for.
struct AcpComposerMenuView: View {
    let rows: [AcpComposerMenuRow]
    let advancedLines: [String]
    /// The panel behind a row, resolved lazily so a submenu is only built for
    /// the row the pointer or the keyboard actually reached.
    let submenu: (AcpComposerMenuRow.Target) -> AcpComposerSubmenu
    /// Brand marks for the agent submenu. Not consulted for any other panel: a
    /// mark column and a checkmark column would both be saying "this one".
    let identity: (String) -> QuietIdentity
    let choose: (AcpComposerMenuRow.Target, String) -> Void
    /// Favourites survive as a group that floats to the top of the model
    /// submenu — never as a star column, which would put a second control on
    /// every row of a menu whose whole point is that it has none. The context
    /// menu is the quiet way in.
    let toggleFavorite: (String) -> Void
    let manageAgents: () -> Void
    let dismiss: () -> Void
    /// Bound so a typed filter survives the pointer moving between rows; only a
    /// submenu past `AcpComposerMenu.searchThreshold` ever shows the field.
    @Binding var query: String

    @State private var armed: AcpComposerMenuRow.Target?
    @State private var highlightedRow: Int?
    @State private var highlightedOption: Int?
    @State private var advancedExpanded = false
    @FocusState private var panelFocused: Bool

    private static let rowsWidth: CGFloat = 232
    private static let submenuWidth: CGFloat = 208
    private static let panelInset: CGFloat = 6

    private var openSubmenu: AcpComposerSubmenu? { armed.map(submenu) }
    private var submenuOptions: [AcpComposerMenuOption] { openSubmenu?.options ?? [] }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rowsColumn
            if let panel = openSubmenu {
                Divider()
                submenuColumn(panel)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onAppear { panelFocused = true }
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onKeyPress(.rightArrow) { enterSubmenu() }
        .onKeyPress(.leftArrow) { leaveSubmenu() }
        .onKeyPress(.return) { activateHighlighted() }
        .onExitCommand {
            if armed == nil {
                dismiss()
            } else {
                _ = leaveSubmenu()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat settings")
        .accessibilityIdentifier("acp.composer.menu")
    }

    // MARK: - Disclosure rows

    private var rowsColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                disclosureRow(row, isHighlighted: highlightedRow == index || armed == row.target)
                    .onHover { inside in
                        guard inside else { return }
                        highlightedRow = index
                        highlightedOption = nil
                        armed = row.target
                    }
            }

            if !advancedLines.isEmpty {
                Divider().padding(.vertical, 4)
                advancedDisclosure
            }
        }
        .padding(Self.panelInset)
        .frame(width: Self.rowsWidth, alignment: .leading)
    }

    private func disclosureRow(_ row: AcpComposerMenuRow, isHighlighted: Bool) -> some View {
        Button {
            armed = row.target
            highlightedOption = nil
        } label: {
            HStack(spacing: 8) {
                Text(row.label)
                    .font(.callout)
                Spacer(minLength: 10)
                Text(row.value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius))
        }
        .buttonStyle(.plain)
        .background(
            isHighlighted ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius)
        )
        .accessibilityLabel("\(row.label): \(row.value)")
        .accessibilityHint("Opens the \(row.label.lowercased()) choices")
        .accessibilityIdentifier("acp.composer.menu.row.\(row.id)")
    }

    /// The reference's muted `Advanced ^`. It carries what the pill cannot hold
    /// and no row can change — statements, not controls — so it is hidden
    /// outright when there is nothing to say rather than opening onto a blank.
    private var advancedDisclosure: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                advancedExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Advanced")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced")
            .accessibilityValue(advancedExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("acp.composer.menu.advanced")

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(advancedLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("acp.composer.menu.advancedLine")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 3)
            }
        }
    }

    // MARK: - Submenu panel

    private func submenuColumn(_ panel: AcpComposerSubmenu) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(panel.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.top, 5)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("acp.composer.menu.submenu.title")

            if panel.showsSearch {
                searchField
            }

            if panel.options.isEmpty {
                Text("Nothing to choose here yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("acp.composer.menu.submenu.empty")
            } else {
                ForEach(Array(panel.options.enumerated()), id: \.element.id) { index, option in
                    optionRow(option, isHighlighted: highlightedOption == index)
                        .onHover { inside in
                            if inside { highlightedOption = index }
                        }
                }
            }

            if armed == .agent {
                Divider().padding(.vertical, 4)
                manageAgentsRow
            }
        }
        .padding(Self.panelInset)
        .frame(width: Self.submenuWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.title)
        .accessibilityIdentifier("acp.composer.menu.submenu")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityLabel("Filter this list")
                .accessibilityIdentifier("acp.composer.menu.search")
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 4)
    }

    private func optionRow(_ option: AcpComposerMenuOption, isHighlighted: Bool) -> some View {
        Button {
            activate(option)
        } label: {
            HStack(spacing: 8) {
                if armed == .agent {
                    QuietIdentityMarkView(identity: identity(option.id), size: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name)
                        .font(.callout)
                        .lineLimit(1)
                    if let caption = option.caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(option.isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius))
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .background(
            isHighlighted && option.isEnabled
                ? AnyShapeStyle(.quaternary.opacity(0.7))
                : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius)
        )
        .contextMenu {
            if armed == .model {
                Button("Keep at the top of this list") { toggleFavorite(option.id) }
            }
        }
        .accessibilityLabel(spokenLabel(option))
        .accessibilityAddTraits(option.isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("acp.composer.menu.option.\(option.id)")
    }

    private var manageAgentsRow: some View {
        Button {
            dismiss()
            manageAgents()
        } label: {
            HStack(spacing: 6) {
                Text("Manage agents…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage agents in Settings")
        .accessibilityIdentifier("acp.composer.menu.manageAgents")
    }

    private func spokenLabel(_ option: AcpComposerMenuOption) -> String {
        var label = option.name
        if let caption = option.caption { label += ", \(caption)" }
        if option.isSelected { label += ", selected" }
        if !option.isEnabled { label += ", unavailable" }
        return label
    }

    // MARK: - Keyboard

    /// Up/Down walks whichever column the highlight is in; the submenu's walk
    /// skips rows Return cannot activate.
    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        if armed != nil, highlightedOption != nil || highlightedRow == nil {
            highlightedOption = AcpComposerMenu.move(
                from: highlightedOption,
                by: delta,
                enabled: submenuOptions.map(\.isEnabled)
            )
            return .handled
        }
        guard let next = AcpComposerMenu.move(from: highlightedRow, by: delta, count: rows.count) else {
            return .ignored
        }
        highlightedRow = next
        highlightedOption = nil
        armed = rows[next].target
        return .handled
    }

    private func enterSubmenu() -> KeyPress.Result {
        guard armed != nil, !submenuOptions.isEmpty else { return .ignored }
        if highlightedOption == nil {
            highlightedOption = AcpComposerMenu.move(
                from: nil,
                by: 1,
                enabled: submenuOptions.map(\.isEnabled)
            )
        }
        return .handled
    }

    private func leaveSubmenu() -> KeyPress.Result {
        guard highlightedOption != nil else {
            armed = nil
            return .handled
        }
        highlightedOption = nil
        return .handled
    }

    private func activateHighlighted() -> KeyPress.Result {
        if let index = highlightedOption, submenuOptions.indices.contains(index) {
            activate(submenuOptions[index])
            return .handled
        }
        if let index = highlightedRow, rows.indices.contains(index) {
            armed = rows[index].target
            return enterSubmenu()
        }
        return .ignored
    }

    private func activate(_ option: AcpComposerMenuOption) {
        guard option.isEnabled, let target = armed else { return }
        choose(target, option.id)
    }
}
