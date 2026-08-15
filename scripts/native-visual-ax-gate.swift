import ApplicationServices
import Darwin
import Foundation

struct ElementRecord {
    let identifier: String?
    let role: String?
    let labels: [String]
    let enabled: Bool?
    let childCount: Int
}

struct Snapshot {
    var windowCount = 0
    var records: [ElementRecord] = []
    var errorCodes = Set<Int32>()

    var identifiers: Set<String> {
        Set(records.compactMap(\.identifier))
    }

    var labels: [String] {
        records.flatMap(\.labels)
    }
}

struct Receipt: Codable {
    let processID: Int32
    let surface: String
    let windowCount: Int
    let elementCount: Int
    let identifiers: [String]
    let categoryLabels: [String]
    let itemIdentifierCount: Int
    let validationIdentifierPresent: Bool
    let searchRole: String?
    let categoryNavigationRoles: [String]
    let commonMetadataFields: [String]
    let secretFree: Bool
    let terminalPaletteIdentifierCount: Int
    let terminalPaletteLabels: [String]
    let terminalPaletteRole: String?
    let terminalPaletteChildCount: Int?
}

private let categoryTitles = [
    "Custom Agents",
    "MCP Servers",
    "Terminal Themes",
    "Language Grammars",
    "Preview Mappings",
]

private let categoryIdentifiers = [
    "extensions.category.custom-agents",
    "extensions.category.mcp-servers",
    "extensions.category.terminal-themes",
    "extensions.category.language-grammars",
    "extensions.category.preview-mappings",
]

private let itemIdentifiers = [
    "extensions.item.custom-agents:custom-reviewer",
    "extensions.item.mcp-servers:project-files",
    "extensions.item.terminal-themes:cafe-theme",
    "extensions.item.language-grammars:broken-grammar",
    "extensions.item.preview-mappings:notes-preview",
]

private func value(
    _ attribute: String,
    of element: AXUIElement,
    errors: inout Set<Int32>
) -> CFTypeRef? {
    var resultValue: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &resultValue
    )
    guard result == .success else {
        if result != .attributeUnsupported && result != .noValue {
            errors.insert(result.rawValue)
        }
        return nil
    }
    return resultValue
}

private func string(
    _ attribute: String,
    of element: AXUIElement,
    errors: inout Set<Int32>
) -> String? {
    guard let result = value(attribute, of: element, errors: &errors) as? String,
          !result.isEmpty else { return nil }
    return result
}

private func snapshot(processID: pid_t) -> Snapshot {
    var result = Snapshot()
    let application = AXUIElementCreateApplication(processID)
    let windows = value(
        kAXWindowsAttribute,
        of: application,
        errors: &result.errorCodes
    ) as? [AXUIElement] ?? []
    result.windowCount = windows.count
    guard let window = windows.first else { return result }

    var visited = Set<CFHashCode>()
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 40,
              visited.count < 4_000,
              visited.insert(CFHash(element)).inserted else { return }
        let identifier = string(
            kAXIdentifierAttribute,
            of: element,
            errors: &result.errorCodes
        )
        let role = string(kAXRoleAttribute, of: element, errors: &result.errorCodes)
        let labels = [
            kAXDescriptionAttribute,
            kAXTitleAttribute,
            kAXValueAttribute,
            kAXHelpAttribute,
        ].compactMap { string($0, of: element, errors: &result.errorCodes) }
        let enabled = value(
            kAXEnabledAttribute,
            of: element,
            errors: &result.errorCodes
        ) as? Bool
        let children = value(
            kAXChildrenAttribute,
            of: element,
            errors: &result.errorCodes
        ) as? [AXUIElement] ?? []
        result.records.append(ElementRecord(
            identifier: identifier,
            role: role,
            labels: labels,
            enabled: enabled,
            childCount: children.count
        ))
        for child in children { walk(child, depth: depth + 1) }
    }
    walk(window, depth: 0)
    return result
}

private func containsLabel(_ needle: String, in snapshot: Snapshot) -> Bool {
    snapshot.labels.contains {
        $0.localizedCaseInsensitiveContains(needle)
    }
}

private func matchingRecord(
    label: String,
    in snapshot: Snapshot
) -> ElementRecord? {
    snapshot.records.first { record in
        record.labels.contains { $0.localizedCaseInsensitiveContains(label) }
    }
}

private func failure(surface: String, snapshot: Snapshot) -> String? {
    guard snapshot.windowCount == 1 else {
        return "wrong-window-count-\(snapshot.windowCount)"
    }
    if surface == "settings-terminal" {
        let matches = snapshot.records.filter {
            $0.identifier == "settings.terminal.palette-preview"
        }
        guard matches.count == 1 else {
            return "wrong-terminal-palette-count-\(matches.count)"
        }
        let preview = matches[0]
        guard preview.enabled != false else { return "disabled-terminal-palette" }
        guard preview.childCount == 0 else {
            return "terminal-palette-exposes-\(preview.childCount)-decorative-children"
        }
        let summary = preview.labels.joined(separator: " ")
        for role in [
            "macOS Terminal theme",
            "Foreground text",
            "Background",
            "Cursor",
            "ANSI green",
            "ANSI blue",
        ] where !summary.localizedCaseInsensitiveContains(role) {
            return "terminal-palette-missing-\(role.replacingOccurrences(of: " ", with: "-"))"
        }
        return nil
    }
    if surface == "chat-thinking" {
        let matches = snapshot.records.filter { $0.identifier == "acp.thinkingStatus" }
        guard matches.count == 1 else {
            return "wrong-thinking-status-count-\(matches.count)"
        }
        let summary = matches[0].labels.joined(separator: " ")
        guard !summary.isEmpty else { return "empty-thinking-status-label" }
        // The fixture's trailing in-progress call titles the line, and the
        // spoken form appends ", working" — never an ellipsis.
        guard summary.localizedCaseInsensitiveContains("Running the focused native tests") else {
            return "thinking-status-missing-tool-title"
        }
        guard summary.localizedCaseInsensitiveContains("working") else {
            return "thinking-status-missing-working"
        }
        guard !summary.contains("…") else { return "thinking-status-speaks-ellipsis" }
        return nil
    }
    let identifiers = snapshot.identifiers
    guard identifiers.contains("extensions.hub") else { return "missing-hub-identifier" }
    guard let search = matchingRecord(label: "Search extensions", in: snapshot),
          search.role == kAXTextFieldRole,
          search.enabled != false else {
        return "missing-enabled-search-field"
    }
    for field in ["Source:", "Scope:", "Version and integrity:", "Updates:"]
        where !containsLabel(field, in: snapshot) {
        return "missing-common-metadata-\(field)"
    }
    guard !containsLabel("fixture-secret", in: snapshot) else { return "secret-leaked-to-ax" }

    switch surface {
    case "settings-extensions":
        for title in categoryTitles where !containsLabel(title, in: snapshot) {
            return "missing-category-label-\(title)"
        }
        for identifier in itemIdentifiers where !identifiers.contains(identifier) {
            return "missing-item-identifier-\(identifier)"
        }
        guard identifiers.contains("extensions.validation.language-grammars:broken-grammar") else {
            return "missing-validation-identifier"
        }
        for identifier in categoryIdentifiers where !identifiers.contains(identifier) {
            return "missing-wide-category-control-\(identifier)"
        }
        guard containsLabel("Extension categories", in: snapshot) else {
            return "missing-wide-category-group"
        }
    case "settings-extensions-narrow":
        guard let picker = matchingRecord(label: "Extension category", in: snapshot),
              picker.role == kAXPopUpButtonRole,
              picker.enabled != false else {
            return "missing-enabled-compact-category-picker"
        }
        guard categoryIdentifiers.allSatisfy({ !identifiers.contains($0) }) else {
            return "wide-category-rail-visible-in-narrow-layout"
        }
        // The compact catalog is a LazyVStack. Only mounted rows belong in the
        // external AX tree, while the in-app receipt separately proves that all
        // five fixture categories and the invalid grammar are present.
        guard categoryTitles.contains(where: { containsLabel($0, in: snapshot) }) else {
            return "missing-mounted-compact-category"
        }
        guard itemIdentifiers.contains(where: identifiers.contains) else {
            return "missing-mounted-compact-item"
        }
    default:
        return "unsupported-surface-\(surface)"
    }
    return nil
}

private func receipt(
    processID: pid_t,
    surface: String,
    snapshot: Snapshot
) -> Receipt {
    let identifiers = snapshot.identifiers
    let commonFields = ["Source:", "Scope:", "Version and integrity:", "Updates:"]
        .filter { containsLabel($0, in: snapshot) }
    let navigationRecords: [ElementRecord]
    if surface == "settings-extensions" {
        navigationRecords = snapshot.records.filter {
            guard let identifier = $0.identifier else { return false }
            return categoryIdentifiers.contains(identifier)
        }
    } else if surface == "settings-extensions-narrow" {
        navigationRecords = snapshot.records.filter {
            $0.labels.contains { $0.localizedCaseInsensitiveContains("Extension category") }
        }
    } else {
        navigationRecords = []
    }
    let terminalPaletteRecords = snapshot.records.filter {
        $0.identifier == "settings.terminal.palette-preview"
    }
    let terminalPalette = terminalPaletteRecords.first
    return Receipt(
        processID: processID,
        surface: surface,
        windowCount: snapshot.windowCount,
        elementCount: snapshot.records.count,
        identifiers: identifiers.filter { $0.hasPrefix("extensions.") }.sorted(),
        categoryLabels: categoryTitles.filter { containsLabel($0, in: snapshot) },
        itemIdentifierCount: itemIdentifiers.filter(identifiers.contains).count,
        validationIdentifierPresent: identifiers.contains(
            "extensions.validation.language-grammars:broken-grammar"
        ),
        searchRole: matchingRecord(label: "Search extensions", in: snapshot)?.role,
        categoryNavigationRoles: navigationRecords.compactMap(\.role).sorted(),
        commonMetadataFields: commonFields,
        secretFree: !containsLabel("fixture-secret", in: snapshot),
        terminalPaletteIdentifierCount: terminalPaletteRecords.count,
        terminalPaletteLabels: terminalPalette?.labels ?? [],
        terminalPaletteRole: terminalPalette?.role,
        terminalPaletteChildCount: terminalPalette?.childCount
    )
}

guard CommandLine.arguments.count == 3,
      let processID = pid_t(CommandLine.arguments[1]),
      processID > 0 else {
    fputs("usage: native-visual-ax-gate <pid> <surface>\n", stderr)
    exit(64)
}
let surface = CommandLine.arguments[2]
let receiptPrefix: String
switch surface {
case "settings-terminal": receiptPrefix = "KAISOLA_NATIVE_TERMINAL_PALETTE_AX"
case "chat-thinking": receiptPrefix = "KAISOLA_NATIVE_CHAT_THINKING_AX"
default: receiptPrefix = "KAISOLA_NATIVE_EXTENSIONS_AX"
}
let deadline = Date().addingTimeInterval(6)
var latest = Snapshot()
var latestFailure = "window-not-ready"

repeat {
    latest = snapshot(processID: processID)
    if let currentFailure = failure(surface: surface, snapshot: latest) {
        latestFailure = currentFailure
    } else {
        let result = receipt(processID: processID, surface: surface, snapshot: latest)
        let data = try JSONEncoder().encode(result)
        let payload = String(decoding: data, as: UTF8.self)
        print("\(receiptPrefix)=\(payload)")
        print("\(receiptPrefix)=PASS surface=\(surface)")
        exit(0)
    }
    usleep(50_000)
} while Date() < deadline && kill(processID, 0) == 0

let result = receipt(processID: processID, surface: surface, snapshot: latest)
if let data = try? JSONEncoder().encode(result) {
    print("\(receiptPrefix)=\(String(decoding: data, as: UTF8.self))")
}
fputs(
    "\(receiptPrefix)=FAIL \(latestFailure) "
        + "errors=\(latest.errorCodes.sorted())\n",
    stderr
)
exit(1)
