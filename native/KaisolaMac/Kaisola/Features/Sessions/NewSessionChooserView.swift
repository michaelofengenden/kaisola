import SwiftUI

enum NewSessionPrimaryChoice: String, Equatable, Hashable, Sendable {
    case terminal
    case agentTerminalCategory
    case chatCategory
    case mesh
}

struct NewSessionPrimaryOption: Identifiable, Equatable, Sendable {
    var id: NewSessionPrimaryChoice { choice }
    let choice: NewSessionPrimaryChoice
    let title: String
    let detail: String
    let symbol: String
    let isEnabled: Bool
    let disabledReason: String?
}

enum NewSessionChooserPresentation {
    static let terminalUnavailableReason = "Saved terminals are view-only right now."
    static let launchFailureMessage =
        "Session did not start. Check the terminal connection or Run On choice, then try again."

    static func terminalRowsEnabled(
        terminalControlAvailable: Bool,
        isLaunching: Bool
    ) -> Bool {
        terminalControlAvailable && !isLaunching
    }

    static func primaryOptions(
        catalog: NewSessionChoiceCatalog,
        terminalControlAvailable: Bool
    ) -> [NewSessionPrimaryOption] {
        var options = [
            NewSessionPrimaryOption(
                choice: .terminal,
                title: "Terminal",
                detail: "Open a plain shell in this project.",
                symbol: "terminal",
                isEnabled: terminalControlAvailable,
                disabledReason: terminalControlAvailable ? nil : terminalUnavailableReason
            ),
        ]
        if !catalog.terminalAgents.isEmpty {
            options.append(
                NewSessionPrimaryOption(
                    choice: .agentTerminalCategory,
                    title: "Agent Terminal",
                    detail: "Start an agent CLI in its own terminal.",
                    symbol: "chevron.left.forwardslash.chevron.right",
                    isEnabled: terminalControlAvailable,
                    disabledReason: terminalControlAvailable ? nil : terminalUnavailableReason
                )
            )
        }
        if !catalog.chatAgents.isEmpty {
            options.append(
                NewSessionPrimaryOption(
                    choice: .chatCategory,
                    title: "Chat",
                    detail: "Work with an agent in a native conversation.",
                    symbol: "bubble.left.and.text.bubble.right",
                    isEnabled: true,
                    disabledReason: nil
                )
            )
        }
        options.append(
            NewSessionPrimaryOption(
                choice: .mesh,
                title: "Mesh",
                detail: "Open an all-agent collaborative workspace.",
                symbol: "circle.hexagongrid.fill",
                isEnabled: true,
                disabledReason: nil
            )
        )
        return options
    }
}

/// A temporary session tab becomes a real surface only after one of these
/// choices is made. Until then this view owns presentation only and starts no
/// process or broker work.
struct NewSessionChooserView: View {
    let projectName: String
    let catalog: NewSessionChoiceCatalog
    let terminalControlAvailable: Bool
    let isLaunching: Bool
    let launchFailed: Bool
    let choose: (NewSessionChoice) -> Void
    let cancel: () -> Void

    private enum Screen: Equatable {
        case primary
        case agentTerminal
        case chat
    }

    @State private var screen: Screen = .primary
    @FocusState private var focusedPrimaryChoice: NewSessionPrimaryChoice?
    @FocusState private var focusedAgentID: String?

    private var primaryOptions: [NewSessionPrimaryOption] {
        NewSessionChooserPresentation.primaryOptions(
            catalog: catalog,
            terminalControlAvailable: terminalControlAvailable
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start a session")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Choose what this tab should become in \(projectName).")
                    .font(.callout)
                    .foregroundStyle(.kaisolaSecondary)
            }

            Group {
                switch screen {
                case .primary:
                    primaryChoices
                case .agentTerminal:
                    agentChoices(
                        title: "Agent Terminal",
                        agents: catalog.terminalAgents,
                        symbol: "terminal",
                        isEnabled: NewSessionChooserPresentation.terminalRowsEnabled(
                            terminalControlAvailable: terminalControlAvailable,
                            isLaunching: isLaunching
                        ),
                        choice: NewSessionChoice.agentTerminal
                    )
                case .chat:
                    agentChoices(
                        title: "Chat",
                        agents: catalog.chatAgents,
                        symbol: "bubble.left.and.text.bubble.right",
                        isEnabled: !isLaunching,
                        choice: NewSessionChoice.chat
                    )
                }
            }

            HStack {
                if isLaunching {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting session…")
                        .foregroundStyle(.kaisolaSecondary)
                } else if launchFailed {
                    Label {
                        Text(NewSessionChooserPresentation.launchFailureMessage)
                            .foregroundStyle(.kaisolaPrimary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                        .accessibilityIdentifier("new-session-launch-failed")
                }
                if screen != .primary {
                    Button("Back") {
                        screen = .primary
                        focusFirstEnabledChoice()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.kaisolaSecondary)
                    .disabled(isLaunching)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isLaunching)
            }
            .font(.callout)
        }
        .padding(24)
        .frame(width: 500)
        .background {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.76))
                .overlay {
                    RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.11), lineWidth: KaisolaVisualSystem.hairline)
                }
        }
        .shadow(color: Color.black.opacity(0.06), radius: 16, y: 6)
        .onAppear(perform: focusFirstEnabledChoice)
        .onExitCommand {
            if !isLaunching {
                cancel()
            }
        }
        .onChange(of: terminalControlAvailable) { _, available in
            guard available, screen == .agentTerminal else { return }
            focusFirstAgent(in: catalog.terminalAgents)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Start a session in \(projectName)")
    }

    private var primaryChoices: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(primaryOptions) { option in
                Button {
                    select(option.choice)
                } label: {
                    choiceLabel(
                        title: option.title,
                        detail: option.disabledReason ?? option.detail,
                        symbol: option.symbol
                    )
                }
                .buttonStyle(NewSessionChoiceButtonStyle())
                .disabled(!option.isEnabled || isLaunching)
                .focusable()
                .focused($focusedPrimaryChoice, equals: option.choice)
                .help(option.disabledReason ?? option.detail)
                .accessibilityLabel(option.title)
                .accessibilityHint(option.disabledReason ?? option.detail)
            }
        }
    }

    private func agentChoices(
        title: String,
        agents: [NewSessionAgentOption],
        symbol: String,
        isEnabled: Bool,
        choice: @escaping (String) -> NewSessionChoice
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose an agent for \(title)")
                .font(.headline)
            ForEach(agents) { agent in
                Button {
                    choose(choice(agent.id))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: agent.symbol.isEmpty ? symbol : agent.symbol)
                            .frame(width: 20)
                        Text(agent.name)
                            .font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.kaisolaTertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NewSessionChoiceButtonStyle())
                .disabled(!isEnabled)
                .focusable()
                .focused($focusedAgentID, equals: agent.id)
                .help(isEnabled ? "Start \(agent.name)" : NewSessionChooserPresentation.terminalUnavailableReason)
                .accessibilityLabel("\(title) with \(agent.name)")
                .accessibilityHint(
                    isEnabled
                        ? "Starts \(title.lowercased()) with \(agent.name)"
                        : NewSessionChooserPresentation.terminalUnavailableReason
                )
            }
        }
    }

    private func choiceLabel(title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private func select(_ choice: NewSessionPrimaryChoice) {
        switch choice {
        case .terminal:
            choose(.terminal)
        case .agentTerminalCategory:
            screen = .agentTerminal
            focusFirstAgent(in: catalog.terminalAgents)
        case .chatCategory:
            screen = .chat
            focusFirstAgent(in: catalog.chatAgents)
        case .mesh:
            choose(.mesh)
        }
    }

    private func focusFirstEnabledChoice() {
        DispatchQueue.main.async {
            focusedPrimaryChoice = primaryOptions.first(where: \.isEnabled)?.choice
        }
    }

    private func focusFirstAgent(in agents: [NewSessionAgentOption]) {
        DispatchQueue.main.async {
            focusedAgentID = agents.first?.id
        }
    }
}

private struct NewSessionChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.075 : 0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: KaisolaVisualSystem.insetRadius, style: .continuous)
                            .stroke(Color.primary.opacity(0.11), lineWidth: KaisolaVisualSystem.hairline)
                    }
            }
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}
