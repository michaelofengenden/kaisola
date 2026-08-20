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
    var showsCancel = true
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
                    // Same grammar as Cancel across the row: two buttons, one
                    // style. Plain text here read as an inert status label.
                    Button("Back") {
                        screen = .primary
                        focusFirstEnabledChoice()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLaunching)
                }
                Spacer()
                if showsCancel {
                    Button("Cancel", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isLaunching)
                }
            }
            .font(.callout)
        }
        .padding(24)
        // A ceiling, not a fixed size: the content column can legitimately be
        // 220pt with Files and a document open, and a fixed 500 clipped the
        // grid instead of letting it reflow.
        .frame(maxWidth: 500)
        .background {
            // Opaque on purpose: the translucent card read as grey over the
            // workspace glass. Solid controlBackgroundColor is white in light
            // appearance and the matching dark surface in dark.
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.11), lineWidth: KaisolaVisualSystem.hairline)
                }
        }
        .shadow(color: Color.black.opacity(0.06), radius: 16, y: 6)
        .onAppear(perform: focusFirstEnabledChoice)
        .onExitCommand {
            // Escape backs out one level before it cancels anything: on an
            // agent sub-screen the expected exit is "back", and the
            // empty-workspace instance (showsCancel == false) previously had
            // no keyboard exit from that screen at all.
            if screen != .primary {
                screen = .primary
                focusFirstEnabledChoice()
            } else if showsCancel, !isLaunching {
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
        // Adaptive so a narrow content column reflows to one column instead
        // of clipping the second.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], spacing: 10) {
            ForEach(primaryOptions) { option in
                Button {
                    select(option.choice)
                } label: {
                    choiceLabel(
                        title: option.title,
                        detail: option.disabledReason ?? option.detail,
                        symbol: option.symbol,
                        isEnabled: option.isEnabled && !isLaunching
                    )
                }
                .buttonStyle(NewSessionChoiceButtonStyle(
                    isFocused: focusedPrimaryChoice == option.choice
                ))
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
                        // The same disabled ink as the primary cards: without
                        // it a row disabled mid-launch (or with control lost)
                        // renders pixel-identical to a clickable one.
                        Image(systemName: agent.symbol.isEmpty ? symbol : agent.symbol)
                            .foregroundStyle(
                                isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.kaisolaDisabled)
                            )
                            .frame(width: 20)
                        Text(agent.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(
                                isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.kaisolaDisabled)
                            )
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.kaisolaTertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NewSessionChoiceButtonStyle(
                    isFocused: focusedAgentID == agent.id
                ))
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

    private func choiceLabel(
        title: String,
        detail: String,
        symbol: String,
        isEnabled: Bool = true
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.kaisolaDisabled))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                // A disabled card dims its own title, never the explanation:
                // the detail line IS the reason the card is disabled, and a
                // whole-card opacity used to push it below the readable floor.
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.kaisolaDisabled))
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

struct NewSessionChoiceButtonStyle: ButtonStyle {
    /// Fill/stroke coverage per interaction state. Named so the ladder is
    /// checkable at a glance: rest < hover ≤ focus < press, and a disabled
    /// card declines the hover lift entirely rather than dimming it.
    static let restFill = 0.035
    static let hoverFill = 0.065
    static let pressFill = 0.09
    static let restStroke = 0.11
    static let hoverStroke = 0.18

    /// Keyboard focus, driven by the chooser's own `@FocusState`. The view
    /// focuses its first enabled card programmatically and Tab moves between
    /// them, so without a visible rung the cursor was invisible.
    var isFocused = false

    func makeBody(configuration: Configuration) -> some View {
        StyledCard(configuration: configuration, isFocused: isFocused)
    }

    private struct StyledCard: View {
        let configuration: Configuration
        let isFocused: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let hovering = hovered && isEnabled
            let focused = isFocused && isEnabled
            let fill = configuration.isPressed
                ? NewSessionChoiceButtonStyle.pressFill
                : (hovering || focused
                    ? NewSessionChoiceButtonStyle.hoverFill
                    : NewSessionChoiceButtonStyle.restFill)
            configuration.label
                .background {
                    RoundedRectangle(
                        cornerRadius: KaisolaVisualSystem.insetRadius,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(fill))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: KaisolaVisualSystem.insetRadius,
                            style: .continuous
                        )
                        .stroke(
                            Color.primary.opacity(
                                hovering
                                    ? NewSessionChoiceButtonStyle.hoverStroke
                                    : NewSessionChoiceButtonStyle.restStroke
                            ),
                            lineWidth: KaisolaVisualSystem.hairline
                        )
                    }
                    .overlay {
                        if focused {
                            RoundedRectangle(
                                cornerRadius: KaisolaVisualSystem.insetRadius,
                                style: .continuous
                            )
                            .stroke(
                                Color.accentColor,
                                lineWidth: KaisolaVisualSystem.focusStroke
                            )
                        }
                    }
                }
                // The press dip is the only whole-card dim left: a disabled
                // card keeps its ink readable and states its reason in the
                // detail line instead (see `choiceLabel`).
                .opacity(configuration.isPressed ? 0.88 : 1)
                .animation(
                    .easeOut(duration: KaisolaVisualSystem.hoverDuration),
                    value: hovering
                )
                .onHover { hovered = $0 }
        }
    }
}
