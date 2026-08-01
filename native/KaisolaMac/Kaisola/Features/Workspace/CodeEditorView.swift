import AppKit
import Foundation
import SwiftUI
import WebKit

enum CodeEditorLanguage: String, Equatable, Sendable {
    case plain
    case javascript
    case typescript
    case tsx
    case python
    case json
    case html
    case css
    case swift
    case shell
    case yaml

    static func detect(for url: URL) -> CodeEditorLanguage {
        switch url.pathExtension.lowercased() {
        case "js", "jsx", "mjs", "cjs": .javascript
        case "ts", "mts", "cts": .typescript
        case "tsx": .tsx
        case "py", "pyw": .python
        case "json", "jsonl", "geojson": .json
        case "html", "htm", "xhtml": .html
        case "css", "scss", "sass", "less": .css
        case "swift": .swift
        case "sh", "bash", "zsh", "fish": .shell
        case "yaml", "yml": .yaml
        default: .plain
        }
    }
}

enum CodeEditorLineSeparator: String, Equatable, Sendable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"

    /// Prefer CRLF only when every LF belongs to a CRLF pair. Mixed files use
    /// LF as the structural separator so every newline remains navigable while
    /// the preceding CR bytes stay verbatim content. Lone-CR files retain CR.
    static func detect(in source: String) -> CodeEditorLineSeparator {
        let units = source.utf16
        var previous: UInt16?
        var sawLF = false
        var sawLoneLF = false
        var sawCR = false
        for unit in units {
            if unit == 13 { sawCR = true }
            if unit == 10 {
                sawLF = true
                if previous != 13 { sawLoneLF = true }
            }
            previous = unit
        }
        if sawLF { return sawLoneLF ? .lf : .crlf }
        return sawCR ? .cr : .lf
    }
}

enum FileEditorLineTarget {
    static func key(documentID: String, line: Int, navigationRevision: UInt64) -> String {
        "\(documentID)|\(line)|\(navigationRevision)"
    }
}

/// The editor page is not a file URL and never receives workspace read access.
/// Its private scheme serves exactly the two immutable runtime assets below.
enum CodeEditorAssetPolicy {
    static let scheme = "kaisola-editor"
    static let host = "app"

    static func resource(for url: URL) -> (name: String, extension: String, mimeType: String)? {
        guard url.scheme?.lowercased() == scheme,
              url.host(percentEncoded: false)?.lowercased() == host,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else { return nil }
        switch url.path {
        case "/index.html": return ("index", "html", "text/html")
        case "/editor.bundle.js": return ("editor.bundle", "js", "text/javascript")
        default: return nil
        }
    }

    static func allowsNavigation(to url: URL) -> Bool {
        resource(for: url) != nil
    }
}

struct CodeEditorSourceChange: Equatable, Sendable {
    let from: Int
    let to: Int
    let insert: String
}

struct CodeEditorSourceMutation: Equatable, Sendable {
    let text: String
    let inverse: [CodeEditorSourceChange]
}

/// Applies CodeMirror offsets as UTF-16 ranges, matching both JavaScript string
/// indexing and Foundation's NSString representation. All ranges are validated
/// against the pre-transaction source before any bytes are changed.
enum CodeEditorSourceTransaction {
    static func applyAndInvert(
        _ changes: [CodeEditorSourceChange],
        to source: String
    ) -> CodeEditorSourceMutation? {
        guard !changes.isEmpty else { return nil }
        let original = source as NSString
        var previousEnd = 0
        var cumulativeDelta = 0
        var inverse: [CodeEditorSourceChange] = []
        inverse.reserveCapacity(changes.count)

        for change in changes {
            guard change.from >= previousEnd,
                  change.from >= 0,
                  change.to >= change.from,
                  change.to <= original.length else { return nil }
            let removed = original.substring(with: NSRange(
                location: change.from,
                length: change.to - change.from
            ))
            let insertedLength = (change.insert as NSString).length
            let newStart = change.from + cumulativeDelta
            inverse.append(CodeEditorSourceChange(
                from: newStart,
                to: newStart + insertedLength,
                insert: removed
            ))
            cumulativeDelta += insertedLength - (change.to - change.from)
            previousEnd = change.to
        }

        let result = NSMutableString(string: source)
        for change in changes.reversed() {
            result.replaceCharacters(
                in: NSRange(location: change.from, length: change.to - change.from),
                with: change.insert
            )
        }
        return CodeEditorSourceMutation(text: result as String, inverse: inverse)
    }
}

private struct CodeEditorSelection: Equatable, Sendable {
    let anchor: Int
    let head: Int

    func clamped(toUTF16Length length: Int) -> CodeEditorSelection {
        CodeEditorSelection(
            anchor: min(length, max(0, anchor)),
            head: min(length, max(0, head))
        )
    }

    var payload: [String: Any] { ["anchor": anchor, "head": head] }
}

private struct CodeEditorUndoRecord: Sendable {
    let forward: [CodeEditorSourceChange]
    let reverse: [CodeEditorSourceChange]
    let beforeSelection: CodeEditorSelection
    let afterSelection: CodeEditorSelection
}

@MainActor
private final class CodeEditorUndoTarget: NSObject {
    enum Direction: Equatable { case undo, redo }

    weak var coordinator: CodeEditorView.Coordinator?

    func register(_ record: CodeEditorUndoRecord, with manager: UndoManager) {
        manager.registerUndo(withTarget: self) { target in
            target.perform(record, direction: .undo)
        }
        manager.setActionName("Edit Source")
    }

    private func perform(_ record: CodeEditorUndoRecord, direction: Direction) {
        guard let coordinator,
              coordinator.applyUndoRecord(record, direction: direction) else { return }
        let manager = coordinator.activeUndoManager
        manager.registerUndo(withTarget: self) { target in
            target.perform(record, direction: direction == .undo ? .redo : .undo)
        }
        manager.setActionName("Edit Source")
    }
}

@MainActor
private final class CodeEditorAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let bundle: Bundle

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let resource = CodeEditorAssetPolicy.resource(for: requestURL),
              let resourceURL = bundle.url(
                forResource: resource.name,
                withExtension: resource.extension,
                subdirectory: "CodeEditor"
              ),
              let data = try? Data(contentsOf: resourceURL, options: [.mappedIfSafe]) else {
            urlSchemeTask.didFailWithError(NSError(
                domain: "Kaisola.CodeEditorAssets",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The bundled source editor is unavailable."]
            ))
            return
        }
        let response = URLResponse(
            url: requestURL,
            mimeType: resource.mimeType,
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// A networkless CodeMirror island. Swift supplies the source and accepts only
/// validated text transactions, scroll position, and undo/redo requests over
/// the bridge. The page receives no path, file handle, credential, or network
/// capability; save/revert and dirty-state ownership stay in FilePreviewView.
struct CodeEditorView: NSViewRepresentable {
    static let bridgeName = "kaisolaEditor"
    static let pageURL = URL(string: "kaisola-editor://app/index.html")!

    @Binding var text: String
    let fileURL: URL
    let targetLine: Int?
    var navigationRevision: UInt64 = 0
    let fontSize: CGFloat
    let colorScheme: ColorScheme
    let undoManager: UndoManager?
    let scrollMemory: FilePreviewTextScrollMemory
    var onError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        let assetHandler = CodeEditorAssetSchemeHandler(bundle: .main)
        configuration.setURLSchemeHandler(assetHandler, forURLScheme: CodeEditorAssetPolicy.scheme)
        configuration.userContentController.add(context.coordinator, name: Self.bridgeName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel("Source editor")

        context.coordinator.mount(
            webView: webView,
            assetHandler: assetHandler,
            binding: $text,
            fileURL: fileURL,
            targetLine: targetLine,
            navigationRevision: navigationRevision,
            fontSize: fontSize,
            colorScheme: colorScheme,
            undoManager: undoManager,
            scrollMemory: scrollMemory,
            onError: onError
        )
        webView.load(URLRequest(url: Self.pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            binding: $text,
            fileURL: fileURL,
            targetLine: targetLine,
            navigationRevision: navigationRevision,
            fontSize: fontSize,
            colorScheme: colorScheme,
            undoManager: undoManager,
            scrollMemory: scrollMemory,
            onError: onError
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.dismantle()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: bridgeName)
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private struct Configuration: Equatable {
            let language: CodeEditorLanguage
            let theme: String
            let fontSize: Double
            let lineSeparator: CodeEditorLineSeparator
        }

        private struct BridgeChange {
            let source: CodeEditorSourceChange
            let fromB: Int
            let toB: Int
        }

        private var textBinding: Binding<String>
        private weak var webView: WKWebView?
        // WKWebViewConfiguration owns the handler, but retaining it explicitly
        // documents and pins the intended lifetime across content reloads.
        private var assetHandler: CodeEditorAssetSchemeHandler?
        private var authoritativeText: String
        private var lineSeparator: CodeEditorLineSeparator
        private var documentID = ""
        private var documentToken = UUID().uuidString.lowercased()
        private var targetLine: Int?
        private var navigationRevision: UInt64 = 0
        private var fontSize: CGFloat = 13
        private var colorScheme: ColorScheme = .light
        private var suppliedUndoManager: UndoManager?
        private let fallbackUndoManager = UndoManager()
        private let undoTarget = CodeEditorUndoTarget()
        private var scrollMemory: FilePreviewTextScrollMemory?
        private var onError: ((String) -> Void)?
        private var revision = 0
        private var pageReady = false
        private var initialized = false
        private var lastSentConfiguration: Configuration?
        private var lastLineTargetKey: String?
        private var isDismantled = false

        var activeUndoManager: UndoManager { suppliedUndoManager ?? fallbackUndoManager }

        init(text: Binding<String>) {
            textBinding = text
            authoritativeText = text.wrappedValue
            lineSeparator = CodeEditorLineSeparator.detect(in: text.wrappedValue)
            super.init()
            undoTarget.coordinator = self
        }

        fileprivate func mount(
            webView: WKWebView,
            assetHandler: CodeEditorAssetSchemeHandler,
            binding: Binding<String>,
            fileURL: URL,
            targetLine: Int?,
            navigationRevision: UInt64,
            fontSize: CGFloat,
            colorScheme: ColorScheme,
            undoManager: UndoManager?,
            scrollMemory: FilePreviewTextScrollMemory,
            onError: ((String) -> Void)?
        ) {
            self.webView = webView
            self.assetHandler = assetHandler
            update(
                binding: binding,
                fileURL: fileURL,
                targetLine: targetLine,
                navigationRevision: navigationRevision,
                fontSize: fontSize,
                colorScheme: colorScheme,
                undoManager: undoManager,
                scrollMemory: scrollMemory,
                onError: onError
            )
        }

        func update(
            binding: Binding<String>,
            fileURL: URL,
            targetLine: Int?,
            navigationRevision: UInt64,
            fontSize: CGFloat,
            colorScheme: ColorScheme,
            undoManager: UndoManager?,
            scrollMemory: FilePreviewTextScrollMemory,
            onError: ((String) -> Void)?
        ) {
            textBinding = binding
            self.targetLine = targetLine
            self.navigationRevision = navigationRevision
            self.fontSize = fontSize
            self.colorScheme = colorScheme
            suppliedUndoManager = undoManager
            self.scrollMemory = scrollMemory
            self.onError = onError

            let nextDocumentID = fileURL.standardizedFileURL.path
            if documentID != nextDocumentID {
                clearUndoHistory()
                documentID = nextDocumentID
                documentToken = UUID().uuidString.lowercased()
                authoritativeText = binding.wrappedValue
                lineSeparator = CodeEditorLineSeparator.detect(in: authoritativeText)
                revision = 0
                initialized = false
                lastSentConfiguration = nil
                lastLineTargetKey = nil
                initializePageIfReady()
                return
            }

            let externalReplacement = authoritativeText != binding.wrappedValue
            var lineSeparatorChanged = false
            if externalReplacement {
                clearUndoHistory()
                authoritativeText = binding.wrappedValue
                let nextLineSeparator = CodeEditorLineSeparator.detect(in: authoritativeText)
                lineSeparatorChanged = nextLineSeparator != lineSeparator
                lineSeparator = nextLineSeparator
                revision &+= 1
            }
            guard initialized else {
                initializePageIfReady()
                return
            }
            if lineSeparatorChanged {
                initialized = false
                lastSentConfiguration = nil
                initializePageIfReady()
                return
            }
            let configurationChanged = lastSentConfiguration != currentConfiguration
            let line = pendingLineTarget()
            guard externalReplacement || configurationChanged || line != nil else { return }
            sendState(
                text: externalReplacement ? authoritativeText : nil,
                selection: nil,
                line: line,
                restoreScroll: externalReplacement && line == nil
            )
        }

        func dismantle() {
            isDismantled = true
            clearUndoHistory()
            webView = nil
            assetHandler = nil
        }

        private var currentConfiguration: Configuration {
            Configuration(
                language: CodeEditorLanguage.detect(for: URL(fileURLWithPath: documentID)),
                theme: colorScheme == .dark ? "dark" : "light",
                fontSize: Double(fontSize),
                lineSeparator: lineSeparator
            )
        }

        private func initializePageIfReady() {
            guard pageReady, !initialized, !isDismantled, let webView else { return }
            let configuration = currentConfiguration
            let line = pendingLineTarget()
            let fraction = line == nil ? scrollMemory?.fraction(for: documentID) : nil
            let payload: [String: Any] = [
                "text": authoritativeText,
                "documentToken": documentToken,
                "revision": revision,
                "language": configuration.language.rawValue,
                "theme": configuration.theme,
                "fontSize": configuration.fontSize,
                "lineSeparator": configuration.lineSeparator.rawValue,
                "line": line ?? NSNull(),
                "scrollFraction": fraction ?? NSNull(),
                "fixtureMode": ProcessInfo.processInfo.environment[
                    "KAISOLA_NATIVE_VISUAL_FIXTURE"
                ] == "1",
            ]
            initialized = true
            lastSentConfiguration = configuration
            callEditor(
                webView,
                function: "initialize",
                payload: payload,
                failurePrefix: "Could not start the source editor"
            )
        }

        private func sendState(
            text: String?,
            selection: CodeEditorSelection?,
            line: Int?,
            restoreScroll: Bool
        ) {
            guard initialized, let webView else { return }
            let configuration = currentConfiguration
            var payload: [String: Any] = [
                "documentToken": documentToken,
                "revision": revision,
                "language": configuration.language.rawValue,
                "theme": configuration.theme,
                "fontSize": configuration.fontSize,
                "lineSeparator": configuration.lineSeparator.rawValue,
                "line": line ?? NSNull(),
                "scrollFraction": restoreScroll ? (scrollMemory?.fraction(for: documentID) ?? 0) : NSNull(),
            ]
            if let text { payload["text"] = text }
            if let selection { payload["selection"] = selection.payload }
            lastSentConfiguration = configuration
            callEditor(
                webView,
                function: "applySwiftState",
                payload: payload,
                failurePrefix: "Could not update the source editor"
            )
        }

        private func callEditor(
            _ webView: WKWebView,
            function: String,
            payload: [String: Any],
            failurePrefix: String
        ) {
            // `callAsyncJavaScript` serializes arguments without interpolating
            // source into executable JavaScript. File text can therefore never
            // escape its value boundary, even when it contains script syntax.
            webView.callAsyncJavaScript(
                "return window.KaisolaEditor.\(function)(payload)",
                arguments: ["payload": payload],
                in: nil,
                in: .page
            ) { [weak self] result in
                if case let .failure(error) = result {
                    self?.onError?("\(failurePrefix): \(error.localizedDescription)")
                }
            }
        }

        private func pendingLineTarget() -> Int? {
            guard let targetLine, targetLine > 0 else { return nil }
            // A citation owns the initial route only. Including document length
            // here would snap the caret back to that line after every edit.
            let key = FileEditorLineTarget.key(
                documentID: documentID,
                line: targetLine,
                navigationRevision: navigationRevision
            )
            guard key != lastLineTargetKey else { return nil }
            lastLineTargetKey = key
            return targetLine
        }

        private func clearUndoHistory() {
            suppliedUndoManager?.removeAllActions(withTarget: undoTarget)
            fallbackUndoManager.removeAllActions(withTarget: undoTarget)
        }

        fileprivate func applyUndoRecord(
            _ record: CodeEditorUndoRecord,
            direction: CodeEditorUndoTarget.Direction
        ) -> Bool {
            let changes = direction == .undo ? record.reverse : record.forward
            guard let mutation = CodeEditorSourceTransaction.applyAndInvert(
                changes,
                to: authoritativeText
            ) else { return false }
            authoritativeText = mutation.text
            revision &+= 1
            let selection = direction == .undo ? record.beforeSelection : record.afterSelection
            textBinding.wrappedValue = mutation.text
            sendState(text: mutation.text, selection: selection, line: nil, restoreScroll: false)
            return true
        }

        private func handleChange(_ body: [String: Any]) {
            guard string(body["documentToken"]) == documentToken,
                  integer(body["baseRevision"]) == revision,
                  let nextRevision = integer(body["revision"]),
                  nextRevision == revision + 1,
                  let rawChanges = body["changes"] as? [[String: Any]],
                  !rawChanges.isEmpty,
                  let beforeSelection = selection(body["beforeSelection"]),
                  let afterSelection = selection(body["selection"]),
                  let expectedLength = integer(body["documentLength"]) else {
                resynchronize(after: body, reason: "The editor sent an invalid change transaction.")
                return
            }
            let decoded = rawChanges.compactMap(decodeChange)
            guard decoded.count == rawChanges.count,
                  let mutation = CodeEditorSourceTransaction.applyAndInvert(
                    decoded.map(\.source),
                    to: authoritativeText
                  ),
                  (mutation.text as NSString).length == expectedLength,
                  zip(decoded, mutation.inverse).allSatisfy({ pair in
                      pair.0.fromB == pair.1.from && pair.0.toB == pair.1.to
                  }) else {
                resynchronize(after: body, reason: "The editor change did not match the Swift document.")
                return
            }

            let oldLength = (authoritativeText as NSString).length
            let newLength = (mutation.text as NSString).length
            let record = CodeEditorUndoRecord(
                forward: decoded.map(\.source),
                reverse: mutation.inverse,
                beforeSelection: beforeSelection.clamped(toUTF16Length: oldLength),
                afterSelection: afterSelection.clamped(toUTF16Length: newLength)
            )
            authoritativeText = mutation.text
            revision = nextRevision
            undoTarget.register(record, with: activeUndoManager)
            textBinding.wrappedValue = mutation.text
        }

        private func resynchronize(after body: [String: Any], reason: String) {
            revision = max(revision + 1, (integer(body["revision"]) ?? revision) + 1)
            sendState(text: authoritativeText, selection: nil, line: nil, restoreScroll: true)
            onError?(reason + " Swift restored the last verified source.")
        }

        private func decodeChange(_ raw: [String: Any]) -> BridgeChange? {
            guard let fromA = integer(raw["fromA"]),
                  let toA = integer(raw["toA"]),
                  let fromB = integer(raw["fromB"]),
                  let toB = integer(raw["toB"]),
                  let insert = string(raw["insert"]) else { return nil }
            return BridgeChange(
                source: CodeEditorSourceChange(from: fromA, to: toA, insert: insert),
                fromB: fromB,
                toB: toB
            )
        }

        private func selection(_ raw: Any?) -> CodeEditorSelection? {
            guard let dictionary = raw as? [String: Any],
                  let anchor = integer(dictionary["anchor"]),
                  let head = integer(dictionary["head"]) else { return nil }
            return CodeEditorSelection(anchor: anchor, head: head)
        }

        private func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber else { return nil }
            let integer = number.intValue
            guard integer >= 0, number.doubleValue == Double(integer) else { return nil }
            return integer
        }

        private func string(_ value: Any?) -> String? { value as? String }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == CodeEditorView.bridgeName,
                  let body = message.body as? [String: Any],
                  let type = string(body["type"]) else { return }
            switch type {
            case "ready":
                pageReady = true
                initialized = false
                initializePageIfReady()
            case "initialized":
                guard string(body["documentToken"]) == documentToken,
                      integer(body["revision"]) == revision,
                      integer(body["documentLength"]) == (authoritativeText as NSString).length else {
                    resynchronize(after: body, reason: "The source editor initialized out of sync.")
                    return
                }
                if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1" {
                    print("KAISOLA_NATIVE_CODE_EDITOR=ready")
                }
            case "change":
                handleChange(body)
            case "scroll":
                guard string(body["documentToken"]) == documentToken,
                      let fraction = (body["fraction"] as? NSNumber)?.doubleValue,
                      fraction.isFinite else { return }
                scrollMemory?.record(fraction, for: documentID)
            case "undo":
                guard string(body["documentToken"]) == documentToken else { return }
                activeUndoManager.undo()
            case "redo":
                guard string(body["documentToken"]) == documentToken else { return }
                activeUndoManager.redo()
            default:
                return
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url,
                  CodeEditorAssetPolicy.allowsNavigation(to: target) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            onError?("Could not load the source editor: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            onError?("Could not load the source editor: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The authoritative source never lived in the content process.
            // Reloading the two bundled assets reconstructs the editor from
            // Swift state without risking a stale or partially applied draft.
            pageReady = false
            initialized = false
            lastSentConfiguration = nil
            webView.reload()
        }
    }
}
