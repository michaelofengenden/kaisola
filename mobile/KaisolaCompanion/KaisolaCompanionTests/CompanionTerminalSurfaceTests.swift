import KaisolaCore
import SwiftTerm
import UIKit
import XCTest
@testable import KaisolaCompanion

@MainActor
final class CompanionTerminalSurfaceTests: XCTestCase {
    func testObserverRestoresDarkPaletteAfterLightOSCReplay() throws {
        let view = CompanionSafeTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 640),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let coordinator = CompanionTerminalSurface.Coordinator(
            onInput: { _ in },
            onResize: { _, _ in }
        )

        coordinator.apply(
            output: "\u{1B}]11;#ffffff\u{07}\u{1B}]10;#111111\u{07}visible",
            epoch: "epoch-1",
            to: view
        )

        let background = rgba(view.nativeBackgroundColor)
        let foreground = rgba(view.nativeForegroundColor)
        let layerBackground = rgba(UIColor(cgColor: try XCTUnwrap(view.layer.backgroundColor)))

        XCTAssertLessThan(background.red, 0.10)
        XCTAssertLessThan(background.green, 0.10)
        XCTAssertLessThan(background.blue, 0.10)
        XCTAssertGreaterThan(foreground.red, 0.80)
        XCTAssertGreaterThan(foreground.green, 0.80)
        XCTAssertGreaterThan(foreground.blue, 0.80)
        XCTAssertEqual(layerBackground.red, background.red, accuracy: 0.001)
        XCTAssertEqual(layerBackground.green, background.green, accuracy: 0.001)
        XCTAssertEqual(layerBackground.blue, background.blue, accuracy: 0.001)
    }

    private func rgba(_ color: UIColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return (red, green, blue, alpha)
    }
}
