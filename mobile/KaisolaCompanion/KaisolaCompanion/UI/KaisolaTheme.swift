import SwiftUI

enum KaisolaTheme {
    // Mirrors the desktop dark-mode roles in src/styles/tokens.css.
    static let accent = Color(red: 149 / 255, green: 164 / 255, blue: 86 / 255)
    static let electric = Color(red: 164 / 255, green: 179 / 255, blue: 100 / 255)
    static let running = accent
    static let waiting = Color(red: 216 / 255, green: 164 / 255, blue: 74 / 255)
    static let done = Color(red: 84 / 255, green: 192 / 255, blue: 138 / 255)
    static let failed = Color(red: 225 / 255, green: 106 / 255, blue: 106 / 255)
    static let info = Color(red: 90 / 255, green: 169 / 255, blue: 230 / 255)

    static let darkFrame = Color(red: 10 / 255, green: 11 / 255, blue: 13 / 255)
    static let darkCanvas = Color(red: 14 / 255, green: 16 / 255, blue: 20 / 255)
    static let darkPanel = Color(red: 20 / 255, green: 22 / 255, blue: 28 / 255)
    static let darkRaised = Color(red: 26 / 255, green: 29 / 255, blue: 37 / 255)
    static let darkBorder = Color(red: 35 / 255, green: 38 / 255, blue: 47 / 255)
    static let terminalBackground = Color(red: 11 / 255, green: 13 / 255, blue: 17 / 255)

    static func panel(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkPanel : Color(uiColor: .secondarySystemGroupedBackground)
    }

    static func raised(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkRaised : Color.primary.opacity(0.035)
    }

    static func border(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkBorder : Color.black.opacity(0.055)
    }

    static func color(for status: CompanionSessionStatus) -> Color {
        switch status {
        case .running: running
        case .waiting: waiting
        case .done: done
        case .failed: failed
        case .idle: .secondary
        }
    }
}

struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                KaisolaTheme.darkFrame
                LinearGradient(
                    colors: [KaisolaTheme.darkCanvas.opacity(0.72), KaisolaTheme.darkFrame],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct KaisolaCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        content
            .padding(padding)
            .background(KaisolaTheme.panel(for: colorScheme), in: shape)
            .overlay {
                shape.stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5)
            }
    }
}

struct KaisolaInset: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background(KaisolaTheme.raised(for: colorScheme), in: shape)
            .overlay {
                shape.stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5)
            }
    }
}

extension View {
    func kaisolaCard(padding: CGFloat = 16) -> some View {
        modifier(KaisolaCard(padding: padding))
    }

    func kaisolaInset(radius: CGFloat = 14) -> some View {
        modifier(KaisolaInset(radius: radius))
    }
}
