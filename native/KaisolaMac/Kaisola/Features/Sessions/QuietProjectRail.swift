import Combine
import SwiftUI

/// "Quiet fleet" v2.3 sidebar rail. Spec: single-line rows
/// (glyph · title · time · dot-at-right-edge), idle rows draw no dot,
/// plain-text headers with hover-only chrome, 30pt session indent,
/// collapsed headers show a count + dot rollup (amber outermost).
///
/// The rail is pure presentation: every mutating action it offers is a closure
/// or an `AppModel` call that already existed, so the sidebar's context menus
/// (pin, rename, split, End Session, Move…) are passed in unchanged by the
/// hosting view rather than reimplemented here.
struct QuietProjectRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var attention: AttentionCenter

    private let expansion: (String) -> Binding<Bool>
    private let isActiveProject: (String) -> Bool
    /// Terminal selection carries a focus policy the rail must not own (window
    /// hand-off, focused-pane and cross-project guards), so the host supplies it.
    private let selectSession: (BrokerTerminalRecord) -> Void
    /// The hover `+` offers creation only; destructive project actions stay in
    /// the row's context menu.
    private let launchMenu: (AppModel.ProjectGroup) -> AnyView
    private let projectMenu: (AppModel.ProjectGroup) -> AnyView
    private let sessionMenu: (BrokerTerminalRecord) -> AnyView
    private let chatMenu: (AcpChatHandle) -> AnyView
    private let meshMenu: (MeshSession) -> AnyView

    /// Time-in-state, not time-since-creation: rows report how long the surface
    /// has been in the state it is showing.
    @State private var clock = QuietStatusClock()
    @State private var now = Date()
    /// Held in `@State` so a parent re-render (which happens on every streamed
    /// terminal byte) cannot restart the timer before it ever fires.
    @State private var tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let orderStore = SessionOrderStore()

    init(
        model: AppModel,
        attention: AttentionCenter,
        expansion: @escaping (String) -> Binding<Bool>,
        isActiveProject: @escaping (String) -> Bool,
        selectSession: @escaping (BrokerTerminalRecord) -> Void,
        launchMenu: @escaping (AppModel.ProjectGroup) -> AnyView,
        contextMenu: @escaping (AppModel.ProjectGroup) -> AnyView,
        sessionContextMenu: @escaping (BrokerTerminalRecord) -> AnyView,
        chatContextMenu: @escaping (AcpChatHandle) -> AnyView,
        meshContextMenu: @escaping (MeshSession) -> AnyView
    ) {
        self.model = model
        self.attention = attention
        self.expansion = expansion
        self.isActiveProject = isActiveProject
        self.selectSession = selectSession
        self.launchMenu = launchMenu
        self.projectMenu = contextMenu
        self.sessionMenu = sessionContextMenu
        self.chatMenu = chatContextMenu
        self.meshMenu = meshContextMenu
    }

    var body: some View {
        ForEach(model.projects) { project in
            QuietProjectGroup(
                model: model,
                attention: attention,
                project: project,
                isExpanded: expansion(project.id),
                isActive: isActiveProject(project.id),
                now: now,
                orderStore: orderStore,
                since: { clock.since(id: $0) },
                note: { id, status in clock.note(id: id, status: status, at: Date()) },
                selectSession: selectSession,
                launchMenu: launchMenu,
                projectMenu: projectMenu,
                sessionMenu: sessionMenu,
                chatMenu: chatMenu,
                meshMenu: meshMenu
            )
        }
        .onMove { indices, target in
            guard let first = indices.first else { return }
            let id = model.projects[first].id
            let to = target > first ? target - 1 : target
            model.moveProject(id: id, toIndex: to)
        }
        .onReceive(tick) { now = $0 }
    }
}

// MARK: - Metrics

/// Every size the rail uses. Text bottoms out at 10.5pt — no *label* in the
/// sidebar is smaller than the time label; symbol glyphs (the hover chevron and
/// `+`) may be smaller, since they carry no reading load.
private enum QuietRailMetrics {
    static let headerText: CGFloat = 13
    static let titleText: CGFloat = 12.5
    static let secondaryText: CGFloat = 10.5
    static let chevronText: CGFloat = 9
    static let plusText: CGFloat = 10
    static let glyphColumn: CGFloat = 13
    static let dot: CGFloat = 6
    static let sessionIndent: CGFloat = 30
    static let rowHeight: CGFloat = 26
    static let headerHeight: CGFloat = 30
    static let horizontalInset: CGFloat = 8
    static let trailingInset: CGFloat = 10
    static let pulseDuration: Double = 1.4
}

// MARK: - Project group

/// One project: a plain-text header (hover reveals its chevron and `+`) plus,
/// when expanded, that project's chats, meshes, and terminal sessions.
private struct QuietProjectGroup: View {
    @ObservedObject var model: AppModel
    @ObservedObject var attention: AttentionCenter
    let project: AppModel.ProjectGroup
    @Binding var isExpanded: Bool
    let isActive: Bool
    let now: Date
    let orderStore: SessionOrderStore
    let since: (String) -> Date?
    let note: (String, QuietSessionStatus) -> Void
    let selectSession: (BrokerTerminalRecord) -> Void
    let launchMenu: (AppModel.ProjectGroup) -> AnyView
    let projectMenu: (AppModel.ProjectGroup) -> AnyView
    let sessionMenu: (BrokerTerminalRecord) -> AnyView
    let chatMenu: (AcpChatHandle) -> AnyView
    let meshMenu: (MeshSession) -> AnyView

    @State private var hovering = false
    /// Manual drag order, read from disk once per project so streamed output
    /// never turns a re-render into file I/O.
    @State private var manualOrder: [String] = []
    @State private var loadedOrder = false

    var body: some View {
        let chats = model.chats(in: project.id)
        let meshes = model.meshes(in: project.id)
        // `AppModel.projects` already returns each group's sessions in pinned
        // order, so the manual drag order is the only sort applied here.
        let sessions = SessionOrderStore.apply(manualOrder, to: project.sessions)
        let statuses = statusMap(sessions: sessions, chats: chats, meshes: meshes)

        Group {
            header(statuses: statuses)
            if isExpanded {
                ForEach(chats) { chat in
                    chatRow(chat, status: statuses[chat.id] ?? .idle)
                }
                ForEach(meshes) { mesh in
                    meshRow(mesh, status: statuses[mesh.id] ?? .idle)
                }
                ForEach(sessions) { session in
                    sessionRow(session, status: statuses[session.id] ?? .idle)
                }
                .onMove { indices, target in
                    var ids = sessions.map(\.id)
                    ids.move(fromOffsets: indices, toOffset: target)
                    manualOrder = ids
                    orderStore.setOrder(projectID: project.id, ids: ids)
                }
                if sessions.isEmpty, chats.isEmpty, meshes.isEmpty {
                    emptyRow
                }
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(statuses: [String: QuietSessionStatus]) -> some View {
        let tint = ProjectTint.color(project.colorHex) ?? WorkspacePalette.project
        HStack(spacing: 6) {
            // A real Button, not a tap gesture: it is what gives the header a
            // press action for VoiceOver, Full Keyboard Access and automation.
            // The `+` stays a SIBLING of the button rather than part of its
            // label, because a Menu nested inside a button label never receives
            // the click that opens it.
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: QuietRailMetrics.headerText, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? HierarchicalShapeStyle.primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !isExpanded {
                        QuietRollupView(rollup: QuietRollup.of(Array(statuses.values)))
                    }
                    if hovering {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: QuietRailMetrics.chevronText, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                // The button's own label owns the full row geometry — height,
                // horizontal inset and width — so its hit area (and VoiceOver
                // frame) covers the entire 30pt row, not just the intrinsic
                // text height. Mirrors QuietRowBody's chain (~line 494).
                .padding(.horizontal, QuietRailMetrics.horizontalInset)
                .frame(height: QuietRailMetrics.headerHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The row is both the section heading and its expand control, so the
            // header trait moves onto the button rather than being lost inside
            // the (now combined) label.
            .accessibilityAddTraits(.isHeader)
            if hovering {
                Menu {
                    launchMenu(project)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: QuietRailMetrics.plusText, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New session in \(project.name)")
                .accessibilityLabel("New session in \(project.name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The active project's tint wash is the only fill in the rail; every
        // other row earns its emphasis from the dot instead.
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius, style: .continuous)
                    .fill(tint.opacity(0.12))
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) { hovering = inside }
        }
        .contextMenu {
            // Move Up/Down come first so the destructive tail of the passed-in
            // project menu (Close Project) stays last in the composed menu.
            // ⌥↑/⌥↓ target the active project only, so a menu opened on a
            // non-active project's header never reorders the wrong row.
            Button("Move Up") {
                guard isActive else { return }
                model.moveProject(id: project.id, delta: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: .option)
            .disabled(!isActive)
            Button("Move Down") {
                guard isActive else { return }
                model.moveProject(id: project.id, delta: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: .option)
            .disabled(!isActive)
            Divider()
            projectMenu(project)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(isExpanded ? "Collapse" : "Expand")) { toggle() }
        .onAppear {
            if !loadedOrder {
                loadedOrder = true
                manualOrder = orderStore.order(projectID: project.id)
            }
            noteAll(statuses)
        }
        .onChange(of: statuses) { _, updated in noteAll(updated) }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var emptyRow: some View {
        Text("No activity yet")
            .font(.system(size: QuietRailMetrics.secondaryText))
            .foregroundStyle(.tertiary)
            .padding(.leading, QuietRailMetrics.sessionIndent)
            .frame(height: QuietRailMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func toggle() {
        if !isActive { model.activateProject(id: project.id) }
        withAnimation(.easeInOut(duration: KaisolaVisualSystem.stateDuration)) { isExpanded.toggle() }
    }

    // MARK: Rows

    private func sessionRow(_ record: BrokerTerminalRecord, status: QuietSessionStatus) -> some View {
        QuietSessionRowView(
            record: record,
            glyph: QuietKindGlyph.glyph(
                agentName: model.agentProfile(for: record.id)?.name,
                processName: model.meta(for: record.id)?.processName
            ),
            title: model.sessionTitle(for: record),
            status: status,
            timeLabel: timeLabel(record.id),
            isSelected: model.isSurfaceVisible(record.id),
            tooltip: tooltip(for: record),
            select: { selectSession(record) },
            menu: sessionMenu
        )
    }

    private func chatRow(_ chat: AcpChatHandle, status: QuietSessionStatus) -> some View {
        QuietChatRowView(
            chat: chat,
            glyph: QuietKindGlyph.glyph(agentName: chat.agentID, processName: nil),
            title: chat.conversation.title,
            status: status,
            timeLabel: timeLabel(chat.id),
            isSelected: model.isSurfaceVisible(chat.id),
            tooltip: chatTooltip(chat),
            select: { model.selectChat(chat.id) },
            menu: chatMenu
        )
    }

    private func meshRow(_ mesh: MeshSession, status: QuietSessionStatus) -> some View {
        QuietMeshRowView(
            mesh: mesh,
            title: mesh.title,
            status: status,
            timeLabel: timeLabel(mesh.id),
            isSelected: model.isSurfaceVisible(mesh.id),
            tooltip: mesh.stage == "Idle" ? "Mesh · Ready" : "Mesh · \(mesh.stage)",
            select: { model.selectMesh(mesh.id) },
            menu: meshMenu
        )
    }

    // MARK: Derivations

    private func timeLabel(_ id: String) -> String {
        guard let start = since(id) else { return "" }
        return QuietTimeLabel.label(since: start, now: now)
    }

    /// Everything the collapsed rollup and the expanded rows both need, derived
    /// once per body pass.
    private func statusMap(
        sessions: [BrokerTerminalRecord],
        chats: [AcpChatHandle],
        meshes: [MeshSession]
    ) -> [String: QuietSessionStatus] {
        var map: [String: QuietSessionStatus] = [:]
        for record in sessions { map[record.id] = terminalStatus(record) }
        for chat in chats { map[chat.id] = chatStatus(chat) }
        for mesh in meshes { map[mesh.id] = meshStatus(mesh) }
        return map
    }

    /// A completed turn is not by itself a needs-you: it becomes one only while
    /// it is still unseen, which `QuietSessionStatus` models as `doneUnseen`.
    /// The rule itself lives in `QuietStatusDerivation` so it can be tested.
    private func hasPermissionAttention(_ id: String) -> Bool {
        QuietStatusDerivation.needsAttention(entries: attention.entries, for: id)
    }

    private func terminalStatus(_ record: BrokerTerminalRecord) -> QuietSessionStatus {
        var acknowledged = false
        if case .responded(let at) = record.agentActivity {
            acknowledged = attention.hasAcknowledgedSessionResponse(targetID: record.id, completedAt: at)
        }
        return QuietStatusDerivation.terminal(
            activity: record.agentActivity,
            exited: record.exited,
            hasPermissionAttention: hasPermissionAttention(record.id),
            respondedAcknowledged: acknowledged
        )
    }

    private func chatStatus(_ chat: AcpChatHandle) -> QuietSessionStatus {
        QuietStatusDerivation.chat(
            isRunning: chat.conversation.isRunning,
            isConnected: chat.conversation.isConnected,
            hasPendingPermission: chat.conversation.pendingPermission != nil,
            hasPermissionAttention: hasPermissionAttention(chat.id),
            statusMessage: chat.conversation.statusMessage
        )
    }

    /// Derived from the columns' live conversations, not from `mesh.stage`:
    /// stage is a display string, so matching it against "Idle" left
    /// "Interrupted" and "Scout timed out…" pulsing green forever.
    private func meshStatus(_ mesh: MeshSession) -> QuietSessionStatus {
        QuietStatusDerivation.mesh(
            anyColumnRunning: mesh.anyRunning,
            hasPermissionAttention: hasPermissionAttention(mesh.id)
        )
    }

    private func noteAll(_ statuses: [String: QuietSessionStatus]) {
        for (id, status) in statuses { note(id, status) }
    }

    /// What the old two-line row's subtitle carried, moved into the tooltip so
    /// the row itself stays one line.
    private func tooltip(for record: BrokerTerminalRecord) -> String {
        var parts = ["PID \(record.pid.map(String.init) ?? "—")"]
        if !record.exited {
            if let branch = model.branch(for: record.id) { parts.append("⎇ \(branch)") }
            if let process = model.meta(for: record.id)?.processName { parts.append(process) }
        }
        if !model.isOwned(record.id) { parts.append("observed") }
        return parts.joined(separator: " · ")
    }

    private func chatTooltip(_ chat: AcpChatHandle) -> String {
        var parts = ["Chat · \(chat.agentID)"]
        if let message = chat.conversation.statusMessage, !message.isEmpty { parts.append(message) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Collapsed rollup

/// A collapsed project's whole story: how many surfaces are active, and which
/// states they are in. Amber (needs-you) sorts to the outer edge so the eye
/// finds it at the right margin without expanding anything.
private struct QuietRollupView: View {
    let rollup: QuietRollup

    var body: some View {
        HStack(spacing: 5) {
            if rollup.total > 0 {
                Text("\(rollup.total)")
                    .font(.system(size: QuietRailMetrics.secondaryText).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(rollup.dots.enumerated()), id: \.offset) { _, state in
                if let color = state.dotColor {
                    Circle()
                        .fill(color)
                        .frame(width: QuietRailMetrics.dot, height: QuietRailMetrics.dot)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        // An empty rollup draws nothing; without this VoiceOver still stops on
        // an unlabeled element between the project name and its chrome.
        .accessibilityHidden(rollup.total == 0)
    }

    private var label: String {
        guard rollup.total > 0 else { return "" }
        return (["\(rollup.total) active"] + rollup.dots.compactMap(\.accessibilityWord))
            .joined(separator: ", ")
    }
}

// MARK: - Row anatomy

/// The four tokens every row shares: kind glyph, title, time-in-state, dot.
/// The dot always occupies its 6pt slot even when it draws nothing, so the
/// times stay in one column down the whole rail.
private struct QuietRowBody: View {
    let glyph: String
    let title: String
    let timeLabel: String
    let status: QuietSessionStatus
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(glyph)
                .font(.system(size: QuietRailMetrics.secondaryText))
                .foregroundStyle(.tertiary)
                .frame(width: QuietRailMetrics.glyphColumn, alignment: .center)
            Text(title)
                .font(.system(size: QuietRailMetrics.titleText))
                .foregroundStyle(status.isDimmed ? HierarchicalShapeStyle.tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The only compressible token in the row; without this it loses
                // to its fixed-size siblings and truncates first.
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(timeLabel)
                .font(.system(size: QuietRailMetrics.secondaryText).monospacedDigit())
                .foregroundStyle(.tertiary)
            QuietStatusDot(status: status)
        }
        .padding(.leading, QuietRailMetrics.sessionIndent)
        .padding(.trailing, QuietRailMetrics.trailingInset)
        .frame(height: QuietRailMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .padding(.horizontal, 6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A row with no time-in-state yet must not read as "…, idle, " — the
    /// components are joined only when they carry something.
    private var accessibilityLabel: String {
        [title, status.accessibilityWord ?? "idle", timeLabel]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// Idle and ended draw nothing — silence is information — but the slot stays.
private struct QuietStatusDot: View {
    let status: QuietSessionStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var shouldPulse: Bool { status == .working && !reduceMotion }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: QuietRailMetrics.dot, height: QuietRailMetrics.dot)
            if let color = status.dotColor {
                Circle()
                    .fill(color)
                    .frame(width: QuietRailMetrics.dot, height: QuietRailMetrics.dot)
                    .opacity(pulsing ? 0.3 : 1)
            }
        }
        .frame(width: QuietRailMetrics.dot, height: QuietRailMetrics.dot)
        .animation(
            shouldPulse
                ? .easeInOut(duration: QuietRailMetrics.pulseDuration).repeatForever(autoreverses: true)
                : nil,
            value: pulsing
        )
        .onAppear { pulsing = shouldPulse }
        .onChange(of: shouldPulse) { _, pulse in pulsing = pulse }
        .accessibilityHidden(true)
    }
}

// MARK: - Concrete rows

private struct QuietSessionRowView: View {
    let record: BrokerTerminalRecord
    let glyph: String
    let title: String
    let status: QuietSessionStatus
    let timeLabel: String
    let isSelected: Bool
    let tooltip: String
    let select: () -> Void
    let menu: (BrokerTerminalRecord) -> AnyView

    var body: some View {
        // A Button, not a tap gesture: a gesture is invisible to VoiceOver,
        // Full Keyboard Access and automation, so the row would expose no press
        // action. `.plain` keeps the row's own appearance.
        Button(action: select) {
            QuietRowBody(
                glyph: glyph,
                title: title,
                timeLabel: timeLabel,
                status: status,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .help(tooltip)
        .contextMenu { menu(record) }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct QuietChatRowView: View {
    let chat: AcpChatHandle
    let glyph: String
    let title: String
    let status: QuietSessionStatus
    let timeLabel: String
    let isSelected: Bool
    let tooltip: String
    let select: () -> Void
    let menu: (AcpChatHandle) -> AnyView

    var body: some View {
        Button(action: select) {
            QuietRowBody(
                glyph: glyph,
                title: title,
                timeLabel: timeLabel,
                status: status,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .help(tooltip)
        .contextMenu { menu(chat) }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct QuietMeshRowView: View {
    let mesh: MeshSession
    let title: String
    let status: QuietSessionStatus
    let timeLabel: String
    let isSelected: Bool
    let tooltip: String
    let select: () -> Void
    let menu: (MeshSession) -> AnyView

    var body: some View {
        Button(action: select) {
            QuietRowBody(
                glyph: "⌗",
                title: title,
                timeLabel: timeLabel,
                status: status,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .help(tooltip)
        .contextMenu { menu(mesh) }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
