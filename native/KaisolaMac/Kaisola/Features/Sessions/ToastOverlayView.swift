import AppKit
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.toasts) { toast in
                Button {
                    center.dismiss(toast.id)
                } label: {
                    ToastCapsule(toast: toast)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(toast.message)
                .accessibilityHint("Dismiss notification")
                .transition(reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(true)
            }
        }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(
            reduceMotion
                ? .easeOut(duration: KaisolaVisualSystem.stateDuration)
                : .spring(response: 0.34, dampingFraction: 0.85),
            value: center.toasts
        )
        .onAppear { announceNewToasts(center.toasts) }
        .onChange(of: center.toasts) { _, toasts in announceNewToasts(toasts) }
    }

    private func announceNewToasts(_ toasts: [ToastCenter.Toast]) {
        toasts.forEach(ToastAccessibilityAnnouncements.postIfNeeded)
    }
}

/// `ToastCenter` is app-wide while every window renders its own overlay. Keep
/// announcement de-duplication app-wide too, or VoiceOver would speak the same
/// transient result once per open window.
@MainActor
private enum ToastAccessibilityAnnouncements {
    private static let retentionLimit = 64
    private static var announcedIDs: Set<UUID> = []
    private static var announcementOrder: [UUID] = []

    static func postIfNeeded(_ toast: ToastCenter.Toast) {
        guard announcedIDs.insert(toast.id).inserted else { return }
        announcementOrder.append(toast.id)
        if announcementOrder.count > retentionLimit {
            let expiredCount = announcementOrder.count - retentionLimit
            let expired = Array(announcementOrder.prefix(expiredCount))
            announcementOrder.removeFirst(expiredCount)
            announcedIDs.subtract(expired)
        }

        let priority: NSAccessibilityPriorityLevel = switch toast.style {
        case .error: .high
        case .info, .success: .medium
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: toast.message,
                .priority: priority.rawValue,
            ]
        )
    }
}

/// One capsule. Icon and tint carry the meaning: neutral info, green success,
/// orange failure. The parent chooses a motion-safe transition.
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
