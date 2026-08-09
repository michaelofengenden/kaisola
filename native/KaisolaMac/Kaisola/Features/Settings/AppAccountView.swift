import SwiftUI

/// Native Kaisola account UI backed by the same Firebase REST and Keychain
/// implementation as the iPhone companion. Only the redacted profile reaches
/// SwiftUI; refresh and ID tokens remain inside `FirebaseAuthBackend`.
struct AppAccountSettingsView: View {
    @ObservedObject var auth: AuthModel
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatarView(account: auth.account, size: 36)

            identityLines

            Spacer(minLength: 12)

            switch auth.phase {
            case .restoring:
                ProgressView().controlSize(.small)
            case .signedOut:
                googleSignInButton
            case .signingIn:
                Button("Cancel") { Task { await auth.signOut() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .signedIn:
                Button("Sign Out") { Task { await auth.signOut() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .failed:
                Button("Try Again") {
                    auth.clearError()
                    Task { await auth.signInWithGoogle() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// The headline plus either the ordinary caption or the recovery strip.
    /// The recovery branch speaks as one element: read as three, the row is an
    /// avatar, a headline fragment, and an orphaned explanation.
    @ViewBuilder
    private var identityLines: some View {
        if let notice = recoveryNotice {
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                recoveryStrip(notice)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(notice.accessibilityLabel)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
            }
        }
    }

    /// The one signed-out phase that carries a migration explanation.
    private var recoveryNotice: AppAccountRecoveryNotice? {
        guard case .signedOut = auth.phase, let message = auth.signedOutNotice else { return nil }
        return AppAccountRecoveryNotice(title: title, message: message)
    }

    private func recoveryStrip(_ notice: AppAccountRecoveryNotice) -> some View {
        let increased = accessibilityContrast == .increased
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            // Always drawn, not only under Differentiate Without Color: the
            // triangle is what carries "warning" when the amber is gone.
            Image(systemName: notice.systemImage)
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
            // Deliberately unclamped. At accessibility text sizes a two-line
            // limit truncates the explanation mid-sentence; wrapping is the
            // lesser cost in a settings card.
            Text(notice.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(notice.tone.foregroundColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(notice.tone.backgroundColor, in: shape)
        .overlay {
            shape.strokeBorder(
                notice.tone.foregroundColor.opacity(notice.borderOpacity(increasedContrast: increased)),
                lineWidth: notice.borderWidth(increasedContrast: increased)
            )
        }
    }

    private var googleSignInButton: some View {
        Button {
            Task { await auth.signInWithGoogle() }
        } label: {
            HStack(spacing: 7) {
                GoogleAccountGlyph().frame(width: 14, height: 14)
                Text("Sign In with Google")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var title: String {
        switch auth.phase {
        case let .signedIn(account):
            return account.displayName?.isEmpty == false ? account.displayName! : account.email
        case .signingIn: return "Signing in to Kaisola…"
        case .failed: return "Kaisola account"
        case .restoring: return "Restoring Kaisola account…"
        case .signedOut:
            return auth.signedOutNotice == nil
                ? "Kaisola account"
                : "Sign in again to finish the upgrade"
        }
    }

    private var detail: String {
        switch auth.phase {
        case let .signedIn(account): return account.email
        case let .failed(message): return message
        case .signedOut:
            // The migration notice is not a caption any more — it has its own
            // strip (`recoveryStrip`), which is the only branch that reads
            // `auth.signedOutNotice`.
            return "Use the same account as your iPhone companion."
        case .signingIn: return "Finish in the secure Google sheet."
        case .restoring: return "Checking the saved Keychain session."
        }
    }

    private var detailColor: Color {
        if case .failed = auth.phase { return .red }
        return .secondary
    }
}

/// The one-time "sign in again after the signing migration" explanation, as a
/// value rather than as view code, so its palette, its non-colour cue, and the
/// sentence VoiceOver reads can each be asserted without a running view.
///
/// The row used to paint this copy as raw `.orange` caption text straight onto
/// the Settings card. System orange is tuned to be noticed, not read: against
/// the light card it lands near 2:1, well under WCAG AA for small text, and it
/// moves with whatever material and wallpaper sit behind the window. The notice
/// now borrows the shared `needsYou` badge semantics, which pair a foreground
/// with its own opaque fill, so the ratio is a property of that pair rather
/// than of the desktop behind the glass.
struct AppAccountRecoveryNotice: Equatable {
    /// The row headline this notice explains.
    let title: String
    /// The safe copy saying why the saved session has to be recreated.
    let message: String

    /// The shared contrast-tuned warning tone. Amber, like the `needsYou`
    /// status dot, so "this one wants a decision from you" reads the same way
    /// in Settings as it does on the session rail.
    var tone: KaisolaStatusTone { .needsYou }

    /// The exact packed sRGB pair the strip paints with. Exposed because a
    /// `Color` built from a dynamic `NSColor` does not compare, so a palette
    /// that exists only as `Color` is a palette no contrast gate can defend.
    var palette: KaisolaStatusBadgePalette { tone.palette }

    /// The second, non-colour channel. Strip the hue and the filled triangle
    /// still says warning.
    var systemImage: String { "exclamationmark.triangle.fill" }

    /// One sentence for VoiceOver, led by the shared status word so the
    /// warning survives where the amber and the triangle cannot.
    var accessibilityLabel: String {
        let word = QuietSessionStatus.needsYou.accessibilityWord ?? "needs you"
        return "Kaisola account \(word). \(Self.sentence(title)) \(Self.sentence(message))"
    }

    /// Increase Contrast asks for a harder edge, not a different colour: the
    /// fill already clears AA on its own, so the border is what strengthens.
    func borderOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.85 : 0.24
    }

    func borderWidth(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 1 : KaisolaVisualSystem.hairline
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?…".contains(last) else { return trimmed }
        return trimmed + "."
    }
}

struct AccountAvatarView: View {
    let account: AuthAccount?
    var size: CGFloat

    var body: some View {
        ZStack {
            fallback
            if let url = account?.avatarURL {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipped()
                            .clipShape(Circle())
                            .compositingGroup()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: size, height: size)
                .clipped()
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.6))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.92), Color.purple.opacity(0.76)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Text(account?.initials ?? "K")
                    .font(.system(size: size * 0.40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}

struct GoogleAccountGlyph: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side * 0.39
            let width = side * 0.20
            let arcs: [(Color, Double, Double)] = [
                (Color(red: 0.26, green: 0.52, blue: 0.96), -22, 70),
                (Color(red: 0.20, green: 0.66, blue: 0.33), 70, 160),
                (Color(red: 0.98, green: 0.74, blue: 0.02), 160, 250),
                (Color(red: 0.92, green: 0.26, blue: 0.21), 250, 338),
            ]
            for (color, start, end) in arcs {
                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(start),
                    endAngle: .degrees(end),
                    clockwise: false
                )
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width))
            }
            context.fill(
                Path(CGRect(x: center.x, y: center.y - width / 2, width: radius, height: width)),
                with: .color(Color(red: 0.26, green: 0.52, blue: 0.96))
            )
        }
        .accessibilityHidden(true)
    }
}
