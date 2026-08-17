import SwiftUI

struct AccountSignInFormState: Equatable {
    var code = ""
    var showsTranscript = false

    /// Clears every form-local value and returns the focus state the sheet
    /// should apply before the replacement attempt begins.
    mutating func prepareForRetry() -> Bool {
        code = ""
        showsTranscript = false
        return false
    }
}

enum AccountSignInFooterAction: Equatable {
    case cancel
    case retry
    case done
}

enum AccountSignInFooterPolicy {
    /// `stalled` is the sheet's judgement that a live attempt has gone quiet
    /// for too long. It surfaces Retry without waiting for the CLI to exit,
    /// because a login that hangs never becomes `.failed` on its own.
    static func actions(
        for phase: AccountSignInController.Phase,
        stalled: Bool = false
    ) -> [AccountSignInFooterAction] {
        switch phase {
        case .failed:
            [.cancel, .retry]
        case .succeeded:
            [.done]
        default:
            stalled ? [.cancel, .retry] : [.cancel]
        }
    }
}

/// Signing in to one account, without leaving Settings.
///
/// The previous affordance posted `.kaisolaRunInTerminal`, which opened a
/// terminal in whichever project was in front — so signing in to an account
/// meant a stray session in an unrelated project, and the credential landed
/// wherever that terminal's environment pointed. Michael: "can you make it so
/// the sign in is directly via the settings and not opening another terminal on
/// one of the projects?"
struct AccountSignInSheet: View {
    let profile: UsageAccountProfile
    let dismiss: () -> Void

    @StateObject private var controller = AccountSignInController()
    @State private var form = AccountSignInFormState()
    /// A live attempt has gone quiet past the phase's patience window. Judged
    /// here rather than in the controller because it is presentation: nothing
    /// about the subprocess changes, the sheet just stops pretending progress.
    @State private var stalled = false
    @FocusState private var codeFocused: Bool

    /// How long each phase may sit silent before the sheet says so and offers
    /// Retry. Launching covers the 12-second shell probe plus the spawn; a
    /// browser wait with no URL yet means the CLI has printed nothing usable;
    /// submitting means the CLI took a code and went quiet, which is the one
    /// hang the user cannot diagnose. The phases that are genuinely waiting
    /// on the user — a browser wait with its link, the code prompt — never
    /// count as stalled.
    static func stallPatience(for phase: AccountSignInController.Phase) -> Duration? {
        switch phase {
        case .launching: .seconds(25)
        case .awaitingBrowser(.none): .seconds(20)
        case .submitting: .seconds(20)
        default: nil
        }
    }

    /// The identity the per-phase task keys on. The attempt number matters:
    /// a retry from a stalled `.launching` lands back on `.launching`, which
    /// compares equal — phase alone would keep the stale stall verdict and
    /// never start a fresh patience window for the replacement attempt.
    struct PhaseTaskID: Equatable {
        let attempt: Int
        let phase: AccountSignInController.Phase
    }

    /// How long the success beat stays on screen before the sheet closes
    /// itself. Long enough to read "Signed in", short enough to not need Done.
    static let successDismissDelay: Duration = .seconds(1.2)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sign in to \(profile.label)")
                    .font(.headline)
                Text("\(profile.provider.displayName) · \(profile.directory)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.kaisolaSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            status

            if stalled, !controller.phase.isFinished {
                Label(
                    "Nothing has arrived from the \(AccountSignInController.toolName(for: profile.provider)) CLI in a while. Retry, or check Details for what it said.",
                    systemImage: "clock.badge.questionmark"
                )
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }

            if controller.phase.acceptsCode || controller.phase == .submitting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste the code from the browser")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                    HStack(spacing: 8) {
                        TextField("Authorization code", text: $form.code)
                            .textFieldStyle(.roundedBorder)
                            .focused($codeFocused)
                            .onSubmit { controller.submit(code: form.code) }
                            .accessibilityLabel("Authorization code")
                        Button("Submit") { controller.submit(code: form.code) }
                            .buttonStyle(.borderedProminent)
                            .disabled(form.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || controller.phase == .submitting)
                    }
                }
                .transition(.opacity)
            }

            DisclosureGroup("Details", isExpanded: $form.showsTranscript) {
                ScrollView {
                    Text(controller.transcript.isEmpty ? "Starting…" : controller.transcript)
                        .font(.caption.monospaced())
                        .foregroundStyle(.kaisolaSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
            }
            .font(.caption)

            HStack {
                if let url = controller.phase.url, !controller.phase.isFinished {
                    Button("Open Sign-In Page") { controller.openSignInPage() }
                        .help(url.absoluteString)
                }
                Spacer()
                switch AccountSignInFooterPolicy.actions(for: controller.phase, stalled: stalled) {
                case [.done]:
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case [.cancel, .retry]:
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Retry") {
                        codeFocused = form.prepareForRetry()
                        controller.retry(profile: profile)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Starts a new sign-in attempt without closing Settings")
                default:
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        // One animation clock for every phase swap. The body used to rebuild
        // per phase with no continuity at all — the code field popped in, the
        // status swapped icon and text, the footer changed button count, and
        // the sheet height jumped on each. Michael: "the sign-in is a little
        // chopped."
        .animation(.easeInOut(duration: 0.18), value: controller.phase)
        .animation(.easeInOut(duration: 0.18), value: stalled)
        .onAppear { controller.start(profile: profile) }
        .onChange(of: controller.phase) { _, phase in
            // The code field is the only thing to do once it appears.
            if phase.acceptsCode {
                codeFocused = true
            } else if phase.isFinished || phase == .launching {
                codeFocused = false
            }
        }
        // Restarts on every phase change AND every new attempt, so each phase
        // gets a fresh patience window and success gets its exit beat.
        // Cancellation on identity change is what clears a pending stall
        // verdict.
        .task(id: PhaseTaskID(attempt: controller.attemptCount, phase: controller.phase)) {
            stalled = false
            if controller.phase == .succeeded {
                try? await Task.sleep(for: Self.successDismissDelay)
                if !Task.isCancelled { dismiss() }
                return
            }
            guard let patience = Self.stallPatience(for: controller.phase) else { return }
            try? await Task.sleep(for: patience)
            guard !Task.isCancelled else { return }
            stalled = true
            // The transcript is where the explanation lives; opening it for
            // the user beats telling them it exists.
            form.showsTranscript = true
        }
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .launching:
            progressLabel(
                "Starting \(profile.provider.displayName)…",
                caption: "Locating the CLI through your login shell — a slow shell setup can take a few seconds."
            )
        case .awaitingBrowser:
            label(
                "Finish signing in with your browser. Kaisola is waiting.",
                symbol: "safari",
                tone: .secondary
            )
        case .awaitingCode:
            // The CLI prints this prompt even when the browser can finish the
            // handshake by itself — in which case sign-in completes with no
            // code ever shown. So the copy offers the field without demanding
            // it, rather than leaving the user hunting for a code that the
            // browser already said "all set up" about.
            label(
                "Approve the sign-in in your browser. Paste the code below if it gives you one.",
                symbol: "arrow.down.doc",
                tone: .secondary
            )
        case .submitting:
            progressLabel("Checking the code…")
        case .succeeded:
            label(
                "Signed in. \(profile.label) now has its own credentials, and its usage appears under Usage.",
                symbol: "checkmark.circle.fill",
                tone: .green
            )
        case let .failed(message):
            label(message, symbol: "exclamationmark.triangle.fill", tone: .orange)
        }
    }

    private func label(_ text: String, symbol: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tone)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// A working phase shows a live spinner, not a static hourglass — the
    /// hourglass made a 12-second shell probe indistinguishable from a hang.
    private func progressLabel(_ text: String, caption: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
