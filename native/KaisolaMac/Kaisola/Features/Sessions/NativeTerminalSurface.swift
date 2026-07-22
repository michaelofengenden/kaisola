import AppKit
import SwiftTerm
import SwiftUI

struct NativeTerminalSurface: NSViewRepresentable {
    let output: String
    let streamEpoch: String?
    let endOffset: Int64?
    // Input exists only for sessions the native app owns; observed sessions
    // keep the sealed read-only view whose send path is compiled away.
    var isOwned: Bool = false
    var onInput: ((String) -> Void)? = nil
    var onResize: ((_ columns: Int, _ rows: Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ReadOnlyTerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view: ReadOnlyTerminalView = isOwned
            ? OwnedTerminalView(frame: .zero, font: font)
            : ReadOnlyTerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        view.allowMouseReporting = isOwned
        view.linkReporting = .implicit
        view.optionAsMetaKey = false
        view.setAccessibilityLabel(isOwned ? "Terminal" : "Read-only terminal output")
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        context.coordinator.apply(output: output, epoch: streamEpoch, endOffset: endOffset, to: view)
        return view
    }

    func updateNSView(_ view: ReadOnlyTerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        context.coordinator.apply(output: output, epoch: streamEpoch, endOffset: endOffset, to: view)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onInput: ((String) -> Void)?
        var onResize: ((_ columns: Int, _ rows: Int) -> Void)?
        private var renderedEpoch: String?
        private var renderedStartOffset: Int64?
        private var renderedEndOffset: Int64?
        private var hasRendered = false

        @MainActor
        func apply(output: String, epoch: String?, endOffset: Int64?, to view: ReadOnlyTerminalView) {
            defer { view.updateAccessibilityValue(from: output) }
            let outputBytes = Int64(output.utf8.count)
            let startOffset = endOffset.map { $0 - outputBytes }

            if !hasRendered {
                if !output.isEmpty { view.feed(text: output) }
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
                        view.feed(text: suffix)
                        renderedStartOffset = newStart
                        renderedEndOffset = newEnd
                        return
                    }
                }
            }

            if epoch != renderedEpoch || startOffset != renderedStartOffset || endOffset != renderedEndOffset {
                view.getTerminal().resetToInitialState()
                if !output.isEmpty { view.feed(text: output) }
            }
            renderedEpoch = epoch
            renderedStartOffset = startOffset
            renderedEndOffset = endOffset
            hasRendered = true
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
            guard let onInput, !data.isEmpty else { return }
            onInput(String(decoding: data, as: UTF8.self))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            onResize?(newCols, newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased()) else { return }
            NSWorkspace.shared.open(url)
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

    func updateAccessibilityValue(from output: String) {
        accessibilitySource = output
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
}
