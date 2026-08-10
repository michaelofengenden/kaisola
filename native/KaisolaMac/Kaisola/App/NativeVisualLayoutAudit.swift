import CryptoKit
import Foundation

/// Structural evidence a hosted visual fixture records beside its PNG.
///
/// The image gate can only answer "did anything render at all". Everything the
/// captured screenshots actually regress on — a header the window buttons sit
/// on top of, a clipped pane, a label that vanished, a truncated action — is
/// geometry, so the fixture writes the geometry down and the audit below
/// judges it deterministically.
///
/// Every rectangle is normalized to the capture target's content bounds with a
/// top-left origin. GitHub's headless WindowServer scales the declared window,
/// so absolute point or pixel frames would not compare across runners.
struct NativeVisualLayoutSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    struct Rect: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = max(0, width)
            self.height = max(0, height)
        }

        var maxX: Double { x + width }
        var maxY: Double { y + height }
        var area: Double { width * height }

        func intersection(_ other: Rect) -> Rect {
            let minX = Swift.max(x, other.x)
            let minY = Swift.max(y, other.y)
            let maxX = Swift.min(self.maxX, other.maxX)
            let maxY = Swift.min(self.maxY, other.maxY)
            guard maxX > minX, maxY > minY else {
                return Rect(x: 0, y: 0, width: 0, height: 0)
            }
            return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        /// Positive slack tolerates sub-pixel rounding at the content edge; a
        /// half-point of AppKit rounding is not a clipped control.
        func isContained(in other: Rect, slack: Double) -> Bool {
            x >= other.x - slack
                && y >= other.y - slack
                && maxX <= other.maxX + slack
                && maxY <= other.maxY + slack
        }

        var describedForReport: String {
            String(
                format: "x=%.4f y=%.4f w=%.4f h=%.4f",
                x, y, width, height
            )
        }
    }

    /// One accessibility or view-tree element the fixture could see.
    struct Element: Codable, Equatable, Sendable {
        var id: String
        var role: String
        var label: String
        var value: String?
        var frame: Rect
        /// Containers legitimately underlap the window controls in a
        /// `fullSizeContentView` window. Only leaves are judged for overlap.
        var isLeaf: Bool
        var isInteractive: Bool
        var isFocused: Bool
        var isTruncated: Bool
        /// Rendered height in points, kept unnormalized so a type floor stays
        /// meaningful on a scaled runner capture.
        var pointHeight: Double

        init(
            id: String,
            role: String,
            label: String,
            value: String? = nil,
            frame: Rect,
            isLeaf: Bool = true,
            isInteractive: Bool = false,
            isFocused: Bool = false,
            isTruncated: Bool = false,
            pointHeight: Double = 0
        ) {
            self.id = id
            self.role = role
            self.label = label
            self.value = value
            self.frame = frame
            self.isLeaf = isLeaf
            self.isInteractive = isInteractive
            self.isFocused = isFocused
            self.isTruncated = isTruncated
            self.pointHeight = pointHeight
        }

        var text: String {
            [label, value ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    /// Ink measured on the app's own content layer, never on the composited
    /// screen. Window material and the user's wallpaper do not render into a
    /// `cacheDisplay` bitmap, so a quiet region reads as quiet regardless of
    /// what sits behind the glass.
    struct InkSample: Codable, Equatable, Sendable {
        var coverage: Double
        var minimumLuminance: Double
        var maximumLuminance: Double
        var samples: Int

        init(coverage: Double, minimumLuminance: Double, maximumLuminance: Double, samples: Int) {
            self.coverage = coverage
            self.minimumLuminance = minimumLuminance
            self.maximumLuminance = maximumLuminance
            self.samples = samples
        }

        static var empty: InkSample {
            InkSample(
                coverage: 0,
                minimumLuminance: 0,
                maximumLuminance: 0,
                samples: 0
            )
        }

        var luminanceRange: Double {
            guard samples > 0, coverage > 0 else { return 0 }
            return max(0, maximumLuminance - minimumLuminance)
        }

        var describedForReport: String {
            String(
                format: "coverage=%.3f range=%.3f samples=%d",
                coverage, luminanceRange, samples
            )
        }
    }

    /// Coarse content fingerprint. Cells are row-major from the top-left.
    struct InkGrid: Codable, Equatable, Sendable {
        var columns: Int
        var rows: Int
        var cells: [InkSample]

        func cellRect(column: Int, row: Int) -> Rect {
            Rect(
                x: Double(column) / Double(columns),
                y: Double(row) / Double(rows),
                width: 1 / Double(columns),
                height: 1 / Double(rows)
            )
        }

        /// Merges every cell that overlaps `rect` and is not covered by a mask.
        /// Masked material (terminal output, web previews, live timestamps) is
        /// dropped whole-cell so a nondeterministic region can never decide a
        /// verdict.
        func sample(in rect: Rect, masks: [Rect]) -> InkSample {
            guard columns > 0, rows > 0, cells.count == columns * rows else {
                return .empty
            }
            var coverage = 0.0
            var weight = 0.0
            var minimum = 1.0
            var maximum = 0.0
            var samples = 0
            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let cell = cellRect(column: column, row: row)
                    let overlap = cell.intersection(rect).area
                    guard overlap > 0 else { continue }
                    if masks.contains(where: { $0.intersection(cell).area > 0 }) { continue }
                    let sample = cells[row * columns + column]
                    guard sample.samples > 0 else { continue }
                    coverage += sample.coverage * overlap
                    weight += overlap
                    samples += sample.samples
                    if sample.coverage > 0 {
                        minimum = Swift.min(minimum, sample.minimumLuminance)
                        maximum = Swift.max(maximum, sample.maximumLuminance)
                    }
                }
            }
            guard weight > 0, samples > 0 else { return .empty }
            return InkSample(
                coverage: coverage / weight,
                minimumLuminance: minimum <= maximum ? minimum : 0,
                maximumLuminance: minimum <= maximum ? maximum : 0,
                samples: samples
            )
        }
    }

    struct WindowControl: Codable, Equatable, Sendable {
        var name: String
        var frame: Rect
        var isHidden: Bool
    }

    var schemaVersion: Int
    var surface: String
    var appearance: String
    /// Content bounds in points, so a type floor and the reported geometry can
    /// be read back in the units a designer thinks in.
    var contentWidth: Double
    var contentHeight: Double
    var windowControls: [WindowControl]
    /// Union of the visible window buttons plus the standard titlebar margin.
    var controlZone: Rect?
    var controlZoneInk: InkSample?
    var contentInk: InkGrid?
    /// "accessibility", "view-tree" or "none" — an audit that silently sees no
    /// elements must be able to say so instead of reporting a clean surface.
    var inventorySource: String
    var elements: [Element]
    var focusedElementID: String?

    init(
        schemaVersion: Int = NativeVisualLayoutSnapshot.schemaVersion,
        surface: String,
        appearance: String = "light",
        contentWidth: Double,
        contentHeight: Double,
        windowControls: [WindowControl] = [],
        controlZone: Rect? = nil,
        controlZoneInk: InkSample? = nil,
        contentInk: InkGrid? = nil,
        inventorySource: String = "none",
        elements: [Element] = [],
        focusedElementID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.surface = surface
        self.appearance = appearance
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.windowControls = windowControls
        self.controlZone = controlZone
        self.controlZoneInk = controlZoneInk
        self.contentInk = contentInk
        self.inventorySource = inventorySource
        self.elements = elements
        self.focusedElementID = focusedElementID
    }

    var contentBounds: Rect { Rect(x: 0, y: 0, width: 1, height: 1) }
}

/// Rule identifiers, kept as constants because the reviewed expectations file
/// and the CI self-test both address rules by name.
enum NativeVisualLayoutRule {
    static let controlOverlap = "control-overlap"
    static let controlZoneInk = "control-zone-ink"
    static let clipped = "clipped"
    static let offscreen = "offscreen"
    static let elementCollision = "element-collision"
    static let truncatedText = "truncated-text"
    static let missingLabel = "missing-label"
    static let missingAction = "missing-action"
    static let missingFocus = "missing-focus"
    static let focusOutsideContent = "focus-outside-content"
    static let typeFloor = "type-floor"
    static let inventoryUnavailable = "inventory-unavailable"
    static let contentInkFloor = "content-ink-floor"
    static let missingWindowControls = "missing-window-controls"

    static var all: [String] {
        [
            controlOverlap, controlZoneInk, clipped, offscreen, elementCollision,
            truncatedText, missingLabel, missingAction, missingFocus,
            focusOutsideContent, typeFloor, inventoryUnavailable, contentInkFloor,
            missingWindowControls,
        ]
    }
}

enum NativeVisualLayoutSeverity: String, Codable, Sendable {
    /// Fails the gate.
    case fail
    /// Printed for the reviewer, does not fail the gate. Rules start here when
    /// the signal has not been observed on a real runner yet.
    case observe
    case off
}

struct NativeVisualLayoutViolation: Equatable, Sendable {
    var rule: String
    var surface: String
    var detail: String
    var severity: NativeVisualLayoutSeverity

    var reportLine: String {
        "surface=\(surface) rule=\(rule) severity=\(severity.rawValue) \(detail)"
    }
}

/// The reviewed baseline. Every threshold, mask and required label the audit
/// applies lives here, so tightening or relaxing the gate is a reviewable diff
/// rather than a code change buried in a rule.
struct NativeVisualLayoutExpectations: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    struct ControlZoneInkPolicy: Codable, Equatable, Sendable {
        /// Fraction of the control strip that must carry app-drawn pixels
        /// before the strip counts as occupied at all.
        var coverageThreshold: Double
        /// A flat sidebar fill under the buttons is fine; contrast inside the
        /// strip is what a reader sees as content sitting on the controls.
        var luminanceRangeThreshold: Double
        /// A handful of antialiased pixels is not evidence. The probe samples
        /// the strip densely, so this only rejects a degenerate measurement.
        var minimumSamples: Int

        static var `default`: ControlZoneInkPolicy {
            ControlZoneInkPolicy(
                coverageThreshold: 0.04,
                luminanceRangeThreshold: 0.18,
                minimumSamples: 64
            )
        }
    }

    struct Surface: Codable, Equatable, Sendable {
        var requiredLabels: [String]?
        var requiredActions: [String]?
        /// Nondeterministic material excluded from every ink rule.
        var masks: [NativeVisualLayoutSnapshot.Rect]?
        var requiresFocus: Bool?
        var minimumTextPointHeight: Double?
        var minimumContentInkCoverage: Double?
        var allowsWindowControlsHidden: Bool?
        var severities: [String: NativeVisualLayoutSeverity]?

        static var empty: Surface { Surface() }

        init(
            requiredLabels: [String]? = nil,
            requiredActions: [String]? = nil,
            masks: [NativeVisualLayoutSnapshot.Rect]? = nil,
            requiresFocus: Bool? = nil,
            minimumTextPointHeight: Double? = nil,
            minimumContentInkCoverage: Double? = nil,
            allowsWindowControlsHidden: Bool? = nil,
            severities: [String: NativeVisualLayoutSeverity]? = nil
        ) {
            self.requiredLabels = requiredLabels
            self.requiredActions = requiredActions
            self.masks = masks
            self.requiresFocus = requiresFocus
            self.minimumTextPointHeight = minimumTextPointHeight
            self.minimumContentInkCoverage = minimumContentInkCoverage
            self.allowsWindowControlsHidden = allowsWindowControlsHidden
            self.severities = severities
        }

        /// Surface entries override the defaults field by field, so a surface
        /// only states what it actually differs on.
        func resolved(against defaults: Surface) -> Surface {
            Surface(
                requiredLabels: requiredLabels ?? defaults.requiredLabels,
                requiredActions: requiredActions ?? defaults.requiredActions,
                masks: masks ?? defaults.masks,
                requiresFocus: requiresFocus ?? defaults.requiresFocus,
                minimumTextPointHeight: minimumTextPointHeight ?? defaults.minimumTextPointHeight,
                minimumContentInkCoverage: minimumContentInkCoverage
                    ?? defaults.minimumContentInkCoverage,
                allowsWindowControlsHidden: allowsWindowControlsHidden
                    ?? defaults.allowsWindowControlsHidden,
                severities: (defaults.severities ?? [:]).merging(severities ?? [:]) { _, new in new }
            )
        }
    }

    var schemaVersion: Int
    /// `required` fails a surface whose fixture reported no elements at all;
    /// `observe` reports it. A gate that quietly sees nothing is the failure
    /// mode this whole file exists to prevent, so the policy is explicit.
    var inventoryPolicy: NativeVisualLayoutSeverity
    var severities: [String: NativeVisualLayoutSeverity]
    var controlZoneInk: ControlZoneInkPolicy
    /// Elements at or above this share of the content are containers, and a
    /// container under the titlebar is the normal `fullSizeContentView` shape.
    var containerAreaShare: Double
    /// Panes and backdrops also give themselves away by spanning a whole edge:
    /// the settings sidebar's material view is only a fifth of the width but
    /// runs the full height, and it is meant to sit under the buttons. A wide
    /// label is not a backdrop, so this stays close to a full span.
    var containerSpanShare: Double
    /// Fraction of the control strip an element must cover before its overlap
    /// counts, so a one-pixel corner touch is not a regression.
    var controlOverlapShare: Double
    var edgeSlack: Double
    var defaults: Surface
    var surfaces: [String: Surface]

    func surface(_ name: String) -> Surface {
        (surfaces[name] ?? .empty).resolved(against: defaults)
    }

    func severity(of rule: String, surface: Surface) -> NativeVisualLayoutSeverity {
        surface.severities?[rule] ?? severities[rule] ?? .fail
    }
}

/// Pure verdict: a snapshot plus the reviewed expectations produce a sorted,
/// deterministic violation list. No file system, no AppKit, no clock.
enum NativeVisualLayoutAudit {
    static func violations(
        in snapshot: NativeVisualLayoutSnapshot,
        expectations: NativeVisualLayoutExpectations
    ) -> [NativeVisualLayoutViolation] {
        let surface = expectations.surface(snapshot.surface)
        var found: [NativeVisualLayoutViolation] = []

        func record(_ rule: String, _ detail: String) {
            let severity = expectations.severity(of: rule, surface: surface)
            guard severity != .off else { return }
            found.append(NativeVisualLayoutViolation(
                rule: rule,
                surface: snapshot.surface,
                detail: detail,
                severity: severity
            ))
        }

        let masks = surface.masks ?? []
        let leaves = snapshot.elements.filter {
            $0.isLeaf
                && $0.frame.area < expectations.containerAreaShare
                && $0.frame.width < expectations.containerSpanShare
                && $0.frame.height < expectations.containerSpanShare
        }

        // 1. Window controls: present, and nothing drawn on top of them.
        let visibleControls = snapshot.windowControls.filter { !$0.isHidden }
        if visibleControls.isEmpty, surface.allowsWindowControlsHidden != true {
            record(
                NativeVisualLayoutRule.missingWindowControls,
                "reason=no-visible-standard-window-buttons"
            )
        }
        if let zone = snapshot.controlZone {
            for element in leaves {
                let overlap = element.frame.intersection(zone).area
                guard zone.area > 0,
                      overlap / zone.area >= expectations.controlOverlapShare else { continue }
                record(
                    NativeVisualLayoutRule.controlOverlap,
                    "element=\(element.id) role=\(element.role) "
                        + "label=\(reportable(element.label)) "
                        + "frame=[\(element.frame.describedForReport)] "
                        + String(format: "share=%.3f", overlap / zone.area)
                )
            }
            if let ink = snapshot.controlZoneInk {
                let policy = expectations.controlZoneInk
                if ink.samples >= policy.minimumSamples,
                   ink.coverage >= policy.coverageThreshold,
                   ink.luminanceRange >= policy.luminanceRangeThreshold {
                    record(
                        NativeVisualLayoutRule.controlZoneInk,
                        "zone=[\(zone.describedForReport)] \(ink.describedForReport)"
                    )
                }
            }
        }

        // 2. Inventory-backed geometry.
        if snapshot.elements.isEmpty {
            let severity = expectations.inventoryPolicy
            if severity != .off {
                found.append(NativeVisualLayoutViolation(
                    rule: NativeVisualLayoutRule.inventoryUnavailable,
                    surface: snapshot.surface,
                    detail: "source=\(snapshot.inventorySource) elements=0",
                    severity: severity
                ))
            }
        }

        let content = snapshot.contentBounds
        for element in leaves {
            if element.frame.intersection(content).area <= 0 {
                record(
                    NativeVisualLayoutRule.offscreen,
                    "element=\(element.id) label=\(reportable(element.label)) "
                        + "frame=[\(element.frame.describedForReport)]"
                )
            } else if !element.frame.isContained(in: content, slack: expectations.edgeSlack) {
                record(
                    NativeVisualLayoutRule.clipped,
                    "element=\(element.id) label=\(reportable(element.label)) "
                        + "frame=[\(element.frame.describedForReport)]"
                )
            }
            if element.isTruncated {
                record(
                    NativeVisualLayoutRule.truncatedText,
                    "element=\(element.id) role=\(element.role) "
                        + "text=\(reportable(element.text))"
                )
            }
            if let floor = surface.minimumTextPointHeight,
               element.role == "AXStaticText",
               element.pointHeight > 0,
               element.pointHeight < floor {
                record(
                    NativeVisualLayoutRule.typeFloor,
                    "element=\(element.id) text=\(reportable(element.text)) "
                        + String(format: "height=%.2f floor=%.2f", element.pointHeight, floor)
                )
            }
        }

        // 3. Interactive controls must not sit on each other. Text may overlap
        // its own decoration, so only hit-testable leaves are compared.
        let interactive = leaves.filter(\.isInteractive)
        for (index, element) in interactive.enumerated() {
            for other in interactive.dropFirst(index + 1) {
                let overlap = element.frame.intersection(other.frame).area
                let smaller = min(element.frame.area, other.frame.area)
                guard smaller > 0, overlap / smaller >= 0.25 else { continue }
                record(
                    NativeVisualLayoutRule.elementCollision,
                    "elements=\(element.id)+\(other.id) "
                        + "labels=\(reportable(element.label))+\(reportable(other.label)) "
                        + String(format: "share=%.3f", overlap / smaller)
                )
            }
        }

        // 4. Critical labels and actions.
        if !snapshot.elements.isEmpty {
            for label in surface.requiredLabels ?? [] where !containsText(snapshot.elements, label) {
                record(
                    NativeVisualLayoutRule.missingLabel,
                    "expected=\(reportable(label))"
                )
            }
            for action in surface.requiredActions ?? [] {
                let present = snapshot.elements.contains {
                    $0.isInteractive && $0.text.localizedCaseInsensitiveContains(action)
                }
                if !present {
                    record(
                        NativeVisualLayoutRule.missingAction,
                        "expected=\(reportable(action))"
                    )
                }
            }
        }

        // 5. Focus.
        if surface.requiresFocus == true {
            if let focusedID = snapshot.focusedElementID,
               let focused = snapshot.elements.first(where: { $0.id == focusedID }) {
                if !focused.frame.isContained(in: content, slack: expectations.edgeSlack) {
                    record(
                        NativeVisualLayoutRule.focusOutsideContent,
                        "element=\(focused.id) frame=[\(focused.frame.describedForReport)]"
                    )
                }
            } else {
                record(
                    NativeVisualLayoutRule.missingFocus,
                    "reason=no-focused-element"
                )
            }
        }

        // 6. Structural image assertion over the unmasked content.
        if let floor = surface.minimumContentInkCoverage, let grid = snapshot.contentInk {
            let sample = grid.sample(in: content, masks: masks)
            if sample.samples > 0, sample.coverage < floor {
                record(
                    NativeVisualLayoutRule.contentInkFloor,
                    "\(sample.describedForReport) " + String(format: "floor=%.3f", floor)
                )
            }
        }

        return found.sorted {
            ($0.rule, $0.detail) < ($1.rule, $1.detail)
        }
    }

    private static func containsText(
        _ elements: [NativeVisualLayoutSnapshot.Element],
        _ needle: String
    ) -> Bool {
        elements.contains { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    /// Report lines are parsed by eye in a CI log; keep them single-token.
    private static func reportable(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = collapsed.count > 60
            ? String(collapsed.prefix(60)) + "…"
            : collapsed
        return "\"" + limited.replacingOccurrences(of: "\"", with: "'") + "\""
    }
}

/// The review record that guards the reviewed baseline. Changing a threshold,
/// a mask or a required label changes the expectations digest, and the gate
/// refuses the run until a human has recorded who looked at the before/after
/// artifacts and why the new baseline is correct.
struct NativeVisualBaselineReview: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var expectationsDigest: String
    var reviewedBy: String
    var reviewedAt: String
    var reason: String
    /// Artifact references for the screenshots that were compared. Free-form
    /// on purpose: a workflow run URL, an artifact name, or both.
    var beforeArtifact: String
    var afterArtifact: String

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func failureReason(forExpectations data: Data) -> String? {
        if schemaVersion != Self.schemaVersion {
            return "review-schema=\(schemaVersion) expected=\(Self.schemaVersion)"
        }
        for (field, value) in [
            ("reviewedBy", reviewedBy),
            ("reviewedAt", reviewedAt),
            ("reason", reason),
            ("beforeArtifact", beforeArtifact),
            ("afterArtifact", afterArtifact),
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "review-field-empty=\(field)"
        }
        let actual = Self.digest(of: data)
        guard actual == expectationsDigest.lowercased() else {
            return "expectations-digest=\(actual) reviewed=\(expectationsDigest.lowercased())"
        }
        return nil
    }
}

/// Directory runner used by CI and by the fixture itself.
enum NativeVisualLayoutGate {
    static let snapshotSuffix = ".layout.json"

    struct Report: Equatable, Sendable {
        var surfaces: [String]
        var violations: [NativeVisualLayoutViolation]

        var failures: [NativeVisualLayoutViolation] {
            violations.filter { $0.severity == .fail }
        }

        var observations: [NativeVisualLayoutViolation] {
            violations.filter { $0.severity == .observe }
        }
    }

    struct SelfTestCase: Codable, Equatable, Sendable {
        var snapshot: String
        var expectedRules: [String]
        var note: String?
    }

    struct SelfTestManifest: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var cases: [SelfTestCase]
    }

    enum GateError: Error, CustomStringConvertible {
        case usage(String)
        case unreadable(String, String)
        case unknownRule(String, String)
        case reviewRejected(String)
        case schema(String)

        var description: String {
            switch self {
            case let .usage(detail):
                return "usage: \(detail)"
            case let .unreadable(path, detail):
                return "unreadable \(path): \(detail)"
            case let .unknownRule(caseName, rule):
                return "self-test case \(caseName) names unknown rule \(rule)"
            case let .reviewRejected(detail):
                return "baseline review rejected: \(detail)"
            case let .schema(detail):
                return "schema: \(detail)"
            }
        }
    }

    static func decoder() -> JSONDecoder { JSONDecoder() }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func loadExpectations(at url: URL) throws -> (NativeVisualLayoutExpectations, Data) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GateError.unreadable(url.path, error.localizedDescription)
        }
        let expectations: NativeVisualLayoutExpectations
        do {
            expectations = try decoder().decode(NativeVisualLayoutExpectations.self, from: data)
        } catch {
            throw GateError.unreadable(url.path, "\(error)")
        }
        guard expectations.schemaVersion == NativeVisualLayoutExpectations.schemaVersion else {
            throw GateError.schema(
                "expectations=\(expectations.schemaVersion) "
                    + "expected=\(NativeVisualLayoutExpectations.schemaVersion)"
            )
        }
        for rule in expectations.severities.keys where !NativeVisualLayoutRule.all.contains(rule) {
            throw GateError.schema("expectations name unknown rule \(rule)")
        }
        return (expectations, data)
    }

    /// A reviewed baseline is only trustworthy if the review record still
    /// describes the bytes being applied.
    static func verifyReview(expectationsData: Data, reviewURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: reviewURL)
        } catch {
            throw GateError.unreadable(reviewURL.path, error.localizedDescription)
        }
        let review: NativeVisualBaselineReview
        do {
            review = try decoder().decode(NativeVisualBaselineReview.self, from: data)
        } catch {
            throw GateError.unreadable(reviewURL.path, "\(error)")
        }
        if let reason = review.failureReason(forExpectations: expectationsData) {
            throw GateError.reviewRejected(reason)
        }
    }

    static func snapshotURLs(in directory: URL) throws -> [URL] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw GateError.unreadable(directory.path, error.localizedDescription)
        }
        return contents
            .filter { $0.lastPathComponent.hasSuffix(snapshotSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadSnapshot(at url: URL) throws -> NativeVisualLayoutSnapshot {
        let snapshot: NativeVisualLayoutSnapshot
        do {
            snapshot = try decoder().decode(
                NativeVisualLayoutSnapshot.self,
                from: try Data(contentsOf: url)
            )
        } catch {
            throw GateError.unreadable(url.path, "\(error)")
        }
        guard snapshot.schemaVersion == NativeVisualLayoutSnapshot.schemaVersion else {
            throw GateError.schema(
                "\(url.lastPathComponent) snapshot=\(snapshot.schemaVersion) "
                    + "expected=\(NativeVisualLayoutSnapshot.schemaVersion)"
            )
        }
        return snapshot
    }

    /// Every captured PNG must be accompanied by a snapshot. A fixture that
    /// stops emitting one would otherwise silently drop out of the gate.
    static func missingSnapshots(in directory: URL) throws -> [String] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw GateError.unreadable(directory.path, error.localizedDescription)
        }
        let snapshots = Set(
            contents
                .filter { $0.lastPathComponent.hasSuffix(snapshotSuffix) }
                .map { String($0.lastPathComponent.dropLast(snapshotSuffix.count)) }
        )
        return contents
            .filter { $0.pathExtension == "png" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !snapshots.contains($0) }
            .sorted()
    }

    static func run(
        directory: URL,
        expectationsURL: URL,
        reviewURL: URL,
        emit: (String) -> Void = { print($0) }
    ) throws -> Report {
        let (expectations, expectationsData) = try loadExpectations(at: expectationsURL)
        try verifyReview(expectationsData: expectationsData, reviewURL: reviewURL)
        emit(
            "KAISOLA_NATIVE_VISUAL_LAYOUT_BASELINE=PASS digest="
                + NativeVisualBaselineReview.digest(of: expectationsData)
        )

        var report = Report(surfaces: [], violations: [])
        for name in try missingSnapshots(in: directory) {
            report.violations.append(NativeVisualLayoutViolation(
                rule: NativeVisualLayoutRule.inventoryUnavailable,
                surface: name,
                detail: "reason=no-layout-snapshot-beside-capture",
                severity: .fail
            ))
        }
        let urls = try snapshotURLs(in: directory)
        guard !urls.isEmpty else {
            throw GateError.usage("no \(snapshotSuffix) files in \(directory.path)")
        }
        for url in urls {
            let snapshot = try loadSnapshot(at: url)
            report.surfaces.append(snapshot.surface)
            let violations = NativeVisualLayoutAudit.violations(
                in: snapshot,
                expectations: expectations
            )
            report.violations.append(contentsOf: violations)
            for violation in violations {
                emit("KAISOLA_NATIVE_VISUAL_LAYOUT=\(verdictWord(violation.severity)) \(violation.reportLine)")
            }
            if !violations.contains(where: { $0.severity == .fail }) {
                emit(
                    "KAISOLA_NATIVE_VISUAL_LAYOUT=PASS surface=\(snapshot.surface) "
                        + "elements=\(snapshot.elements.count) source=\(snapshot.inventorySource)"
                )
            }
        }
        return report
    }

    /// Proves the gate still rejects the regressions it was built for. A gate
    /// nobody can see failing is the same as no gate.
    static func selfTest(
        fixtures: URL,
        expectationsURL: URL,
        emit: (String) -> Void = { print($0) }
    ) throws -> Bool {
        let (expectations, _) = try loadExpectations(at: expectationsURL)
        let manifestURL = fixtures.appendingPathComponent("self-test.json", isDirectory: false)
        let manifest: SelfTestManifest
        do {
            manifest = try decoder().decode(
                SelfTestManifest.self,
                from: try Data(contentsOf: manifestURL)
            )
        } catch {
            throw GateError.unreadable(manifestURL.path, "\(error)")
        }
        guard manifest.schemaVersion == SelfTestManifest.currentSchemaVersion else {
            throw GateError.schema(
                "self-test=\(manifest.schemaVersion) "
                    + "expected=\(SelfTestManifest.currentSchemaVersion)"
            )
        }
        guard !manifest.cases.isEmpty else {
            throw GateError.usage("self-test manifest lists no cases")
        }
        var passed = true
        for testCase in manifest.cases {
            for rule in testCase.expectedRules where !NativeVisualLayoutRule.all.contains(rule) {
                throw GateError.unknownRule(testCase.snapshot, rule)
            }
            let snapshot = try loadSnapshot(
                at: fixtures.appendingPathComponent(testCase.snapshot, isDirectory: false)
            )
            let failing = Set(
                NativeVisualLayoutAudit
                    .violations(in: snapshot, expectations: expectations)
                    .filter { $0.severity == .fail }
                    .map(\.rule)
            )
            let missing = testCase.expectedRules.filter { !failing.contains($0) }.sorted()
            let unexpected = testCase.expectedRules.isEmpty ? failing.sorted() : []
            if missing.isEmpty, unexpected.isEmpty {
                emit(
                    "KAISOLA_NATIVE_VISUAL_LAYOUT_SELFTEST=PASS case=\(testCase.snapshot) "
                        + "rules=\(testCase.expectedRules.sorted().joined(separator: ","))"
                )
            } else {
                passed = false
                emit(
                    "KAISOLA_NATIVE_VISUAL_LAYOUT_SELFTEST=FAIL case=\(testCase.snapshot) "
                        + "missing=\(missing.joined(separator: ",")) "
                        + "unexpected=\(unexpected.joined(separator: ","))"
                )
            }
        }
        return passed
    }

    private static func verdictWord(_ severity: NativeVisualLayoutSeverity) -> String {
        switch severity {
        case .fail: return "FAIL"
        case .observe: return "OBSERVE"
        case .off: return "OFF"
        }
    }
}

extension NativeVisualLayoutGate.SelfTestManifest {
    static let currentSchemaVersion = 1
}

/// Command-line entry points, invoked from `KaisolaMacMain` before the GUI is
/// ever created so CI can run the gate on a headless runner.
enum NativeVisualLayoutCommand {
    static let gateFlag = "--visual-layout-gate"
    static let selfTestFlag = "--visual-layout-self-test"
    static let expectationsFlag = "--expectations"
    static let reviewFlag = "--review"

    struct Invocation: Equatable {
        enum Mode: Equatable {
            case gate(directory: String)
            case selfTest(fixtures: String)
        }

        var mode: Mode
        var expectations: String?
        var review: String?
    }

    /// Returns nil for an ordinary app launch so a normal start never pays for
    /// this parse beyond a prefix check.
    static func parse(arguments: [String]) -> Invocation? {
        var mode: Invocation.Mode?
        var expectations: String?
        var review: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let value = arguments.index(after: index) < arguments.endIndex
                ? arguments[arguments.index(after: index)]
                : nil
            switch argument {
            case gateFlag:
                guard let value else { return nil }
                mode = .gate(directory: value)
                index = arguments.index(index, offsetBy: 2)
                continue
            case selfTestFlag:
                guard let value else { return nil }
                mode = .selfTest(fixtures: value)
                index = arguments.index(index, offsetBy: 2)
                continue
            case expectationsFlag:
                guard let value else { return nil }
                expectations = value
                index = arguments.index(index, offsetBy: 2)
                continue
            case reviewFlag:
                guard let value else { return nil }
                review = value
                index = arguments.index(index, offsetBy: 2)
                continue
            default:
                index = arguments.index(after: index)
            }
        }
        guard let mode else { return nil }
        return Invocation(mode: mode, expectations: expectations, review: review)
    }

    static func requestsGate(arguments: [String]) -> Bool {
        arguments.contains(gateFlag) || arguments.contains(selfTestFlag)
    }

    /// Runs the requested mode and returns the process exit status.
    static func run(_ invocation: Invocation, emit: (String) -> Void = { print($0) }) -> Int32 {
        let expectations = URL(
            fileURLWithPath: invocation.expectations
                ?? "native/KaisolaMac/VisualBaselines/layout-expectations.json"
        )
        do {
            switch invocation.mode {
            case let .gate(directory):
                let review = URL(
                    fileURLWithPath: invocation.review
                        ?? "native/KaisolaMac/VisualBaselines/layout-review.json"
                )
                let report = try NativeVisualLayoutGate.run(
                    directory: URL(fileURLWithPath: directory, isDirectory: true),
                    expectationsURL: expectations,
                    reviewURL: review,
                    emit: emit
                )
                guard report.failures.isEmpty else {
                    emit(
                        "KAISOLA_NATIVE_VISUAL_LAYOUT_GATE=FAIL "
                            + "surfaces=\(report.surfaces.count) "
                            + "failures=\(report.failures.count) "
                            + "observations=\(report.observations.count)"
                    )
                    return 1
                }
                emit(
                    "KAISOLA_NATIVE_VISUAL_LAYOUT_GATE=PASS "
                        + "surfaces=\(report.surfaces.count) "
                        + "observations=\(report.observations.count)"
                )
                return 0
            case let .selfTest(fixtures):
                let passed = try NativeVisualLayoutGate.selfTest(
                    fixtures: URL(fileURLWithPath: fixtures, isDirectory: true),
                    expectationsURL: expectations,
                    emit: emit
                )
                emit("KAISOLA_NATIVE_VISUAL_LAYOUT_SELFTEST_GATE=\(passed ? "PASS" : "FAIL")")
                return passed ? 0 : 1
            }
        } catch {
            emit("KAISOLA_NATIVE_VISUAL_LAYOUT_GATE=FAIL \(error)")
            return 1
        }
    }
}
