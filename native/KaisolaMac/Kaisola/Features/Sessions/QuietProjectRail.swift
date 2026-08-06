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
/// it. Activation now changes exactly two things: which row is drawn bold, and
/// which row is expanded. Nothing moves. There is no second section and
/// therefore no "Projects" label above one — a single unbroken list needs no
/// heading, and the column already announces itself to assistive technology
/// through the List's own accessibility label.
///
/// Row grammar is unchanged: identity mark · title · time-in-state · dot at the
/// right edge, and idle rows draw no dot.
///
/// v1.1.9 settles which row carries a fill, and it is not the project's.
///
/// The active project used to wear a tinted gradient glass capsule. A project
/// row is a *heading*, and a heading that is also the loudest painted object in
/// the column competes with the thing the column exists to point at — the
/// surface you are actually looking at. The active project is now signalled by
/// **weight alone**: bold against regular, with the 36pt session indent
/// carrying the hierarchy. No capsule, no gradient, no tint fill, no stroke.
///
/// The single fill in the rail moved to the selected surface row, Safari's
/// sidebar grammar: the row on screen draws its title in the user's accent
/// colour on a soft neutral pill (`QuietSelectionPill`), every other row is
/// plain `.secondary`. This supersedes v1.1.7's "no washes anywhere" — that
/// pass removed the wash while the project capsule stayed, which left the
/// loudest object in the column on the row that mattered least. Exactly one row
/// is selected at a time (`QuietRowSelection`), and the `.isSelected`
/// accessibility trait rides the same rule.
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
    /// The active header's `+` offers creation only; destructive project actions
    /// stay in the row's context menu. Its contents (New Terminal, the agent
    /// terminals, Chat, Mesh) are the host's — the rail only decides where the
    /// control sits and when it is drawn.
    private let launchMenu: (AppModel.ProjectGroup) -> AnyView
    private let projectMenu: (AppModel.ProjectGroup) -> AnyView
    private let sessionMenu: (BrokerTerminalRecord) -> AnyView
    private let chatMenu: (AcpChatHandle) -> AnyView
    private let meshMenu: (MeshSession) -> AnyView
    private let deleteRecentlyClosed: (AppModel.RecentlyClosedSurface) -> Void

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
        meshContextMenu: @escaping (MeshSession) -> AnyView,
        deleteRecentlyClosed: @escaping (AppModel.RecentlyClosedSurface) -> Void
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
        self.deleteRecentlyClosed = deleteRecentlyClosed
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
            meshMenu: meshMenu,
            deleteRecentlyClosed: deleteRecentlyClosed
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
enum QuietRailMetrics {
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
    /// v1.1.7 pushed the step to 32pt (two identity slots), landing this
    /// constant at 40 while the rail narrowed to 228.
    ///
    /// v1.1.8 narrows the rail again, 228 → 210, and that is where the trade
    /// finally bites: at 210 with a 40pt indent a session title gets 99.5pt,
    /// which renders **14** characters of a real title — under the 15-character
    /// floor `QuietIdentityMarkTests` holds. The indent gives the 4pt back
    /// rather than the title doing so: at 36 (8pt inset + a 28pt step) the title
    /// gets 103.5pt and 15 characters survive. 28pt is still comfortably past
    /// one identity slot, so a session's mark still starts well beyond where its
    /// project's mark ends — the nesting reads, it is simply no longer two full
    /// slots. `QuietRowBudget` holds the arithmetic and a test holds the
    /// character count.
    static let sessionIndent: CGFloat = 36
    /// One cadence for every row in the rail: sessions, compact projects and
    /// the active project header all measure 32pt.
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
    ///
    /// 10 → 12 in v1.1.10, when the active header's `+` stopped being
    /// hover-only. The sidebar's resize corridor is an *overlay* on the trailing
    /// edge of the List and reaches `NativeWorkspaceChrome.projectSidebarDividerReach`
    /// (10.5pt) inward, so at 10 the corridor sat over the last half-point of
    /// the `+` slot — already noted in `RootShellView` as a known ~1.5pt overlap
    /// and left alone while the control only existed under the pointer. A
    /// permanent control that is now *the* way to make a session cannot share
    /// its edge with a drag handle, so the slot moves inside the reach instead.
    static let plusTrailingInset: CGFloat = 12
}

/// Which of the project header's trailing controls are drawn, given the row's
/// placement and whether the pointer is inside the group.
///
/// Pure so "creating a session is always one click away" is a test rather than
/// a `if hovering` that the next layout pass can quietly re-add.
enum QuietProjectHeaderControls {
    /// The `+` launch menu.
    ///
    /// Permanent on the **active** project, hover-only on every other row.
    ///
    /// v1.1.7 removed the rail's last resting chrome and left creation four
    /// doors, all of them either hidden or remembered: this `+` (revealed on
    /// hover), the project and session context menus, ⌘T, and the command
    /// palette. Michael's round-2 note is that this is the wrong trade — "make
    /// it easier to open new sessions" — and it is the wrong trade specifically
    /// on the row you are already working in. Exactly one project is active at a
    /// time, so making its `+` permanent adds exactly one 18pt glyph to the
    /// whole rail: the app's most common action becomes visible without the
    /// column acquiring a control per row.
    ///
    /// Inactive projects keep the hover rule, and today they draw no `+` at all
    /// — creating a session in a project you are not in goes through that row's
    /// context menu. The rule is stated for both placements anyway so that a
    /// future compact `+` cannot arrive as a *resting* one: one permanent glyph
    /// in the whole rail is a control, one per row is a toolbar.
    static func showsLaunchControl(isActive: Bool, hovering: Bool) -> Bool {
        isActive || hovering
    }

    /// Accessibility identifier for the active project's launch menu, so its
    /// presence-without-hover can be asserted from outside the process.
    static let launchIdentifier = "rail.new-session"

    /// The expand/collapse chevron stays hover-only in both placements: the
    /// whole row is already the disclosure control, so the glyph is a hint
    /// rather than the only way in.
    static func showsDisclosureChevron(hovering: Bool) -> Bool { hovering }
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
    /// The project you are in: expanded, with its surfaces, and drawn bold.
    case active
    /// Any other project: one compact line, expandable in place.
    case compact
}

/// How a project row says it is the one you are in — with type, and nothing
/// else.
///
/// Stated as a table for the same reason `QuietRowEmphasis` is: "the ONLY
/// difference between the active project and every other one is weight" has to
/// be a testable claim, not a pair of literals two hundred lines apart that a
/// later pass can quietly re-tint.
enum QuietProjectEmphasis {
    /// The project you are in.
    static let activeWeight: Font.Weight = .bold
    /// Every other project.
    static let restingWeight: Font.Weight = .regular

    static func weight(isActive: Bool) -> Font.Weight {
        isActive ? activeWeight : restingWeight
    }
}

/// A project's leading mark: the stacked-tile glyph the v4 mock uses, in the
/// same 16pt slot a surface row's identity mark occupies, so project names and
/// session titles start on two consistent columns.
///
/// A **folder**, at Michael's direction. This mark used to be
/// `square.on.square` on the argument that a folder reads as a *file system*
/// row while the rail's projects are workspaces. That distinction turns out to
/// be one the rail does not need to draw: every project here *is* a directory
/// on disk, it is the one the sessions beneath it run in, and the stacked
/// squares read as "duplicate" far more readily than as "workspace". It also
/// now agrees with the Files rail, which has drawn folders as folders all
/// along.
///
/// Only the active project's mark carries the project tint — every other row's
/// mark stays neutral, so the tint means "this is the project you are in"
/// rather than "this is a project".
private struct QuietProjectMarkView: View {
    /// `nil` for a compact (non-active) row.
    let tint: Color?

    var body: some View {
        Image(systemName: "folder")
            .font(.system(size: QuietRailMetrics.projectMarkText, weight: .regular))
            .foregroundStyle(tint ?? Color.secondary)
            .frame(width: QuietRailMetrics.mark, height: QuietRailMetrics.mark)
            .accessibilityHidden(true)
    }
}

// MARK: - Project group

/// One project. Pinned: a 32pt header carrying the project's tinted name, a
/// resting `+` that opens the launch menu, and its chats/meshes/sessions
/// beneath.
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
    let deleteRecentlyClosed: (AppModel.RecentlyClosedSurface) -> Void

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
        let recentlyClosed = model.recentlyClosedSurfaces(in: project.id)
        // `AppModel.projects` already returns each group's sessions in pinned
        // order, so the manual drag order is the only sort applied here.
        let sessions = SessionOrderStore.apply(manualOrder, to: project.sessions)
        let statuses = statusMap(sessions: sessions, chats: chats, meshes: meshes)

        // One row wears the selection pill; every other row that is *also* on
        // screen wears a quieter one.
        //
        // A split shows two surfaces at once, and the rail used to mark only
        // the focused one — so the second pane sat beside the first looking
        // closed. Michael: "there is a bug with the double clicked/viewing
        // multiple tabs." The rail already knew the whole visible set; it was
        // collapsing it to a single id before drawing.
        let onScreen = onScreenSurfaceIDs(chats: chats, meshes: meshes, sessions: sessions)
        let selected = QuietRowSelection.selectedID(
            visibleIDs: onScreen,
            focusedPaneID: model.focusedPaneID
        )

        Group {
            header(statuses: statuses)
            if isExpanded {
                ForEach(chats) { chat in
                    chatRow(chat, status: statuses[chat.id] ?? .idle, selected: selected, onScreen: onScreen)
                }
                ForEach(meshes) { mesh in
                    meshRow(mesh, status: statuses[mesh.id] ?? .idle, selected: selected, onScreen: onScreen)
                }
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    sessionRow(
                        session,
                        ordinal: index + 1,
                        status: statuses[session.id] ?? .idle,
                        selected: selected,
                        onScreen: onScreen
                    )
                }
                .onMove { indices, target in
                    var ids = sessions.map(\.id)
                    ids.move(fromOffsets: indices, toOffset: target)
                    manualOrder = ids
                    orderStore.setOrder(projectID: project.id, ids: ids)
                }
                if !recentlyClosed.isEmpty {
                    recentlyClosedRow(recentlyClosed)
                }
                if sessions.isEmpty, chats.isEmpty, meshes.isEmpty, recentlyClosed.isEmpty {
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

    /// The active project, drawn bold *in place*.
    ///
    /// No capsule, no gradient, no tint fill and no stroke: the row paints
    /// nothing behind itself in any state. What says "this is the project you
    /// are in" is the name's weight, and — one row down — the sessions the
    /// expansion reveals at their 36pt indent. The project's own tint survives
    /// on its 11.5pt identity mark, which is a colour *label* rather than a
    /// highlight; nothing else in the row is coloured.
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
                        .font(.system(
                            size: QuietRailMetrics.headerText,
                            weight: QuietProjectEmphasis.weight(isActive: true)
                        ))
                        .foregroundStyle(HierarchicalShapeStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: QuietRailMetrics.laneGap)
                    HStack(spacing: QuietRailMetrics.laneGap) {
                        if !isExpanded {
                            QuietRollupView(rollup: QuietRollup.of(Array(statuses.values)))
                        }
                        if QuietProjectHeaderControls.showsDisclosureChevron(hovering: hovering) {
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
            //
            // On the active project it is drawn at rest — see
            // `QuietProjectHeaderControls.showsLaunchControl`. It is the rail's
            // only piece of resting chrome and it buys the app's most common
            // action; everything else in the column still appears only under the
            // pointer.
            ZStack {
                if QuietProjectHeaderControls.showsLaunchControl(
                    isActive: isActive,
                    hovering: hovering
                ) {
                    Menu {
                        launchMenu(project)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: QuietRailMetrics.plusText, weight: .semibold))
                            // `.secondary` at rest, not `.primary`: present
                            // enough to find without competing with the project
                            // name beside it, which is the row's actual subject.
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New session in \(project.name)")
                    .accessibilityLabel("New session in \(project.name)")
                    .accessibilityIdentifier(QuietProjectHeaderControls.launchIdentifier)
                }
            }
            .frame(width: QuietRailMetrics.plusSlot, height: QuietRailMetrics.rowHeight)
            .padding(.trailing, QuietRailMetrics.plusTrailingInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
                        .font(.system(
                            size: QuietRailMetrics.headerText,
                            weight: QuietProjectEmphasis.weight(isActive: false)
                        ))
                        .foregroundStyle(HierarchicalShapeStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: QuietRailMetrics.laneGap)
                    // The rollup summarises rows you cannot see. Once the
                    // project is expanded you can see them, and every working
                    // agent is already saying so on its own row — so the
                    // header's "1 ●" is the same news printed twice, on two
                    // lines that sit directly above one another. The hover
                    // lane already made this call; the resting lane did not.
                    if !isExpanded {
                        QuietRollupView(rollup: QuietRollup.of(Array(statuses.values)))
                            .fixedSize()
                    }
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
    /// simply becomes the bold one — v1.1.8's whole point.
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

    private func recentlyClosedRow(_ surfaces: [AppModel.RecentlyClosedSurface]) -> some View {
        Menu {
            if let newest = surfaces.first {
                Button("Undo Last Close") { restoreRecentlyClosed(newest.id) }
                Divider()
            }
            ForEach(surfaces) { surface in
                Menu(surface.title) {
                    Button("Restore") { restoreRecentlyClosed(surface.id) }
                    Button("Delete Permanently…", role: .destructive) {
                        deleteRecentlyClosed(surface)
                    }
                }
            }
        } label: {
            HStack(spacing: QuietRailMetrics.markGap) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: QuietRailMetrics.projectMarkText))
                    .foregroundStyle(.secondary)
                    .frame(width: QuietRailMetrics.mark)
                Text("Recently Closed")
                    .lineLimit(1)
                Spacer(minLength: QuietRailMetrics.laneGap)
                Text("\(surfaces.count)")
                    .font(.system(size: QuietRailMetrics.secondaryText).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: QuietRailMetrics.secondaryText, weight: .medium))
            .padding(.leading, QuietRailMetrics.sessionIndent)
            .padding(.trailing, QuietRailMetrics.trailingInset)
            .frame(height: QuietRailMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Restore or permanently delete closed chats and Mesh runs")
        .accessibilityLabel("Recently Closed, \(surfaces.count) items")
        .onHover { inside in setHover(inside) }
        .listRowInsets(QuietRailMetrics.listRowBleed)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func restoreRecentlyClosed(_ id: String) {
        Task {
            switch await model.restoreRecentlyClosedSurface(id) {
            case .completed, .unavailable:
                break
            case .needsConfirmation:
                break
            case let .blocked(message):
                ToastCenter.shared.show(message, style: .error, duration: 5)
            }
        }
    }

    // The hover-revealed "New session" ghost row is gone (v1.1.7) and is not
    // coming back. A row that appears under the pointer whenever it crosses the
    // group is a row that pops at the user, and it moves the rows below it while
    // the pointer is travelling.
    //
    // v1.1.10 answers "make it easier to open new sessions" the other way: the
    // active header's `+` is simply drawn at rest (see
    // `QuietProjectHeaderControls.showsLaunchControl`) rather than a second
    // affordance being added beside it. One glyph, in the row the user is
    // already in, that does not move and does not appear or disappear. The other
    // doors are unchanged: the project and session context menus, the File menu
    // (⌘T), and the command palette.

    // MARK: Rows

    /// The one surface in this group that is drawn as selected, or `nil`.
    ///
    /// Only the active project can own the selection — every other project's
    /// pane layout is a memory of where its surfaces *were*, not what is on
    /// screen — and inside it the focused pane wins, so a split highlights the
    /// pane you are typing in rather than both of its rows.
    /// Every surface of this project currently on screen, in draw order.
    private func onScreenSurfaceIDs(
        chats: [AcpChatHandle],
        meshes: [MeshSession],
        sessions: [BrokerTerminalRecord]
    ) -> [String] {
        guard isActive else { return [] }
        let ids = chats.map(\.id) + meshes.map(\.id) + sessions.map(\.id)
        return ids.filter { model.isSurfaceVisible($0) }
    }

    private func sessionRow(
        _ record: BrokerTerminalRecord,
        ordinal: Int,
        status: QuietSessionStatus,
        selected: String?,
        onScreen: [String]
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
            isSelected: selected == record.id,
            isOnScreen: onScreen.contains(record.id),
            tooltip: tooltip(for: record),
            groupHover: setHover,
            select: { selectSession(record) },
            reveal: { model.revealSurfaceBeside(record.id) },
            menu: { sessionMenu(record) }
        )
    }

    private func chatRow(_ chat: AcpChatHandle, status: QuietSessionStatus, selected: String?, onScreen: [String]) -> some View {
        QuietSurfaceRowView(
            id: chat.id,
            identity: QuietIdentity.identity(agentName: chat.agentID, processName: nil),
            title: chat.conversation.title,
            status: status,
            timeLabel: timeLabel(chat.id),
            isSelected: selected == chat.id,
            isOnScreen: onScreen.contains(chat.id),
            tooltip: chatTooltip(chat),
            groupHover: setHover,
            select: { model.selectChat(chat.id) },
            reveal: { model.revealSurfaceBeside(chat.id) },
            menu: { chatMenu(chat) }
        )
    }

    private func meshRow(_ mesh: MeshSession, status: QuietSessionStatus, selected: String?, onScreen: [String]) -> some View {
        QuietSurfaceRowView(
            id: mesh.id,
            identity: .mesh,
            title: mesh.title,
            status: status,
            timeLabel: timeLabel(mesh.id),
            isSelected: selected == mesh.id,
            isOnScreen: onScreen.contains(mesh.id),
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
        // Adopted terminals name their provenance — a moved session must never
        // silently pass as native to the project showing it.
        if model.sessionAdoptions[record.id] != nil {
            let home = model.projects.first(where: { $0.id == record.projectID })?.name
                ?? record.projectID
            parts.append("via \(home)")
        }
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
                QuietStatusMark(status: state, size: QuietRailMetrics.dot)
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

/// How a surface row says it is the one on screen.
///
/// v1.1.7 deleted `QuietSelectionWash` on the grounds that a wash was "a second
/// selection language competing with the active project's capsule". v1.1.9
/// resolves that competition the other way round: the capsule is gone (a
/// project row is a heading, see `QuietProjectEmphasis`) and the fill it freed
/// moves onto the row it was always meant to mark — the surface you are looking
/// at. That is Safari's sidebar grammar, and it is what the rail is measured
/// against: accent-coloured label on a soft neutral pill, everything else plain.
///
/// Stated as a table rather than inline ternaries so "selected differs from
/// resting in exactly these three tokens" is a testable claim.
enum QuietRowEmphasis {
    /// The visible surface: accent ink, semibold.
    ///
    /// Weight is kept as a *second* cue on top of the colour. The pill and the
    /// accent both vanish for a user who cannot separate the hues (or who has
    /// set a low-contrast accent); the weight does not, and it costs nothing.
    static let selectedWeight: Font.Weight = .semibold
    /// Everything else in the rail: regular, one step back.
    static let restingWeight: Font.Weight = .regular

    static func weight(isSelected: Bool) -> Font.Weight {
        isSelected ? selectedWeight : restingWeight
    }
}

/// Which surface row is drawn as selected.
///
/// Pure, because "exactly one row at a time" is a rule and not a rendering
/// detail — and because the two ways it can break are both invisible in a
/// screenshot of the happy path: a split makes two surfaces visible at once,
/// and a project that is not the active one can still carry a stored pane
/// layout from the last time you were in it. Callers pass only the ids that
/// belong to the project actually on screen.
enum QuietRowSelection {
    /// - Parameters:
    ///   - visibleIDs: surfaces of the active project that are on screen, in
    ///     the order the rail draws them.
    ///   - focusedPaneID: the pane holding focus, if any.
    /// - Returns: the single id that wears the pill, or `nil` when nothing of
    ///   this project is on screen.
    static func selectedID(visibleIDs: [String], focusedPaneID: String?) -> String? {
        guard !visibleIDs.isEmpty else { return nil }
        // The focused pane wins a split. It is deliberately checked against the
        // visible set rather than trusted: focus can still name a surface that
        // has since been hidden or that belongs to another window entirely, and
        // that must fall back to a real row rather than to no row at all.
        if let focusedPaneID, visibleIDs.contains(focusedPaneID) { return focusedPaneID }
        return visibleIDs.first
    }
}

/// Every number the selected row's pill is made of.
///
/// Neutral on purpose. The colour in this row is the *label*, in the user's own
/// accent; a tinted pill under tinted text is the coloured chip the v1.1.7 pass
/// was right to delete. The fill exists only to give the accent something to sit
/// on, which is why both values are single digits of opacity.
enum QuietSelectionPill {
    /// Light appearance: a whisper of the label colour's own ink.
    static let lightFillOpacity: Double = 0.06
    /// Dark appearance, where the same recipe would disappear: white, slightly
    /// stronger, because a dark rail swallows a 6% black.
    static let darkFillOpacity: Double = 0.10
    /// Shares the app's inset radius, so the pill is the same corner as every
    /// other rounded surface in the window.
    static var cornerRadius: CGFloat { KaisolaVisualSystem.insetRadius }
    /// Inset from the row's own edges, so the pill floats inside the column
    /// rather than reaching the sidebar's border.
    static let horizontalInset: CGFloat = 6
    /// How much of the pill a split's *other* pane wears.
    ///
    /// Both panes are genuinely on screen, so both are marked — but only one
    /// holds focus, and the rail must not present them as equals. Just over
    /// half reads as "also open" at a glance without competing with the row
    /// whose title is in the accent colour.
    static let companionOpacity: Double = 0.55

    static func fillOpacity(dark: Bool) -> Double { dark ? darkFillOpacity : lightFillOpacity }
}

/// The soft neutral pill under the selected surface row.
private struct QuietSelectionPillView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: QuietSelectionPill.cornerRadius, style: .continuous)
            .fill(fill)
            .padding(.horizontal, QuietSelectionPill.horizontalInset)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        let dark = colorScheme == .dark
        let base: Color = dark ? .white : .primary
        return base.opacity(QuietSelectionPill.fillOpacity(dark: dark))
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
    /// On screen, but not the pane holding focus.
    var isOnScreen = false
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
                // Three steps: the row you are looking at is the user's accent
                // colour, an ended row is tertiary, everything else is
                // secondary regular.
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
        // The rail's ONE fill, and only under the row on screen. `.isSelected`
        // on the enclosing Button carries the same fact to assistive
        // technology, so the pill is decoration and is hidden from it.
        // The focused row wears the pill; a companion pane in a split wears a
        // fainter one. A split used to mark only the focused surface, so the
        // other pane — equally on screen — was indistinguishable from a closed
        // session. The two states stay clearly ranked: colour and a full pill
        // for the row you are typing in, a quiet fill for the one beside it.
        .background {
            if isSelected {
                QuietSelectionPillView()
            } else if isOnScreen {
                QuietSelectionPillView().opacity(QuietSelectionPill.companionOpacity)
            }
        }
        // Deliberately NOT `.accessibilityElement(children: .combine)` here:
        // that would make this the row's own isolated accessibility node,
        // nested *inside* the enclosing Button in `QuietSurfaceRowView`
        // rather than merged into it — System Events then sees a button with
        // AXPress but no AXTitle, since the label lives on a child it never
        // descends into. The combine + label live on the Button itself.
    }

    /// Selection outranks dimming: an ended session you are still looking at is
    /// the row the sidebar is pointing at, and greying it would leave the pill
    /// under a title that reads as inactive.
    private var titleStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        // A companion pane is on screen, so it reads at full strength — but in
        // the primary ink rather than the accent, which stays the mark of the
        // one row you are typing in.
        if isOnScreen { return AnyShapeStyle(HierarchicalShapeStyle.primary) }
        if status.isDimmed { return AnyShapeStyle(HierarchicalShapeStyle.tertiary) }
        return AnyShapeStyle(HierarchicalShapeStyle.secondary)
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
            QuietStatusMark(status: status, size: QuietRailMetrics.dot)
                .opacity(pulsing ? 0.3 : 1)
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
    /// On screen, but not the pane holding focus.
    var isOnScreen = false
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
