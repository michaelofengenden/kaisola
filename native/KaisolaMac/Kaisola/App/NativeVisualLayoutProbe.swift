import AppKit
import Foundation

/// Records the structural facts a hosted visual fixture can see about the
/// window it is about to capture: where the standard window buttons are, what
/// the accessibility tree exposes, and how much app-drawn ink sits in the
/// regions the audit judges.
///
/// The probe never decides anything. It writes facts down;
/// `NativeVisualLayoutAudit` applies the reviewed expectations to them.
@MainActor
enum NativeVisualLayoutProbe {
    /// Elements and ink are both capped so a pathological tree cannot turn a
    /// fixture into a timeout.
    static let elementLimit = 1_500
    static let depthLimit = 40
    static let inkColumns = 24
    static let inkRows = 18
    static let inkSamplesPerCellAxis = 4
    static let controlZoneSampleColumns = 48
    static let controlZoneSampleRows = 16
    /// Standard titlebar breathing room around the buttons. Content that lands
    /// inside this strip reads as sitting on the controls.
    static let controlZoneMargin: CGFloat = 6

    nonisolated static func snapshotURL(forCapturePath path: String) -> URL {
        let capture = URL(fileURLWithPath: path, isDirectory: false)
        let stem = capture.deletingPathExtension().lastPathComponent
        return capture
            .deletingLastPathComponent()
            .appendingPathComponent(stem + NativeVisualLayoutGate.snapshotSuffix, isDirectory: false)
    }

    static func snapshot(
        of window: NSWindow,
        surface: String,
        appearance: String
    ) -> NativeVisualLayoutSnapshot? {
        guard let contentView = window.contentView else { return nil }
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let controls = windowControls(of: window, in: contentView)
        let zone = controlZone(from: controls, in: bounds)
        let bitmap = contentBitmap(of: contentView)
        let inventory = elements(in: window, contentView: contentView)

        return NativeVisualLayoutSnapshot(
            surface: surface,
            appearance: appearance,
            contentWidth: Double(bounds.width),
            contentHeight: Double(bounds.height),
            windowControls: controls,
            controlZone: zone,
            controlZoneInk: zone.flatMap { sample(bitmap, in: $0, columns: controlZoneSampleColumns, rows: controlZoneSampleRows) },
            contentInk: bitmap.map(inkGrid(of:)),
            inventorySource: inventory.source,
            elements: inventory.elements,
            focusedElementID: inventory.focusedElementID
        )
    }

    nonisolated static func write(
        _ snapshot: NativeVisualLayoutSnapshot,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try NativeVisualLayoutGate.encoder().encode(snapshot).write(to: url, options: .atomic)
    }

    // MARK: - Geometry

    /// Normalizes an AppKit rect in content coordinates into the audit's
    /// top-left, 0…1 space. `NSHostingView` is flipped and a plain `NSView` is
    /// not, so the caller states which one it measured — reading a flipped
    /// hierarchy as bottom-left puts the window buttons at the foot of the
    /// window and every geometry rule then judges the wrong strip.
    nonisolated static func normalize(
        _ rect: CGRect,
        in bounds: CGRect,
        flipped: Bool = false
    ) -> NativeVisualLayoutSnapshot.Rect {
        guard bounds.width > 0, bounds.height > 0 else {
            return NativeVisualLayoutSnapshot.Rect(x: 0, y: 0, width: 0, height: 0)
        }
        let y = flipped
            ? (rect.minY - bounds.minY) / bounds.height
            : (bounds.maxY - rect.maxY) / bounds.height
        return NativeVisualLayoutSnapshot.Rect(
            x: Double((rect.minX - bounds.minX) / bounds.width),
            y: Double(y),
            width: Double(rect.width / bounds.width),
            height: Double(rect.height / bounds.height)
        )
    }

    private static func windowControls(
        of window: NSWindow,
        in contentView: NSView
    ) -> [NativeVisualLayoutSnapshot.WindowControl] {
        let buttons: [(String, NSWindow.ButtonType)] = [
            ("close", .closeButton),
            ("miniaturize", .miniaturizeButton),
            ("zoom", .zoomButton),
        ]
        return buttons.compactMap { name, type in
            guard let button = window.standardWindowButton(type) else { return nil }
            let inWindow = button.convert(button.bounds, to: nil)
            let inContent = contentView.convert(inWindow, from: nil)
            return NativeVisualLayoutSnapshot.WindowControl(
                name: name,
                frame: normalize(inContent, in: contentView.bounds, flipped: contentView.isFlipped),
                isHidden: button.isHidden || button.alphaValue < 0.05
            )
        }
    }

    private static func controlZone(
        from controls: [NativeVisualLayoutSnapshot.WindowControl],
        in bounds: CGRect
    ) -> NativeVisualLayoutSnapshot.Rect? {
        let visible = controls.filter { !$0.isHidden }
        guard let first = visible.first else { return nil }
        var minX = first.frame.x
        var minY = first.frame.y
        var maxX = first.frame.maxX
        var maxY = first.frame.maxY
        for control in visible.dropFirst() {
            minX = min(minX, control.frame.x)
            minY = min(minY, control.frame.y)
            maxX = max(maxX, control.frame.maxX)
            maxY = max(maxY, control.frame.maxY)
        }
        let marginX = Double(controlZoneMargin / max(1, bounds.width))
        let marginY = Double(controlZoneMargin / max(1, bounds.height))
        let x = max(0, minX - marginX)
        let y = max(0, minY - marginY)
        return NativeVisualLayoutSnapshot.Rect(
            x: x,
            y: y,
            width: min(1, maxX + marginX) - x,
            height: min(1, maxY + marginY) - y
        )
    }

    // MARK: - Inventory

    private struct Inventory {
        var source: String
        var elements: [NativeVisualLayoutSnapshot.Element]
        var focusedElementID: String?
    }

    private static func elements(in window: NSWindow, contentView: NSView) -> Inventory {
        var collected: [NativeVisualLayoutSnapshot.Element] = []
        var focused: String?
        let focusedElement = window.firstResponder as? NSView

        func visit(_ node: Any, path: String, depth: Int) {
            guard collected.count < elementLimit, depth < depthLimit else { return }
            let object = node as AnyObject
            guard let accessible = object as? NSAccessibilityProtocol else { return }
            let role = accessible.accessibilityRole()?.rawValue ?? "AXUnknown"
            let children = accessible.accessibilityChildren() ?? []
            let frame = contentFrame(of: object, window: window, contentView: contentView)
            if let frame, frame.width > 0, frame.height > 0 {
                let label = accessible.accessibilityLabel()
                    ?? accessible.accessibilityTitle()
                    ?? ""
                let value = (accessible.accessibilityValue() as? String)
                let isLeaf = children.isEmpty
                let view = object as? NSView
                let element = NativeVisualLayoutSnapshot.Element(
                    id: path,
                    role: role,
                    label: label,
                    value: value,
                    frame: normalize(frame, in: contentView.bounds, flipped: contentView.isFlipped),
                    isLeaf: isLeaf,
                    isInteractive: isInteractive(role: role),
                    isFocused: view != nil && view === focusedElement,
                    isTruncated: isTruncated(object, frame: frame),
                    pointHeight: Double(frame.height)
                )
                if element.isFocused { focused = element.id }
                collected.append(element)
            }
            for (index, child) in children.enumerated() {
                visit(child, path: path.isEmpty ? "\(index)" : "\(path)/\(index)", depth: depth + 1)
            }
        }

        visit(contentView, path: "0", depth: 0)
        if collected.count > 1 {
            return Inventory(
                source: "accessibility",
                elements: collected,
                focusedElementID: focused
            )
        }
        // A SwiftUI hosting view publishes its accessibility children to a
        // connected assistive client, not to an in-process walk, so it answers
        // with itself and nothing else. The real view tree still carries the
        // AppKit surfaces — alert sheets, text fields, scroll views — which is
        // where measured truncation and focus live. Fall back to it, and name
        // the source so a snapshot can never claim coverage it does not have.
        collected = []
        focused = nil

        func visitView(_ view: NSView, path: String, depth: Int) {
            guard collected.count < elementLimit, depth < depthLimit else { return }
            let frame = view.convert(view.bounds, to: contentView)
            if frame.width > 0, frame.height > 0, !view.isHidden {
                let element = NativeVisualLayoutSnapshot.Element(
                    id: path,
                    role: view.accessibilityRole()?.rawValue ?? "AXUnknown",
                    label: view.accessibilityLabel() ?? view.accessibilityTitle() ?? "",
                    value: view.accessibilityValue() as? String,
                    frame: normalize(frame, in: contentView.bounds, flipped: contentView.isFlipped),
                    isLeaf: view.subviews.isEmpty,
                    isInteractive: view is NSControl,
                    isFocused: view === focusedElement,
                    isTruncated: isTruncated(view, frame: frame),
                    pointHeight: Double(frame.height)
                )
                if element.isFocused { focused = element.id }
                collected.append(element)
            }
            for (index, child) in view.subviews.enumerated() {
                visitView(child, path: "\(path)/\(index)", depth: depth + 1)
            }
        }

        visitView(contentView, path: "0", depth: 0)
        return Inventory(
            source: collected.count > 1 ? "view-tree" : (collected.isEmpty ? "none" : "root-only"),
            elements: collected,
            focusedElementID: focused
        )
    }

    private static func isInteractive(role: String) -> Bool {
        [
            "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
            "AXTextField", "AXTextArea", "AXSlider", "AXLink", "AXComboBox", "AXTabButton",
            "AXDisclosureTriangle", "AXIncrementor", "AXSearchField",
        ].contains(role)
    }

    private static func contentFrame(
        of object: AnyObject,
        window: NSWindow,
        contentView: NSView
    ) -> CGRect? {
        if let view = object as? NSView {
            return view.convert(view.bounds, to: contentView)
        }
        guard let element = object as? NSAccessibilityElementProtocol else { return nil }
        let screenFrame = element.accessibilityFrame()
        guard screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let inWindow = window.convertFromScreen(screenFrame)
        return contentView.convert(inWindow, from: nil)
    }

    /// Truncation is measured, never guessed from a trailing ellipsis: plenty
    /// of legitimate labels end in one. AppKit text cells can report the width
    /// their string actually wants, which is the honest signal.
    private static func isTruncated(_ object: AnyObject, frame: CGRect) -> Bool {
        guard let field = object as? NSTextField, !field.attributedStringValue.string.isEmpty else {
            return false
        }
        guard field.maximumNumberOfLines == 1 || !field.cell!.wraps else { return false }
        let wanted = field.attributedStringValue.size().width
        return wanted > frame.width + 1
    }

    // MARK: - Ink

    /// App-drawn content only. `cacheDisplay` skips window material and the
    /// desktop behind it, so a wallpaper cannot make a quiet strip look busy.
    private static func contentBitmap(of view: NSView) -> NSBitmapImageRep? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func inkGrid(of bitmap: NSBitmapImageRep) -> NativeVisualLayoutSnapshot.InkGrid {
        var cells: [NativeVisualLayoutSnapshot.InkSample] = []
        cells.reserveCapacity(inkColumns * inkRows)
        for row in 0 ..< inkRows {
            for column in 0 ..< inkColumns {
                let rect = NativeVisualLayoutSnapshot.Rect(
                    x: Double(column) / Double(inkColumns),
                    y: Double(row) / Double(inkRows),
                    width: 1 / Double(inkColumns),
                    height: 1 / Double(inkRows)
                )
                cells.append(sample(
                    bitmap,
                    in: rect,
                    columns: inkSamplesPerCellAxis,
                    rows: inkSamplesPerCellAxis
                ) ?? .empty)
            }
        }
        return NativeVisualLayoutSnapshot.InkGrid(
            columns: inkColumns,
            rows: inkRows,
            cells: cells
        )
    }

    /// `rect` is normalized with a top-left origin, matching the bitmap's own
    /// pixel order.
    static func sample(
        _ bitmap: NSBitmapImageRep?,
        in rect: NativeVisualLayoutSnapshot.Rect,
        columns: Int,
        rows: Int
    ) -> NativeVisualLayoutSnapshot.InkSample? {
        guard let bitmap, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              columns > 0, rows > 0, rect.width > 0, rect.height > 0 else {
            return nil
        }
        var visible = 0
        var samples = 0
        var minimum = 1.0
        var maximum = 0.0
        for row in 0 ..< rows {
            let normalizedY = rect.y + (Double(row) + 0.5) / Double(rows) * rect.height
            let y = min(bitmap.pixelsHigh - 1, max(0, Int(normalizedY * Double(bitmap.pixelsHigh))))
            for column in 0 ..< columns {
                let normalizedX = rect.x + (Double(column) + 0.5) / Double(columns) * rect.width
                let x = min(bitmap.pixelsWide - 1, max(0, Int(normalizedX * Double(bitmap.pixelsWide))))
                samples += 1
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                guard color.alphaComponent > 0.05 else { continue }
                visible += 1
                let luminance = 0.2126 * Double(color.redComponent)
                    + 0.7152 * Double(color.greenComponent)
                    + 0.0722 * Double(color.blueComponent)
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        guard samples > 0 else { return nil }
        return NativeVisualLayoutSnapshot.InkSample(
            coverage: Double(visible) / Double(samples),
            minimumLuminance: visible > 0 ? minimum : 0,
            maximumLuminance: visible > 0 ? maximum : 0,
            samples: samples
        )
    }
}
