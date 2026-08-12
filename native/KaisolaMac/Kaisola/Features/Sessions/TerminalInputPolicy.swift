import AppKit
import SwiftTerm

/// "Clear Terminal" for a surface whose history the broker owns.
///
/// A Kaisola terminal is not the authority on its own output: the broker keeps
/// an append-only spool and every renderer — this window, a popped-out window,
/// the transcript sheet, the phone companion — is reconstructed from it. There
/// is therefore nothing a clear could delete here that would stay deleted, and
/// deleting broker bytes would be the wrong promise to make from a View menu
/// item. Typing `clear` into the PTY is also wrong: it would land in whatever
/// the user (or an agent CLI) has half-composed at the prompt.
///
/// So this clears the *live renderer* only — erase the visible screen, drop
/// SwiftTerm's in-memory scrollback, home the cursor, and return to the live
/// bottom. The PTY is untouched and the coordinator's rendered byte cursor is
/// unchanged, so streaming output keeps appending incrementally rather than
/// forcing a full re-feed. A later full reconstruction (a stream-epoch change,
/// or a pane remounted from a project switch) legitimately repaints the earlier
/// output, and the retained transcript can always still reach it.
enum TerminalClearCommand {
    /// CUP home + ED 2 (erase display) + ED 3 (erase scrollback), fed through
    /// the parser instead of mutating SwiftTerm's buffers directly so cursor,
    /// wrap, and image state stay consistent with the renderer's own rules.
    static let escapeSequence = "\u{1B}[H\u{1B}[2J\u{1B}[3J"

    /// Shown when the command is invoked with no terminal to act on, because a
    /// silent no-op is exactly the failure this bundle exists to remove.
    static let noTerminalMessage = "Focus a terminal to clear it."
}

/// When the "jump to live output" pill is offered, and where it sits.
///
/// The pill is strictly a recovery affordance for a viewport the user moved:
/// it must never appear on a surface that cannot scroll, and never over a
/// full-screen TUI, where SwiftTerm pins `scrollPosition` to 0 on the
/// alternate buffer and "the bottom" has no meaning.
enum TerminalJumpToBottomPolicy {
    static let trailingInset: CGFloat = 12
    static let bottomInset: CGFloat = 10
    /// The legacy scroller keeps a permanently visible track on the right edge;
    /// clear it so the pill never sits under the user's scroll target.
    static let scrollerInset: CGFloat = 16

    static func isVisible(
        canScroll: Bool,
        isAtLiveBottom: Bool,
        isAlternateBuffer: Bool
    ) -> Bool {
        canScroll && !isAlternateBuffer && !isAtLiveBottom
    }

    static func frame(in bounds: NSRect, size: NSSize, flipped: Bool) -> NSRect {
        let x = max(bounds.minX, bounds.maxX - size.width - trailingInset - scrollerInset)
        let y = flipped
            ? max(bounds.minY, bounds.maxY - size.height - bottomInset)
            : bounds.minY + bottomInset
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

/// Fractional macOS scroll state layered over SwiftTerm's integer `yDisp`.
///
/// SwiftTerm remains the only parser, buffer owner, and row renderer. Its AppKit
/// renderer deliberately paints the first row just below the viewport, so the
/// host can reveal that row continuously by moving the view's bounds origin
/// while keeping `yDisp` on the integer row immediately above it. This state is
/// point-based (rather than event-count-based), which preserves AppKit's native
/// trackpad acceleration and momentum samples without reimplementing either.
struct TerminalContinuousScrollProjection: Equatable, Sendable {
    let rawPosition: CGFloat
    let boundedPosition: CGFloat
    let presentedPosition: CGFloat
    let rowHeight: CGFloat
    let maximumRow: Int
    let anchorRow: Int
    let offsetWithinAnchor: CGFloat
    let scrollbarPosition: Double
    let isRubberBanding: Bool
}

struct TerminalContinuousScrollState: Equatable, Sendable {
    /// Matches AppKit's rubber-band curve: displacement remains responsive at
    /// the edge, then asymptotically resists pulling farther than the viewport.
    private static let rubberBandCoefficient: CGFloat = 0.55

    private(set) var rawPosition: CGFloat
    private(set) var rowHeight: CGFloat
    private(set) var maximumRow: Int
    private(set) var viewportExtent: CGFloat

    init(
        anchorRow: Int,
        fractionalOffset: CGFloat,
        rowHeight: CGFloat,
        maximumRow: Int,
        viewportExtent: CGFloat
    ) {
        self.rowHeight = max(1, rowHeight)
        self.maximumRow = max(0, maximumRow)
        self.viewportExtent = max(1, viewportExtent)
        let row = max(0, min(anchorRow, self.maximumRow))
        self.rawPosition = CGFloat(row) * self.rowHeight + fractionalOffset
    }

    var projection: TerminalContinuousScrollProjection {
        let maximumPosition = CGFloat(maximumRow) * rowHeight
        let boundedPosition = max(0, min(rawPosition, maximumPosition))
        let presentedPosition: CGFloat
        if rawPosition < 0 {
            presentedPosition = -Self.rubberBandDistance(
                -rawPosition,
                dimension: viewportExtent
            )
        } else if rawPosition > maximumPosition {
            presentedPosition = maximumPosition + Self.rubberBandDistance(
                rawPosition - maximumPosition,
                dimension: viewportExtent
            )
        } else {
            presentedPosition = rawPosition
        }

        let anchorRow: Int
        if boundedPosition >= maximumPosition {
            anchorRow = maximumRow
        } else {
            anchorRow = max(0, min(maximumRow, Int(floor(boundedPosition / rowHeight))))
        }
        let offset = presentedPosition - CGFloat(anchorRow) * rowHeight
        let scrollbarPosition = maximumPosition > 0
            ? Double(boundedPosition / maximumPosition)
            : 1
        return TerminalContinuousScrollProjection(
            rawPosition: rawPosition,
            boundedPosition: boundedPosition,
            presentedPosition: presentedPosition,
            rowHeight: rowHeight,
            maximumRow: maximumRow,
            anchorRow: anchorRow,
            offsetWithinAnchor: offset,
            scrollbarPosition: scrollbarPosition,
            isRubberBanding: rawPosition < 0 || rawPosition > maximumPosition
        )
    }

    mutating func apply(scrollingDeltaY: CGFloat) {
        // AppKit/SwiftTerm define positive delta Y as movement toward older
        // output, while this coordinate grows toward the live bottom.
        rawPosition -= scrollingDeltaY
    }

    /// Rebase after output trimming or geometry changes while retaining the
    /// exact sub-row location. This never scans or materializes scrollback.
    mutating func reconfigure(
        anchorRow: Int,
        rowHeight newRowHeight: CGFloat,
        maximumRow newMaximumRow: Int,
        viewportExtent newViewportExtent: CGFloat
    ) {
        let oldProjection = projection
        // Displacement past an edge is not a position within a row, so it is
        // carried across the rebase in points rather than as a fraction. This
        // is exactly zero unless a band is active, so a normal rebase is
        // unchanged. Streamed output moves the live bottom on every batch, and
        // dropping the band each time is what made an overscrolled terminal
        // vibrate under a running agent instead of resting under the finger.
        let overshoot = rawPosition - oldProjection.boundedPosition
        let oldFraction = oldProjection.isRubberBanding
            ? 0
            : max(0, min(1, oldProjection.offsetWithinAnchor / rowHeight))
        rowHeight = max(1, newRowHeight)
        maximumRow = max(0, newMaximumRow)
        viewportExtent = max(1, newViewportExtent)
        let row = max(0, min(anchorRow, maximumRow))
        rawPosition = CGFloat(row) * rowHeight + oldFraction * rowHeight + overshoot
    }

    /// Advance a deterministic critically-damped-looking edge return. Returns
    /// true while another frame is useful and false once the edge is exact.
    @discardableResult
    mutating func approachSettlement(retainingOvershoot: CGFloat = 0.68) -> Bool {
        let maximumPosition = CGFloat(maximumRow) * rowHeight
        let target = max(0, min(rawPosition, maximumPosition))
        let remaining = rawPosition - target
        guard abs(remaining) > 0.1 else {
            rawPosition = target
            return false
        }
        rawPosition = target + remaining * max(0, min(retainingOvershoot, 0.95))
        return true
    }

    mutating func settle() {
        rawPosition = max(0, min(rawPosition, CGFloat(maximumRow) * rowHeight))
    }

    private static func rubberBandDistance(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        let dimension = max(1, dimension)
        return dimension * (1 - 1 / (distance * rubberBandCoefficient / dimension + 1))
    }
}

/// OSC 52 — "put this on the user's clipboard" — from a program running in the
/// terminal.
///
/// This is a genuinely useful capability (an agent CLI offering to copy a
/// command, `tmux`/`nvim` yanking over SSH) and a genuinely dangerous one: the
/// emitter can be any script, on either end of a remote session, and silently
/// replacing what a user is about to paste into their shell is a known attack
/// rather than a hypothetical. Kaisola therefore refuses the write unless the
/// user has explicitly granted it in Settings > Terminal, and tells them once
/// where the switch is instead of failing invisibly.
///
/// The *read* half is never granted: SwiftTerm asks through `clipboardRead`,
/// and returning nil there makes it send no reply at all, so no clipboard
/// contents can be exfiltrated to whatever is running in the pane.
enum TerminalClipboardWriteRequest {
    enum Decision: Equatable {
        /// Consent is granted and the payload is usable clipboard text.
        case copy(String)
        /// Consent is withheld. `showsGuidance` is true only for the first
        /// blocked attempt, so a chatty program cannot turn the refusal into a
        /// wall of toasts.
        case refused(showsGuidance: Bool)
        /// Nothing a person could have meant to paste.
        case ignored
    }

    /// A clipboard write is a short piece of text a human is about to paste.
    /// SwiftTerm has already base64-decoded the payload; this caps what is
    /// accepted so a runaway program cannot push megabytes onto the pasteboard.
    static let maximumPayloadBytes = 256 * 1_024

    static let guidanceMessage =
        "A terminal program tried to change your clipboard. Allow it in Settings > Terminal."

    static func decide(
        content: Data,
        consentGranted: Bool,
        hasShownGuidance: Bool
    ) -> Decision {
        // Validity is decided before consent on purpose: a malformed or absurd
        // payload was never a clipboard write, so it must not spend the single
        // guidance toast the user gets.
        guard !content.isEmpty,
              content.count <= maximumPayloadBytes,
              let text = String(data: content, encoding: .utf8),
              !containsRejectedControls(text) else { return .ignored }
        let payload = trimmingExecutionNewlines(text)
        guard !payload.isEmpty else { return .ignored }
        guard consentGranted else { return .refused(showsGuidance: !hasShownGuidance) }
        return .copy(payload)
    }

    /// Tab, newline, and carriage return are ordinary text; every other C0
    /// control (and DEL) is either a terminal command that escaped its parser
    /// or an attempt to hide part of the payload from whatever renders the
    /// paste. Neither belongs on a text pasteboard.
    private static func containsRejectedControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            guard value < 0x20 || value == 0x7F else { return false }
            return value != 0x09 && value != 0x0A && value != 0x0D
        }
    }

    /// Drop trailing newlines. Copying "text" and "text\n" is indistinguishable
    /// to the user, but pasting the second into a shell *runs* it — the classic
    /// OSC 52 auto-execute vector. Interior newlines are preserved.
    ///
    /// Scalars, not `Character`s: `\r\n` is a single Swift grapheme cluster, so
    /// a `Character`-based trim silently leaves a CRLF terminator in place —
    /// exactly the payload this is meant to defuse.
    private static func trimmingExecutionNewlines(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while let last = scalars.last, last == "\n" || last == "\r" {
            scalars.removeLast()
        }
        return String(scalars)
    }
}

/// The other half of focus synchronization: after the model moves its pane
/// focus, AppKit's first responder must follow, or the ring says one thing
/// while typing (and VoiceOver) go somewhere else.
@MainActor
enum TerminalKeyboardFocus {
    /// Never take the keyboard away from somewhere the user is typing. The
    /// field editor behind every `NSTextField` — the omnibar, a rename sheet,
    /// a chat composer — is an `NSText`, so this one check covers them all.
    static func canClaimFocus(from responder: NSResponder?) -> Bool {
        guard let responder else { return true }
        return !(responder is NSText)
    }

    @discardableResult
    static func moveFirstResponder(
        toSessionID id: String,
        in window: NSWindow? = NSApplication.shared.keyWindow
    ) -> Bool {
        guard let window,
              let root = window.contentView,
              let terminal = TerminalFocusResolver.terminal(in: root, paneID: id),
              window.firstResponder !== terminal,
              canClaimFocus(from: window.firstResponder) else { return false }
        return window.makeFirstResponder(terminal)
    }
}

/// Which terminal a window-level command acts on.
///
/// The model's focused pane is the surface the user can *see* highlighted, so
/// it wins; the AppKit first responder is the fallback for the moments before
/// the two agree. Refusing the command is deliberately preferred over
/// grabbing some other terminal in the window: when the focused pane is a
/// chat or Mesh surface (or the id is simply stale), acting on an unrelated
/// terminal elsewhere in the layout would be a surprise, not a convenience.
@MainActor
enum TerminalFocusResolver {
    static func focusedTerminal(in window: NSWindow?, paneID: String?) -> ReadOnlyTerminalView? {
        guard let window, let root = window.contentView else { return nil }
        if let paneID, let match = terminal(in: root, paneID: paneID) { return match }
        // A live first responder is still trustworthy evidence of where the
        // keyboard actually is right now. An arbitrary DFS match through the
        // rest of the view tree is not, so there is no further fallback.
        return window.firstResponder as? ReadOnlyTerminalView
    }

    /// Depth-first search for a terminal view. A nil `paneID` matches the first
    /// terminal found, which is what a single-pane window always wants.
    static func terminal(in root: NSView, paneID: String?) -> ReadOnlyTerminalView? {
        if let terminal = root as? ReadOnlyTerminalView,
           paneID == nil || terminal.paneSessionID == paneID {
            return terminal
        }
        for subview in root.subviews {
            if let match = terminal(in: subview, paneID: paneID) { return match }
        }
        return nil
    }
}

/// Records when the user last performed a scroll gesture, so terminal scroll
/// callbacks can be attributed to intent rather than to layout.
///
/// SwiftTerm emits `scrolled(source:position:)` from several paths that involve
/// no user at all — `Terminal.resize` (which every pane geometry change runs),
/// a one-second synchronized-output timeout that agent TUIs arm constantly via
/// DECSET 2026, and `resetToInitialState`. Each of those latched the surface's
/// "user scrolled away" flag, after which nothing ever re-pinned it; that is why
/// terminals came back from a project tab switch stranded mid-scrollback.
///
/// A local monitor is used because SwiftTerm exposes none of these entry points
/// for overriding: `scrollWheel` is `public`, not `open`, and `pageUp`/`pageDown`
/// are declared in an extension.
@MainActor
enum TerminalScrollGestureMonitor {
    /// How long after a gesture a scroll callback is still attributed to it.
    /// Comfortably covers a queued display pass without spanning the 1s
    /// synchronized-output timeout.
    static let recencyWindow: TimeInterval = 0.25

    private static var monitor: Any?
    private static var lastGestureTimestamp: TimeInterval = -.greatestFiniteMagnitude
    private static weak var lastGestureView: ReadOnlyTerminalView?
    private static var lastGestureWasUpward = false
    private static weak var activeScrollerGestureView: ReadOnlyTerminalView?

    /// Page keys SwiftTerm treats as scrollback navigation.
    private static let scrollKeyCodes: Set<UInt16> = [116, 121] // page up, page down

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .scrollWheel, .magnify, .swipe, .keyDown,
                .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            ]
        ) { event in
            if event.type == .leftMouseDown
                || event.type == .leftMouseDragged
                || event.type == .leftMouseUp {
                let view: ReadOnlyTerminalView?
                if event.type == .leftMouseDown {
                    view = terminalViewForScroller(at: event)
                    activeScrollerGestureView = view
                } else {
                    view = activeScrollerGestureView
                }
                if let view, event.window === view.window {
                    if event.type == .leftMouseDown {
                        view.prepareForDiscreteScrollInput()
                    }
                    recordGesture(view: view, at: event.timestamp, scrollingUpward: false)
                }
                if event.type == .leftMouseUp {
                    activeScrollerGestureView = nil
                }
                return event
            }
            if event.type == .keyDown,
               let view = terminalView(for: event),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.keyCode == 126 || event.keyCode == 125 {
                let backward = event.keyCode == 126
                // Attribute the gesture before `scrollTo(row:)` invokes the
                // delegate synchronously; otherwise output can immediately
                // undo this explicit command jump.
                if view.navigateSemanticPrompt(
                    backward: backward,
                    beforeScroll: {
                        recordGesture(
                            view: view,
                            at: event.timestamp,
                            scrollingUpward: backward
                        )
                    }
                ) {
                    return nil
                }
            }
            if let view = terminalView(for: event),
               (event.type != .keyDown || scrollKeyCodes.contains(event.keyCode)) {
                if event.type == .scrollWheel {
                    let routesToNativeScrollback = view.wheelUsesNativeScrollback(event)
                    recordGesture(
                        view: view,
                        at: event.timestamp,
                        scrollingUpward: event.scrollingDeltaY > 0
                            && routesToNativeScrollback
                    )
                    // SwiftTerm's macOS `scrollWheel(with:)` is non-open and
                    // row-quantized. Consume only precise normal-buffer samples;
                    // alternate screens and app mouse reporting continue into
                    // SwiftTerm byte-for-byte unchanged.
                    let handledContinuously = view.handleContinuousScroll(
                        scrollingDeltaY: event.scrollingDeltaY,
                        hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                        phase: event.phase,
                        momentumPhase: event.momentumPhase,
                        routesToNativeScrollback: routesToNativeScrollback
                    )
                    if !handledContinuously,
                       !event.hasPreciseScrollingDeltas || !routesToNativeScrollback {
                        view.prepareForDiscreteScrollInput()
                    }
                    // SwiftTerm uses positive `scrollingDeltaY` for upward
                    // movement. The history seam is checked against the exact
                    // fractional position, not merely integer row zero.
                    _ = view.requestHistoryBeyondTop(
                        scrollingDeltaY: event.scrollingDeltaY,
                        now: event.timestamp
                    )
                    if handledContinuously { return nil }
                } else if event.type == .keyDown {
                    view.prepareForDiscreteScrollInput()
                    recordGesture(
                        view: view,
                        at: event.timestamp,
                        scrollingUpward: view.canScroll && event.keyCode == 116
                    )
                } else {
                    recordGesture(
                        view: view,
                        at: event.timestamp,
                        scrollingUpward: false
                    )
                }
                if event.type == .keyDown, event.keyCode == 116 {
                    // Page Up is SwiftTerm's keyboard scrollback route.
                    // Repeating it at row zero should cross the same history
                    // seam as a continued trackpad gesture. Home/End are sent
                    // to the application and are intentionally not attributed.
                    _ = view.requestHistoryBeyondTop(
                        scrollingDeltaY: 1,
                        now: event.timestamp
                    )
                }
            }
            return event
        }
    }

    /// `NSEvent.timestamp` and `systemUptime` share the same time base.
    static func isActive(for view: ReadOnlyTerminalView) -> Bool {
        lastGestureView === view
            && ProcessInfo.processInfo.systemUptime - lastGestureTimestamp < recencyWindow
    }

    static func isScrollingUpward(for view: ReadOnlyTerminalView) -> Bool {
        isActive(for: view) && lastGestureWasUpward
    }

    /// A real SwiftTerm scroll callback supersedes the pending direction hint;
    /// from this point the exact public position is the pinning authority.
    static func acknowledgeScrollPosition(for view: ReadOnlyTerminalView) {
        guard lastGestureView === view else { return }
        lastGestureWasUpward = false
    }

    /// Test seam — lets the pin policy be exercised without synthesising events.
    static func noteGestureForTesting(
        view: ReadOnlyTerminalView,
        at timestamp: TimeInterval? = nil,
        scrollingUpward: Bool = true
    ) {
        lastGestureTimestamp = timestamp ?? ProcessInfo.processInfo.systemUptime
        lastGestureView = view
        lastGestureWasUpward = scrollingUpward
    }

    /// Accessibility actions are genuine user navigation even though they do
    /// not pass through NSEvent. Attribute them to the same sticky-scroll lane
    /// so streamed output cannot immediately undo a VoiceOver page movement.
    static func noteAccessibilityGesture(
        view: ReadOnlyTerminalView,
        scrollingUpward: Bool
    ) {
        recordGesture(
            view: view,
            at: ProcessInfo.processInfo.systemUptime,
            scrollingUpward: scrollingUpward
        )
    }

    static func resetForTesting() {
        lastGestureTimestamp = -.greatestFiniteMagnitude
        lastGestureView = nil
        lastGestureWasUpward = false
        activeScrollerGestureView = nil
    }

    private static func recordGesture(
        view: ReadOnlyTerminalView,
        at timestamp: TimeInterval,
        scrollingUpward: Bool
    ) {
        lastGestureTimestamp = timestamp
        lastGestureView = view
        lastGestureWasUpward = scrollingUpward
    }

    /// Attribute mouse tracking only when it began on SwiftTerm's actual native
    /// NSScroller. Text selection and link clicks inside the terminal must not
    /// acquire permission to mutate sticky-scroll state.
    private static func terminalViewForScroller(at event: NSEvent) -> ReadOnlyTerminalView? {
        guard let window = event.window,
              let contentView = window.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        var foundScroller = false
        while let view = candidate {
            if view is NSScroller { foundScroller = true }
            if let terminal = view as? ReadOnlyTerminalView {
                return foundScroller ? terminal : nil
            }
            candidate = view.superview
        }
        return nil
    }

    private static func terminalView(for event: NSEvent) -> ReadOnlyTerminalView? {
        if event.type == .keyDown {
            return event.window?.firstResponder as? ReadOnlyTerminalView
        }
        guard let window = event.window,
              let contentView = window.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let view = candidate {
            if let terminal = view as? ReadOnlyTerminalView { return terminal }
            candidate = view.superview
        }
        return nil
    }
}

/// The writable variant for native-owned sessions: SwiftTerm's normal input
/// path stays intact and lands in the delegate's `send`, which the surface
/// forwards to the broker controller connection.
final class OwnedTerminalView: ReadOnlyTerminalView {
    private var fileDropActive = false
    private(set) var isInputAuthorized = false

    /// The concrete class expresses durable controller eligibility; this
    /// revocable capability expresses whether this exact controller connection
    /// owns the PTY right now. Default-denied prevents a just-created or reused
    /// view from emitting before the coordinator callbacks are fully rebound.
    func setInputAuthorized(_ authorized: Bool) {
        guard isInputAuthorized != authorized else {
            allowMouseReporting = authorized
            setAccessibilityLabel(authorized ? "Terminal" : "Read-only terminal output")
            reconcileInputAffordances()
            return
        }
        isInputAuthorized = authorized
        allowMouseReporting = authorized
        setAccessibilityLabel(authorized ? "Terminal" : "Read-only terminal output")
        reconcileInputAffordances()
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard isInputAuthorized else {
            notifyReadOnlyInput()
            return
        }
        terminalDelegate?.send(source: self, data: data)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu(title: "Terminal")
        if isInputAuthorized {
            addContextItem("Paste", action: #selector(paste(_:)), to: menu, at: min(1, menu.items.count))
        }
        return menu
    }

    /// Codex owns clipboard-image ingestion behind Control-V, while macOS
    /// users naturally invoke Command-V (including Edit > Paste). SwiftTerm's
    /// generic paste implementation only asks the pasteboard for text, so an
    /// image-only clipboard otherwise becomes a silent no-op. Forward the
    /// image-specific key to Codex only when an image is actually present;
    /// ordinary text continues through SwiftTerm's bracketed-paste path.
    override func paste(_ sender: Any) {
        guard isInputAuthorized else {
            notifyReadOnlyInput()
            return
        }
        if agentLaunchCommand == "codex",
           TerminalImageDrop.pasteboardContainsImage(.general) {
            send(source: getTerminal(), data: ArraySlice([0x16]))
            return
        }
        if let plan = TerminalImageDrop.pastePlan(
            from: .general,
            syntax: TerminalImageDrop.syntax(forLaunchCommand: agentLaunchCommand)
        ) {
            insert(plan)
            return
        }
        let terminal = getTerminal()
        if terminal.bracketedPasteMode,
           let text = NSPasteboard.general.string(forType: .string) {
            sendBracketedPaste(text, to: terminal)
            return
        }
        super.paste(sender)
    }

    /// Claude Code's own image paste is Control-V, and that path reads the
    /// macOS clipboard itself — which is precisely how it ends up attaching a
    /// file's *icon* instead of the file (see `TerminalImageDrop.pastePlan`).
    /// So when an image is on the clipboard, Control-V is answered here with a
    /// staged `@` mention instead of being forwarded.
    ///
    /// Only when a plan comes back: with no image on the clipboard Control-V is
    /// still Control-V, which in a plain shell is the literal-next-character
    /// quote and must keep working.
    func handleControlVIfImagePresent() -> Bool {
        guard isInputAuthorized else { return false }
        guard let plan = TerminalImageDrop.pastePlan(
            from: .general,
            syntax: TerminalImageDrop.syntax(forLaunchCommand: agentLaunchCommand)
        ) else { return false }
        insert(plan)
        return true
    }

    /// ⌥-click moves the cursor to the click, the way iTerm2 and Terminal.app
    /// do — which is how you reposition inside an agent CLI's composer.
    ///
    /// Nothing in the stack implemented this: SwiftTerm reads `.shift` on the
    /// mouse paths and never `.option`, so a ⌥-click landed in a branch that
    /// does nothing. Worse, it wasn't inert — link activation ignores modifiers,
    /// so ⌥-clicking a path in the composer opened a file preview instead.
    ///
    /// This is synthesised as arrow keys, which is what terminal emulators
    /// actually do; there is no protocol-level "put the cursor here". The
    /// horizontal case needs only `getCursorLocation()`. Vertical movement is
    /// allowed solely when OSC 133 proves both rows are active prompt input.
    override func mouseUp(with event: NSEvent) {
        guard isInputAuthorized,
              shouldHandleOptionClick(event),
              let cell = terminalCell(at: convert(event.locationInWindow, from: nil)),
              // A scrolled-back viewport row is not the cursor's screen row.
              isViewportAtLiveBottom
        else {
            super.mouseUp(with: event)
            return
        }

        // Claim the event either way. Returning without `super` is what
        // suppresses the link activation and mouse-report release below it.
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        // Outside a proven active OSC 133 input region, Up/Down can recall
        // history in shell and agent composers. Consume the vertical click
        // without emitting bytes when either row lies beyond those bounds.
        let verticalDelta = cell.row - cursor.y
        if verticalDelta != 0 {
            guard let cursorPosition = scrollInvariantCursorPosition(),
                  let inputRows = semanticTracker.activeInputRows else { return }
            let clickedRow = terminal.buffer.totalLinesTrimmed
                + terminal.getTopVisibleRow()
                + cell.row
            guard inputRows.contains(cursorPosition.row),
                  inputRows.contains(clickedRow) else { return }
        }

        let horizontalDelta = cell.column - cursor.x
        guard verticalDelta != 0 || horizontalDelta != 0 else { return }

        let applicationCursor = terminal.applicationCursor
        // Capped so a stray click on a very wide pane cannot spray hundreds of
        // bytes at the CLI.
        var payload: [UInt8] = []
        let verticalKey = verticalDelta > 0
            ? (applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            : (applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
        for _ in 0..<min(abs(verticalDelta), terminal.rows) {
            payload.append(contentsOf: verticalKey)
        }
        let horizontalKey = horizontalDelta > 0
            ? (applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
            : (applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
        for _ in 0..<min(abs(horizontalDelta), terminal.cols) {
            payload.append(contentsOf: horizontalKey)
        }
        send(source: terminal, data: ArraySlice(payload))
    }

    /// Option alone, a real click rather than the end of a drag-selection.
    private func shouldHandleOptionClick(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1, !linkPointerDragged else { return false }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
    }

    /// Finder/iTerm-style file drops are bracketed-pasted into the active CLI.
    /// Using SwiftTerm's paste path (rather than a raw broker write) preserves
    /// the terminal mode those TUIs negotiated.
    ///
    /// See `TerminalImageDrop` for why an image is staged and mentioned rather
    /// than pasted as a plain path — in short, a quoted path attaches nothing,
    /// and macOS screenshot filenames contain spaces that break `@` mentions.
    static func droppedFileText(_ urls: [URL], agentLaunchCommand: String?) -> String {
        droppedFilePlan(urls, agentLaunchCommand: agentLaunchCommand).text
    }

    static func droppedFilePlan(
        _ urls: [URL],
        agentLaunchCommand: String?
    ) -> TerminalImageDrop.InsertionPlan {
        TerminalImageDrop.insertionPlan(
            for: urls,
            syntax: TerminalImageDrop.syntax(forLaunchCommand: agentLaunchCommand)
        )
    }

    private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    private func setFileDropActive(_ active: Bool) {
        guard fileDropActive != active else { return }
        fileDropActive = active
        wantsLayer = true
        layer?.borderWidth = active ? 2 : 0
        layer?.borderColor = active ? NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor : nil
        layer?.cornerRadius = active ? 9 : 0
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = isInputAuthorized
            && !droppedFileURLs(from: sender.draggingPasteboard).isEmpty
        setFileDropActive(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = isInputAuthorized
            && !droppedFileURLs(from: sender.draggingPasteboard).isEmpty
        setFileDropActive(accepts)
        return accepts ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setFileDropActive(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isInputAuthorized && !droppedFileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setFileDropActive(false) }
        return performFileDrop(urls: droppedFileURLs(from: sender.draggingPasteboard))
    }

    /// Testable core shared with AppKit drag delivery. Authorization is checked
    /// before an image can be staged or an insertion plan can be constructed.
    @discardableResult
    func performFileDrop(urls: [URL]) -> Bool {
        guard isInputAuthorized else { return false }
        let plan = Self.droppedFilePlan(urls, agentLaunchCommand: agentLaunchCommand)
        guard !plan.text.isEmpty else { return false }
        window?.makeFirstResponder(self)
        insert(plan)
        return true
    }

    /// Bracketed-paste an insertion plan and disclose anything it downgraded.
    ///
    /// Shared by the drop and the paste paths so a clipboard image and a
    /// dropped one reach the CLI by exactly the same route.
    private func insert(_ plan: TerminalImageDrop.InsertionPlan) {
        guard isInputAuthorized else { return }
        let terminal = getTerminal()
        if terminal.bracketedPasteMode {
            sendBracketedPaste(plan.text, to: terminal)
        } else {
            send(source: terminal, data: ArraySlice(Array(plan.text.utf8)))
        }
        if let warning = plan.warningMessage {
            ToastCenter.shared.show(warning, style: .error, duration: 5)
        }
    }

    /// Treat DECSET 2004's wrapper and body as one ownership-epoch packet.
    /// Three delegate callbacks let a controller flap strand the CLI after the
    /// opening marker or deliver only a suffix; one callback is all-or-nothing
    /// at AppModel's queue boundary.
    private func sendBracketedPaste(_ text: String, to terminal: Terminal) {
        var payload = Array("\u{1B}[200~".utf8)
        payload.append(contentsOf: text.utf8)
        payload.append(contentsOf: "\u{1B}[201~".utf8)
        send(source: terminal, data: ArraySlice(payload))
    }

    /// Shift+Enter types a newline instead of submitting — ESC CR, the mapping
    /// Claude/Codex CLIs (and the Electron terminal) treat as "insert line
    /// break". SwiftTerm's `keyDown` isn't `open`, so the intercept rides a
    /// local monitor that only claims the event while this view is focused;
    /// it uninstalls when the view leaves its window (weak self keeps a
    /// stragglling monitor harmless).
    private var shiftEnterMonitor: Any?

    static func shouldHandleShiftEnter(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        keyCode == 36
            && modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
    }

    /// Control-V — `v` is key code 9 — with no other modifier.
    ///
    /// Matching the keystroke is not the same as claiming it: the monitor only
    /// claims it when the clipboard actually holds an image the agent can be
    /// handed, so Control-V keeps its shell meaning the rest of the time.
    static func shouldConsiderControlV(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        keyCode == 9
            && modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
    }

    /// Shared by the local key monitor and tests so Shift+Enter cannot bypass
    /// the same revocable `send` gate as ordinary keys and paste.
    @discardableResult
    func sendShiftEnter() -> Bool {
        guard isInputAuthorized else { return false }
        send(source: getTerminal(), data: ArraySlice([0x1B, 0x0D]))
        return true
    }

    private func reconcileInputAffordances() {
        guard isInputAuthorized, window != nil else {
            unregisterDraggedTypes()
            setFileDropActive(false)
            if let shiftEnterMonitor {
                NSEvent.removeMonitor(shiftEnterMonitor)
                self.shiftEnterMonitor = nil
            }
            return
        }
        registerForDraggedTypes([.fileURL])
        guard shiftEnterMonitor == nil else { return }
        shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isShiftEnter = Self.shouldHandleShiftEnter(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            )
            let isControlV = Self.shouldConsiderControlV(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            )
            guard isShiftEnter || isControlV else { return event }
            // Local monitors fire on the main thread; NSEvent itself must stay
            // outside the isolation hop (it isn't Sendable).
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      self.isInputAuthorized,
                      let window = self.window,
                      window.isKeyWindow,
                      window.firstResponder === self else { return false }
                if isControlV { return self.handleControlVIfImagePresent() }
                return self.sendShiftEnter()
            }
            return handled ? nil : event
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileInputAffordances()
    }
}
