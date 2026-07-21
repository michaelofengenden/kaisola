import SwiftUI

/// The calm entry gate — one promise, one action. Mirrors the ChatGPT/Codex
/// apps: no form, no chrome, the same Google account the desktop uses.
struct SignInView: View {
    @EnvironmentObject private var auth: AuthModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var isSigningIn: Bool {
        if case .signingIn = auth.phase { return true }
        return false
    }

    private var errorText: String? {
        if case let .failed(message) = auth.phase { return message }
        return nil
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            VStack(spacing: 0) {
                Spacer()

                brandmark
                    .padding(.bottom, 28)

                Text("Kaisola Companion")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .tracking(-0.4)

                Text("Your agents, from anywhere.\nSign in with the account your Mac uses.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 12)
                    .padding(.horizontal, 8)

                Spacer()

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(KaisolaTheme.failed)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .kaisolaInset(radius: 13)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                googleButton

                Text("Signing in links this phone to your Kaisola account. Pairing to a specific Mac happens next over an encrypted connection.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 20)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
        }
        .animation(.smooth(duration: 0.4), value: auth.phase)
        .onAppear {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) { appeared = true }
        }
    }

    private var brandmark: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinearGradient(colors: [KaisolaTheme.electric, KaisolaTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 72, height: 72)
            .overlay {
                // The desktop tile mark: four offset panes.
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(KaisolaTheme.darkFrame)
            }
            .shadow(color: KaisolaTheme.accent.opacity(0.45), radius: 22, y: 10)
    }

    private var googleButton: some View {
        Button {
            Task { await auth.signInWithGoogle() }
        } label: {
            HStack(spacing: 11) {
                if isSigningIn {
                    ProgressView()
                        .controlSize(.small)
                        .tint(colorScheme == .dark ? KaisolaTheme.accent : .black)
                } else {
                    GoogleGlyph()
                        .frame(width: 18, height: 18)
                }
                Text(isSigningIn ? "Signing in…" : "Continue with Google")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(colorScheme == .dark ? Color.primary : .black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                colorScheme == .dark ? KaisolaTheme.darkRaised : Color.white,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(colorScheme == .dark ? KaisolaTheme.darkBorder : Color.black.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(QuietPressStyle())
        .disabled(isSigningIn)
        .accessibilityLabel("Continue with Google")
    }
}

/// The Google "G" — drawn, not an asset, so it needs no bundle image.
struct GoogleGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let colors: [(Color, Double, Double)] = [
                (Color(red: 0.26, green: 0.52, blue: 0.96), -20, 70),   // blue
                (Color(red: 0.20, green: 0.66, blue: 0.33), 70, 160),   // green
                (Color(red: 0.98, green: 0.74, blue: 0.02), 160, 250),  // yellow
                (Color(red: 0.92, green: 0.26, blue: 0.21), 250, 340),  // red
            ]
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = s * 0.42
            let lineW = s * 0.22
            for (color, start, end) in colors {
                var path = Path()
                path.addArc(center: center, radius: radius,
                            startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineW, lineCap: .butt))
            }
            // The horizontal bar of the G.
            var bar = Path()
            bar.addRect(CGRect(x: center.x, y: center.y - lineW / 2, width: radius + lineW / 2, height: lineW))
            ctx.fill(bar, with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))
        }
        .accessibilityHidden(true)
    }
}

#Preview("Signed out") {
    SignInView().environmentObject(AuthModel.previewSignedOut())
}
