import SwiftUI

/// The in-window toast strip: a bottom-center stack of auto-dismissing capsules
/// driven by `ToastCenter.shared`. Layered into `RootShellView` with `.overlay`,
/// the same way the command palette is presented. The stack is click-through
/// everywhere except the capsules themselves — an empty layout frame draws
/// nothing, so it never intercepts hits, and only the capsules opt in — so the
/// workspace underneath keeps taking clicks while a toast is visible. Tap a
/// capsule to dismiss it early.
struct ToastOverlayView: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.toasts) { toast in
                ToastCapsule(toast: toast)
                    .contentShape(Capsule())
                    .onTapGesture { center.dismiss(toast.id) }
                    .allowsHitTesting(true)
            }
        }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: center.toasts)
    }
}

/// One capsule. Icon and tint carry the meaning: neutral info, green success,
/// orange failure. The move+fade transition rides the container's animation.
private struct ToastCapsule: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var symbol: String {
        switch toast.style {
        case .info: "info.circle"
        case .success: "checkmark.seal.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .info: .secondary
        case .success: .green
        case .error: .orange
        }
    }
}
