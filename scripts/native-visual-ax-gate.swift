import ApplicationServices
import Darwin
import Foundation

struct ElementRecord {
    let identifier: String?
    let role: String?
    let labels: [String]
    let enabled: Bool?
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
        result.records.append(ElementRecord(
            identifier: identifier,
            role: role,
            labels: labels,
            enabled: enabled
        ))
        let children = value(
            kAXChildrenAttribute,
            of: element,
            errors: &result.errorCodes
        ) as? [AXUIElement] ?? []
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
    let identifiers = snapshot.identifiers
    guard identifiers.contains("extensions.hub") else { return "missing-hub-identifier" }
    guard let search = matchingRecord(label: "Search extensions", in: snapshot),
          search.role == kAXTextFieldRole,
          search.enabled != false else {
        return "missing-enabled-search-field"
    }
    for title in categoryTitles where !containsLabel(title, in: snapshot) {
        return "missing-category-label-\(title)"
    }
    for identifier in itemIdentifiers where !identifiers.contains(identifier) {
        return "missing-item-identifier-\(identifier)"
    }
    guard identifiers.contains("extensions.validation.language-grammars:broken-grammar") else {
        return "missing-validation-identifier"
    }
    for field in ["Source:", "Scope:", "Version and integrity:", "Updates:"]
        where !containsLabel(field, in: snapshot) {
        return "missing-common-metadata-\(field)"
    }
    guard !containsLabel("fixture-secret", in: snapshot) else { return "secret-leaked-to-ax" }

    switch surface {
    case "settings-extensions":
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
    } else {
        navigationRecords = snapshot.records.filter {
            $0.labels.contains { $0.localizedCaseInsensitiveContains("Extension category") }
        }
    }
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
        secretFree: !containsLabel("fixture-secret", in: snapshot)
    )
}

guard CommandLine.arguments.count == 3,
      let processID = pid_t(CommandLine.arguments[1]),
      processID > 0 else {
    fputs("usage: native-visual-ax-gate <pid> <surface>\n", stderr)
    exit(64)
}
let surface = CommandLine.arguments[2]
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
        print("KAISOLA_NATIVE_EXTENSIONS_AX=\(payload)")
        print("KAISOLA_NATIVE_EXTENSIONS_AX=PASS surface=\(surface)")
        exit(0)
    }
    usleep(50_000)
} while Date() < deadline && kill(processID, 0) == 0

let result = receipt(processID: processID, surface: surface, snapshot: latest)
if let data = try? JSONEncoder().encode(result) {
    print("KAISOLA_NATIVE_EXTENSIONS_AX=\(String(decoding: data, as: UTF8.self))")
}
fputs(
    "KAISOLA_NATIVE_EXTENSIONS_AX=FAIL \(latestFailure) "
        + "errors=\(latest.errorCodes.sorted())\n",
    stderr
)
exit(1)
