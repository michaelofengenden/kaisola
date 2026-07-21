import SwiftTerm
import SwiftUI
import UIKit

/// UIKit terminal emulator hosted in SwiftUI. A replacement bounded snapshot
/// performs a full terminal reset; ordered suffixes are fed incrementally.
struct CompanionTerminalSurface: UIViewRepresentable {
    let output: String
    let streamEpoch: String?
    let controlEnabled: Bool
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeUIView(context: Context) -> CompanionSafeTerminalView {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = CompanionSafeTerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        view.onUsableLayout = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.renderPending(to: view)
        }
        view.linkReporting = .none
        view.allowMouseReporting = false
        var options = view.getTerminal().options
        options.enableSixelReported = false
        options.kittyImageCacheLimitBytes = 2 * 1024 * 1024
        options.ansi256PaletteStrategy = .xterm
        view.getTerminal().options = options
        view.enforceDarkPalette()
        view.showsHorizontalScrollIndicator = false
        context.coordinator.apply(output: output, epoch: streamEpoch, to: view)
        return view
    }

    func updateUIView(_ view: CompanionSafeTerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onResize = onResize
        context.coordinator.controlEnabled = controlEnabled
        context.coordinator.apply(output: output, epoch: streamEpoch, to: view)
        if controlEnabled && !context.coordinator.didFocusForCurrentLease {
            context.coordinator.didFocusForCurrentLease = true
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        } else if !controlEnabled {
            context.coordinator.didFocusForCurrentLease = false
            _ = view.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onInput: (Data) -> Void
        var onResize: (Int, Int) -> Void
        var controlEnabled = false
        var didFocusForCurrentLease = false
        private var renderedOutput = ""
        private var renderedEpoch: String?
        private var pendingOutput = ""
        private var pendingEpoch: String?

        init(onInput: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        @MainActor
        func apply(output: String, epoch: String?, to view: CompanionSafeTerminalView) {
            pendingOutput = output
            pendingEpoch = epoch
            renderPending(to: view)
        }

        /// SwiftUI creates the UIKit view at zero size. Feeding a full PTY
        /// replay at that point makes SwiftTerm parse it through a one-column
        /// grid; later layout cannot reconstruct cursor-addressed frames. Wait
        /// until layout has established a real phone-sized terminal geometry.
        @MainActor
        func renderPending(to view: CompanionSafeTerminalView) {
            guard view.bounds.width >= 120, view.bounds.height >= 80 else { return }
            let output = pendingOutput
            let epoch = pendingEpoch
            guard output != renderedOutput || epoch != renderedEpoch else { return }
            if epoch != renderedEpoch || !output.hasPrefix(renderedOutput) {
                view.getTerminal().resetToInitialState()
                if !output.isEmpty { view.feed(text: output) }
            } else {
                let suffix = output.dropFirst(renderedOutput.count)
                if !suffix.isEmpty { view.feed(text: String(suffix)) }
            }
            // A replay can contain OSC 4/10/11 palette mutations emitted by a
            // CLI that was running with a light desktop theme. Parse the VT
            // stream faithfully, then restore the observer's dark appearance.
            view.enforceDarkPalette()
            renderedEpoch = epoch
            renderedOutput = output
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard controlEnabled, !data.isEmpty else { return }
            onInput(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard controlEnabled, newCols >= 20, newRows >= 5 else { return }
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// SwiftTerm routes emulator-generated device/focus/query replies through this
/// method, while physical keyboard input uses `send(data:)` on the view. Never
/// let untrusted terminal output synthesize bytes back into the Mac PTY.
final class CompanionSafeTerminalView: TerminalView {
    var onUsableLayout: (() -> Void)?

    @MainActor
    func enforceDarkPalette() {
        installColors(CompanionTerminalPalette.ansi)
        nativeBackgroundColor = CompanionTerminalPalette.background
        nativeForegroundColor = CompanionTerminalPalette.foreground
        // SwiftTerm renders default-background cells transparently over its
        // backing layer. Keep UIKit and terminal defaults in lockstep so
        // scrolling cannot reveal white strips.
        backgroundColor = CompanionTerminalPalette.background
        layer.backgroundColor = CompanionTerminalPalette.background.cgColor
        caretColor = UIColor(red: 0.69, green: 0.77, blue: 0.35, alpha: 1)
        caretTextColor = CompanionTerminalPalette.background
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width >= 120, bounds.height >= 80 else { return }
        onUsableLayout?()
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@MainActor
private enum CompanionTerminalPalette {
    static let background = UIColor(red: 0.035, green: 0.043, blue: 0.047, alpha: 1)
    static let foreground = UIColor(red: 0.89, green: 0.91, blue: 0.90, alpha: 1)

    /// A restrained high-contrast dark palette. ANSI white remains readable as
    /// text, while the backing-layer fix above ensures default cells never
    /// inherit the phone's light appearance.
    static let ansi: [SwiftTerm.Color] = [
        terminalColor(0x16, 0x1b, 0x1d), terminalColor(0xd7, 0x5f, 0x69),
        terminalColor(0x8f, 0xb5, 0x73), terminalColor(0xd0, 0xaa, 0x62),
        terminalColor(0x72, 0x95, 0xd6), terminalColor(0xb5, 0x82, 0xc4),
        terminalColor(0x69, 0xb3, 0xb0), terminalColor(0xc8, 0xcc, 0xca),
        terminalColor(0x5f, 0x68, 0x6a), terminalColor(0xf0, 0x7b, 0x83),
        terminalColor(0xa7, 0xc9, 0x88), terminalColor(0xe0, 0xbd, 0x73),
        terminalColor(0x8a, 0xa8, 0xe7), terminalColor(0xc8, 0x9b, 0xd4),
        terminalColor(0x7e, 0xc6, 0xc2), terminalColor(0xee, 0xf0, 0xef),
    ]

    private static func terminalColor(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }
}
