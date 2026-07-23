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

struct NativeTerminalSurface: NSViewRepresentable {
    let output: String
    let streamEpoch: String?
    let endOffset: Int64?
    // Input exists only for sessions the native app owns; observed sessions
    // keep the sealed read-only view whose send path is compiled away.
    var isOwned: Bool = false
    /// Terminal font size (⌘+/⌘−/⌘0 via NativePreviewSettings).
    var fontSize: Double = NativePreviewSettings.terminalFontDefault
    var fontFamily: String = TerminalFontOptions.systemMonoSentinel
    var fontWeight: String = "regular"
    /// Native macOS Terminal by default; Kaisola keeps Electron palette parity.
    var paletteMode: TerminalPaletteMode = .native
    /// Paper palette on light appearances, ink on dark.
    var lightSurface: Bool = false
    var onInput: ((String) -> Void)? = nil
    var onResize: ((_ columns: Int, _ rows: Int) -> Void)? = nil
    /// Live OSC title changes (auto-naming owned sessions).
    var onTitleChange: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ReadOnlyTerminalView {
        let font = TerminalFontOptions.resolveFont(family: fontFamily, size: fontSize, weightRaw: fontWeight)
        let view: ReadOnlyTerminalView = isOwned
            ? OwnedTerminalView(frame: .zero, font: font)
            : ReadOnlyTerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        view.configureTerminalTheme(light: lightSurface, mode: paletteMode)
        view.allowMouseReporting = isOwned
        view.linkReporting = .implicit
        view.optionAsMetaKey = false
        view.setAccessibilityLabel(isOwned ? "Terminal" : "Read-only terminal output")
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        context.coordinator.onTitleChange = onTitleChange
        context.coordinator.apply(output: output, epoch: streamEpoch, endOffset: endOffset, to: view)
        return view
    }

    func updateNSView(_ view: ReadOnlyTerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        context.coordinator.onTitleChange = onTitleChange
        let desired = TerminalFontOptions.resolveFont(family: fontFamily, size: fontSize, weightRaw: fontWeight)
        if view.font.fontName != desired.fontName || abs(view.font.pointSize - desired.pointSize) > 0.1 {
            view.font = desired
        }
        if view.themeKey != Self.themeKey(light: lightSurface, mode: paletteMode) {
            view.configureTerminalTheme(light: lightSurface, mode: paletteMode)
        }
        context.coordinator.apply(output: output, epoch: streamEpoch, endOffset: endOffset, to: view)
    }

    private static func themeKey(light: Bool, mode: TerminalPaletteMode) -> String {
        "\(mode.rawValue):\(light ? "light" : "dark")"
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onInput: ((String) -> Void)?
        var onResize: ((_ columns: Int, _ rows: Int) -> Void)?
        var onTitleChange: ((String) -> Void)?
        private var renderedEpoch: String?
        private var renderedStartOffset: Int64?
        private var renderedEndOffset: Int64?
        private var hasRendered = false
        /// Reconstructing a terminal view means feeding retained PTY history
        /// through SwiftTerm again. That history can contain cursor/color/device
        /// queries. SwiftTerm correctly answers those queries through `send`,
        /// but answering a historical query a second time injects replies such
        /// as `ESC[1;1R` and `OSC 11;rgb:...` into the *live* shell. The shell is
        /// usually back at a prompt by then, so the replies become visible input
        /// and corrupt the next command. Suppress only reconstruction replies;
        /// fresh incremental output still receives normal terminal responses.
        private var suppressReplayReplies = false

        // Sticky-scroll pinning (Electron parity). While `userUnpinned` is false
        // the surface snaps back to the newest output after every feed so it
        // stays glued to live output across feeds/resizes/tab switches; only a
        // deliberate user scroll up flips it true, and scrolling back to the
        // bottom flips it back. `isFeeding` masks the scroll callbacks the
        // terminal emits synchronously while we feed (and while we snap to the
        // bottom) so output-driven scrolls are never mistaken for user intent.
        private var userUnpinned = false
        private var isFeeding = false
        /// `scrollPosition` is 1.0 exactly at the live bottom; treat anything at
        /// or above this as "still pinned" to tolerate rounding.
        private static let pinnedThreshold = 0.999

        @MainActor
        func apply(output: String, epoch: String?, endOffset: Int64?, to view: ReadOnlyTerminalView) {
            defer { view.updateAccessibilityValue(from: output) }
            let outputBytes = Int64(output.utf8.count)
            let startOffset = endOffset.map { $0 - outputBytes }

            if !hasRendered {
                if !output.isEmpty { feed(output, to: view, suppressReplies: true) }
                renderedEpoch = epoch
                renderedStartOffset = startOffset
                renderedEndOffset = endOffset
                hasRendered = true
                return
            }

            if epoch == renderedEpoch,
               let oldEnd = renderedEndOffset,
               let newEnd = endOffset,
               let newStart = startOffset,
               newStart >= 0,
               oldEnd >= newStart,
               newEnd >= oldEnd {
                if newEnd == oldEnd {
                    // A broker stream is immutable within an epoch. Equal byte
                    // bounds therefore mean SwiftTerm already has this view.
                    if newStart == renderedStartOffset { return }
                } else {
                    let bytesToSkip = oldEnd - newStart
                    if let suffix = outputSuffix(output, droppingUTF8Bytes: bytesToSkip),
                       Int64(suffix.utf8.count) == newEnd - oldEnd {
                        feed(suffix, to: view, suppressReplies: false)
                        renderedStartOffset = newStart
                        renderedEndOffset = newEnd
                        return
                    }
                }
            }

            if epoch != renderedEpoch || startOffset != renderedStartOffset || endOffset != renderedEndOffset {
                view.getTerminal().resetToInitialState()
                // A reset means a fresh stream state — effectively a remount. Any
                // prior scroll targeted the now-discarded scrollback, so re-pin to
                // live output (Electron parity: remounts follow the newest bytes).
                userUnpinned = false
                if !output.isEmpty { feed(output, to: view, suppressReplies: true) }
            }
            renderedEpoch = epoch
            renderedStartOffset = startOffset
            renderedEndOffset = endOffset
            hasRendered = true
        }

        /// Feeds `text` into the terminal and, unless the user has deliberately
        /// scrolled up, snaps the viewport back to the newest output so the
        /// surface stays glued to live output (Electron sticky-scroll parity).
        /// `isFeeding` stays set across both the feed and the snap so every
        /// scroll callback the terminal emits during this window is treated as
        /// output-driven, never as a user scroll.
        @MainActor
        private func feed(_ text: String, to view: ReadOnlyTerminalView, suppressReplies: Bool) {
            isFeeding = true
            suppressReplayReplies = suppressReplies
            defer {
                suppressReplayReplies = false
                isFeeding = false
            }
            view.feed(text: text)
            if !userUnpinned {
                view.scrollToLiveBottom()
            }
        }

        private func outputSuffix(_ output: String, droppingUTF8Bytes count: Int64) -> String? {
            guard count >= 0, count <= Int64(output.utf8.count), let distance = Int(exactly: count) else {
                return nil
            }
            let utf8 = output.utf8
            let byteIndex = utf8.index(utf8.startIndex, offsetBy: distance)
            guard let stringIndex = byteIndex.samePosition(in: output) else { return nil }
            return String(output[stringIndex...])
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Reached only from OwnedTerminalView: the read-only subclass
            // swallows every byte before the delegate can see it.
            guard !suppressReplayReplies, let onInput, !data.isEmpty else { return }
            onInput(String(decoding: data, as: UTF8.self))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            onResize?(newCols, newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) { onTitleChange?(title) }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {
            // Ignore the scroll callbacks emitted while we feed output or snap to
            // the bottom; only a deliberate user scroll changes the pin state.
            guard !isFeeding else { return }
            // `position` is the relative viewport position (1.0 at the live
            // bottom): leaving the bottom unpins, returning to it re-pins.
            userUnpinned = position < Self.pinnedThreshold
        }

        /// Splits a `file:` OSC 8 link into its filesystem path and an optional
        /// trailing `:LINE` citation. Agent CLIs emit both `file:///a/b.swift:42`
        /// and the percent-encoded `file:///a/b.swift%3A42`; `URL.path` is already
        /// percent-decoded, so both collapse to the same string here. The colon is
        /// treated as a line number only when it is the last colon, is followed by
        /// digits, and leaves a non-empty path — so directory URLs and paths whose
        /// colon is not a citation pass through untouched.
        static func parseFileLink(_ url: URL) -> (path: String, line: Int?) {
            let decodedPath = url.path
            guard let colonIndex = decodedPath.lastIndex(of: ":") else {
                return (decodedPath, nil)
            }
            let lineToken = decodedPath[decodedPath.index(after: colonIndex)...]
            let pathPart = String(decodedPath[..<colonIndex])
            guard !pathPart.isEmpty,
                  !lineToken.isEmpty,
                  lineToken.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let line = Int(lineToken) else {
                return (decodedPath, nil)
            }
            return (pathPart, line)
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            switch url.scheme?.lowercased() {
            case "https", "http":
                if LocalhostDetector.isLocalDevURL(url) {
                    NotificationCenter.default.post(name: .kaisolaOpenBrowserCard, object: url)
                    return
                }
                NSWorkspace.shared.open(url)
            case "file":
                // OSC 8 file links (agent CLIs cite files): open in Kaisola's
                // built-in preview via the shell rather than executing/revealing
                // the file through Launch Services. RootShellView observes
                // `.kaisolaOpenFileLink` and drives its file preview.
                let parsed = Self.parseFileLink(url)
                let fileURL = URL(fileURLWithPath: parsed.path)
                var userInfo: [AnyHashable: Any] = ["url": fileURL]
                if let line = parsed.line { userInfo["line"] = line }
                NotificationCenter.default.post(
                    name: .kaisolaOpenFileLink,
                    object: nil,
                    userInfo: userInfo
                )
            default:
                break
            }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Drops both physical-key input and terminal-generated query replies. SwiftTerm
/// still provides native selection, copy, and Command-F search, but no byte can
/// flow from this view back to a PTY. The view claims keyboard focus when it
/// joins a window so Copy/Select All/Find reach it without a mouse, and exposes
/// the retained tail of the buffer as a read-only accessibility value.
class ReadOnlyTerminalView: TerminalView {
    static let accessibilityTailLimit = 8_000

    // Copy-on-write reference updated per stream apply in O(1); the bounded
    // tail is materialized only when accessibility actually asks for it.
    private var accessibilitySource: String = ""

    override func send(source: Terminal, data: ArraySlice<UInt8>) {}

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
        guard let window else { return }
        if Self.shouldClaimFocus(currentFirstResponder: window.firstResponder, window: window) {
            window.makeFirstResponder(self)
        }
    }

    /// Which palette is installed, so appearance/palette flips reconfigure once.
    private(set) var isLightTheme = false
    private(set) var themeKey = ""

    /// Installs either the clean native palette or the Electron-matched Kaisola
    /// palette. Both remain fully opaque so glass chrome never compromises a
    /// terminal's contrast.
    func configureTerminalTheme(light: Bool = false, mode: TerminalPaletteMode = .native) {
        let palette = TerminalTheme.palette(light: light, mode: mode)
        isLightTheme = light
        themeKey = "\(mode.rawValue):\(light ? "light" : "dark")"
        installColors(palette.ansi)
        nativeForegroundColor = palette.foreground
        nativeBackgroundColor = palette.background
        caretColor = palette.cursor
        selectedTextBackgroundColor = palette.selection
        useBrightColors = true
        wantsLayer = true
        layer?.backgroundColor = palette.background.cgColor
    }

    func updateAccessibilityValue(from output: String) {
        accessibilitySource = output
    }

    /// Snap the viewport to the newest output (Electron sticky-scroll parity).
    /// `scroll(toPosition:)` is SwiftTerm's public relative-scroll API — 1.0 is
    /// the live bottom — and is a harmless no-op when there is nothing to
    /// scroll, so callers can invoke it after every feed while pinned.
    func scrollToLiveBottom() {
        scroll(toPosition: 1)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? {
        String(accessibilitySource.suffix(Self.accessibilityTailLimit))
    }
}

/// The writable variant for native-owned sessions: SwiftTerm's normal input
/// path stays intact and lands in the delegate's `send`, which the surface
/// forwards to the broker controller connection.
final class OwnedTerminalView: ReadOnlyTerminalView {
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        terminalDelegate?.send(source: self, data: data)
    }

    /// Shift+Enter types a newline instead of submitting — ESC CR, the mapping
    /// Claude/Codex CLIs (and the Electron terminal) treat as "insert line
    /// break". SwiftTerm's `keyDown` isn't `open`, so the intercept rides a
    /// local monitor that only claims the event while this view is focused;
    /// it uninstalls when the view leaves its window (weak self keeps a
    /// stragglling monitor harmless).
    private var shiftEnterMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let shiftEnterMonitor {
                NSEvent.removeMonitor(shiftEnterMonitor)
                self.shiftEnterMonitor = nil
            }
        } else if shiftEnterMonitor == nil {
            shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 36, event.modifierFlags.contains(.shift) else { return event }
                // Local monitors fire on the main thread; NSEvent itself must
                // stay outside the isolation hop (it isn't Sendable).
                let handled = MainActor.assumeIsolated { () -> Bool in
                    // Only claim the keystroke when THIS view is the first
                    // responder of the KEY window — otherwise a background
                    // window's terminal would swallow a Shift+Enter meant for
                    // whatever the user is actually focused on.
                    guard let self,
                          let window = self.window,
                          window.isKeyWindow,
                          window.firstResponder === self else { return false }
                    self.terminalDelegate?.send(source: self, data: ArraySlice([0x1B, 0x0D]))
                    return true
                }
                return handled ? nil : event
            }
        }
    }
}
