import SwiftUI

/// Native Kaisola account UI backed by the same Firebase REST and Keychain
/// implementation as the iPhone companion. Only the redacted profile reaches
/// SwiftUI; refresh and ID tokens remain inside `FirebaseAuthBackend`.
struct AppAccountSettingsView: View {
    @ObservedObject var auth: AuthModel

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatarView(account: auth.account, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
            }

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

    private var googleSignInButton: some View {
        Button {
            Task { await auth.signInWithGoogle() }
        } label: {
            HStack(spacing: 7) {
                GoogleAccountGlyph().frame(width: 14, height: 14)
                Text("Sign in with Google")
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
            return auth.signedOutNotice
                ?? "Use the same account as your iPhone companion."
        case .signingIn: return "Finish in the secure Google sheet."
        case .restoring: return "Checking the saved Keychain session."
        }
    }

    private var detailColor: Color {
        if case .failed = auth.phase { return .red }
        if case .signedOut = auth.phase, auth.signedOutNotice != nil { return .orange }
        return .secondary
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
