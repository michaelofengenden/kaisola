import AppKit
import SwiftUI

/// The ACP composer: one rounded card holding the message field and a row of
/// chips, in the grammar Claude Code and Codex both settled on.
///
/// The card is the whole control. Nothing inside it gets its own box — the
/// field has no second background, and the chips are naked text that only
/// acquire a surface under the pointer — so the eye reads one object with a
/// row of settings along its bottom edge rather than a toolbar bolted to a
/// text box. Hairline dividers, not gaps, separate the chips: they are peers
/// on one rail, and a gap would have implied grouping that does not exist.
struct AcpComposerCard: View {
    @ObservedObject var conversation: AcpConversation
    @Binding var draft: String
    @FocusState.Binding var focused: Bool
    /// True while the conversation has produced nothing, which is the only
    /// thing that changes about the card: its placeholder.
    var isNewConversation = false
    let send: () -> Void
    var onKeyboardFocus: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var modelPickerPresented = false
    @State private var favorites: Set<String> = []

    private let favoritesStore = AcpModelFavoritesStore()

    private var agentName: String { AcpAgentIdentity.agentName(fromChatTitle: conversation.title) }
    private var identity: QuietIdentity { AcpAgentIdentity.identity(fromChatTitle: conversation.title) }

    private var currentModelName: String? {
        guard let id = conversation.currentModelID ?? conversation.models.first?.id else { return nil }
        return conversation.models.first { $0.id == id }?.name
    }

    private var sendAction: AcpComposerAction {
        AcpComposerSendPolicy.action(isRunning: conversation.isRunning)
    }

    private var sendEnabled: Bool {
        AcpComposerSendPolicy.isEnabled(
            draft: draft,
            isConnected: conversation.isConnected,
            isRunning: conversation.isRunning,
            hasAttachments: !conversation.pendingAttachments.isEmpty
        )
    }

    private var placeholder: String {
        if conversation.isRunning { return "Queue a follow-up…" }
        return isNewConversation
            ? "Describe what to build, or attach images"
            : "Ask for follow-up changes or attach images"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...8)
                .focused($focused)
                .onChange(of: focused) { _, isFocused in
                    if isFocused { onKeyboardFocus?() }
                }
                .onSubmit(send)
                .padding(.horizontal, 13)
                .padding(.top, 11)
                .padding(.bottom, 9)
                .accessibilityLabel("Message the agent")
                .accessibilityIdentifier("acp.composer.field")

            controlRow
                .padding(.horizontal, 7)
                .padding(.bottom, 7)
        }
        .background(cardFill, in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.panelRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: KaisolaVisualSystem.focusStroke)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.07), radius: 9, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("acp.composer")
        .task(id: agentName) {
            favorites = favoritesStore.favorites(agentKey: agentName)
        }
    }

    /// Opaque under Reduce Transparency, and opaque anyway in practice: the
    /// card sits over a transcript, and a translucent composer would let agent
    /// output scroll behind the text the user is writing.
    private var cardFill: Color {
        reduceTransparency
            ? Color(nsColor: .textBackgroundColor)
            : Color(light: 0xFFFFFF, dark: 0x1D1D1F)
    }

    // MARK: - Control row

    private var controlRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    attachmentMenu
                    chipDivider
                    modelChip
                    if let metrics = AcpComposerMetrics.chipLabel(
                        option: AcpComposerMetrics.primaryOption(conversation.configOptions),
                        usage: conversation.usage
                    ) {
                        chipDivider
                        metricsChip(metrics)
                    }
                    if let posture = AcpPermissionPostureMap.current(
                        modes: conversation.modes,
                        currentID: conversation.currentModeID
                    ) {
                        chipDivider
                        permissionChip(posture)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            trailingControls
                .fixedSize()
        }
    }

    private var chipDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: KaisolaVisualSystem.focusStroke, height: 15)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    // MARK: - Attachment menu

    private var attachmentMenu: some View {
        Menu {
            Button(action: openAttachmentPanel) {
                Label("Add files or photos", systemImage: "paperclip")
            }
            .keyboardShortcut("u", modifiers: .command)

            // "Add folder" and "Import GitHub issue" are deliberately absent:
            // `AcpAttachmentClassifier` rejects directories, and nothing in the
            // app turns an issue into a prompt. A greyed-out row would only
            // advertise a capability that does not exist.
            if !conversation.commands.isEmpty {
                Divider()
                Button(action: beginSlashCommand) {
                    Label("Slash commands", systemImage: "text.badge.plus")
                }
            }
        } label: {
            Group {
                if conversation.preparingAttachmentCount > 0 {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!conversation.isConnected)
        .help("Attach files or photos, or insert a slash command")
        .accessibilityLabel("Add attachments")
        .accessibilityIdentifier("acp.composer.attach")
    }

    private func beginSlashCommand() {
        if !draft.hasPrefix("/") { draft = "/" + draft }
        focused = true
    }

    /// Open Finder without entering a nested modal run loop. The picker starts
    /// in this chat's workspace, and selected files are materialized/read on a
    /// detached task so adding an iCloud or large-on-disk item never blocks
    /// chat rendering or terminal input.
    private func openAttachmentPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = conversation.workspaceURL
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Attach"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls { conversation.prepareAttachment(fileURL: url) }
            }
        }
    }

    // MARK: - Model chip

    private var modelChip: some View {
        Button {
            modelPickerPresented = true
        } label: {
            AcpComposerChipLabel(
                label: AcpAgentIdentity.chipLabel(agentName: agentName, modelName: currentModelName)
            ) {
                QuietIdentityMarkView(identity: identity, size: 13)
            }
        }
        .buttonStyle(AcpComposerChipButtonStyle())
        .help("Choose the model this chat runs on")
        .accessibilityLabel("Model: \(AcpAgentIdentity.chipLabel(agentName: agentName, modelName: currentModelName))")
        .accessibilityIdentifier("acp.composer.model")
        .popover(isPresented: $modelPickerPresented, arrowEdge: .top) {
            AcpModelPickerView(
                identity: identity,
                agentName: agentName,
                models: conversation.models,
                currentID: conversation.currentModelID,
                favorites: favorites,
                select: { id in
                    conversation.selectModel(id)
                    modelPickerPresented = false
                },
                toggleFavorite: { id in
                    favorites = favoritesStore.toggle(id, agentKey: agentName)
                },
                dismiss: { modelPickerPresented = false }
            )
        }
    }

    // MARK: - Effort · context chip

    private func metricsChip(_ label: String) -> some View {
        Menu {
            ForEach(conversation.configOptions) { option in
                Picker(option.name, selection: Binding(
                    get: { option.currentValue ?? option.choices.first?.value ?? "" },
                    set: { conversation.selectConfigOption(option.id, value: $0) }
                )) {
                    ForEach(option.choices) { choice in
                        Text(choice.name).tag(choice.value)
                    }
                }
                .pickerStyle(.inline)
            }
            if let usage = conversation.usage, usage.max > 0 {
                Divider()
                Text("Context used: \(AcpComposerMetrics.compactTokens(usage.used)) of \(AcpComposerMetrics.compactTokens(usage.max))")
            }
        } label: {
            AcpComposerChipLabel(label: label) { EmptyView() }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Agent effort and context window")
        .accessibilityLabel("Agent effort and context window: \(label)")
        .accessibilityIdentifier("acp.composer.effort")
    }

    // MARK: - Permission chip

    private func permissionChip(_ posture: AcpPermissionPosture) -> some View {
        Menu {
            Picker("Permission", selection: Binding(
                get: { posture.id },
                set: { conversation.selectMode($0) }
            )) {
                ForEach(AcpPermissionPostureMap.postures(conversation.modes)) { option in
                    Label(option.label, systemImage: option.symbol).tag(option.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            AcpComposerChipLabel(label: posture.label, tint: postureTint(posture)) {
                Image(systemName: posture.symbol).font(.system(size: 10, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How this agent asks before acting")
        .accessibilityLabel("Permission: \(posture.label)")
        .accessibilityIdentifier("acp.composer.permission")
    }

    /// Only the top rung is coloured. Warning amber on a mode that merely
    /// accepts edits would spend the one colour the composer has on the wrong
    /// state, and then have nothing left to say for "Full access".
    private func postureTint(_ posture: AcpPermissionPosture) -> Color? {
        posture.isPermissive ? KaisolaStatusTone.needsYou.foregroundColor : nil
    }

    // MARK: - Send / stop

    private var trailingControls: some View {
        HStack(spacing: 6) {
            if conversation.isRunning {
                Button(action: conversation.cancel) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 26, height: 26)
                        .background(Color.secondary.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop the current turn")
                .accessibilityLabel("Stop the current turn")
                .accessibilityIdentifier("acp.composer.stop")
            }
            Button(action: send) {
                Image(systemName: sendAction == .queue ? "plus" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white.opacity(sendEnabled ? 1 : 0.7))
                    .frame(width: 26, height: 26)
                    .background(
                        sendEnabled ? Color.accentColor : Color.secondary.opacity(0.32),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!sendEnabled)
            .help(sendAction == .queue ? "Queue this as a follow-up" : "Send")
            .accessibilityLabel(sendAction == .queue ? "Queue follow-up" : "Send message")
            .accessibilityIdentifier("acp.composer.send")
        }
    }
}

/// The face of a composer chip: an optional mark, the value, and the
/// disclosure caret. Naked by default; `AcpComposerChipButtonStyle` and the
/// borderless menu style supply the pressed/hover surface.
struct AcpComposerChipLabel<Leading: View>: View {
    let label: String
    var tint: Color?
    @ViewBuilder var leading: () -> Leading

    init(label: String, tint: Color? = nil, @ViewBuilder leading: @escaping () -> Leading) {
        self.label = label
        self.tint = tint
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: 5) {
            leading()
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(tint ?? .primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .contentShape(RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius))
    }
}

/// A chip's only decoration: a faint surface on hover, matching what the
/// borderless menu style does for the chips that open menus.
struct AcpComposerChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // The hover state lives in a real `View`, not in the style struct.
        // SwiftUI does not allocate storage for `@State` declared on a
        // `ButtonStyle`, so a chip written that way would never light up.
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background(
                    (configuration.isPressed || hovering)
                        ? AnyShapeStyle(.quaternary.opacity(0.6))
                        : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius)
                )
                .onHover { inside in
                    guard !reduceMotion else {
                        hovering = inside
                        return
                    }
                    withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) { hovering = inside }
                }
        }
    }
}

/// The heading a chat wears before it has said anything: "What should we build
/// in <project>?", with the project name dotted-underlined so it reads as the
/// one variable in the sentence rather than as a link.
struct AcpEmptyStateHeadline: View {
    let heading: AcpEmptyState.Heading

    var body: some View {
        Text(attributed)
            .font(.system(size: 28, weight: .regular))
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary)
            .padding(.horizontal, 24)
            .accessibilityLabel(heading.spoken)
            .accessibilityIdentifier("acp.emptyState.heading")
    }

    private var attributed: AttributedString {
        var result = AttributedString(heading.lead)
        if !heading.project.isEmpty {
            var project = AttributedString(heading.project)
            project.underlineStyle = Text.LineStyle(pattern: .dot, color: nil)
            result += project
        }
        result += AttributedString(heading.tail)
        return result
    }
}

private extension Color {
    /// Appearance-adaptive color from packed RGB hex values. A local copy, as
    /// in `QuietIdentityMark` and `QuietSessionStatus`: each stays private to
    /// its file so the pattern is visible where it is used.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
