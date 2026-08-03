import SwiftUI

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
    @State private var code = ""
    @State private var showsTranscript = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sign in to \(profile.label)")
                    .font(.headline)
                Text("\(profile.provider.displayName) · \(profile.directory)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            status

            if controller.phase.acceptsCode || controller.phase == .submitting {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paste the code from the browser")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Authorization code", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .focused($codeFocused)
                            .onSubmit { controller.submit(code: code) }
                            .accessibilityLabel("Authorization code")
                        Button("Submit") { controller.submit(code: code) }
                            .buttonStyle(.borderedProminent)
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || controller.phase == .submitting)
                    }
                }
            }

            DisclosureGroup("Details", isExpanded: $showsTranscript) {
                ScrollView {
                    Text(controller.transcript.isEmpty ? "Starting…" : controller.transcript)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
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
                if controller.phase.isFinished {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
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
        .onAppear { controller.start(profile: profile) }
        .onChange(of: controller.phase) { _, phase in
            // The code field is the only thing to do once it appears.
            if phase.acceptsCode { codeFocused = true }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .launching:
            label("Starting \(profile.provider.displayName)…", symbol: "hourglass", tone: .secondary)
        case .awaitingBrowser:
            label(
                "Finish signing in with your browser. Kaisola is waiting.",
                symbol: "safari",
                tone: .secondary
            )
        case .awaitingCode:
            label(
                "Approve the sign-in, then paste the code it gives you.",
                symbol: "arrow.down.doc",
                tone: .secondary
            )
        case .submitting:
            label("Checking the code…", symbol: "hourglass", tone: .secondary)
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
}
