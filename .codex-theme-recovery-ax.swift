import ApplicationServices
import Darwin
import Foundation

private struct Record {
    let element: AXUIElement
    let identifier: String?
    let role: String?
    let labels: [String]
    let enabled: Bool?
}

private func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func string(_ name: String, _ element: AXUIElement) -> String? {
    guard let value = attribute(name, element) as? String, !value.isEmpty else { return nil }
    return value
}

private func records(pid: pid_t) -> [Record] {
    let app = AXUIElementCreateApplication(pid)
    let windows = attribute(kAXWindowsAttribute, app) as? [AXUIElement] ?? []
    var result: [Record] = []
    var visited = Set<CFHashCode>()
    func walk(_ element: AXUIElement, _ depth: Int) {
        guard depth < 40, result.count < 4_000,
              visited.insert(CFHash(element)).inserted else { return }
        result.append(Record(
            element: element,
            identifier: string(kAXIdentifierAttribute, element),
            role: string(kAXRoleAttribute, element),
            labels: [
                kAXDescriptionAttribute,
                kAXTitleAttribute,
                kAXValueAttribute,
                kAXHelpAttribute,
            ].compactMap { string($0, element) },
            enabled: attribute(kAXEnabledAttribute, element) as? Bool
        ))
        for child in attribute(kAXChildrenAttribute, element) as? [AXUIElement] ?? [] {
            walk(child, depth + 1)
        }
    }
    for window in windows { walk(window, 0) }
    return result
}

private func hasLabel(_ needle: String, _ record: Record) -> Bool {
    record.labels.contains { $0.localizedCaseInsensitiveContains(needle) }
}

guard CommandLine.arguments.count == 2,
      let pid = pid_t(CommandLine.arguments[1]), pid > 0 else {
    fputs("usage: theme-recovery-ax <pid>\n", stderr)
    exit(64)
}

let deadline = Date().addingTimeInterval(8)
var pressed = false
while Date() < deadline, kill(pid, 0) == 0 {
    let current = records(pid: pid)
    if !pressed,
       let category = current.first(where: {
           $0.identifier == "extensions.category.terminal-themes"
       }) {
        let result = AXUIElementPerformAction(category.element, kAXPressAction as CFString)
        guard result == .success else {
            fputs("KAISOLA_THEME_RECOVERY_AX=FAIL press-\(result.rawValue)\n", stderr)
            exit(1)
        }
        pressed = true
    }
    if pressed {
        let updated = records(pid: pid)
        let identifiers = Set(updated.compactMap(\.identifier))
        let reveal = updated.first { hasLabel("Reveal Recovery Copy", $0) }
        let reset = updated.first { hasLabel("Reset Registry", $0) }
        let importer = updated.first { hasLabel("Import Theme", $0) }
        let copyNamed = updated.contains { hasLabel("terminal-themes.json.preserved-", $0) }
        let lastKnownGood = updated.contains { hasLabel("last-known-good", $0) }
        if identifiers.contains("extensions.themes.registry-warning"),
           reveal?.role == kAXButtonRole, reveal?.enabled != false,
           reset?.role == kAXButtonRole, reset?.enabled != false,
           importer?.role == kAXButtonRole, importer?.enabled == false,
           copyNamed, lastKnownGood {
            print("KAISOLA_THEME_RECOVERY_AX=PASS warning=true reveal=true reset=true importDisabled=true copyNamed=true lastKnownGood=true")
            exit(0)
        }
    }
    usleep(40_000)
}

let final = records(pid: pid)
let identifiers = Set(final.compactMap(\.identifier)).sorted().joined(separator: ",")
let labels = final.flatMap(\.labels).joined(separator: " | ")
fputs("KAISOLA_THEME_RECOVERY_AX=FAIL pressed=\(pressed) identifiers=\(identifiers) labels=\(labels)\n", stderr)
exit(1)
