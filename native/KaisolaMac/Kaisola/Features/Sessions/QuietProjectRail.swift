import Combine
import SwiftUI

/// "Quiet fleet" v4.4 sidebar rail: **one** list of projects in the order the
/// user stored them, with the active project expanded in place — wherever it
/// sits — and every other project a compact one-line row that can be expanded
/// without stealing focus.
///
/// v1.1.8 removed the pinned-on-top information architecture. Pinning the
/// active project meant activating a project *moved* it, so the rail rearranged
/// itself under the pointer on the single most common action in the app and the
/// spatial memory the stored order exists to give you was destroyed by using
/// it. Activation now changes exactly two things: which row wears the tinted
/// capsule, and which row is expanded. Nothing moves. There is no second
/// section and therefore no "Projects" label above one — a single unbroken list
/// needs no heading, and the column already announces itself to assistive
/// technology through the List's own accessibility label.
///
/// Row grammar is unchanged: identity mark · title · time-in-state · dot at the
/// right edge, and idle rows draw no dot.
///
/// v1.1.7 removed the last of the rail's boxes. There is now **exactly one**
/// background fill in the whole sidebar — the active project's tinted glass
/// capsule. Surface rows have none at all: a visible session is signalled by
/// its title alone (primary, semibold) against `.secondary` regular for the
/// rest, and by the `.isSelected` accessibility trait, which is the only part
/// of "selected" assistive technology ever read out of the wash.
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
        Group {
            ForEach(projects) { project in
                group(
                    project,
                    placement: isActiveProject(project.id) ? .active : .compact
                )
            }
            // The dragged list IS the persisted list now, so the drag offsets
            // need no remapping around a pinned row — `QuietRailOrder` is down
            // to translating SwiftUI's before-the-move `toOffset` into the
            // after-the-removal index the store inserts at.
            .onMove { indices, target in
                guard let from = indices.first,
                      let move = QuietRailOrder.moveIndex(
                          orderedIDs: projects.map(\.id),
                          from: from,
                          to: target
                      ) else { return }
                model.moveProject(id: move.id, toIndex: move.toIndex)
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

// MARK: - Project drag mapping

/// Maps a drag in the project list onto the index
/// `AppModel.moveProject(id:toIndex:)` expects. Pure so the arithmetic can be
/// tested without a list.
///
/// This used to carry a *pinned offset*: the rail rendered the active project
/// on its own above a compact list that excluded it, so every drag index had to
/// be projected out of that shortened list and back into the persisted order,
/// with a special case for "dropped at the top of a list whose top is not the
/// top of the store". v1.1.8 renders one list in stored order, so the mapping is
/// direct and that entire class of off-by-one is gone rather than tested for.
enum QuietRailOrder {
    struct Move: Equatable {
        let id: String
        let toIndex: Int
    }

    /// - Parameters:
    ///   - orderedIDs: the persisted project order, which is also what is drawn.
    ///   - from: source index (SwiftUI `onMove` offsets).
    ///   - to: destination index, measured *before* the row is removed.
    /// - Returns: the project to move and its destination index in the order
    ///   with that project taken out — which is what the store's
    ///   remove-then-insert wants — or `nil` for a no-op or out-of-range drag.
    static func moveIndex(orderedIDs: [String], from: Int, to: Int) -> Move? {
        guard from >= 0, from < orderedIDs.count else { return nil }
        let destination = max(0, min(to, orderedIDs.count))
        // SwiftUI's `toOffset` is measured before the removal, so a drop past
        // the row's own slot lands one index lower once it is taken out; a drop
        // onto its own slot (or immediately after it) changes nothing.
        let landed = destination > from ? destination - 1 : destination
        guard landed != from else { return nil }
        return Move(id: orderedIDs[from], toIndex: landed)
    }
}

// MARK: - Metrics

/// Every size the rail uses. Text bottoms out at 10.5pt — no *label* in the
/// sidebar is smaller than the time label; symbol glyphs (the hover chevron and
/// `+`) may be smaller, since they carry no reading load.
private enum QuietRailMetrics {
    static let headerText: CGFloat = 13
    static let titleText: CGFloat = 13
    static let secondaryText: CGFloat = 10.5
    static let chevronText: CGFloat = 9
    static let plusText: CGFloat = 10
    /// The stacked-tile project mark. Drawn a shade larger than the old folder
    /// glyph because an outline mark carries less ink at the same point size.
    static let projectMarkText: CGFloat = 11.5
    static let revealText: CGFloat = 10
    /// Slot the hover-only "open beside" control occupies in the trailing lane.
    static let revealSlot: CGFloat = 16
    /// Identity slot and the gap between it and the label.
    static let mark: CGFloat = QuietIdentityMarkView.slot
    static let markGap: CGFloat = 8
    static let dot: CGFloat = 6
    /// A session sits a clear step in from its project row's leading edge.
    ///
    /// The v1.1.5 width-budget work cut the STEP (this minus the project row's
    /// own 8pt inset) to 18pt — one mark-width, a 10pt step the eye read as
    /// "slightly ragged" rather than "nested". v1.1.6 bought a 22pt step;
    /// v1.1.7 pushes the step to 32pt (two identity slots), which lands the
    /// indent itself — the constant below — at 40 (8pt inset + 32pt step)
    /// *while* the rail narrows to 228, which is the trade worth stating: at
    /// 228 a session title still gets 117.5pt — 17 characters of a real title
    /// — so the nesting is paid for out of the row's slack, not out of
    /// legibility. `QuietRowBudget` holds the arithmetic and a test holds the
    /// character count.
    static let sessionIndent: CGFloat = 40
    /// One cadence for every row in the rail: sessions, compact projects and
    /// the pinned project header all measure 32pt.
    static let rowHeight: CGFloat = 32
    static let horizontalInset: CGFloat = 8
    static let trailingInset: CGFloat = 10
    /// macOS's `List` reserves a fixed row inset (8pt leading, 9pt trailing)
    /// that `listRowInsets(EdgeInsets())` does *not* clear, and neither does
    /// `contentMargins`. At the 200pt default sidebar those 17pt were most of
    /// the difference between a title showing 7 characters and 16, so each row
    /// cancels the platform inset and divides the full column width itself —
    /// the rail already insets its own wash from the column edge.
    ///
    /// Degrades safely: were a future macOS to stop reserving the inset, the
    /// row would overhang its cell by these amounts and be clipped there, which
    /// costs only the row's own leading indent and trailing padding — the mark,
    /// title, time and dot all sit inside that margin.
    static let listRowBleed = EdgeInsets(top: 0, leading: -8, bottom: 0, trailing: -9)
    /// Gap inside the trailing lane (reveal · time · dot, or rollup · chevron).
    /// Tighter than `markGap` so the lane costs the title as little as possible.
    static let laneGap: CGFloat = 5
    /// How long a group keeps its hover state while the pointer crosses from
    /// one of its rows into the next. Without the grace period the row the
    /// pointer is travelling *to* can be removed before it arrives.
    static let hoverGrace: Double = 0.12
    static let pulseDuration: Double = 1.4
    /// The trailing slot the active header's `+` menu occupies.
    ///
    /// Reserved whether or not the menu is drawn. It used to be a plain sibling
    /// of a `maxWidth: .infinity` button, so the button claimed the whole row
    /// and the menu was laid out *past* the row's trailing edge — it rendered
    /// half outside the project row. A reserved slot is also what keeps the
    /// header's rollup from shifting sideways when the pointer arrives.
    static let plusSlot: CGFloat = 18
    /// Distance from the row's trailing edge to the `+` slot. Lands the slot
    /// just inside the active project's capsule, which is itself inset by
    /// `KaisolaVisualSystem.chromeInset`.
    static let plusTrailingInset: CGFloat = 10
}

/// What a surface row's title is actually given, derived from the same metrics
/// the row lays out with.
///
/// The rail's scarcest resource is title width, and it regressed silently: the
/// v1.1.4 row spent 30pt on its indent, four uniform 8pt gaps and a trailing
/// lane that could not be compressed, leaving a 200pt sidebar's title 56pt —
/// seven characters. Stating the budget as arithmetic gives that a test.
enum QuietRowBudget {
    /// Leading inset of a project row (active header or compact row).
    static let projectIndent: CGFloat = QuietRailMetrics.horizontalInset
    /// Leading inset of a surface row (session, chat, mesh) and of the rail's
    /// "New session" / "No activity yet" rows, which share the same column.
    static let sessionIndent: CGFloat = QuietRailMetrics.sessionIndent
    /// The hierarchy step: how much deeper a session's mark starts than its
    /// project's. Stated as arithmetic so "sessions must sit clearly deeper
    /// than project rows" is a test rather than a pair of literals that can
    /// drift back together the next time the title lane needs points.
    static var indentStep: CGFloat { sessionIndent - projectIndent }

    /// The slot the active project header reserves at its trailing edge for the
    /// `+` menu, and how far that slot sits in from the row's own edge.
    ///
    /// Exposed because the bug was geometric, not visual: the `+` used to be a
    /// bare sibling of a `maxWidth: .infinity` button, so it was laid out
    /// *past* the row and rendered cut in half. Reserving the slot is what
    /// makes containment structural, and `headerPlusReserved` is the number an
    /// accessibility frame check can be read against.
    static let headerPlusSlot: CGFloat = QuietRailMetrics.plusSlot
    static let headerPlusTrailingInset: CGFloat = QuietRailMetrics.plusTrailingInset
    static var headerPlusReserved: CGFloat { headerPlusSlot + headerPlusTrailingInset }

    /// - Parameters:
    ///   - sidebarWidth: the navigation column's width. Rows span it entirely;
    ///     see `QuietRailMetrics.listRowBleed`.
    ///   - timeLabelWidth: rendered width of the time-in-state label.
    ///   - showsReveal: whether the hover-only "open beside" control is drawn.
    /// - Returns: points left for the title once every fixed token is paid for.
    static func titleWidth(
        sidebarWidth: CGFloat,
        timeLabelWidth: CGFloat,
        showsReveal: Bool
    ) -> CGFloat {
        var lane = timeLabelWidth + QuietRailMetrics.laneGap + QuietRailMetrics.dot
        if showsReveal { lane += QuietRailMetrics.revealSlot + QuietRailMetrics.laneGap }
        return sidebarWidth
            - QuietRailMetrics.sessionIndent
            - QuietRailMetrics.trailingInset
            - QuietRailMetrics.mark
            - QuietRailMetrics.markGap
            // The spacer between the title and the lane, at its minimum — which
            // is where it sits whenever the title is long enough to truncate.
            - QuietRailMetrics.laneGap
            - lane
    }
}

/// How a project row is drawn. NOT where it sits — v1.1.8 decoupled those: the
/// active project is drawn `.active` in whatever slot the stored order gives it.
private enum QuietProjectPlacement {
    /// The project you are in: expanded, with its surfaces, on a tinted capsule.
    case active
    /// Any other project: one compact line, expandable in place.
    case compact
}

/// A project's leading mark: the stacked-tile glyph the v4 mock uses, in the
/// same 16pt slot a surface row's identity mark occupies, so project names and
/// session titles start on two consistent columns.
///
/// Deliberately not `folder`/`folder.fill`: a folder reads as a *file system*
/// row, and the rail's projects are workspaces. Only the active project's mark
/// carries the project tint — every other row's mark stays neutral so the tint
/// means "this is the project you are in" rather than "this is a project".
private struct QuietProjectMarkView: View {
    /// `nil` for a compact (non-active) row.
    let tint: Color?

    var body: some View {
        Image(systemName: "square.on.square")
            .font(.system(size: QuietRailMetrics.projectMarkText, weight: .regular))
            .foregroundStyle(tint ?? Color.secondary)
            .frame(width: QuietRailMetrics.mark, height: QuietRailMetrics.mark)
            .accessibilityHidden(true)
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
    /// Bumped on every hover transition anywhere in the group so a pending
    /// "leave" can tell whether the pointer actually left or merely crossed
    /// into the next row of the same group.
    @State private var hoverGeneration = 0
    /// Manual drag order, read from disk once per project so streamed output
    /// never turns a re-render into file I/O.
    @State private var manualOrder: [String] = []
    @State private var loadedOrder = false

    private var isActive: Bool { placement == .active }

    /// Hover is a property of the whole *group*, not of one row: the pointer
    /// travels across sibling rows on its way to the header's chrome, and a
    /// leave is deferred by one grace period so crossing a row boundary never
    /// removes the control the pointer is heading for.
    private func setHover(_ inside: Bool) {
        hoverGeneration &+= 1
        if inside {
            guard !hovering else { return }
            withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) { hovering = true }
            return
        }
        let generation = hoverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + QuietRailMetrics.hoverGrace) {
            guard generation == hoverGeneration, hovering else { return }
            withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) { hovering = false }
        }
    }

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
            }
        }
    }

    // MARK: Header

    private func header(statuses: [String: QuietSessionStatus]) -> some View {
        Group {
            switch placement {
            case .active: activeHeader(statuses: statuses)
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

    /// The active project, drawn on its own tinted glass capsule *in place*.
    ///
    /// This is the one place in the rail where colour is *identity* rather than
    /// status, and it is deliberate: the capsule is what says "this is the
    /// project you are in". Its language is the approved v1.1.6 mock's —
    /// a shallow tint gradient, a lit top edge and a hairline tint stroke (see
    /// `QuietActiveGlass`) — restrained enough that the status dots two columns
    /// over still read first. Name and mark keep the same tint, so the row is
    /// one object rather than a coloured box with grey contents.
    private func activeHeader(statuses: [String: QuietSessionStatus]) -> some View {
        // Spacing 0: the `+` slot below carries its own trailing inset, and a
        // stack gap on top of it would push the menu back out of the row.
        HStack(spacing: 0) {
            // A real Button, not a tap gesture: it is what gives the header a
            // press action for VoiceOver, Full Keyboard Access and automation.
            // The `+` stays a SIBLING of the button rather than part of its
            // label, because a Menu nested inside a button label never receives
            // the click that opens it.
            Button {
                withAnimation(.easeInOut(duration: KaisolaVisualSystem.stateDuration)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 0) {
                    QuietProjectMarkView(tint: tint)
                        .padding(.trailing, QuietRailMetrics.markGap)
                    Text(project.name)
                        .font(.system(size: QuietRailMetrics.headerText, weight: .semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: QuietRailMetrics.laneGap)
                    HStack(spacing: QuietRailMetrics.laneGap) {
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
                    .fixedSize()
                }
                // The button's own label owns the full row geometry — height,
                // horizontal inset and width — so its hit area (and VoiceOver
                // frame) covers the entire 32pt row, not just the intrinsic
                // text height. Mirrors QuietRowBody's chain. Only the LEADING
                // inset is the label's: the trailing edge belongs to the `+`
                // slot below, which the button must stop short of.
                .padding(.leading, QuietRailMetrics.horizontalInset)
                .frame(height: QuietRailMetrics.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The row is both the section heading and its expand control, so the
            // header trait moves onto the button rather than being lost inside
            // the (now combined) label.
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(project.id)
            // The `+` sits in a slot the header always reserves, so it can only
            // ever be laid out INSIDE the row. As a bare sibling of a
            // `maxWidth: .infinity` button it was pushed past the row's trailing
            // edge and rendered clipped in half.
            ZStack {
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
            .frame(width: QuietRailMetrics.plusSlot, height: QuietRailMetrics.rowHeight)
            .padding(.trailing, QuietRailMetrics.plusTrailingInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background { QuietActiveProjectGlass(tint: tint) }
        .modifier(projectRowChrome)
    }

    /// Every other project: one line, no wash, expandable in place.
    private func compactRow(statuses: [String: QuietSessionStatus]) -> some View {
        HStack(spacing: 6) {
            Button(action: activate) {
                HStack(spacing: 0) {
                    QuietProjectMarkView(tint: nil)
                        .padding(.trailing, QuietRailMetrics.markGap)
                    Text(project.name)
                        .font(.system(size: QuietRailMetrics.headerText))
                        .foregroundStyle(HierarchicalShapeStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: QuietRailMetrics.laneGap)
                    QuietRollupView(rollup: QuietRollup.of(Array(statuses.values)))
                        .fixedSize()
                }
                .padding(.leading, QuietRailMetrics.horizontalInset)
                .frame(height: QuietRailMetrics.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(project.id)
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
            setHover: setHover,
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

    /// Activation moves nothing. The row keeps its slot in the stored order and
    /// simply becomes the one wearing the tinted capsule — v1.1.8's whole point.
    /// It does expand: a project opened collapsed would hide the surfaces the
    /// click was asking for.
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
            .contentShape(Rectangle())
            .onHover { inside in setHover(inside) }
            .listRowInsets(QuietRailMetrics.listRowBleed)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    // The hover-revealed "New session" ghost row is gone (v1.1.7). A row that
    // appears under the pointer whenever it crosses the group is a row that
    // pops at the user, and it was the rail's last piece of resting chrome.
    // Creation keeps four doors that do not move: the active header's `+` menu,
    // the project and session context menus, the File menu (⌘T), and the
    // command palette.

    // MARK: Rows

    private func sessionRow(
        _ record: BrokerTerminalRecord,
        ordinal: Int,
        status: QuietSessionStatus
    ) -> some View {
        let processName = model.meta(for: record.id)?.processName
        return QuietSurfaceRowView(
            id: record.id,
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
            groupHover: setHover,
            select: { selectSession(record) },
            reveal: { model.revealSurfaceBeside(record.id) },
            menu: { sessionMenu(record) }
        )
    }

    private func chatRow(_ chat: AcpChatHandle, status: QuietSessionStatus) -> some View {
        QuietSurfaceRowView(
            id: chat.id,
            identity: QuietIdentity.identity(agentName: chat.agentID, processName: nil),
            title: chat.conversation.title,
            status: status,
            timeLabel: timeLabel(chat.id),
            isSelected: model.isSurfaceVisible(chat.id),
            tooltip: chatTooltip(chat),
            groupHover: setHover,
            select: { model.selectChat(chat.id) },
            reveal: { model.revealSurfaceBeside(chat.id) },
            menu: { chatMenu(chat) }
        )
    }

    private func meshRow(_ mesh: MeshSession, status: QuietSessionStatus) -> some View {
        QuietSurfaceRowView(
            id: mesh.id,
            identity: .mesh,
            title: mesh.title,
            status: status,
            timeLabel: timeLabel(mesh.id),
            isSelected: model.isSurfaceVisible(mesh.id),
            tooltip: mesh.stage == "Idle" ? "Mesh · Ready" : "Mesh · \(mesh.stage)",
            groupHover: setHover,
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
    /// The group owns the hover state (and its leave grace period), so the row
    /// reports into it rather than writing a binding directly.
    let setHover: (Bool) -> Void
    let isActive: Bool
    let expandLabel: String
    let toggle: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let menu: () -> AnyView
    let onAppear: () -> Void

    func body(content: Content) -> some View {
        content
            .onHover { inside in setHover(inside) }
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
            .listRowInsets(QuietRailMetrics.listRowBleed)
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

/// How a surface row says it is the one on screen — with no box at all.
///
/// v1.1.7 deleted `QuietSelectionWash`, the rounded grey rectangle that used to
/// sit under a visible row. A wash is a second selection language competing
/// with the active project's capsule, and stacked down a column of five rows it
/// turned the rail back into a list of chips. What is left is the least a row
/// can say and still be found: the title's own weight and colour.
///
/// Stated as a table rather than inline ternaries so "the ONLY difference is
/// type" is a testable claim.
enum QuietRowEmphasis {
    /// The visible surface: full ink, semibold.
    static let selectedWeight: Font.Weight = .semibold
    /// Everything else in the rail: regular, one step back.
    static let restingWeight: Font.Weight = .regular

    static func weight(isSelected: Bool) -> Font.Weight {
        isSelected ? selectedWeight : restingWeight
    }
}

/// Every number the active project's tinted glass capsule is made of.
///
/// Stated as one table rather than inline literals because the whole risk of
/// this treatment is drift toward candy: each value is the *ceiling* the mock
/// approved, and the relationships between them (top heavier than bottom, the
/// lit edge brighter in light mode than in dark, every value well under half)
/// are what keep it reading as glass rather than as a coloured chip. Tested.
enum QuietActiveGlass {
    /// Tint alpha at the capsule's top edge…
    static let topFillOpacity: Double = 0.18
    /// …and at its bottom, so the fill falls away rather than sitting flat.
    static let bottomFillOpacity: Double = 0.08
    /// Hairline tint stroke: enough to draw the capsule's edge against a busy
    /// wallpaper, not enough to outline it.
    static let strokeOpacity: Double = 0.26
    /// The 1pt lit top edge that makes the capsule read as a reflective
    /// surface. Light mode can carry a bright specular; dark mode cannot —
    /// white at that strength on a dark rail reads as a seam, not a highlight.
    static func highlightOpacity(dark: Bool) -> Double { dark ? 0.12 : 0.35 }
    /// Where the highlight has faded to nothing, as a fraction of row height.
    /// It is a *top* highlight: past this point the capsule is only its tint.
    static let highlightFalloff: Double = 0.5
}

/// The active project's tint as a reflective glass capsule.
///
/// Three layers, cheapest first: a vertical tint gradient, a hairline tint
/// stroke on the border, and a 1pt white inner edge along the top that fades
/// out by mid-row. No material and no blur — the sidebar's backdrop is already
/// one live layer (v1.1.5) and stacking a second one here is exactly the cost
/// that got the old four-layer sidebar card deleted.
private struct QuietActiveProjectGlass: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius, style: .continuous)
    }

    private var highlight: Color {
        .white.opacity(QuietActiveGlass.highlightOpacity(dark: colorScheme == .dark))
    }

    var body: some View {
        shape
            .fill(
                LinearGradient(
                    colors: [
                        tint.opacity(QuietActiveGlass.topFillOpacity),
                        tint.opacity(QuietActiveGlass.bottomFillOpacity),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // `strokeBorder`, not `stroke`: the hairline has to sit inside the
            // capsule, or half of it lands on the neighbouring row's pixels.
            .overlay { shape.strokeBorder(tint.opacity(QuietActiveGlass.strokeOpacity), lineWidth: 1) }
            .overlay {
                shape
                    .inset(by: 0.5)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: highlight, location: 0),
                                .init(color: highlight.opacity(0), location: QuietActiveGlass.highlightFalloff),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
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
        // Spacing is 0 and every gap is explicit: a uniform `HStack` spacing
        // charged the title for four gaps, three of which sat inside the
        // trailing lane where they bought nothing.
        HStack(spacing: 0) {
            QuietIdentityMarkView(identity: identity)
                .padding(.trailing, QuietRailMetrics.markGap)
            Text(title)
                .font(.system(size: QuietRailMetrics.titleText, weight: QuietRowEmphasis.weight(isSelected: isSelected)))
                // Three steps, and type carries all of them: an ended row is
                // tertiary, the row you are looking at is primary semibold,
                // everything else is secondary regular. No fill anywhere.
                .foregroundStyle(titleStyle)
                .lineLimit(1)
                .truncationMode(.tail)
                // The only compressible token in the row; without this it loses
                // to its fixed-size siblings and truncates first.
                .layoutPriority(1)
            Spacer(minLength: QuietRailMetrics.laneGap)
            trailingLane
        }
        .padding(.leading, QuietRailMetrics.sessionIndent)
        .padding(.trailing, QuietRailMetrics.trailingInset)
        .frame(height: QuietRailMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // No `.background` at all. The row draws nothing behind itself in any
        // state; `.isSelected` on the enclosing Button is what assistive
        // technology reads, and it is unaffected by the wash's removal.
        //
        // Deliberately NOT `.accessibilityElement(children: .combine)` here:
        // that would make this the row's own isolated accessibility node,
        // nested *inside* the enclosing Button in `QuietSurfaceRowView`
        // rather than merged into it — System Events then sees a button with
        // AXPress but no AXTitle, since the label lives on a child it never
        // descends into. The combine + label live on the Button itself.
    }

    private var titleStyle: HierarchicalShapeStyle {
        if status.isDimmed { return .tertiary }
        return isSelected ? .primary : .secondary
    }

    /// Reveal, time-in-state and dot travel as ONE `fixedSize` lane.
    ///
    /// They used to be free-floating `HStack` children at the default layout
    /// priority, which let the row's leftover width land on the `Spacer` while
    /// the time label was compressed *below the width of its own first glyph*:
    /// the label then rendered as a ~2pt vertical sliver of a digit at the
    /// row's trailing edge, which read as a stray "{". Sizing the lane first
    /// and never compressing it means the label either fits whole or the title
    /// (the only flexible token left) gives up the space.
    private var trailingLane: some View {
        HStack(spacing: QuietRailMetrics.laneGap) {
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
                    .frame(width: QuietRailMetrics.revealSlot, height: QuietRailMetrics.revealSlot)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { reveal() })
                    .help("Open beside (⌘-click the row)")
                    .accessibilityHidden(true)
            }
            // An empty label must not reserve a lane slot; `Text("")` still
            // costs the lane a gap.
            if !timeLabel.isEmpty {
                Text(timeLabel)
                    .font(.system(size: QuietRailMetrics.secondaryText).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            QuietStatusDot(status: status)
        }
        .fixedSize()
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
    /// The surface's stable id (session/chat/mesh id). Carried onto the row's
    /// `accessibilityIdentifier` so scripted automation (System Events, XCUITest)
    /// can address a specific row without depending on its visible title.
    let id: String
    let identity: QuietIdentity
    let title: String
    let status: QuietSessionStatus
    let timeLabel: String
    let isSelected: Bool
    let tooltip: String
    /// Reports this row's hover into its project group's shared `hovering`
    /// flag (see `setHover`), which is what keeps the header's hover-only
    /// chevron and "+" menu (`activeHeader`/`compactRow`) visible while the
    /// pointer is anywhere among the group's rows, not just resting on the
    /// header itself.
    let groupHover: (Bool) -> Void
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
        // The label lives on the Button itself, not on the nested `QuietRowBody`:
        // a label declared on a child that is its own `.accessibilityElement`
        // never surfaces as the Button's AXTitle/description, which left
        // System Events seeing a row with AXPress but no readable title.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
        .accessibilityAction { select() }
        .accessibilityAction(named: Text("Open beside")) { reveal() }
        .onHover { inside in
            groupHover(inside)
            withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) { hovering = inside }
        }
        .help(tooltip)
        .contextMenu { menu() }
        .listRowInsets(QuietRailMetrics.listRowBleed)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// A row with no time-in-state yet must not read as "…, idle, " — the
    /// components are joined only when they carry something.
    private var accessibilityLabel: String {
        [title, status.accessibilityWord ?? "idle", timeLabel]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
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
