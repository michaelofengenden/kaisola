import AppKit
import SwiftUI

/// How wide a Mesh column has to be before its transcript is worth reading.
///
/// Mesh reuses the single-chat transcript views, and three of those content
/// types set a hard floor. Each floor is measured from the font the view
/// actually renders with rather than written down as a constant, so a change of
/// type size — the user's or the system's — moves the threshold with it.
enum MeshColumnWidth {
    /// The code line a column must show without growing its own horizontal
    /// scrollbar: a full statement plus a two-column diff gutter. The
    /// transcript's own sample — `let renderer = TranscriptRenderer(cache:
    /// .incremental)` — is 53 characters, and it was the line clipped in the
    /// reproduction.
    static let codeLineCharacters = 54
    /// The workspace-relative path a tool row has to keep identifiable. Below
    /// this, "Inspect native/KaisolaMac/Kaisola/Mesh/MeshView.swift" collapses
    /// to "Inspect n…" and the row stops naming anything.
    static let toolPathCharacters = 44

    /// Transcript `LazyVStack` padding, both edges.
    static let transcriptInset: CGFloat = 10
    /// `AcpTranscriptCodeBlock` text padding, both edges.
    static let codeBlockInset: CGFloat = 10
    /// Vertical scroller plus the code block's rounded border.
    static let scrollerAllowance: CGFloat = 16
    /// Symbol, spacing, and the Stop/Diff/Integrate cluster in a column header.
    static let headerChrome: CGFloat = 92
    /// Icon, spacing, and padding around the permission bar's three answers.
    static let permissionChrome: CGFloat = 86
    /// Tool-row disclosure symbol and spacing.
    static let toolRowChrome: CGFloat = 34

    /// SwiftUI's `.caption` on macOS, the size the transcript's code blocks and
    /// tool rows render at. Deliberately not `NSFont.smallSystemFontSize`,
    /// which is the AppKit control size and a point larger.
    static let captionPointSize: CGFloat = 10
    /// SwiftUI's `.callout`, the size a column header's agent name renders at.
    static let headerPointSize: CGFloat = 12

    /// The narrowest column Mesh will lay out side by side. `textScale` is the
    /// reader's type-size multiplier: larger text needs a wider column to hold
    /// the same content, so the threshold rises with it.
    static func minimum(textScale: CGFloat = 1) -> CGFloat {
        let scale = min(max(textScale, 0.5), 4)
        return max(
            codeFloor(scale: scale),
            toolRowFloor(scale: scale),
            controlsFloor(scale: scale)
        ).rounded(.up)
    }

    /// SwiftUI's type-size steps as a multiplier on the base body size. The
    /// accessibility sizes are the ones that actually strand a Mesh column, so
    /// they are the reason this mapping exists.
    static func textScale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.86
        case .small: 0.91
        case .medium: 0.96
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.24
        case .xxxLarge: 1.35
        case .accessibility1: 1.65
        case .accessibility2: 1.94
        case .accessibility3: 2.35
        case .accessibility4: 2.76
        case .accessibility5: 3.12
        @unknown default: 1
        }
    }

    private static func codeFloor(scale: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: captionPointSize * scale, weight: .regular)
        return CGFloat(codeLineCharacters) * advance(of: font)
            + 2 * codeBlockInset
            + 2 * transcriptInset
            + scrollerAllowance
    }

    private static func toolRowFloor(scale: CGFloat) -> CGFloat {
        let path = NSFont.monospacedSystemFont(ofSize: captionPointSize * scale, weight: .regular)
        let verb = width(of: "Inspect ", font: .systemFont(ofSize: captionPointSize * scale))
        return verb
            + CGFloat(toolPathCharacters) * advance(of: path)
            + 2 * transcriptInset
            + toolRowChrome * scale
    }

    /// The column header and the permission bar both lay their controls out in
    /// one row, so either can be the binding floor before the transcript is.
    private static func controlsFloor(scale: CGFloat) -> CGFloat {
        let header = width(
            of: "Claude Code",
            font: .systemFont(ofSize: headerPointSize * scale, weight: .semibold)
        )
            + width(of: "StopDiffIntegrate", font: .systemFont(ofSize: captionPointSize * scale))
            + headerChrome * scale
        let permission = width(
            of: "DenyAllow onceAlways allow",
            font: .systemFont(ofSize: captionPointSize * scale)
        )
            + permissionChrome * scale
        return max(header, permission)
    }

    private static func advance(of font: NSFont) -> CGFloat {
        width(of: "0", font: font)
    }

    private static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// How the Mesh presents its columns. Both modes show every agent; they differ
/// in whether every agent also gets a transcript on screen at once.
enum MeshColumnDeck: Equatable, Sendable {
    /// Every column side by side — the original layout, kept for as long as
    /// each column still clears the readable minimum.
    case sideBySide
    /// One readable transcript plus an overview strip carrying the rest of the
    /// agents' status and waiting permissions.
    case focused
}

/// The rules that decide which deck the Mesh draws and what it draws into it.
/// Pure, so the thresholds can be pinned without hosting a window.
enum MeshColumnDeckPolicy {
    /// The 1-point divider drawn between side-by-side columns.
    static let dividerWidth: CGFloat = 1

    static func deck(
        availableWidth: CGFloat,
        columnCount: Int,
        textScale: CGFloat = 1
    ) -> MeshColumnDeck {
        // One column is the same picture either way, and a width SwiftUI has
        // not measured yet must not decide anything: the first real layout
        // pass does.
        guard columnCount > 1, availableWidth.isFinite, availableWidth > 0 else {
            return .sideBySide
        }
        let usable = availableWidth - CGFloat(columnCount - 1) * dividerWidth
        let perColumn = usable / CGFloat(columnCount)
        return perColumn >= MeshColumnWidth.minimum(textScale: textScale) ? .sideBySide : .focused
    }

    /// Columns the deck draws a transcript for.
    static func renderedColumnIDs(
        _ columnIDs: [String],
        deck: MeshColumnDeck,
        focusedColumnID: String?
    ) -> [String] {
        switch deck {
        case .sideBySide:
            return columnIDs
        case .focused:
            guard let focused = focusedColumnID, columnIDs.contains(focused) else {
                return Array(columnIDs.prefix(1))
            }
            return [focused]
        }
    }

    /// Columns whose adapter the Mesh starts — every column, in both decks. A
    /// focused deck shows one transcript at a time, and starting only what is
    /// on screen would leave the other agents sitting unconnected until
    /// somebody happened to click them.
    static func startedColumnIDs(
        _ columnIDs: [String],
        deck _: MeshColumnDeck,
        focusedColumnID _: String?
    ) -> [String] {
        columnIDs
    }

    /// Which column the focused deck shows. An explicit choice survives a
    /// relayout and any column coming or going; without one, a column with a
    /// permission waiting wins over plain first-in-order.
    static func focusedColumnID(
        requested: String?,
        columnIDs: [String],
        needingAttention: [String] = []
    ) -> String? {
        if let requested, columnIDs.contains(requested) { return requested }
        if let urgent = needingAttention.first(where: { columnIDs.contains($0) }) { return urgent }
        return columnIDs.first
    }

    /// The column that owns the permission keyboard shortcuts. Only a column
    /// whose permission bar is actually on screen can, or the shortcut answers
    /// a prompt the reader cannot see.
    static func permissionShortcutColumnID(
        renderedColumnIDs: [String],
        permissionColumnIDs: [String]
    ) -> String? {
        permissionColumnIDs.first { renderedColumnIDs.contains($0) }
    }
}

/// One agent's entry in the focused deck's overview strip. It carries what the
/// column header would have said — identity, status, and how many permission
/// answers are waiting — so an agent whose transcript is off screen never goes
/// silent.
struct MeshColumnOverviewItem: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let isRunning: Bool
    let isConnected: Bool
    let pendingPermissionCount: Int

    var needsYou: Bool { pendingPermissionCount > 0 }

    /// A dotted ring, a filled disc, and a hollow ring — three shapes, so the
    /// tint is reinforcement rather than the only way to read the state.
    var statusSymbol: String {
        if isRunning { return "circle.dotted" }
        return isConnected ? "circle.fill" : "circle"
    }

    var statusTint: Color {
        if isRunning { return .accentColor }
        return isConnected ? .green : .secondary
    }

    var statusDescription: String {
        if isRunning { return "Working" }
        return isConnected ? "Connected" : "Not connected"
    }

    var urgencyDescription: String? {
        guard pendingPermissionCount > 0 else { return nil }
        return pendingPermissionCount == 1
            ? "1 permission waiting"
            : "\(pendingPermissionCount) permissions waiting"
    }

    var accessibilityLabel: String {
        [name, statusDescription, urgencyDescription]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

extension MeshColumnOverviewItem {
    @MainActor
    init(column: MeshSession.Column) {
        self.init(
            id: column.id,
            name: column.agent.name,
            symbol: column.agent.symbol,
            isRunning: column.conversation.isRunning,
            isConnected: column.conversation.isConnected,
            pendingPermissionCount: column.conversation.pendingPermissionCount
        )
    }
}

/// One column's transcript UI state, held outside the view that draws it.
/// Crossing the readable-width threshold rebuilds MeshView's column subtree, so
/// keeping readiness, the at-bottom anchor, and the unseen-output badge here —
/// keyed by column — is what stops a relayout from throwing away where each
/// agent's reader had got to.
final class MeshTranscriptViewState: ObservableObject {
    @Published private(set) var isAtBottom = true
    @Published var hasUnseenUpdates = false
    @Published var isReady = false
    var isLoadingEarlier = false
    private var isMounted = false
    private var visibleRowIDs: Set<String> = []
    private var rememberedAnchor: String?

    func noteMounted(_ mounted: Bool) {
        isMounted = mounted
        if !mounted { isReady = false }
    }

    /// Record a transcript row entering or leaving the viewport, and keep the
    /// topmost visible row as the anchor to come back to.
    ///
    /// Only a row *arriving* moves the anchor. Scrolling always brings
    /// something new into view, so the anchor still tracks the reader; a
    /// teardown is nothing but departures, and freezing on those is what stops
    /// a deck change from walking the anchor down to the last row and back to
    /// nothing.
    func noteRow(_ id: String, isVisible: Bool, in rows: [AcpTranscriptRow]) {
        guard isVisible else {
            visibleRowIDs.remove(id)
            return
        }
        visibleRowIDs.insert(id)
        if let top = rows.first(where: { visibleRowIDs.contains($0.id) }) {
            rememberedAnchor = top.id
        }
    }

    /// The bottom sentinel appearing means the reader is following the stream.
    /// It leaving means they scrolled up — but only while the column is still
    /// mounted with rows on screen. A sentinel that leaves because the deck
    /// flipped must not overwrite their place.
    func noteBottomSentinel(isVisible: Bool) {
        if isVisible {
            isAtBottom = true
            hasUnseenUpdates = false
            return
        }
        guard isMounted, !visibleRowIDs.isEmpty else { return }
        isAtBottom = false
    }

    /// Where a rebuilt transcript should land: nil to follow the stream to the
    /// bottom, otherwise the row the reader was last looking at.
    func restorationAnchor(in rows: [AcpTranscriptRow]) -> String? {
        guard !isAtBottom else { return nil }
        if let rememberedAnchor, rows.contains(where: { $0.id == rememberedAnchor }) {
            return rememberedAnchor
        }
        return rows.first(where: { visibleRowIDs.contains($0.id) })?.id
    }

    func followStream() {
        isAtBottom = true
        hasUnseenUpdates = false
    }
}

/// Per-column transcript state, keyed by column id and owned by MeshView so it
/// outlives any one deck. Deliberately not observable: adding or pruning an
/// entry changes nothing on screen, and the views observe the individual
/// column states instead.
final class MeshTranscriptViewStates {
    private var states: [String: MeshTranscriptViewState] = [:]

    func state(for columnID: String) -> MeshTranscriptViewState {
        if let existing = states[columnID] { return existing }
        let created = MeshTranscriptViewState()
        states[columnID] = created
        return created
    }

    /// Drop state for columns the run no longer has.
    func prune(keeping columnIDs: Set<String>) {
        states = states.filter { columnIDs.contains($0.key) }
    }

    var trackedColumnIDs: Set<String> { Set(states.keys) }
}

/// The Mesh surface: one composer fanning a prompt to every agent column;
/// streaming transcripts side by side while they stay readable and an
/// overview-plus-focused-column deck once they would not; per-column status,
/// inline permission answers, and a worktree diff sheet for judging each
/// agent's edits.
struct MeshView: View {
    enum Presentation: Sendable, Equatable {
        case standard
        case embedded
    }

    @ObservedObject var mesh: MeshSession
    private let presentation: Presentation
    @State private var diffSheet = MeshDiffSheetState()
    @State private var integrateColumnID: String?
    /// The column the reader chose to focus. Held here, above the deck, so a
    /// width change never moves it.
    @State private var requestedColumnID: String?
    @State private var transcriptStates = MeshTranscriptViewStates()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var integrationOutcome: MeshIntegrationOutcome?
    /// The column the reported outcome belongs to, so "Try Again" and "Review
    /// Diff" act on it rather than guessing from the message.
    @State private var integratedColumnID: String?
    @FocusState private var composerFocused: Bool
    private let focusRequestGeneration: UInt64?
    private let onKeyboardFocus: (() -> Void)?

    init(
        mesh: MeshSession,
        presentation: Presentation = .standard,
        focusRequestGeneration: UInt64? = nil,
        onKeyboardFocus: (() -> Void)? = nil
    ) {
        _mesh = ObservedObject(wrappedValue: mesh)
        self.presentation = presentation
        self.focusRequestGeneration = focusRequestGeneration
        self.onKeyboardFocus = onKeyboardFocus
    }

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .standard {
                header
                Divider()
            }
            if let outcome = integrationOutcome {
                integrationStatusBar(outcome)
                Divider()
            }
            if mesh.columns.isEmpty {
                if mesh.lifecycle == .recoveryRequired {
                    ContentUnavailableView {
                        Label("Mesh recovery needed", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Kaisola preserved this run's Git manifest but could not safely reattach every worktree. Nothing was deleted.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Starting agents…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                GeometryReader { geometry in
                    columnDeck(availableWidth: geometry.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Every column's adapter starts with the run, not with its column's
        // view: the focused deck only ever mounts one transcript.
        .task(id: mesh.columns.map(\.id)) {
            for id in MeshColumnDeckPolicy.startedColumnIDs(
                mesh.columns.map(\.id),
                deck: .focused,
                focusedColumnID: focusedColumnID
            ) {
                await mesh.startColumn(columnID: id)
            }
        }
        .onChange(of: mesh.columns.map(\.id)) { _, ids in
            transcriptStates.prune(keeping: Set(ids))
        }
        .confirmationDialog(
            "Apply this column's diff to the base project?",
            isPresented: Binding(
                get: { integrateColumnID != nil },
                set: { if !$0 { integrateColumnID = nil } }
            ),
            presenting: integrateColumnID
        ) { columnID in
            Button("Apply Diff") { integrate(columnID) }
            Button("Cancel", role: .cancel) { integrateColumnID = nil }
        } message: { _ in
            Text("Grafts this column's edits onto \(mesh.baseDirectory.lastPathComponent) with a 3-way merge. Conflicts leave git markers you'll need to resolve.")
        }
        .sheet(item: Binding(
            get: { diffSheet.columnID.map(DiffSheetID.init) },
            // SwiftUI only ever writes nil here (a dismissal); opening runs
            // through the column's Diff button so the token is stamped once.
            set: { if $0 == nil { diffSheet.close() } }
        )) { sheet in
            diffSheetBody(for: sheet.id)
        }
        .onAppear { applyFocusRequest(focusRequestGeneration) }
        .onChange(of: focusRequestGeneration) { _, request in
            applyFocusRequest(request)
        }
    }

    private struct DiffSheetID: Identifiable {
        let id: String
    }

    /// The diff sheet for one column. Until that column's own request comes
    /// back the body says so out loud rather than rendering whatever the last
    /// column left in the shared string.
    @ViewBuilder
    private func diffSheetBody(for columnID: String) -> some View {
        let name = mesh.columns.first { $0.id == columnID }?.agent.name ?? ""
        VStack(spacing: 0) {
            HStack {
                Text("Worktree diff — \(name)")
                    .font(.headline)
                Spacer()
                Button("Done") { diffSheet.close() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                if let patch = diffSheet.patch {
                    UnifiedPatchView(patch: patch.isEmpty ? "No changes yet." : patch)
                        .padding(12)
                } else {
                    ProgressView("Loading diff…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(24)
                        .accessibilityLabel(
                            name.isEmpty ? "Loading worktree diff" : "Loading \(name)'s worktree diff"
                        )
                }
            }
        }
        .frame(width: 640, height: 480)
        .task(id: columnID) { await loadDiff(for: columnID) }
    }

    /// Read the column's worktree diff and hand it back through the sheet's
    /// fence, so a slow result that lands after a switch or a dismissal is
    /// dropped instead of painted over the wrong column.
    private func loadDiff(for columnID: String) async {
        let token = diffSheet.token
        let patch = await mesh.diff(for: columnID)
        diffSheet.apply(patch: patch, from: columnID, token: token)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.purple)
            Text(mesh.title).font(.subheadline.weight(.medium))
            if let chip = headerChip {
                Text(chip)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
            }
            if mesh.anyRunning {
                ProgressView().controlSize(.small)
            }
            if let note = mesh.isolationNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
            }
            if let notice = mesh.hookNotice {
                Label(notice, systemImage: "bolt.trianglebadge.exclamationmark")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                    .help(notice)
            }
            Spacer()
            MeshStagedPromptQueueButton(mesh: mesh)
            if mesh.anyRunning {
                Button {
                    Task { await mesh.stopAllTurns() }
                } label: {
                    Label("Stop All", systemImage: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop every running Mesh column without deleting the run")
            }
            configurationMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.ultraThinMaterial)
    }

    private var configurationMenu: some View {
        MeshConfigurationMenu(mesh: mesh)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Send to every agent…", text: $mesh.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($composerFocused)
                .onChange(of: composerFocused) { _, focused in
                    if focused { onKeyboardFocus?() }
                }
                .onSubmit(send)
            Button(action: send) {
                if mesh.hookSubmissionInProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                }
            }
            .buttonStyle(.borderless)
            .disabled(
                mesh.hookSubmissionInProgress
                    || mesh.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .help("Fan this prompt out to every column")
        }
        .padding(10)
        .background(.ultraThinMaterial)
    }

    private func applyFocusRequest(_ generation: UInt64?) {
        guard generation != nil else { return }
        DispatchQueue.main.async {
            composerFocused = true
        }
    }

    private func send() {
        let text = mesh.draft
        Task { @MainActor in
            if await mesh.submit(text), mesh.draft == text {
                mesh.draft = ""
            }
        }
    }

    /// The header status chip: the run's purpose plus, when a staged/idea
    /// pipeline is active, its current phase. Nil for a plain flat build run.
    private var headerChip: String? {
        let queued = mesh.stagedQueuedPromptCount > 0
            ? " · \(mesh.stagedQueuedPromptCount) queued"
            : ""
        switch mesh.purpose {
        case .idea:
            return mesh.stage == "Idle" ? "Idea" : "Idea · \(mesh.stage)"
        case .build:
            return mesh.mode == .staged ? "Staged · \(mesh.stage)\(queued)" : nil
        }
    }

    private var overviewItems: [MeshColumnOverviewItem] {
        mesh.columns.map(MeshColumnOverviewItem.init(column:))
    }

    private var permissionColumnIDs: [String] {
        mesh.columns.filter { $0.conversation.pendingPermission != nil }.map(\.id)
    }

    private var focusedColumnID: String? {
        MeshColumnDeckPolicy.focusedColumnID(
            requested: requestedColumnID,
            columnIDs: mesh.columns.map(\.id),
            needingAttention: permissionColumnIDs
        )
    }

    /// Side-by-side for as long as every column clears the readable minimum;
    /// otherwise one full-width transcript under an overview strip that keeps
    /// the other agents' status and waiting permissions on screen.
    @ViewBuilder
    private func columnDeck(availableWidth: CGFloat) -> some View {
        let deck = MeshColumnDeckPolicy.deck(
            availableWidth: availableWidth,
            columnCount: mesh.columns.count,
            textScale: MeshColumnWidth.textScale(for: dynamicTypeSize)
        )
        let focused = focusedColumnID
        let rendered = MeshColumnDeckPolicy.renderedColumnIDs(
            mesh.columns.map(\.id),
            deck: deck,
            focusedColumnID: focused
        )
        let shortcutColumnID = MeshColumnDeckPolicy.permissionShortcutColumnID(
            renderedColumnIDs: rendered,
            permissionColumnIDs: permissionColumnIDs
        )
        VStack(spacing: 0) {
            if deck == .focused {
                MeshColumnOverviewStrip(
                    items: overviewItems,
                    focusedColumnID: focused,
                    select: { requestedColumnID = $0 }
                )
                Divider()
            }
            HStack(spacing: 0) {
                ForEach(Array(rendered.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider() }
                    if let column = mesh.columns.first(where: { $0.id == id }) {
                        MeshColumnView(
                            column: column,
                            viewState: transcriptStates.state(for: column.id),
                            enablesPermissionShortcuts: column.id == shortcutColumnID,
                            start: { await mesh.startColumn(columnID: column.id) },
                            stop: { Task { await mesh.stopTurn(columnID: column.id) } },
                            showDiff: { diffSheet.open(columnID: column.id) },
                            integrate: { integrateColumnID = column.id }
                        )
                    }
                }
            }
        }
    }

    /// The integration status line. Tint, symbol, what VoiceOver says, and which
    /// buttons appear all come from the typed outcome, so a permission,
    /// repository, patch, or I/O failure stays as loud as a conflict no matter
    /// how git worded it.
    private func integrationStatusBar(_ outcome: MeshIntegrationOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(outcome.message, systemImage: outcome.symbol)
                .font(.caption)
                .foregroundStyle(outcome.severity.foregroundColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(outcome.accessibilityAnnouncement)
            ForEach(outcome.recoveryActions) { action in
                Button(action.title) { perform(action) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(action.help)
                    .accessibilityLabel("\(action.title): \(action.help)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    /// Run one of the outcome's offered recoveries against the column it came
    /// from.
    private func perform(_ action: MeshIntegrationOutcome.Recovery) {
        switch action {
        case .reviewDiff:
            if let columnID = integratedColumnID {
                diffSheet.open(columnID: columnID)
            }
        case .retry:
            if let columnID = integratedColumnID { integrate(columnID) }
        case .revealDestination:
            NSWorkspace.shared.activateFileViewerSelecting([mesh.baseDirectory])
        case .dismiss:
            integrationOutcome = nil
            integratedColumnID = nil
        }
    }

    /// Graft the column's worktree diff onto the base workspace and keep the
    /// typed outcome it reports. Runs on the main actor so the @State writes are
    /// safe.
    private func integrate(_ columnID: String) {
        integratedColumnID = columnID
        Task { @MainActor in
            integrationOutcome = await mesh.integrate(columnID: columnID)
        }
    }
}

private extension MeshIntegrationOutcome.Severity {
    /// The only place a severity becomes a colour. Each state also carries its
    /// own symbol, so tint is reinforcement rather than the whole signal.
    var foregroundColor: Color {
        switch self {
        case .success: KaisolaStatusTone.done.foregroundColor
        case .informational: Color.kaisolaSecondary
        case .warning: KaisolaStatusTone.needsYou.foregroundColor
        case .failure: KaisolaStatusTone.failed.foregroundColor
        }
    }
}

/// Shared by standalone and embedded Mesh headers so a restored queue is never
/// hidden behind a particular presentation mode.
struct MeshStagedPromptQueueButton: View {
    @ObservedObject var mesh: MeshSession
    @State private var isPresented = false

    var body: some View {
        if !mesh.stagedPrompts.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                Label("\(mesh.stagedPrompts.count)", systemImage: "tray.full")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .help("Review queued Mesh prompts")
            .accessibilityLabel(queueAccessibilityLabel)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                queueInspector
            }
        }
    }

    private var queueAccessibilityLabel: String {
        let count = mesh.stagedPrompts.count
        return "Review \(count) queued \(count == 1 ? "prompt" : "prompts")"
    }

    private var queueInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Queued Prompts")
                        .font(.headline)
                    Text("Waiting in dispatch order")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                }
                Spacer()
                Button {
                    _ = mesh.resumeStagedQueue()
                } label: {
                    Label("Resume Queue", systemImage: "play.fill")
                }
                .disabled(!mesh.canResumeStagedQueue)
                .help("Dispatch the oldest waiting prompt")
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(mesh.stagedPrompts.enumerated()), id: \.offset) { index, prompt in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text("Prompt \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.kaisolaSecondary)
                                Spacer()
                                Button(role: .destructive) {
                                    if mesh.removeStagedPrompt(prompt, at: index), mesh.stagedPrompts.isEmpty {
                                        isPresented = false
                                    }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove queued prompt \(index + 1)")
                            }
                            Text(prompt)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Queued prompt \(index + 1)")
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 390, height: 360)
    }
}

/// Compact configuration accessory shared by the standalone Mesh header and
/// the unified session-card header. Session identity and activity therefore
/// appear once while current ACP/MCP configuration remains one click away.
struct MeshConfigurationMenu: View {
    @ObservedObject var mesh: MeshSession

    var body: some View {
        Menu {
            Section("Project") {
                Label(mesh.baseDirectory.path, systemImage: "folder")
            }
            Section("ACP adapters") {
                if mesh.configuredAgentNames.isEmpty {
                    Text("No compatible adapters")
                } else {
                    ForEach(mesh.configuredAgentNames, id: \.self) { name in
                        Label(name, systemImage: "checkmark.circle")
                    }
                }
            }
            Section("MCP servers") {
                if mesh.configuredMCPServerNames.isEmpty {
                    Text("No enabled servers")
                } else {
                    ForEach(mesh.configuredMCPServerNames, id: \.self) { name in
                        Label(name, systemImage: "server.rack")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                Text("\(mesh.configuredAgentNames.count) ACP · \(mesh.configuredMCPServerNames.count) MCP")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.kaisolaSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .kaisolaControlSurface(active: true, tint: .purple)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Current project ACP and MCP configuration")
    }
}

/// The focused deck's overview: every agent's identity, status, and waiting
/// permissions in one row, with the focused column marked. This is what keeps a
/// column whose transcript is off screen from disappearing entirely.
struct MeshColumnOverviewStrip: View {
    let items: [MeshColumnOverviewItem]
    let focusedColumnID: String?
    let select: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button { select(item.id) } label: { chip(item) }
                        .buttonStyle(.plain)
                        .help(item.accessibilityLabel)
                        .accessibilityLabel(item.accessibilityLabel)
                        .accessibilityHint("Show this agent's transcript")
                        .accessibilityAddTraits(
                            item.id == focusedColumnID ? [.isSelected] : []
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mesh agents")
    }

    @ViewBuilder
    private func chip(_ item: MeshColumnOverviewItem) -> some View {
        let isFocused = item.id == focusedColumnID
        let shape = RoundedRectangle(
            cornerRadius: KaisolaVisualSystem.controlRadius,
            style: .continuous
        )
        HStack(spacing: 6) {
            Image(systemName: item.symbol).foregroundStyle(.purple)
            Text(item.name)
                .font(.caption.weight(isFocused ? .semibold : .regular))
                .lineLimit(1)
            Image(systemName: item.statusSymbol)
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(item.statusTint)
            // Urgency survives the column leaving the screen: a waiting
            // permission keeps its own labelled badge in the overview, not a
            // tint on the status dot.
            if let urgency = item.urgencyDescription {
                Label(
                    item.pendingPermissionCount > 1 ? "\(item.pendingPermissionCount)" : "Answer",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    KaisolaStatusTone.needsYou.backgroundColor,
                    in: Capsule()
                )
                .accessibilityHidden(true)
                .help(urgency)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .kaisolaControlSurface(active: isFocused, tint: .purple)
        .overlay {
            // The focused chip is outlined, not only tinted, so which
            // transcript is on screen survives high contrast and greyscale.
            if isFocused {
                shape.strokeBorder(Color.purple.opacity(0.55), lineWidth: 1.5)
            }
        }
        .contentShape(shape)
    }
}

/// One agent's column: status, streaming transcript, inline permission answers,
/// and the worktree diff affordance.
private struct MeshColumnView: View {
    let column: MeshSession.Column
    let enablesPermissionShortcuts: Bool
    let start: () async -> Void
    let stop: () -> Void
    let showDiff: () -> Void
    let integrate: () -> Void
    @ObservedObject private var conversation: AcpConversation
    /// Scroll readiness and anchor live outside the view so a deck change does
    /// not reset them.
    @ObservedObject private var viewState: MeshTranscriptViewState

    init(
        column: MeshSession.Column,
        viewState: MeshTranscriptViewState,
        enablesPermissionShortcuts: Bool,
        start: @escaping () async -> Void,
        stop: @escaping () -> Void,
        showDiff: @escaping () -> Void,
        integrate: @escaping () -> Void
    ) {
        self.column = column
        self.enablesPermissionShortcuts = enablesPermissionShortcuts
        self.start = start
        self.stop = stop
        self.showDiff = showDiff
        self.integrate = integrate
        self.conversation = column.conversation
        self.viewState = viewState
    }

    private var overview: MeshColumnOverviewItem {
        MeshColumnOverviewItem(column: column)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: column.agent.symbol).foregroundStyle(.purple)
                Text(column.agent.name).font(.callout.weight(.semibold))
                // Three states off one tinted dot meant colour was the whole
                // signal. Each state now has its own outline as well, and says
                // its name to VoiceOver and on hover.
                Image(systemName: overview.statusSymbol)
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(overview.statusTint)
                    .accessibilityElement()
                    .accessibilityLabel("\(column.agent.name): \(overview.statusDescription)")
                    .help(overview.statusDescription)
                Spacer()
                if conversation.isRunning {
                    Button(action: stop) {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop \(column.agent.name) without deleting its transcript")
                    .accessibilityLabel("Stop \(column.agent.name) turn")
                }
                if column.worktreePath != nil {
                    Button("Diff", action: showDiff)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("This column's isolated worktree diff vs HEAD")
                    Button("Integrate", action: integrate)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Apply this column's diff onto the base project")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.thinMaterial)
            Divider()
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if conversation.hiddenEarlierCount > 0 {
                                HStack(spacing: 6) {
                                    if viewState.isLoadingEarlier { ProgressView().controlSize(.mini) }
                                    Text(viewState.isLoadingEarlier ? "Loading earlier messages…" : "Earlier messages")
                                        .font(.caption2)
                                        .foregroundStyle(.kaisolaSecondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .onAppear {
                                    guard viewState.isReady,
                                          !viewState.isLoadingEarlier,
                                          let anchor = conversation.visibleRows.first?.id else { return }
                                    viewState.isLoadingEarlier = true
                                    Task { @MainActor in
                                        await conversation.expandEarlier()
                                        TerminalTranscriptScrollPolicy.preserveUserVelocity {
                                            proxy.scrollTo(anchor, anchor: .top)
                                        }
                                        viewState.isLoadingEarlier = false
                                    }
                                }
                            } else if viewState.isReady, !conversation.rows.isEmpty {
                                Text("Beginning of session")
                                    .font(.caption2)
                                    .foregroundStyle(.kaisolaSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                            }
                            if let status = conversation.statusMessage {
                                Label(status, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.kaisolaSecondary)
                            }
                            ForEach(conversation.visibleRows) { row in
                                TranscriptRowView(
                                    row: row,
                                    workspaceURL: conversation.workspaceURL,
                                    retry: { conversation.retryFailed($0) },
                                    terminalSnapshot: { [weak conversation] id in await conversation?.terminalSnapshot(id) }
                                )
                                .id(row.id)
                                .onAppear {
                                    viewState.noteRow(row.id, isVisible: true, in: conversation.visibleRows)
                                }
                                .onDisappear {
                                    viewState.noteRow(row.id, isVisible: false, in: conversation.visibleRows)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                                .onAppear { viewState.noteBottomSentinel(isVisible: true) }
                                .onDisappear { viewState.noteBottomSentinel(isVisible: false) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if viewState.isReady, !viewState.isAtBottom, !conversation.rows.isEmpty {
                        Button {
                            viewState.followStream()
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: viewState.hasUnseenUpdates ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(8)
                        .help(viewState.hasUnseenUpdates ? "Jump to new output" : "Jump to latest")
                        .accessibilityLabel(viewState.hasUnseenUpdates ? "Jump to new agent output" : "Jump to latest agent output")
                    }
                }
                .onAppear {
                    // A deck change remounts this transcript. Land back on the
                    // row the reader was on rather than snapping every column
                    // to the bottom.
                    let anchor = viewState.restorationAnchor(in: conversation.visibleRows)
                    viewState.noteMounted(true)
                    DispatchQueue.main.async {
                        if let anchor {
                            proxy.scrollTo(anchor, anchor: .top)
                        } else {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                        viewState.isReady = true
                    }
                }
                .onDisappear { viewState.noteMounted(false) }
                .onChange(of: conversation.contentVersion) { _, newVersion in
                    guard viewState.isReady,
                          conversation.lastHistoryInsertionContentVersion != newVersion else { return }
                    if viewState.isAtBottom {
                        DispatchQueue.main.async {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    } else {
                        viewState.hasUnseenUpdates = true
                    }
                }
            }
            if let review = conversation.pendingPermissionReview {
                Divider()
                AcpPermissionBar(
                    review: review,
                    allowsRule: conversation.pendingPermissionAllowsRule,
                    pendingCount: conversation.pendingPermissionCount,
                    deny: { conversation.denyPermission() },
                    allowOnce: { conversation.allowPermissionOnce() },
                    createRule: { conversation.answerPermissionAlways() },
                    enablesKeyboardShortcuts: enablesPermissionShortcuts
                )
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        // MeshView starts every column, focused or not; this covers the column
        // that mounts before that task lands.
        .task { await start() }
    }

    private var bottomID: String { "mesh-transcript-bottom-\(column.id)" }
}

/// A raw unified diff with the standard +/− tinting (shared Mesh/diff-sheet
/// rendering).
struct UnifiedPatchView: View {
    let patch: String

    private var rendered: GitBoundedPatch { GitPatchRendering.bounded(patch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rendered.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
                    .background(tint(for: line))
            }
            if rendered.isTruncated {
                Label("Large diff truncated in this view", systemImage: "ellipsis.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.kaisolaSecondary)
                    .padding(.top, 6)
            }
        }
    }

    private func tint(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.13) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.13) }
        if line.hasPrefix("@@") { return .accentColor.opacity(0.13) }
        return .clear
    }
}
