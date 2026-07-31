import Combine
import SwiftUI

/// "Quiet fleet" v4.4 sidebar rail, restyled on Safari's tab-group
/// methodology: the *active* project is pinned at the top of the rail with its
/// surfaces beneath it, and every other project sits under a quiet "Projects"
/// section label as a compact one-line row that can be expanded in place
/// without stealing focus.
///
/// Row grammar is unchanged: identity mark · title · time-in-state · dot at the
/// right edge, idle rows draw no dot, and the only background fill in the whole
/// rail is the neutral selection wash on surfaces that are actually on screen
/// (plus the pinned project's header).
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
        let projects = model.projects
        let active = projects.first { isActiveProject($0.id) }
        let others = projects.filter { $0.id != active?.id }
        Group {
            if let active {
                group(active, placement: .pinned)
            }
            if !others.isEmpty {
                QuietSectionLabel(title: "Projects")
                ForEach(others) { project in
                    group(project, placement: .compact)
                }
                // Drag reorder still writes the persisted project order, but the
                // list being dragged no longer contains the active project, so
                // the indices are mapped back through `QuietRailOrder`.
                .onMove { indices, target in
                    guard let from = indices.first,
                          let move = QuietRailOrder.moveIndex(
                              activeID: active?.id,
                              orderedIDs: projects.map(\.id),
                              from: from,
                              to: target
                          ) else { return }
                    model.moveProject(id: move.id, toIndex: move.toIndex)
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private func group(_ project: AppModel.ProjectGroup, placement: QuietProjectPlacement) -> some View {
        QuietProjectGroup(
            model: model,
            attention: attention,
            project: project,
            isExpanded: expansion(project.id),
            placement: placement,
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
}

// MARK: - Compact-list drag mapping

/// Maps a drag in the compact project list (which excludes the pinned active
/// project) onto the index `AppModel.moveProject(id:toIndex:)` expects in the
/// *persisted* order. Pure so the arithmetic can be tested without a list.
enum QuietRailOrder {
    struct Move: Equatable {
        let id: String
        let toIndex: Int
    }

    /// - Parameters:
    ///   - activeID: the pinned project, absent from the dragged list.
    ///   - orderedIDs: the full persisted project order.
    ///   - from: source index in the compact list (SwiftUI `onMove` offsets).
    ///   - to: destination index in the compact list, before the move.
    /// - Returns: the project to move and its destination in the full order, or
    ///   `nil` when the drag is a no-op or out of range.
    static func moveIndex(activeID: String?, orderedIDs: [String], from: Int, to: Int) -> Move? {
        var compact = orderedIDs.filter { $0 != activeID }
        guard from >= 0, from < compact.count else { return nil }
        let destination = max(0, min(to, compact.count))
        // SwiftUI's `toOffset` is measured before the removal; a drop onto the
        // row's own slot (or immediately after it) changes nothing.
        let landed = destination > from ? destination - 1 : destination
        guard landed != from else { return nil }
        let movedID = compact[from]
        compact.move(fromOffsets: IndexSet(integer: from), toOffset: destination)

        // The persisted store moves a project by remove-then-insert, so the
        // destination index is measured against the order with the dragged
        // project taken out. Anchoring on the row it landed behind keeps the
        // pinned project wherever it already sat.
        let rest = orderedIDs.filter { $0 != movedID }
        guard landed > 0, landed - 1 < compact.count,
              let predecessorIndex = rest.firstIndex(of: compact[landed - 1]) else {
            return Move(id: movedID, toIndex: 0)
        }
        return Move(id: movedID, toIndex: predecessorIndex + 1)
    }
}

// MARK: - Metrics

/// Every size the rail uses. Text bottoms out at 10.5pt — no *label* in the
/// sidebar is smaller than the time label; symbol glyphs (the hover chevron and
/// `+`) may be smaller, since they carry no reading load.
private enum QuietRailMetrics {
    static let headerText: CGFloat = 13
    static let titleText: CGFloat = 13
    static let sectionText: CGFloat = 11
    static let secondaryText: CGFloat = 10.5
    static let chevronText: CGFloat = 9
    static let plusText: CGFloat = 10
    static let folderText: CGFloat = 11
    static let revealText: CGFloat = 10
    /// Identity slot and the gap between it and the label.
    static let mark: CGFloat = QuietIdentityMarkView.slot
    static let markGap: CGFloat = 8
    static let dot: CGFloat = 6
    static let sessionIndent: CGFloat = 30
    /// One cadence for every row in the rail: sessions, compact projects and
    /// the pinned project header all measure 32pt.
    static let rowHeight: CGFloat = 32
    static let horizontalInset: CGFloat = 8
    static let trailingInset: CGFloat = 10
    static let pulseDuration: Double = 1.4
    /// The rail's only fill: a neutral wash, never a tint.
    static let washOpacity: Double = 0.055
}

private enum QuietProjectPlacement {
    /// The active project, pinned to the top of the rail with its surfaces.
    case pinned
    /// Any other project, one compact line under the "Projects" label.
    case compact
}

/// Sentence-case section divider between the pinned project and the rest.
private struct QuietSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: QuietRailMetrics.sectionText, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 14)
            .padding(.leading, 10)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Project group

/// One project. Pinned: a 32pt header carrying the project's tinted name, its
/// chats/meshes/sessions beneath, and a hover-revealed "New session" row.
/// Compact: a single 32pt row with a folder glyph, the project's name, its
/// rollup, and a hover chevron that expands the project in place *without*
/// activating it — activation is the row body's job.
private struct QuietProjectGroup: View {
    @ObservedObject var model: AppModel
    @ObservedObject var attention: AttentionCenter
    let project: AppModel.ProjectGroup
    @Binding var isExpanded: Bool
    let placement: QuietProjectPlacement
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
    @State private var hoveringLaunchRow = false
    /// Manual drag order, read from disk once per project so streamed output
    /// never turns a re-render into file I/O.
    @State private var manualOrder: [String] = []
    @State private var loadedOrder = false

    private var isActive: Bool { placement == .pinned }

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
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    sessionRow(session, ordinal: index + 1, status: statuses[session.id] ?? .idle)
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
                if isActive {
                    newSessionRow
                }
            }
        }
    }

    // MARK: Header

    private func header(statuses: [String: QuietSessionStatus]) -> some View {
        Group {
            switch placement {
            case .pinned: pinnedHeader(statuses: statuses)
            case .compact: compactRow(statuses: statuses)
            }
        }
        // The status clock is stamped from the project's own row so a project
        // whose surfaces are collapsed keeps accumulating time-in-state.
        .onAppear { noteAll(statuses) }
        .onChange(of: statuses) { _, updated in noteAll(updated) }
    }

    private func noteAll(_ statuses: [String: QuietSessionStatus]) {
        for (id, status) in statuses { note(id, status) }
    }

    /// The pinned (active) project. Only the project's *name* carries its tint;
    /// the background is the same neutral wash focused surfaces use, so no tint
    /// fill appears anywhere in the rail.
    private func pinnedHeader(statuses: [String: QuietSessionStatus]) -> some View {
        HStack(spacing: 6) {
            // A real Button, not a tap gesture: it is what gives the header a
            // press action for VoiceOver, Full Keyboard Access and automation.
            // The `+` stays a SIBLING of the button rather than part of its
            // label, because a Menu nested inside a button label never receives
            // the click that opens it.
            Button {
                withAnimation(.easeInOut(duration: KaisolaVisualSystem.stateDuration)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: QuietRailMetrics.markGap) {
                    Image(systemName: "folder")
                        .font(.system(size: QuietRailMetrics.folderText, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: QuietRailMetrics.mark, height: QuietRailMetrics.mark)
                        .accessibilityHidden(true)
                    Text(project.name)
                        .font(.system(size: QuietRailMetrics.headerText, weight: .semibold))
                        .foregroundStyle(tint)
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
                // frame) covers the entire 32pt row, not just the intrinsic
                // text height. Mirrors QuietRowBody's chain.
                .padding(.horizontal, QuietRailMetrics.horizontalInset)
                .frame(height: QuietRailMetrics.rowHeight)
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
        .background { QuietSelectionWash() }
        .modifier(projectRowChrome)
    }

    /// Every other project: one line, no wash, expandable in place.
    private func compactRow(statuses: [String: QuietSessionStatus]) -> some View {
        HStack(spacing: 6) {
            Button(action: activate) {
                HStack(spacing: QuietRailMetrics.markGap) {
                    Image(systemName: "folder")
                        .font(.system(size: QuietRailMetrics.folderText, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .frame(width: QuietRailMetrics.mark, height: QuietRailMetrics.mark)
                        .accessibilityHidden(true)
                    Text(project.name)
                        .font(.system(size: QuietRailMetrics.headerText))
                        .foregroundStyle(HierarchicalShapeStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    QuietRollupView(rollup: QuietRollup.of(Array(statuses.values)))
                }
                .padding(.leading, QuietRailMetrics.horizontalInset)
                .frame(height: QuietRailMetrics.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            // Peeking into a project must not steal the workspace: the chevron
            // is a SIBLING control so its click never reaches the row's
            // activate action. It keeps its slot when hidden so the row's
            // contents do not shift under the pointer on hover.
            Button {
                withAnimation(.easeInOut(duration: KaisolaVisualSystem.stateDuration)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: QuietRailMetrics.chevronText, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: QuietRailMetrics.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .padding(.trailing, QuietRailMetrics.horizontalInset)
            .help(isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
            .accessibilityLabel(isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(projectRowChrome)
    }

    /// Hover, context menu, status bookkeeping and list chrome — identical for
    /// both header shapes.
    private var projectRowChrome: QuietProjectRowChrome {
        QuietProjectRowChrome(
            hovering: $hovering,
            isActive: isActive,
            expandLabel: isExpanded ? "Collapse" : "Expand",
            toggle: { withAnimation(.easeInOut(duration: KaisolaVisualSystem.stateDuration)) { isExpanded.toggle() } },
            moveUp: { model.moveProject(id: project.id, delta: -1) },
            moveDown: { model.moveProject(id: project.id, delta: 1) },
            menu: { projectMenu(project) },
            onAppear: {
                if !loadedOrder {
                    loadedOrder = true
                    manualOrder = orderStore.order(projectID: project.id)
                }
            }
        )
    }

    private var tint: Color { ProjectTint.color(project.colorHex) ?? WorkspacePalette.project }

    /// Activating re-pins the project at the top of the rail; opening it there
    /// collapsed would hide the surfaces the click was asking for.
    private func activate() {
        if !isActive { model.activateProject(id: project.id) }
        if !isExpanded {
            withAnimation(.easeInOut(duration: KaisolaVisualSystem.stateDuration)) { isExpanded = true }
        }
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

    /// The pinned project's creation affordance, under its surfaces. The row
    /// always holds its slot so the pointer can reach it (an `opacity(0)` view
    /// still hit-tests); only its contents are hover-revealed, which keeps the
    /// rail's resting state free of chrome without making the target jump.
    private var newSessionRow: some View {
        Menu {
            launchMenu(project)
        } label: {
            HStack(spacing: QuietRailMetrics.markGap) {
                Image(systemName: "plus")
                    .font(.system(size: QuietRailMetrics.plusText, weight: .semibold))
                    .frame(width: QuietRailMetrics.mark, height: QuietRailMetrics.mark)
                Text("New session")
                    .font(.system(size: QuietRailMetrics.titleText))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(.leading, QuietRailMetrics.sessionIndent)
            .padding(.trailing, QuietRailMetrics.trailingInset)
            .frame(height: QuietRailMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(hovering || hoveringLaunchRow ? 1 : 0)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { inside in
            withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) { hoveringLaunchRow = inside }
        }
        .help("New session in \(project.name)")
        .accessibilityLabel("New session in \(project.name)")
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: Rows

    private func sessionRow(
        _ record: BrokerTerminalRecord,
        ordinal: Int,
        status: QuietSessionStatus
    ) -> some View {
        let processName = model.meta(for: record.id)?.processName
        return QuietSurfaceRowView(
            identity: QuietIdentity.identity(
                agentName: model.agentProfile(for: record.id)?.name,
                processName: processName
            ),
            title: QuietRailTitle.displayTitle(
                rawTitle: model.sessionTitle(for: record),
                projectName: project.name,
                processName: processName,
                ordinal: ordinal
            ),
            status: status,
            timeLabel: timeLabel(record.id),
            isSelected: model.isSurfaceVisible(record.id),
            tooltip: tooltip(for: record),
            select: { selectSession(record) },
            reveal: { model.revealSurfaceBeside(record.id) },
            menu: { sessionMenu(record) }
        )
    }

    private func chatRow(_ chat: AcpChatHandle, status: QuietSessionStatus) -> some View {
        QuietSurfaceRowView(
            identity: QuietIdentity.identity(agentName: chat.agentID, processName: nil),
            title: chat.conversation.title,
            status: status,
            timeLabel: timeLabel(chat.id),
            isSelected: model.isSurfaceVisible(chat.id),
            tooltip: chatTooltip(chat),
            select: { model.selectChat(chat.id) },
            reveal: { model.revealSurfaceBeside(chat.id) },
            menu: { chatMenu(chat) }
        )
    }

    private func meshRow(_ mesh: MeshSession, status: QuietSessionStatus) -> some View {
        QuietSurfaceRowView(
            identity: .mesh,
            title: mesh.title,
            status: status,
            timeLabel: timeLabel(mesh.id),
            isSelected: model.isSurfaceVisible(mesh.id),
            tooltip: mesh.stage == "Idle" ? "Mesh · Ready" : "Mesh · \(mesh.stage)",
            select: { model.selectMesh(mesh.id) },
            reveal: { model.revealSurfaceBeside(mesh.id) },
            menu: { meshMenu(mesh) }
        )
    }

    // MARK: Derivations

    private func timeLabel(_ id: String) -> String {
        guard let start = since(id) else { return "" }
        return QuietTimeLabel.label(since: start, now: now)
    }

    /// Everything the rollup and the expanded rows both need, derived once per
    /// body pass.
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

/// The chrome both project-row shapes share. A `ViewModifier` rather than a
/// helper function so the hover binding, the context menu (Move Up/Down ahead
/// of the host's destructive tail) and the list chrome stay defined once.
private struct QuietProjectRowChrome: ViewModifier {
    @Binding var hovering: Bool
    let isActive: Bool
    let expandLabel: String
    let toggle: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let menu: () -> AnyView
    let onAppear: () -> Void

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) { hovering = inside }
            }
            .contextMenu {
                // Move Up/Down come first so the destructive tail of the
                // passed-in project menu (Close Project) stays last in the
                // composed menu. ⌥↑/⌥↓ target the active project only, so a
                // menu opened on a non-active project never reorders the wrong
                // row.
                Button("Move Up") {
                    guard isActive else { return }
                    moveUp()
                }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .disabled(!isActive)
                Button("Move Down") {
                    guard isActive else { return }
                    moveDown()
                }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .disabled(!isActive)
                Divider()
                menu()
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text(expandLabel)) { toggle() }
            .onAppear { onAppear() }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Collapsed rollup

/// A project's whole story in one glance: how many surfaces are active, and
/// which states they are in. Amber (needs-you) sorts to the outer edge so the
/// eye finds it at the right margin without expanding anything.
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

/// The rail's only background fill: a neutral wash, inset from the rail edges.
/// Never tinted — colour in the sidebar means status, not identity.
private struct QuietSelectionWash: View {
    var body: some View {
        RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius, style: .continuous)
            .fill(Color.primary.opacity(QuietRailMetrics.washOpacity))
            .padding(.horizontal, 6)
    }
}

/// The tokens every surface row shares: identity mark, title, the hover-only
/// "open beside" control, time-in-state, dot. The dot always occupies its 6pt
/// slot even when it draws nothing, so the times stay in one column down the
/// whole rail.
private struct QuietRowBody: View {
    let identity: QuietIdentity
    let title: String
    let timeLabel: String
    let status: QuietSessionStatus
    let isSelected: Bool
    let showsReveal: Bool
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: QuietRailMetrics.markGap) {
            QuietIdentityMarkView(identity: identity)
            Text(title)
                .font(.system(size: QuietRailMetrics.titleText))
                .foregroundStyle(status.isDimmed ? HierarchicalShapeStyle.tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The only compressible token in the row; without this it loses
                // to its fixed-size siblings and truncates first.
                .layoutPriority(1)
            Spacer(minLength: 4)
            if showsReveal {
                // A `highPriorityGesture` rather than a nested Button: SwiftUI
                // gives a descendant's high-priority gesture precedence over the
                // enclosing Button's own gesture, while a Button (or Menu)
                // nested inside a button label is swallowed by it. The row keeps
                // an "Open beside" accessibility action for the paths this
                // pointer-only affordance cannot serve.
                Image(systemName: "square.split.2x1")
                    .font(.system(size: QuietRailMetrics.revealText, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { reveal() })
                    .help("Open beside (⌘-click the row)")
                    .accessibilityHidden(true)
            }
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
                QuietSelectionWash()
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

// MARK: - Surface row

/// One terminal, chat or mesh. Sessions, chats and meshes differ only in what
/// they do when pressed and which context menu they carry, so they share one
/// row: the identity mark already says which kind it is.
private struct QuietSurfaceRowView: View {
    let identity: QuietIdentity
    let title: String
    let status: QuietSessionStatus
    let timeLabel: String
    let isSelected: Bool
    let tooltip: String
    let select: () -> Void
    let reveal: () -> Void
    let menu: () -> AnyView

    @State private var hovering = false

    var body: some View {
        // A Button, not a tap gesture: a gesture is invisible to VoiceOver,
        // Full Keyboard Access and automation, so the row would expose no press
        // action. `.plain` keeps the row's own appearance.
        Button(action: press) {
            QuietRowBody(
                identity: identity,
                title: title,
                timeLabel: timeLabel,
                status: status,
                isSelected: isSelected,
                showsReveal: hovering,
                reveal: reveal
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: Text("Open beside")) { reveal() }
        .onHover { inside in
            withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) { hovering = inside }
        }
        .help(tooltip)
        .contextMenu { menu() }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// ⌘-click opens the surface beside the current one instead of replacing
    /// it. SwiftUI's Button action carries no event, so the modifier is read
    /// from `NSEvent.modifierFlags`, which is valid for the click being
    /// dispatched; VoiceOver's press path calls `select()` directly and is
    /// unaffected.
    private func press() {
        if NSEvent.modifierFlags.contains(.command) {
            reveal()
        } else {
            select()
        }
    }
}
