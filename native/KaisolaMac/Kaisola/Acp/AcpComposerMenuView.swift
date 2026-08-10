import AppKit
import SwiftUI

/// The composer's settings menu: compact disclosure rows — `Label  value ›` —
/// plus ACP boolean switches that are complete controls in the first column.
///
/// This replaces the provider rail, search field, and ⌘-numbered column the
/// round-3 picker used. Those were three affordances answering one question,
/// and that question ("which model?") is now one row among the settings a chat
/// actually has. Select rows state a name, the value in force, and that there
/// is more behind it; boolean rows keep the adapter's native on/off shape.
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
    /// Read by the key monitor before it consumes anything. The monitor is
    /// app-wide while installed, so this is the gate that keeps a closed menu
    /// from eating the arrow keys of every other surface.
    let isPresented: () -> Bool
    /// Bound so a typed filter survives the pointer moving between rows; only a
    /// submenu past `AcpComposerMenu.searchThreshold` ever shows the field.
    @Binding var query: String

    /// Highlight and drilldown live in a reference type so the key monitor's
    /// closure can read and write the same state the body renders, rather than
    /// a struct copy frozen at the moment it was installed.
    @StateObject private var state = AcpComposerMenuState()
    @StateObject private var keyMonitor = AcpMenuKeyMonitor()

    private var armed: AcpComposerMenuRow.Target? {
        get { state.armed }
        nonmutating set { state.armed = newValue }
    }

    private var highlightedRow: Int? {
        get { state.highlightedRow }
        nonmutating set { state.highlightedRow = newValue }
    }

    private var highlightedOption: Int? {
        get { state.highlightedOption }
        nonmutating set { state.highlightedOption = newValue }
    }

    private var advancedExpanded: Bool {
        get { state.advancedExpanded }
        nonmutating set { state.advancedExpanded = newValue }
    }

    private static let rowsWidth: CGFloat = 232
    private static let submenuWidth: CGFloat = 208
    private static let panelInset: CGFloat = 6

    /// How tall the panel stands once a submenu is open, whatever that submenu
    /// happens to hold.
    ///
    /// It used to have no bound at all: the panel was as tall as the list
    /// inside it, and the Codex model list alone is thirty-odd rows. So opening
    /// one row's choices grew the popover past the window and over the
    /// conversation, and — because a submenu opens on *hover* — sliding the
    /// pointer down the left column resized the whole panel under it, row by
    /// row. Michael: "it keeps changing its size and goes below and hides the
    /// chat interface."
    ///
    /// One height for every submenu fixes both halves. The panel steps to this
    /// size once when a submenu opens and then holds still no matter which row
    /// the pointer is on, and a list too long for it scrolls rather than
    /// growing. Chosen to seat nine caption-less options — enough that the
    /// short lists (effort, mode) never scroll at all — while staying well
    /// inside the composer's own height.
    private static let openPanelHeight: CGFloat = 268

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
        .onAppear {
            keyMonitor.handle = handleKey
            keyMonitor.start()
        }
        .onDisappear { keyMonitor.stop() }
        .onChange(of: rows) { keyMonitor.handle = handleKey }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat settings")
        .accessibilityIdentifier("acp.composer.menu")
    }

    // MARK: - Disclosure rows

    private var rowsColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                settingsRow(row, isHighlighted: highlightedRow == index || armed == row.target)
                    .onHover { inside in
                        guard inside else { return }
                        highlightedRow = index
                        highlightedOption = nil
                        armed = row.booleanValue == nil ? row.target : nil
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

    @ViewBuilder
    private func settingsRow(_ row: AcpComposerMenuRow, isHighlighted: Bool) -> some View {
        if row.booleanValue != nil {
            booleanRow(row, isHighlighted: isHighlighted)
        } else {
            disclosureRow(row, isHighlighted: isHighlighted)
        }
    }

    private func booleanRow(_ row: AcpComposerMenuRow, isHighlighted: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { row.booleanValue ?? false },
            set: { value in
                guard value != row.booleanValue else { return }
                choose(row.target, value ? "true" : "false")
            }
        )) {
            Text(row.label)
                .font(.callout)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHighlighted ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius)
        )
        .help(row.hint ?? row.label)
        .accessibilityLabel(row.label)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityHint(row.hint ?? "Changes this setting for the current agent session")
        .accessibilityIdentifier("acp.composer.menu.boolean.\(row.id)")
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
                    .foregroundStyle(.kaisolaSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.kaisolaTertiary)
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
                        .foregroundStyle(.kaisolaSecondary)
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.kaisolaTertiary)
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
                            .foregroundStyle(.kaisolaSecondary)
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
                .foregroundStyle(.kaisolaSecondary)
                .padding(.horizontal, 9)
                .padding(.top, 5)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("acp.composer.menu.submenu.title")

            if let note = panel.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("acp.composer.menu.submenu.note")
            }

            if panel.showsSearch {
                searchField
            }

            if panel.options.isEmpty {
                Text("Nothing to choose here yet.")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("acp.composer.menu.submenu.empty")
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(panel.options.enumerated()), id: \.element.id) { index, option in
                                optionRow(option, isHighlighted: highlightedOption == index)
                                    .id(index)
                                    .onHover { inside in
                                        if inside { highlightedOption = index }
                                    }
                            }
                        }
                    }
                    // A short list should not look like a scroller.
                    .scrollBounceBehavior(.basedOnSize)
                    // The arrow keys can now walk the highlight past the
                    // bottom of the viewport, so the viewport follows it.
                    .onChange(of: highlightedOption) { proxy.scrollTo(highlightedOption, anchor: .center) }
                }
            }

            if armed == .agent {
                Divider().padding(.vertical, 4)
                manageAgentsRow
            }
        }
        .padding(Self.panelInset)
        // The height lives here rather than on the enclosing row so the scroll
        // view is actually *offered* a bounded height — a frame on the parent
        // would clip the list instead of letting it scroll.
        .frame(width: Self.submenuWidth, height: Self.openPanelHeight, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.title)
        .accessibilityIdentifier("acp.composer.menu.submenu")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.kaisolaTertiary)
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
                            .foregroundStyle(.kaisolaSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.kaisolaSecondary)
                        .accessibilityHidden(true)
                }
            }
            // A disabled row takes the disabled rung rather than tertiary:
            // tertiary now carries icon-only controls and is held to 3:1, which
            // is not what an inactive option should read as.
            .foregroundStyle(
                option.isEnabled
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(Color.kaisolaDisabled)
            )
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
                    .foregroundStyle(.kaisolaSecondary)
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

    /// Arrow keys walk, Return commits, Escape steps back out one level and
    /// then closes.
    private func handleKey(_ code: UInt16) -> Bool {
        guard isPresented() else { return false }
        switch code {
        case 126: return moveHighlight(-1) == .handled
        case 125: return moveHighlight(1) == .handled
        case 124: return enterSubmenu() == .handled
        case 123: return leaveSubmenu() == .handled
        case 36, 76: return activateHighlighted() == .handled
        case 53:
            // Escape closes the open submenu, then the menu. Left arrow is the
            // one that also steps the highlight back out of the option column;
            // Escape doing that too would need three presses to leave.
            guard armed != nil else {
                dismiss()
                return true
            }
            armed = nil
            highlightedOption = nil
            return true
        default:
            return false
        }
    }

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
        armed = rows[next].booleanValue == nil ? rows[next].target : nil
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
            let row = rows[index]
            if let enabled = row.booleanValue {
                choose(row.target, enabled ? "false" : "true")
                return .handled
            }
            armed = row.target
            return enterSubmenu()
        }
        return .ignored
    }

    private func activate(_ option: AcpComposerMenuOption) {
        guard option.isEnabled, let target = armed else { return }
        choose(target, option.id)
    }
}

/// Which row is armed and where the highlight sits, as a reference type.
///
/// It exists so the key monitor's closure and the rendered body share one
/// value. A `@State` struct copy captured when the monitor was installed would
/// read the right storage but write into a view SwiftUI has since replaced.
@MainActor
final class AcpComposerMenuState: ObservableObject {
    @Published var armed: AcpComposerMenuRow.Target?
    @Published var highlightedRow: Int?
    @Published var highlightedOption: Int?
    @Published var advancedExpanded = false
}

/// Keyboard for the menu, as an app-local event monitor.
///
/// A SwiftUI popover's window never becomes the app's key window here, so
/// `onKeyPress` never fires and a modifier-less `keyboardShortcut` is never
/// dispatched — verified against the running app, where neither the arrows nor
/// Escape reached the panel, and an `NSView` taking first responder inside the
/// popover did not help because the press is delivered to the key window.
/// (⌘-shortcuts do work: those go through the main menu. That is why the old
/// picker's ⌘-digits appeared to.)
///
/// A local monitor sees the press before dispatch regardless of key window. It
/// is installed on appear and removed on disappear — and, because a stray
/// monitor swallowing arrow keys across the whole app would be a far worse bug
/// than a menu that ignores them, `handleKey` refuses every press while the
/// popover is closed. That gate, not the teardown, is what makes this safe.
@MainActor
final class AcpMenuKeyMonitor: ObservableObject {
    private var token: Any?
    /// Returns true when the press was consumed.
    var handle: ((UInt16) -> Bool)?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let handle = self.handle, handle(event.keyCode) else { return event }
            return nil
        }
    }

    func stop() {
        handle = nil
        guard let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
    }
}
