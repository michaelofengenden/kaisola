import SwiftUI

/// First-run welcome. A one-time, three-page pager that frames the product
/// model — durable agents, chats/Mesh/guardrails, and native workspaces —
/// before the user lands in an empty workspace. Shown once, gated by
/// ``OnboardingState`` so it never re-appears after it's been seen.
///
/// The caller owns presentation and persistence: it presents this in a sheet
/// and, on `dismiss`, records ``OnboardingState/markSeen(defaults:)`` and drops
/// the sheet. Every exit path here — Continue past the last page, or Escape —
/// funnels through `dismiss`, so "seen" is recorded however the user leaves.
struct OnboardingView: View {
    /// Close the welcome. The caller marks onboarding seen and drops the sheet.
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var index = 0
    /// Slide direction for the page transition (forward on Continue, back on
    /// Back) so the motion reads as paging rather than a crossfade.
    @State private var forward = true

    /// `@State private` would make the synthesized memberwise initializer
    /// private, so an explicit initializer keeps `OnboardingView(dismiss:)`
    /// callable from the shell that presents it.
    init(dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
    }

    private var pages: [OnboardingPage] { OnboardingPage.all }
    private var isLastPage: Bool { index == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            pager
            Divider()
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Escape leaves onboarding (recorded as seen) from any page. Mirrors
        // the shell's hidden-shortcut pattern so it never steals focus.
        .background(
            Button(action: dismiss) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Kaisola")
    }

    // MARK: - Pages

    private var pager: some View {
        ZStack {
            pageView(pages[index])
                .id(index)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: page.symbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text(page.title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(page.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.features) { feature in
                    featureRow(feature)
                }
            }
            .frame(maxWidth: 430, alignment: .leading)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
    }

    private func featureRow(_ feature: OnboardingFeature) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            pageDots
            Spacer(minLength: 12)
            if index > 0 {
                Button("Back") { advance(-1) }
                    .controlSize(.large)
            }
            Button(isLastPage ? "Start using Kaisola" : "Continue") {
                if isLastPage { dismiss() } else { advance(1) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { page in
                Circle()
                    .fill(page == index ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: page == index ? 8 : 7, height: page == index ? 8 : 7)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: KaisolaVisualSystem.stateDuration),
                        value: index
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1) of \(pages.count)")
    }

    private func advance(_ delta: Int) {
        let target = min(max(index + delta, 0), pages.count - 1)
        guard target != index else { return }
        forward = target > index
        withAnimation(.easeInOut(duration: KaisolaVisualSystem.layoutDuration)) {
            index = target
        }
    }
}

// MARK: - Page model

/// One welcome page: a hero symbol + headline + a short list of supporting
/// features. Kept file-private so nothing outside onboarding depends on it.
private struct OnboardingPage: Identifiable {
    let id: Int
    let symbol: String
    let title: String
    let subtitle: String
    let features: [OnboardingFeature]

    static let all: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            symbol: "terminal.fill",
            title: "Your agents, native",
            subtitle: "Kaisola keeps terminals and agent CLIs running in the background — even while the app quits or updates.",
            features: [
                OnboardingFeature(
                    symbol: "terminal.fill",
                    title: "Owned terminals",
                    detail: "Claude, Codex, and other CLIs launch as real shells you drive."
                ),
                OnboardingFeature(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Survives updates",
                    detail: "Quit or update Kaisola and any in-flight run keeps going."
                ),
                OnboardingFeature(
                    symbol: "clock.arrow.circlepath",
                    title: "Reattaches cleanly",
                    detail: "Relaunch reconnects with continuous scrollback."
                ),
            ]
        ),
        OnboardingPage(
            id: 1,
            symbol: "circle.hexagongrid.fill",
            title: "Chats, Mesh, and guardrails",
            subtitle: "Chat with inline diffs and permissions, fan out with Mesh, and keep sensitive files guarded.",
            features: [
                OnboardingFeature(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: "Chats with diffs",
                    detail: "Inline red/green diffs with a permission prompt for each action."
                ),
                OnboardingFeature(
                    symbol: "circle.hexagongrid.fill",
                    title: "Mesh fan-out",
                    detail: "Send one prompt to every agent, each in its own isolated worktree."
                ),
                OnboardingFeature(
                    symbol: "shield.lefthalf.filled",
                    title: "Sensitive files always ask",
                    detail: "Secrets and keys prompt every time — never auto-approved."
                ),
            ]
        ),
        OnboardingPage(
            id: 2,
            symbol: "sparkles.rectangle.stack",
            title: "Native from end to end",
            subtitle: "Projects, durable terminals, and restored work now stay entirely inside Kaisola.",
            features: [
                OnboardingFeature(
                    symbol: "checkmark.shield",
                    title: "One workspace",
                    detail: "No background scan or migration from unrelated applications."
                ),
                OnboardingFeature(
                    symbol: "externaldrive.badge.checkmark",
                    title: "Durable sessions",
                    detail: "Native terminals survive relaunches and Kaisola updates."
                ),
                OnboardingFeature(
                    symbol: "server.rack",
                    title: "Native service",
                    detail: "Kaisola starts and reconnects its own terminal service automatically."
                ),
            ]
        ),
    ]
}

private struct OnboardingFeature: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String
}

// MARK: - Persisted first-run flag

/// The one-time gate for ``OnboardingView``. Versioned so a future redesign can
/// re-introduce the welcome under a new key (`onboardingSeen.v2`, …) without
/// clearing or colliding with the v1 record. Stored in the preview's own
/// UserDefaults suite, so it never touches any Electron profile.
enum OnboardingState {
    /// Bump this key (v2, v3, …) to re-show a revised onboarding to everyone.
    private static let seenKey = "onboardingSeen.v1"

    /// True until the current onboarding version has been marked seen. Unset
    /// defaults read as `false`, so a fresh install always shows it once.
    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    /// Record that this onboarding version has been seen. Idempotent.
    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}
