import AppKit
import SwiftTerm
import SwiftUI

extension Notification.Name {
    /// Posted when a `file:` OSC 8 link is activated in a terminal surface, so
    /// the shell can open it in Kaisola's built-in file preview instead of
    /// Finder. `userInfo["url"]` is the file `URL`; `userInfo["line"]` is an
    /// optional `Int` line target parsed from a trailing `:LINE` citation.
    static let kaisolaOpenFileLink = Notification.Name("kaisolaOpenFileLink")
}

/// Separates the durable AppKit surface class from the controller connection's
/// live write authority.
///
/// A terminal Kaisola created remains controller-capable while its control
/// socket reconnects, so a brief ownership publication must not replace its
/// parsed SwiftTerm view. The `active` bit is still revoked immediately and is
/// the only state that enables outbound bytes. A genuinely foreign terminal
/// stays on `ReadOnlyTerminalView` by construction.
enum TerminalSurfaceAuthority: Equatable {
    case observerOnly
    case localController(active: Bool)

    init(isOwned: Bool, hasDurableOwnership: Bool) {
        self = isOwned || hasDurableOwnership
            ? .localController(active: isOwned)
            : .observerOnly
    }

    var controllerCapable: Bool {
        if case .localController = self { return true }
        return false
    }

    var inputEnabled: Bool {
        if case .localController(active: true) = self { return true }
        return false
    }
}

/// Redraws only a terminal card when its document advances. The parent shell
/// passes stable configuration and closures, while the high-frequency document
/// lives in a dedicated observable object that does not invalidate the rest of
/// the IDE chrome.
struct TerminalSurfaceFeedView<Content: View>: View {
    @ObservedObject var feed: TerminalSurfaceFeed
    private let content: (TerminalDocument) -> Content

    init(
        feed: TerminalSurfaceFeed,
        @ViewBuilder content: @escaping (TerminalDocument) -> Content
    ) {
        self.feed = feed
        self.content = content
    }

    var body: some View {
        content(feed.document)
    }
}

struct NativeTerminalSurface: NSViewRepresentable {
    /// A restrained increase over SwiftTerm's default metrics keeps dense shell
    /// output readable while preserving correct cursor, selection, and resize
    /// geometry inside the terminal renderer itself.
    static let comfortableLineSpacing: CGFloat = CGFloat(NativePreviewSettings.terminalLineSpacingDefault)

    let output: String
    let streamEpoch: String?
    let endOffset: Int64?
    var scrollback: TerminalScrollback? = nil
    var surfaceDelta: TerminalSurfaceDelta? = nil
    /// Initial directory used to resolve the relative file citations emitted
    /// by agent CLIs. OSC 7 updates replace it as the shell changes directory.
    var workingDirectory: URL? = nil
    /// Durable class eligibility and independently revocable live authority.
    /// See `TerminalSurfaceAuthority` for why controller reconnects must not
    /// change the concrete AppKit view.
    let authority: TerminalSurfaceAuthority
    /// Terminal font size (⌘+/⌘−/⌘0 via NativePreviewSettings).
    var fontSize: Double = NativePreviewSettings.terminalFontDefault
    var fontFamily: String = TerminalFontOptions.systemMonoSentinel
    var fontWeight: String = "regular"
    var lineSpacing: Double = NativePreviewSettings.terminalLineSpacingDefault
    /// Scrollback depth in lines. See `NativePreviewSettings.terminalScrollbackLines`.
    var scrollbackLines: Int = NativePreviewSettings.terminalScrollbackDefault
    /// Whether OSC 52 may write the system clipboard from this surface
    /// (Settings > Terminal, off by default).
    var allowsClipboardWrite: Bool = false
    /// A `TerminalThemeRegistry` id. Native macOS Terminal by default.
    var themeID: String = "native"
    /// Paper palette on light appearances, ink on dark.
    var lightSurface: Bool = false
    /// Identity used to retain this terminal's parsed view across the SwiftUI
    /// teardown a project tab switch causes. Nil disables retention.
    var sessionID: String? = nil
    /// Launch command of the agent CLI running here (`claude`, `codex`, …), so
    /// a dropped image can use the attachment syntax that CLI understands.
    var agentLaunchCommand: String? = nil
    var onInput: ((String) -> Void)? = nil
    var onResize: ((_ columns: Int, _ rows: Int) -> Void)? = nil
    /// Live OSC title changes (auto-naming owned sessions).
    var onTitleChange: ((String) -> Void)? = nil
    /// Live BEL from the PTY. Historical replay is intentionally suppressed by
    /// the coordinator so an old bell never resurrects an attention alert.
    var onBell: (() -> Void)? = nil
    /// Invoked when the user reaches the oldest row SwiftTerm can render and
    /// deliberately scrolls upward again. The host opens the immutable broker
    /// transcript from there; historical ANSI is never prepended into the live
    /// parser or allowed to mutate the PTY screen.
    var onHistoryBoundary: (() -> Void)? = nil
    /// AppKit gave this surface keyboard focus (a click into the grid, or a
    /// programmatic first-responder move). The shell uses it to keep the pane
    /// focus ring truthful about where typing will land.
    var onKeyboardFocus: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        // Claim the retained pair here, before `makeNSView`, so the view and the
        // render state that describes it can never be mismatched. See
        // `TerminalSurfaceCache` for why they must move together.
        if let sessionID,
           let claimed = TerminalSurfaceCache.shared.claim(
               sessionID: sessionID,
               controllerCapable: authority.controllerCapable
           ) {
            claimed.coordinator.reusedView = claimed.view
            return claimed.coordinator
        }
        return Coordinator()
    }

    static func dismantleNSView(_ view: ReadOnlyTerminalView, coordinator: Coordinator) {
        // SwiftUI has removed the card (a project switch, a closed pane). Park
        // the view and its render state so returning to this project re-attaches
        // the already-parsed terminal instead of replaying the transcript.
        guard let sessionID = coordinator.retainedSessionID else { return }
        // Deny at the concrete view before clearing delegate callbacks. A
        // parked surface remains a live object in the cache and must never
        // retain keyboard, mouse-reporting, paste, or drop authority.
        (view as? OwnedTerminalView)?.setInputAuthorized(false)
        coordinator.prepareForRetention()
        view.onHistoryBoundary = nil
        // Parked surfaces must not retain the shell (and its AppModel) through
        // a focus callback that can no longer describe anything on screen.
        view.onKeyboardFocus = nil
        TerminalSurfaceCache.shared.store(
            sessionID: sessionID,
            view: view,
            coordinator: coordinator
        )
    }

    func makeNSView(context: Context) -> ReadOnlyTerminalView {
        let font = TerminalFontOptions.resolveFont(family: fontFamily, size: fontSize, weightRaw: fontWeight)
        context.coordinator.retainedSessionID = sessionID
        if let reused = context.coordinator.reusedView {
            context.coordinator.reusedView = nil
            configureReusedView(reused, context: context)
            return reused
        }
        let view: ReadOnlyTerminalView = authority.controllerCapable
            ? OwnedTerminalView(frame: .zero, font: font)
            : ReadOnlyTerminalView(frame: .zero, font: font)
        // SwiftTerm's overlay scroller follows the system auto-hide policy and
        // can therefore make a scrollable terminal look as though it has no
        // scrollbar. Its legacy style is still a native NSScroller, but keeps
        // the track visible like the standalone Terminal app.
        view.scrollerStyle = .legacy
        view.lineSpacing = CGFloat(NativePreviewSettings.clampedTerminalLineSpacing(lineSpacing))
        // SwiftTerm's default is 500 lines — about a dozen screens — which is
        // why scrolling up appeared to just stop. The Electron terminal this
        // replaced ran 5000. Applied once here: SwiftTerm's resize, font, theme,
        // and reset paths all rebuild from `options.scrollback`, which this
        // updates, so it survives for the life of the view.
        view.changeScrollback(NativePreviewSettings.clampedTerminalScrollback(scrollbackLines))
        view.configureAdvertisedGraphicsCapabilities()
        view.configureSemanticPromptMarks()
        view.configureJumpToLiveBottomAffordance()
        view.terminalDelegate = context.coordinator
        view.configureTerminalTheme(light: lightSurface, themeID: themeID)
        view.configureLinkInteraction()
        Self.configureKeyboardInput(on: view)
        view.agentLaunchCommand = agentLaunchCommand
        view.onHistoryBoundary = onHistoryBoundary
        view.paneSessionID = sessionID
        view.onKeyboardFocus = onKeyboardFocus
        TerminalScrollGestureMonitor.install()
        let coordinator = context.coordinator
        view.onUsableLayout = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.flushPendingInitialRender(to: view)
            coordinator.repinAfterLayout(view)
            coordinator.synchronizeCurrentGeometry(from: view)
        }
        Self.configureAuthority(
            authority,
            on: view,
            coordinator: context.coordinator,
            onInput: onInput,
            onResize: onResize,
            onTitleChange: onTitleChange
        )
        context.coordinator.onBell = onBell
        context.coordinator.allowsClipboardWrite = allowsClipboardWrite
        context.coordinator.setBaseWorkingDirectory(workingDirectory)
        context.coordinator.apply(
            scrollback: scrollback ?? TerminalScrollback(output),
            epoch: streamEpoch,
            endOffset: endOffset,
            surfaceDelta: surfaceDelta,
            to: view
        )
        return view
    }

    /// Re-attach a retained view. Only the bindings that can have changed while
    /// it was parked are refreshed — crucially the transcript is NOT re-fed,
    /// because the coordinator that came back with it already records exactly
    /// which bytes this view holds. `updateNSView` runs immediately after and
    /// applies any delta that arrived in the meantime.
    private func configureReusedView(_ view: ReadOnlyTerminalView, context: Context) {
        let coordinator = context.coordinator
        view.scrollerStyle = .legacy
        view.terminalDelegate = coordinator
        view.configureTerminalTheme(light: lightSurface, themeID: themeID)
        Self.configureKeyboardInput(on: view)
        view.agentLaunchCommand = agentLaunchCommand
        view.onHistoryBoundary = onHistoryBoundary
        view.paneSessionID = sessionID
        view.onKeyboardFocus = onKeyboardFocus
        view.configureAdvertisedGraphicsCapabilities()
        view.configureSemanticPromptMarks()
        view.configureJumpToLiveBottomAffordance()
        view.onUsableLayout = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.flushPendingInitialRender(to: view)
            coordinator.repinAfterLayout(view)
            coordinator.synchronizeCurrentGeometry(from: view)
        }
        Self.configureAuthority(
            authority,
            on: view,
            coordinator: coordinator,
            onInput: onInput,
            onResize: onResize,
            onTitleChange: onTitleChange
        )
        coordinator.onBell = onBell
        coordinator.allowsClipboardWrite = allowsClipboardWrite
        coordinator.setBaseWorkingDirectory(workingDirectory)
    }

    func updateNSView(_ view: ReadOnlyTerminalView, context: Context) {
        Self.configureAuthority(
            authority,
            on: view,
            coordinator: context.coordinator,
            onInput: onInput,
            onResize: onResize,
            onTitleChange: onTitleChange
        )
        context.coordinator.onBell = onBell
        context.coordinator.allowsClipboardWrite = allowsClipboardWrite
        context.coordinator.setBaseWorkingDirectory(workingDirectory)
        view.agentLaunchCommand = agentLaunchCommand
        view.onHistoryBoundary = onHistoryBoundary
        view.paneSessionID = sessionID
        view.onKeyboardFocus = onKeyboardFocus
        let desired = TerminalFontOptions.resolveFont(family: fontFamily, size: fontSize, weightRaw: fontWeight)
        let desiredLineSpacing = CGFloat(NativePreviewSettings.clampedTerminalLineSpacing(lineSpacing))
        if abs(view.lineSpacing - desiredLineSpacing) > 0.001 {
            view.lineSpacing = desiredLineSpacing
        }
        let desiredScrollback = NativePreviewSettings.clampedTerminalScrollback(scrollbackLines)
        if view.getTerminal().options.scrollback != desiredScrollback {
            view.changeScrollback(desiredScrollback)
        }
        if view.font.fontName != desired.fontName || abs(view.font.pointSize - desired.pointSize) > 0.1 {
            view.font = desired
        }
        if view.themeKey != Self.themeKey(light: lightSurface, themeID: themeID) {
            view.configureTerminalTheme(light: lightSurface, themeID: themeID)
        }
        context.coordinator.apply(
            scrollback: scrollback ?? TerminalScrollback(output),
            epoch: streamEpoch,
            endOffset: endOffset,
            surfaceDelta: surfaceDelta,
            to: view
        )
    }

    private static func themeKey(light: Bool, themeID: String) -> String {
        "\(themeID):\(light ? "light" : "dark")"
    }

    /// Rebind a controller-capable surface without ever leaving a stale write
    /// window. Revocation seals the view before callbacks disappear; granting
    /// installs every callback before the view may emit a byte. Read-only views
    /// ignore grants and remain non-promotable.
    @MainActor
    static func configureAuthority(
        _ authority: TerminalSurfaceAuthority,
        on view: ReadOnlyTerminalView,
        coordinator: Coordinator,
        onInput: ((String) -> Void)?,
        onResize: ((_ columns: Int, _ rows: Int) -> Void)?,
        onTitleChange: ((String) -> Void)?
    ) {
        if authority.inputEnabled,
           let ownedView = view as? OwnedTerminalView {
            coordinator.onInput = onInput
            coordinator.setResizeHandler(onResize, synchronizing: view)
            coordinator.setTitleChangeHandler(onTitleChange)
            coordinator.setInputAuthorized(true)
            ownedView.setInputAuthorized(true)
            view.setAccessibilityLabel("Terminal")
        } else {
            (view as? OwnedTerminalView)?.setInputAuthorized(false)
            view.allowMouseReporting = false
            view.setAccessibilityLabel("Read-only terminal output")
            coordinator.setInputAuthorized(false)
            coordinator.onInput = nil
            coordinator.setResizeHandler(nil, synchronizing: view)
            coordinator.setTitleChangeHandler(nil)
        }
    }

    /// Keep Option available to the active keyboard layout. Hard-wiring it to
    /// Meta turns international-layout characters such as @, brackets, braces,
    /// pipes, tildes, and dead-key accents into escape sequences. A future user
    /// preference may opt into Meta explicitly; the safe native default is off.
    @MainActor
    static func configureKeyboardInput(on view: ReadOnlyTerminalView) {
        view.optionAsMetaKey = false
        configureLinkActivation(on: view)
    }

    /// A file an agent cites opens on a plain click.
    ///
    /// The routing for this was already complete — `linkTarget(for:)` resolves
    /// OSC 8 links and bare `path:line` citations against the shell's OSC 7
    /// directory, and `requestOpenLink` hands the result to Kaisola's own file
    /// preview. What was missing is that SwiftTerm's macOS default is
    /// `.hoverWithModifier`, so none of it ran without ⌘ held down. Nothing
    /// says a link needs a modifier, so a click that lands on one did nothing
    /// at all and the whole feature read as absent. Michael: "I want files
    /// linked in the terminal cli for me to be able to click them and they
    /// open."
    ///
    /// `.hover` underlines a link only while the pointer is on it, so nothing
    /// is underlined at rest and a drag still selects text — a drag is not a
    /// click.
    @MainActor
    static func configureLinkActivation(on view: ReadOnlyTerminalView) {
        view.linkHighlightMode = .hover
    }

}

/// Drops both physical-key input and terminal-generated query replies. SwiftTerm
/// still provides native selection, copy, and Command-F search, but no byte can
/// flow from this view back to a PTY. The view claims keyboard focus when it
/// joins a window so Copy/Select All/Find reach it without a mouse, and exposes
/// the retained tail of the buffer as a read-only accessibility value.
class ReadOnlyTerminalView: TerminalView {
    static let accessibilityTailLimit = 8_000
    /// Prevent one trackpad momentum sequence from trying to present the same
    /// transcript sheet repeatedly while the live viewport remains at row 0.
    static let historyBoundaryRequestCooldown: TimeInterval = 0.75

    private lazy var accessibilityAdapter = TerminalAccessibilityAdapter(
        element: self,
        snapshot: { [weak self] retainedSource in
            self?.accessibilityTextSnapshot(retainedSource: retainedSource) ?? ""
        }
    )
    var accessibilityAnnouncementIsScheduled: Bool {
        accessibilityAdapter.isAnnouncementScheduled
    }
    var accessibilityAnnouncementScheduleCount: Int {
        accessibilityAdapter.announcementScheduleCount
    }
    var accessibilityAnnouncementVoiceOverEnabled: () -> Bool {
        get { accessibilityAdapter.isVoiceOverEnabled }
        set { accessibilityAdapter.isVoiceOverEnabled = newValue }
    }
    var accessibilityAnnouncementPoster: ((String) -> Void)? {
        get { accessibilityAdapter.announcementPoster }
        set { accessibilityAdapter.announcementPoster = newValue }
    }
    private(set) var semanticTracker = TerminalSemanticTracker()
    private var semanticHandlerInstalled = false
    private var semanticGridColumns: Int?
    private var semanticGridRows: Int?
    private var semanticDecorationView: TerminalSemanticDecorationView?
    /// The representable hands initial replay back through this callback after
    /// AppKit assigns the real terminal size.
    var onUsableLayout: (() -> Void)?
    /// Host-owned presentation hook for continuing beyond SwiftTerm's bounded
    /// in-memory row model into the broker's disk-backed transcript.
    var onHistoryBoundary: (() -> Void)?
    /// Stable surface identity of the pane this view renders. Window-level
    /// commands (Clear Terminal, pane focus moves) resolve a terminal through
    /// this rather than assuming the AppKit responder chain already agrees with
    /// the model's focused pane.
    var paneSessionID: String?
    /// Published to the shell when AppKit hands this view keyboard focus, so
    /// the pane focus ring follows a click into the terminal instead of staying
    /// on whichever pane was focused last.
    var onKeyboardFocus: (() -> Void)?
    private var jumpToLiveBottomButton: NSButton?
    private var lastHistoryBoundaryRequestAt = -TimeInterval.greatestFiniteMagnitude
    private var continuousScrollState: TerminalContinuousScrollState?
    private var isApplyingContinuousScrollRow = false
    private var continuousSettlementScheduled = false
    private lazy var accessibilityPageUpAction = NSAccessibilityCustomAction(
        name: "Scroll one page up",
        target: self,
        selector: #selector(performAccessibilityPageUp)
    )
    private lazy var accessibilityPageDownAction = NSAccessibilityCustomAction(
        name: "Scroll one page down",
        target: self,
        selector: #selector(performAccessibilityPageDown)
    )
    var hasUsableRenderGeometry: Bool {
        bounds.width > 1 && bounds.height > 1
    }

    override init(frame: CGRect, font: NSFont?) {
        super.init(frame: frame, font: font)
        configureSealedPresentation()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSealedPresentation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSealedPresentation()
    }

    private func configureSealedPresentation() {
        allowMouseReporting = false
        setAccessibilityLabel("Read-only terminal output")
    }

    /// Typed bytes reaching a read-only surface used to vanish without a
    /// word — during the 2026-08-07 phantom-owner incident that silence WAS
    /// the user-visible bug ("can't type"). The bytes still go nowhere (this
    /// surface has no input authority by construction), but the user hears
    /// why, throttled so held keys don't stack toasts. Input restores
    /// automatically once the ownership self-heal reattaches;
    /// OwnedTerminalView overrides this with the real forwarding path.
    private static var lastReadOnlyNoticeAt: Date?

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        notifyReadOnlyInput()
    }

    func notifyReadOnlyInput() {
        let now = Date()
        if Self.lastReadOnlyNoticeAt.map({ now.timeIntervalSince($0) > 3 }) ?? true {
            Self.lastReadOnlyNoticeAt = now
            Task { @MainActor in
                ToastCenter.shared.show(
                    "This terminal is read-only right now — input reconnects automatically.",
                    style: .info
                )
            }
        }
    }

    /// SwiftTerm checks registered OSC handlers before its built-ins, so OSC
    /// 133/633 support does not require patching the dependency parser. Both
    /// protocols share A/B/C/D lifecycle markers. The handlers record only
    /// bounded positions; they never trust or execute embedded command text.
    func configureSemanticPromptMarks() {
        guard !semanticHandlerInstalled else { return }
        semanticHandlerInstalled = true
        let decorationView = TerminalSemanticDecorationView(frame: bounds)
        decorationView.autoresizingMask = [.width, .height]
        decorationView.isHidden = true
        addSubview(decorationView, positioned: .above, relativeTo: nil)
        semanticDecorationView = decorationView
        reconcileSemanticPromptGrid()
        for code in [133, 633] {
            getTerminal().registerOscHandler(code: code) { [weak self] payload in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reconcileSemanticPromptGrid()
                    guard
                        let event = TerminalSemanticEvent.parse(payload),
                        let position = self.scrollInvariantCursorPosition() else { return }
                    self.semanticTracker.prune(before: self.getTerminal().buffer.totalLinesTrimmed)
                    self.semanticTracker.receive(event, at: position)
                    self.updateSemanticDecorations()
                }
            }
        }
    }

    func resetSemanticPromptMarks() {
        semanticTracker = TerminalSemanticTracker()
        updateSemanticDecorations()
    }

    /// A terminal resize can reflow every scrollback row. SwiftTerm does not
    /// expose a row-remapping callback, so stale coordinates are less useful
    /// than an empty index: discard them and let later/replayed marks rebuild
    /// trustworthy navigation bounds.
    func reconcileSemanticPromptGrid() {
        let dimensions = getTerminal().getDims()
        guard dimensions.cols > 0, dimensions.rows > 0 else { return }
        defer {
            semanticGridColumns = dimensions.cols
            semanticGridRows = dimensions.rows
        }
        guard let oldColumns = semanticGridColumns,
              let oldRows = semanticGridRows else { return }
        if oldColumns != dimensions.cols || oldRows != dimensions.rows {
            resetSemanticPromptMarks()
        }
    }

    /// Extend the active input region after each parsed output chunk. Echoed
    /// shell input and secondary prompts can wrap without emitting another OSC
    /// marker, so cursor observation supplies the conservative lower bound used
    /// by vertical Option-click.
    func observeSemanticPromptCursor(refreshDecorations: Bool = true) {
        // Plain shells and CLIs that do not emit OSC 133/633 have no active
        // input region. Avoid a binary search across the SwiftTerm buffer for
        // every streamed packet in that overwhelmingly common case.
        guard semanticTracker.activeInputRows != nil else { return }
        reconcileSemanticPromptGrid()
        guard let position = scrollInvariantCursorPosition() else { return }
        semanticTracker.prune(before: getTerminal().buffer.totalLinesTrimmed)
        semanticTracker.observeCursor(at: position)
        if refreshDecorations { updateSemanticDecorations() }
    }

    /// Cursor row in SwiftTerm's monotonic scroll-invariant coordinate space.
    /// This remains correct even while the user is reading older output: find
    /// the contiguous buffer end through the public invariant-line API, then
    /// subtract the live screen height rather than consulting `yDisp`.
    func scrollInvariantCursorPosition() -> TerminalSemanticPosition? {
        let terminal = getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        var lower = first
        var upper = first + terminal.options.scrollback + terminal.rows + 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if terminal.getScrollInvariantLine(row: middle) == nil {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let end = lower
        guard end > first else { return nil }
        let cursor = terminal.getCursorLocation()
        let activeTop = max(first, end - terminal.rows)
        return TerminalSemanticPosition(row: activeTop + cursor.y, column: cursor.x)
    }

    /// Command-Up/Down follows semantic prompt starts without sending bytes to
    /// the shell. If no mark exists in that direction SwiftTerm retains its
    /// ordinary key behavior.
    @discardableResult
    func navigateSemanticPrompt(
        backward: Bool,
        beforeScroll: (() -> Void)? = nil
    ) -> Bool {
        let terminal = getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        semanticTracker.prune(before: first)
        guard let destination = semanticPromptDestination(backward: backward) else { return false }
        prepareForDiscreteScrollInput()
        beforeScroll?()
        scrollTo(row: max(0, destination.row - first), notifyAccessibility: true)
        updateSemanticDecorations()
        return true
    }

    /// Every path that can move the viewport already calls this — feeds, user
    /// scrolls, re-pins, layout, and reset — so it is also the single hook the
    /// jump-to-live-bottom pill reacts to. Keeping one hook is what stops the
    /// affordance from lagging a scroll by a run-loop turn.
    func updateSemanticDecorations() {
        updateJumpToLiveBottomVisibility()
        guard let semanticDecorationView else { return }
        // Preserve the one transition that hides an old overlay after reset,
        // while making the steady empty state free during ordinary streaming.
        guard !semanticTracker.commands.isEmpty || !semanticDecorationView.isHidden else { return }
        let terminal = getTerminal()
        let rowCount = terminal.rows
        let viewportTop = terminal.buffer.totalLinesTrimmed + terminal.getTopVisibleRow()
        let decorations = semanticTracker.decorations(
            viewportTop: viewportTop,
            rowCount: rowCount
        )
        semanticDecorationView.update(decorations: decorations, rowCount: rowCount)
    }

    func semanticPromptDestination(backward: Bool) -> TerminalSemanticPosition? {
        let terminal = getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        let viewportTop = first + terminal.getTopVisibleRow()
        let destination: TerminalSemanticPosition?
        if backward {
            // From between blocks, land on the closest prompt at or above the
            // viewport. Once that prompt is exactly at the top, move strictly
            // to the previous one rather than consuming a no-op shortcut.
            let boundary = semanticTracker.prompt(at: viewportTop) == nil
                ? viewportTop + 1
                : viewportTop
            destination = semanticTracker.previousPrompt(before: boundary)
        } else {
            destination = semanticTracker.nextPrompt(after: viewportTop)
        }
        return destination
    }

    @objc private func navigateToPreviousSemanticCommand(_ sender: Any?) {
        navigateSemanticPrompt(backward: true)
    }

    @objc private func navigateToNextSemanticCommand(_ sender: Any?) {
        navigateSemanticPrompt(backward: false)
    }

    /// Agent output should advertise navigation without requiring users to
    /// discover a hidden Command-click gesture. SwiftTerm supplies the path/URL
    /// detector and native underline renderer; hover mode makes the cue visible
    /// and activates a link with one ordinary click.
    func configureLinkInteraction() {
        linkReporting = .implicit
        linkHighlightMode = .hover
    }

    /// Match the underline with the standard macOS link cursor. SwiftTerm's
    /// built-in cursor rect is always an I-beam, so use its public link lookup
    /// with screen coordinates to distinguish a navigable cell.
    func terminalLink(at point: NSPoint) -> String? {
        guard let cell = terminalCell(at: point) else { return nil }
        return getTerminal().link(
            at: .screen(Position(col: cell.column, row: cell.row)),
            mode: .explicitAndImplicit
        )
    }

    /// Current continuous viewport state. Kept internal as an interaction/QA
    /// seam; production rendering consumes the same projection below.
    var continuousScrollSnapshot: TerminalContinuousScrollProjection? {
        continuousScrollState?.projection
    }

    /// SwiftTerm's scroller is private, but it is an ordinary direct NSView
    /// child. Updating its public value keeps thumb dragging, VoiceOver, and
    /// fractional trackpad motion on one exact position.
    private var nativeScroller: NSScroller? {
        subviews.first { $0 is NSScroller } as? NSScroller
    }

    var nativeScrollerValue: Double {
        nativeScroller?.doubleValue ?? scrollPosition
    }

    /// Window-space geometry is the installed-app truth for fixed chrome: a
    /// fractional terminal transform must not translate or resize the native
    /// scroll track under the pointer or VoiceOver focus ring.
    var nativeScrollerWindowFrame: NSRect? {
        guard window != nil, let scroller = nativeScroller else { return nil }
        return scroller.convert(scroller.bounds, to: nil)
    }

    private var continuousScrollCellHeight: CGFloat? {
        let rows = getTerminal().getDims().rows
        guard rows > 0 else { return nil }
        let height = getOptimalFrameSize().height / CGFloat(rows)
        return height.isFinite && height > 0 ? height : nil
    }

    /// Count the normal buffer through SwiftTerm's public invariant-line API.
    /// This bounded logarithmic lookup follows streamed growth without copying
    /// row text or flattening the retained byte buffer on any gesture sample.
    private func maximumContinuousScrollRow() -> Int {
        let terminal = getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        var lower = first
        var upper = first + terminal.options.scrollback + terminal.rows + 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if terminal.getScrollInvariantLine(row: middle) == nil {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return max(0, lower - first - terminal.rows)
    }

    /// Consume one precise AppKit wheel sample when, and only when, the normal
    /// buffer owns scrolling. NSEvent has already applied the user's natural-
    /// scrolling preference and acceleration; preserving every delta also
    /// preserves native momentum without synthesizing velocity.
    @discardableResult
    func handleContinuousScroll(
        scrollingDeltaY: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        routesToNativeScrollback: Bool
    ) -> Bool {
        let terminal = getTerminal()
        let ended = phase.contains(.ended)
            || phase.contains(.cancelled)
            || momentumPhase.contains(.ended)
            || momentumPhase.contains(.cancelled)
        let finishesRubberBand = ended
            && continuousScrollState?.projection.isRubberBanding == true
        guard routesToNativeScrollback,
              hasPreciseScrollingDeltas,
              scrollingDeltaY != 0 || finishesRubberBand,
              canScroll,
              !terminal.isCurrentBufferAlternate,
              let rowHeight = continuousScrollCellHeight else { return false }

        cancelContinuousSettlement()
        let maximumRow = maximumContinuousScrollRow()
        let currentRow = terminal.getTopVisibleRow()
        if var state = continuousScrollState {
            let projection = state.projection
            if projection.anchorRow != currentRow
                || abs(projection.rowHeight - rowHeight) > 0.001
                || projection.maximumRow != maximumRow {
                state.reconfigure(
                    anchorRow: currentRow,
                    rowHeight: rowHeight,
                    maximumRow: maximumRow,
                    viewportExtent: bounds.height
                )
            }
            if scrollingDeltaY != 0 {
                state.apply(scrollingDeltaY: scrollingDeltaY * scrollSensitivity)
            }
            continuousScrollState = state
        } else {
            var state = TerminalContinuousScrollState(
                anchorRow: currentRow,
                fractionalOffset: 0,
                rowHeight: rowHeight,
                maximumRow: maximumRow,
                viewportExtent: bounds.height
            )
            state.apply(scrollingDeltaY: scrollingDeltaY * scrollSensitivity)
            continuousScrollState = state
        }

        applyContinuousScrollProjection()
        if continuousScrollState?.projection.isRubberBanding == true {
            let phaseTracked = !phase.isEmpty || !momentumPhase.isEmpty
            if ended || !phaseTracked {
                // A real trackpad sends a zero-delta end/cancel sample. Keep
                // the edge under the user's finger until that sample, while
                // retaining a short fallback for phase-less precise devices.
                scheduleContinuousSettlement(after: ended ? 0 : 0.08)
            }
        }
        return true
    }

    /// Keyboard paging, semantic prompt jumps, and native scrollbar dragging
    /// are row-addressed SwiftTerm operations. Reconcile to their integer row
    /// in the same event turn so there is no stale fractional offset afterward.
    func prepareForDiscreteScrollInput() {
        cancelContinuousSettlement()
        guard continuousScrollState != nil || bounds.origin.y != 0 else { return }
        continuousScrollState = nil
        setBoundsOrigin(NSPoint(x: bounds.origin.x, y: 0))
        alignNativeScrollerToViewport()
        nativeScroller?.doubleValue = scrollPosition
        needsDisplay = true
        semanticDecorationView?.needsDisplay = true
        updateSemanticDecorations()
        layoutJumpToLiveBottomAffordance()
    }

    /// Output can trim the bounded SwiftTerm buffer while a retained view is
    /// fractionally parked in history. Rebase on the parser's new integer row,
    /// retaining the sub-row fraction and the exact mounted NSView identity.
    func reconcileContinuousViewportAfterBufferChange() {
        guard var state = continuousScrollState else { return }
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate else {
            prepareForDiscreteScrollInput()
            return
        }
        // Synchronized-output repaints and reflow briefly expose a normal
        // buffer with no scrollable geometry while SwiftTerm applies the
        // packet. That transient is not a discrete user scroll and must not
        // discard the mounted view's sub-row position. The next stable feed or
        // layout pass rebases the retained projection against real geometry.
        guard canScroll, let rowHeight = continuousScrollCellHeight else { return }
        state.reconfigure(
            anchorRow: terminal.getTopVisibleRow(),
            rowHeight: rowHeight,
            maximumRow: maximumContinuousScrollRow(),
            viewportExtent: bounds.height
        )
        continuousScrollState = state
        applyContinuousScrollProjection(moveIntegerRow: false)
    }

    /// A delegate callback caused by a scrollbar/key/prompt row change may
    /// arrive synchronously. Our own row crossing is marked so it keeps the
    /// fractional projection; every other genuine gesture becomes authoritative.
    func reconcileContinuousViewportAfterExternalScroll() {
        guard !isApplyingContinuousScrollRow,
              let projection = continuousScrollState?.projection,
              projection.anchorRow != getTerminal().getTopVisibleRow() else { return }
        prepareForDiscreteScrollInput()
    }

    private func applyContinuousScrollProjection(moveIntegerRow: Bool = true) {
        guard let projection = continuousScrollState?.projection else { return }
        let oldRow = getTerminal().getTopVisibleRow()
        if moveIntegerRow, oldRow != projection.anchorRow {
            isApplyingContinuousScrollRow = true
            scrollTo(row: projection.anchorRow, notifyAccessibility: false)
            isApplyingContinuousScrollRow = false
        }
        setBoundsOrigin(NSPoint(x: bounds.origin.x, y: -projection.offsetWithinAnchor))
        alignNativeScrollerToViewport()
        nativeScroller?.doubleValue = projection.scrollbarPosition
        needsDisplay = true
        semanticDecorationView?.needsDisplay = true
        updateJumpToLiveBottomVisibility()
        layoutJumpToLiveBottomAffordance()
        if oldRow != projection.anchorRow {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private func cancelContinuousSettlement() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(advanceContinuousSettlement),
            object: nil
        )
        continuousSettlementScheduled = false
    }

    /// `bounds.origin` deliberately moves the renderer and its interactive grid,
    /// but SwiftTerm installs its `NSScroller` as a direct child of that same
    /// view. Counter-position only that native chrome in bounds coordinates so
    /// its window-space track remains fixed while terminal rows move beneath it.
    private func alignNativeScrollerToViewport() {
        guard let scroller = nativeScroller else { return }
        var frame = scroller.frame
        frame.origin.y = bounds.minY
        frame.size.height = bounds.height
        if scroller.frame != frame {
            scroller.frame = frame
        }
    }

    private func scheduleContinuousSettlement(after delay: TimeInterval) {
        cancelContinuousSettlement()
        continuousSettlementScheduled = true
        perform(
            #selector(advanceContinuousSettlement),
            with: nil,
            afterDelay: max(0, delay)
        )
    }

    @objc private func advanceContinuousSettlement() {
        continuousSettlementScheduled = false
        guard var state = continuousScrollState,
              state.projection.isRubberBanding else { return }
        let continues = state.approachSettlement()
        continuousScrollState = state
        applyContinuousScrollProjection(moveIntegerRow: false)
        if continues {
            continuousSettlementScheduled = true
            perform(
                #selector(advanceContinuousSettlement),
                with: nil,
                afterDelay: 1 / 120
            )
        }
    }

    /// Deterministic fixture seam: production uses the 120 Hz edge return above.
    func settleContinuousScrollImmediately() {
        cancelContinuousSettlement()
        guard var state = continuousScrollState else { return }
        state.settle()
        continuousScrollState = state
        applyContinuousScrollProjection(moveIntegerRow: false)
    }

    /// Screen-relative cell under `point`.
    ///
    /// Exact rather than approximate: SwiftTerm's optimal frame width is
    /// `cellWidth * cols + scrollerWidth`, and it never hides its scroller, so
    /// subtracting the scroller recovers the true cell width.
    func terminalCell(at point: NSPoint) -> (column: Int, row: Int)? {
        guard bounds.contains(point) else { return nil }
        let dimensions = getTerminal().getDims()
        guard dimensions.cols > 0, dimensions.rows > 0 else { return nil }
        let optimal = getOptimalFrameSize().size
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
        let cellWidth = max(1, (optimal.width - scrollerWidth) / CGFloat(dimensions.cols))
        let cellHeight = max(1, optimal.height / CGFloat(dimensions.rows))
        let column = max(0, min(dimensions.cols - 1, Int(point.x / cellWidth)))
        // `point` is in the shifted bounds coordinate space. SwiftTerm's own
        // mouse hit testing intentionally measures from the fixed frame height;
        // doing the same folds the fractional bounds origin into the row hit.
        let row = max(0, min(dimensions.rows - 1, Int((frame.height - point.y) / cellHeight)))
        return (column, row)
    }

    /// True when the viewport is showing live output, so a screen row equals the
    /// row the cursor reports. On the alternate screen SwiftTerm reports
    /// `canScroll == false`, which is exactly the full-screen-TUI case.
    var isViewportAtLiveBottom: Bool {
        guard canScroll else { return true }
        guard scrollPosition >= 1.0 else { return false }
        guard let projection = continuousScrollState?.projection else { return true }
        return projection.boundedPosition
            >= CGFloat(projection.maximumRow) * projection.rowHeight
    }

    private func updateLinkCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (terminalLink(at: point) == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    /// Whether this terminal is the thing under the pointer, and therefore
    /// entitled to set the cursor for this event.
    ///
    /// The link affordance is driven by a *local NSEvent monitor* rather than by
    /// SwiftTerm's own (non-open) mouse callbacks, and a local monitor sees every
    /// `.mouseMoved` in the window — not only the ones over this view. Its sole
    /// guard used to be `event.window === window`, so every mounted terminal
    /// stamped `NSCursor.iBeam` on every pointer motion anywhere in its window,
    /// including motion over the sidebar splitter and the pane and panel
    /// dividers. Those dividers set `resizeLeftRight` from a `.cursorUpdate`
    /// tracking area, which fires once on entry; the very next mouse-moved event
    /// put the I-beam straight back. That is the whole "the resize cursor does
    /// not appear reliably" report: the cursor was being set correctly and then
    /// immediately overwritten, a frame later, by a view the pointer was nowhere
    /// near.
    ///
    /// Containment alone is not enough, because a divider corridor deliberately
    /// *overhangs* the cards on either side of it — inside this view's bounds is
    /// exactly where the contested pixels are. So this asks AppKit the same
    /// question a click does: hit-test the window and require the answer to be
    /// this view or something inside it. A tracker sitting above the terminal
    /// then wins the cursor, and a terminal with nothing over it is unaffected.
    private func ownsPointer(for event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        // `visibleRect`, not `bounds`: a pane scrolled or clipped out from under
        // the pointer must not claim it.
        guard visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return false }
        guard let hit = window.contentView?.hitTest(event.locationInWindow) else { return false }
        var candidate: NSView? = hit
        while let view = candidate {
            if view === self { return true }
            candidate = view.superview
        }
        return false
    }
    private var linkInteractionMonitor: Any?
    private var linkPointerDownInView = false
    var linkPointerDragged = false

    /// Terminal-style contextual commands. SwiftTerm provides the responder
    /// actions but no contextual menu of its own, so right-click previously
    /// offered none of the basic selection/copy controls users expect from a
    /// macOS terminal.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Terminal")
        addContextItem("Copy", action: #selector(copy(_:)), to: menu)
        semanticTracker.prune(before: getTerminal().buffer.totalLinesTrimmed)
        if !semanticTracker.commands.isEmpty {
            menu.addItem(.separator())
            let previous = addContextItem(
                "Previous Command",
                action: #selector(navigateToPreviousSemanticCommand(_:)),
                to: menu
            )
            previous.isEnabled = semanticPromptDestination(backward: true) != nil
            let next = addContextItem(
                "Next Command",
                action: #selector(navigateToNextSemanticCommand(_:)),
                to: menu
            )
            next.isEnabled = semanticPromptDestination(backward: false) != nil
        }
        menu.addItem(.separator())
        addContextItem("Select All", action: #selector(selectAll(_:)), to: menu)
        return menu
    }

    @discardableResult
    func addContextItem(
        _ title: String,
        action: Selector,
        to menu: NSMenu,
        at index: Int? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let index {
            menu.insertItem(item, at: index)
        } else {
            menu.addItem(item)
        }
        return item
    }

    /// Claim keyboard focus only from the window itself or its bare content
    /// view — never from a control the user is actually in (the sidebar list
    /// or the find bar's text field).
    static func shouldClaimFocus(currentFirstResponder: NSResponder?, window: NSWindow) -> Bool {
        currentFirstResponder == nil
            || currentFirstResponder === window
            || currentFirstResponder === window.contentView
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelContinuousSettlement()
            if continuousScrollState?.projection.isRubberBanding == true {
                settleContinuousScrollImmediately()
            }
            if let linkInteractionMonitor {
                NSEvent.removeMonitor(linkInteractionMonitor)
                self.linkInteractionMonitor = nil
            }
            linkPointerDownInView = false
            linkPointerDragged = false
        } else if linkInteractionMonitor == nil {
            // SwiftTerm's mouse callbacks are intentionally non-open. A local
            // monitor adds the cursor affordance and keeps a selection drag
            // from becoming a click when it ends over a link. SwiftTerm still
            // owns hover detection, selection, and TUI mouse reporting.
            linkInteractionMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self,
                          let window = self.window,
                          event.window === window else { return }
                    switch event.type {
                    case .mouseMoved:
                        // Only when the pointer is actually ours; see
                        // `ownsPointer(for:)`. Without this the terminal
                        // overwrote every divider's resize cursor.
                        guard self.ownsPointer(for: event) else { break }
                        self.updateLinkCursor(for: event)
                    case .leftMouseDown:
                        // Match the cursor path's hit-test ownership guard. A
                        // divider corridor can deliberately overhang this
                        // terminal's bounds; a press there belongs to the
                        // divider, not to terminal link-selection state.
                        self.linkPointerDownInView = self.ownsPointer(for: event)
                        self.linkPointerDragged = false
                    case .leftMouseDragged where self.linkPointerDownInView:
                        self.linkPointerDragged = true
                        // `mouseUp` opens a hover-visible link. Temporarily
                        // require Command after a real selection drag so the
                        // selection completes without surprising navigation.
                        self.linkHighlightMode = .hoverWithModifier
                    case .leftMouseUp where self.linkPointerDownInView:
                        let restoreHover = self.linkPointerDragged
                        self.linkPointerDownInView = false
                        self.linkPointerDragged = false
                        if restoreHover {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.window != nil else { return }
                                self.configureLinkInteraction()
                            }
                        }
                    default:
                        break
                    }
                }
                return event
            }
        }
        guard let window else { return }
        if Self.shouldClaimFocus(currentFirstResponder: window.firstResponder, window: window) {
            // AppKit-only: a mounting pane (a restored window, a project
            // switch reattaching a retained view) legitimately needs *some*
            // first responder, but mounting is not a user action. Publishing
            // here would let whichever pane happens to mount last steal the
            // pane focus ring — and the broker observer role that follows it
            // — from the pane the model actually restored. Only a genuine
            // user gesture (`mouseDown` below) reports keyboard focus to the
            // model.
            window.makeFirstResponder(self)
        }
    }

    /// SwiftTerm declares `becomeFirstResponder()` `public`, not `open`, so a
    /// subclass in this module cannot observe focus acquisition directly. A
    /// mouse-down in the grid is exactly when AppKit hands this view the first
    /// responder, and it is precisely the desync the pane ring had: keyboard
    /// focus moved into this pane while the ring stayed on the previous one.
    override func mouseDown(with event: NSEvent) {
        publishKeyboardFocus()
        super.mouseDown(with: event)
    }

    /// Tell the shell that typing now lands here. The shell ignores a report
    /// for the pane it already rings, so repeat clicks cost nothing.
    func publishKeyboardFocus() {
        onKeyboardFocus?()
    }

    override func layout() {
        super.layout()
        alignNativeScrollerToViewport()
        layoutJumpToLiveBottomAffordance()
        updateSemanticDecorations()
        if hasUsableRenderGeometry {
            onUsableLayout?()
        }
    }

    /// NavigationSplitView may assign a representable's final frame without a
    /// separate AppKit layout pass. Initial terminal replay cannot depend on
    /// `layout()` alone or the left-tree surface can remain an empty canvas
    /// until the user resizes the window. Frame assignment is the earliest
    /// reliable point at which SwiftTerm has real rows and columns.
    override func setFrameSize(_ newSize: NSSize) {
        let retainedProjection = newSize != frame.size
            ? continuousScrollState?.projection
            : nil
        if retainedProjection != nil {
            // Let SwiftTerm reflow from an integer anchor, then express the same
            // sub-row fraction in its new cell height below. Both happen inside
            // this frame mutation, so AppKit never presents the intermediate.
            cancelContinuousSettlement()
            continuousScrollState = nil
            setBoundsOrigin(NSPoint(x: bounds.origin.x, y: 0))
        }
        super.setFrameSize(newSize)
        if let retainedProjection,
           canScroll,
           !getTerminal().isCurrentBufferAlternate,
           let newRowHeight = continuousScrollCellHeight {
            let normalizedFraction = retainedProjection.isRubberBanding
                ? 0
                : max(0, min(1, retainedProjection.offsetWithinAnchor / retainedProjection.rowHeight))
            continuousScrollState = TerminalContinuousScrollState(
                anchorRow: getTerminal().getTopVisibleRow(),
                fractionalOffset: normalizedFraction * newRowHeight,
                rowHeight: newRowHeight,
                maximumRow: maximumContinuousScrollRow(),
                viewportExtent: bounds.height
            )
            applyContinuousScrollProjection(moveIntegerRow: false)
        }
        reconcileSemanticPromptGrid()
        updateSemanticDecorations()
        if hasUsableRenderGeometry {
            onUsableLayout?()
        }
    }

    /// Which palette is installed, so appearance/palette flips reconfigure once.
    private(set) var isLightTheme = false
    private(set) var themeKey = ""

    /// Installs either the clean native palette or the Electron-matched Kaisola
    /// palette. Both remain fully opaque so glass chrome never compromises a
    /// terminal's contrast.
    func configureTerminalTheme(light: Bool = false, themeID: String = "native") {
        let palette = TerminalTheme.palette(light: light, themeID: themeID)
        isLightTheme = light
        themeKey = "\(themeID):\(light ? "light" : "dark")"
        installColors(palette.ansi)
        nativeForegroundColor = palette.foreground
        nativeBackgroundColor = palette.background
        caretColor = palette.cursor
        selectedTextBackgroundColor = palette.selection
        useBrightColors = true
        wantsLayer = true
        layer?.backgroundColor = palette.background.cgColor
    }

    /// SwiftTerm advertises Sixel in its primary device attributes by default.
    /// Codex uses that capability to paint clipboard-image previews into the
    /// terminal grid; large previews can outlive a TUI reflow and overlap later
    /// rows while the user scrolls or output arrives. Keep clipboard attachment
    /// inside Codex, but withhold the unstable graphical preview capability so
    /// the CLI uses its text attachment fallback until the renderer has a
    /// continuous-output/resize-safe image lifecycle.
    func configureAdvertisedGraphicsCapabilities() {
        getTerminal().options.enableSixelReported = false
    }

    func updateAccessibilityValue(from output: String) {
        accessibilityAdapter.updateRetainedSource(output)
    }

    func updateAccessibilityValue(from scrollback: TerminalScrollback) {
        accessibilityAdapter.updateRetainedSource(
            scrollback.accessibilityTail(maxCharacters: Self.accessibilityTailLimit)
        )
    }

    /// Historical reconstruction is deliberately silent. Capture its final
    /// rendered viewport as the comparison baseline so the first live packet
    /// cannot make VoiceOver recite retained output from before the pane opened.
    func seedAccessibilityAnnouncementBaseline() {
        accessibilityAdapter.seedBaseline()
    }

    /// A live feed only marks work pending. Snapshotting and diffing wait for
    /// the throttle boundary, so token-by-token output never scans the viewport
    /// token by token. Only the AppKit-focused pane may speak; background panes
    /// mark their baseline stale and resume without announcing a backlog.
    func noteLiveOutputForAccessibility() {
        accessibilityAdapter.noteLiveOutput()
    }

    /// Deterministic test seam; production reaches the same delivery through
    /// the main-run-loop selector scheduled above.
    func deliverAccessibilityAnnouncementNow() {
        accessibilityAdapter.deliverAnnouncementNow()
    }

    /// Snap the viewport to the newest output (Electron sticky-scroll parity).
    /// `scroll(toPosition:)` is SwiftTerm's public relative-scroll API — 1.0 is
    /// the live bottom — and is a harmless no-op when there is nothing to
    /// scroll, so callers can invoke it after every feed while pinned.
    func scrollToLiveBottom() {
        prepareForDiscreteScrollInput()
        scroll(toPosition: 1)
        updateSemanticDecorations()
    }

    /// Follow the newest output without cancelling a gesture still in flight.
    ///
    /// Sticky-scroll runs the pin after every output batch, and `scrollToLiveBottom`
    /// routes through `prepareForDiscreteScrollInput`, which drops the continuous
    /// scroll state outright. That is right for the jump pill and the menu
    /// command, where the user asked to leave their position, and wrong for
    /// streamed output, where they may be holding a rubber band past the newest
    /// row. Collapsing it on every batch while the next trackpad sample rebuilt
    /// it from nothing is what a terminal running an agent showed as vibration.
    ///
    /// Rows underneath the band still advance: the band is displacement past the
    /// live bottom, so following that bottom is what keeps it meaningful.
    func followLiveBottomForStreamedOutput() {
        guard continuousScrollState?.projection.isRubberBanding == true else {
            scrollToLiveBottom()
            return
        }
        scroll(toPosition: 1)
        reconcileContinuousViewportAfterBufferChange()
        updateSemanticDecorations()
    }

    /// Erase the live renderer without touching the broker's retained history
    /// or the PTY. See `TerminalClearCommand` for why that is the only honest
    /// meaning "Clear Terminal" can have on a broker-backed surface.
    ///
    /// Refuses (returning `false`) while a retained transcript is still being
    /// fed in progressively: clearing now would only be half-undone a moment
    /// later when the next replay chunk repaints over it.
    @discardableResult
    func clearLiveScrollback() -> Bool {
        guard (terminalDelegate as? NativeTerminalSurface.Coordinator)?.isProgressivelyReplaying != true else {
            ToastCenter.shared.show(TerminalClearCommand.noTerminalMessage, style: .info)
            return false
        }
        feed(text: TerminalClearCommand.escapeSequence)
        // ED 3 resets `buffer.linesTop`, the coordinate space every recorded
        // OSC 133 mark lives in. Stale marks would decorate unrelated rows, so
        // drop the index and let later marks rebuild trustworthy bounds.
        resetSemanticPromptMarks()
        // The scrollback the user had scrolled into no longer exists, so the
        // pin state describing it is meaningless: follow live output again.
        resumeLiveFollow()
        scrollToLiveBottom()
        return true
    }

    /// Return the surface to sticky-scroll follow mode. Shared by the jump pill
    /// and by clearing, both of which end with the viewport at the live bottom.
    func resumeLiveFollow() {
        (terminalDelegate as? NativeTerminalSurface.Coordinator)?.resumeLiveFollow()
    }

    /// A small trailing pill offering the way back to live output. It exists
    /// only while the user is genuinely scrolled up; a permanently visible
    /// control would just be chrome over the terminal.
    func configureJumpToLiveBottomAffordance() {
        guard jumpToLiveBottomButton == nil else { return }
        let button = NSButton(
            title: "Latest",
            image: NSImage(
                systemSymbolName: "arrow.down.to.line.compact",
                accessibilityDescription: nil
            ) ?? NSImage(),
            target: self,
            action: #selector(jumpToLiveBottomClicked(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.isHidden = true
        button.toolTip = "Scroll to the newest output"
        button.setAccessibilityLabel("Scroll to latest output")
        button.setAccessibilityHelp("Returns this terminal to live output and resumes following it")
        addSubview(button, positioned: .above, relativeTo: nil)
        jumpToLiveBottomButton = button
        layoutJumpToLiveBottomAffordance()
    }

    @objc private func jumpToLiveBottomClicked(_ sender: Any?) {
        resumeLiveFollow()
        scrollToLiveBottom()
    }

    /// Visible only while the viewport is genuinely parked above live output.
    func updateJumpToLiveBottomVisibility() {
        guard let button = jumpToLiveBottomButton else { return }
        let visible = TerminalJumpToBottomPolicy.isVisible(
            canScroll: canScroll,
            isAtLiveBottom: isViewportAtLiveBottom,
            isAlternateBuffer: getTerminal().isCurrentBufferAlternate
        )
        guard button.isHidden == visible else { return }
        button.isHidden = !visible
        if visible { layoutJumpToLiveBottomAffordance() }
    }

    private func layoutJumpToLiveBottomAffordance() {
        guard let button = jumpToLiveBottomButton else { return }
        button.sizeToFit()
        button.frame = TerminalJumpToBottomPolicy.frame(
            in: bounds,
            size: button.frame.size,
            flipped: isFlipped
        )
    }

    /// Test seam: the affordance is a private subview, but its state is the
    /// whole contract ("only while scrolled up").
    var jumpToLiveBottomIsVisible: Bool {
        jumpToLiveBottomButton.map { !$0.isHidden } ?? false
    }

    @discardableResult
    func performJumpToLiveBottom() -> Bool {
        guard let button = jumpToLiveBottomButton, !button.isHidden else { return false }
        jumpToLiveBottomClicked(button)
        return true
    }

    /// Launch command of the CLI running in this pane (`claude`, `codex`, …), so
    /// a dropped image can use the attachment syntax that CLI understands. Nil
    /// for a plain shell, where a bare path is the correct thing to paste.
    var agentLaunchCommand: String?

    /// True only when a real user scroll gesture is in flight.
    ///
    /// SwiftTerm's `scrollWheel` is `public` rather than `open` and its
    /// `pageUp`/`pageDown` live in an extension, so none of them can be
    /// overridden from this module. A local event monitor observes the same
    /// gestures without subclassing.
    var isUserScrollGesture: Bool { TerminalScrollGestureMonitor.isActive(for: self) }

    /// Mirrors SwiftTerm's wheel-routing decision without touching its private
    /// accumulator: normal-buffer events use native scrollback unless the
    /// application requested mouse reports and Shift did not bypass them.
    func wheelUsesNativeScrollback(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        let shiftBypassesMouseReporting = event.modifierFlags.contains(.shift)
            && !terminal.mouseShiftCapture
        return !terminal.isCurrentBufferAlternate
            && canScroll
            && (!allowMouseReporting
                || terminal.mouseMode == .off
                || shiftBypassesMouseReporting)
    }

    /// A second upward gesture at row zero is the explicit seam between the
    /// interactive renderer and immutable history. Returning `true` means the
    /// request was accepted; the wheel event itself still reaches SwiftTerm and
    /// remains a harmless top-edge no-op. Alternate-screen TUIs never enter
    /// this lane because `canScroll` is false there.
    @discardableResult
    func requestHistoryBeyondTop(
        scrollingDeltaY: CGFloat,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let atContinuousTop = continuousScrollState.map {
            $0.projection.boundedPosition <= 0
        } ?? true
        guard scrollingDeltaY > 0,
              canScroll,
              getTerminal().getTopVisibleRow() == 0,
              atContinuousTop,
              let onHistoryBoundary,
              now - lastHistoryBoundaryRequestAt >= Self.historyBoundaryRequestCooldown else {
            return false
        }
        lastHistoryBoundaryRequestAt = now
        onHistoryBoundary()
        return true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? { accessibilityAdapter.currentSnapshot() }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = super.accessibilityCustomActions() ?? []
        guard canScroll, !getTerminal().isCurrentBufferAlternate else { return actions }
        actions.append(accessibilityPageUpAction)
        actions.append(accessibilityPageDownAction)
        return actions
    }

    /// VoiceOver's increment/decrement actions share the exact same discrete
    /// page route as Page Down/Page Up and the native scroller. The scrollbar
    /// remains a real NSScroller child, while the terminal keeps its text-area
    /// role and bounded, parser-derived value.
    override func accessibilityPerformDecrement() -> Bool {
        guard canScroll, !getTerminal().isCurrentBufferAlternate else { return false }
        let before = getTerminal().getTopVisibleRow()
        prepareForDiscreteScrollInput()
        TerminalScrollGestureMonitor.noteAccessibilityGesture(
            view: self,
            scrollingUpward: true
        )
        pageUp()
        let moved = getTerminal().getTopVisibleRow() != before
        if moved { NSAccessibility.post(element: self, notification: .valueChanged) }
        return moved
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard canScroll, !getTerminal().isCurrentBufferAlternate else { return false }
        let before = getTerminal().getTopVisibleRow()
        prepareForDiscreteScrollInput()
        TerminalScrollGestureMonitor.noteAccessibilityGesture(
            view: self,
            scrollingUpward: false
        )
        pageDown()
        let moved = getTerminal().getTopVisibleRow() != before
        if moved { NSAccessibility.post(element: self, notification: .valueChanged) }
        return moved
    }

    @objc private func performAccessibilityPageUp() -> Bool {
        accessibilityPerformDecrement()
    }

    @objc private func performAccessibilityPageDown() -> Bool {
        accessibilityPerformIncrement()
    }

    private func accessibilityTextSnapshot(retainedSource: String) -> String {
        let terminal = getTerminal()
        let dimensions = terminal.getDims()
        if dimensions.cols > 0, dimensions.rows > 0 {
            let viewportTop = max(0, terminal.getTopVisibleRow())
            let rendered = terminal.getText(
                start: Position(col: 0, row: viewportTop),
                end: Position(
                    col: dimensions.cols,
                    row: viewportTop + dimensions.rows
                )
            )
            if !rendered.isEmpty {
                return String(rendered.suffix(Self.accessibilityTailLimit))
            }
        }

        // Initial progressive replay can leave the parsed grid empty for a few
        // main-actor turns. Never expose the raw broker stream during that
        // window: replay only its bounded tail through the same parser used by
        // transcript export, so OSC/CSI/DCS bytes cannot reach VoiceOver.
        let rawTail = String(retainedSource.suffix(Self.accessibilityTailLimit))
        let plain = TerminalTranscriptSanitizer.plainPages(
            [rawTail],
            columns: max(2, dimensions.cols),
            rows: max(1, dimensions.rows)
        ).joined()
        return String(plain.suffix(Self.accessibilityTailLimit))
    }
}
