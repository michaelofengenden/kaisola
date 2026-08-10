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
    @FocusState.Binding var attachmentFocused: Bool
    var attachmentAccessibilityFocused: AccessibilityFocusState<Bool>.Binding
    /// True while the conversation has produced nothing, which is the only
    /// thing that changes about the card: its placeholder.
    var isNewConversation = false
    let send: () -> Void
    var onKeyboardFocus: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var menuPresented = false
    @State private var attachmentMenuPresented = false
    @State private var menuQuery = ""
    /// Bumped on every open so the menu's own `@State` — which row is armed,
    /// where the highlight sits, whether Advanced is expanded — starts clean.
    /// SwiftUI keeps popover content alive between presentations, so without a
    /// fresh identity the menu reopens mid-drilldown on last session's row.
    @State private var menuGeneration = 0
    @State private var favorites: Set<String> = []

    private let favoritesStore = AcpModelFavoritesStore()

    private var agentName: String { AcpAgentIdentity.agentName(fromChatTitle: conversation.title) }
    private var identity: QuietIdentity { AcpAgentIdentity.identity(fromChatTitle: conversation.title) }

    /// Everything the adapter declared, with each setting stated once. Every
    /// model/option read below goes through this rather than the conversation's
    /// raw arrays, so the pill and the menu cannot disagree.
    private var surface: AcpComposerSurface {
        AcpComposerSurface.reconciled(
            models: conversation.models,
            currentModelID: conversation.currentModelID,
            modes: conversation.modes,
            configOptions: conversation.configOptions
        )
    }

    private var currentModelName: String? {
        AcpComposerMenu.currentModel(surface)?.name
    }

    /// The adapter option worth naming on the pill's face.
    private var primaryOption: AcpConfigOption? {
        AcpComposerMetrics.primaryOption(surface.options)
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

    /// The reference's arrangement: what the agent is *allowed* to do sits on
    /// the left beside the paperclip, because it is the answer that has a wrong
    /// value; what it will be *spent on* sits on the right, next to send.
    private var controlRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                attachmentMenu
                if let posture = AcpPermissionPostureMap.current(
                    modes: conversation.modes,
                    currentID: conversation.currentModeID
                ) {
                    chipDivider
                    permissionChip(posture)
                }
            }
            .fixedSize()

            Spacer(minLength: 8)

            settingsPill
                .layoutPriority(1)
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
        Button {
            attachmentMenuPresented = true
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
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!conversation.isConnected)
        .help("Attach files or photos, or insert a slash command")
        .accessibilityLabel("Add attachments")
        .accessibilityIdentifier("acp.composer.attach")
        .focusable()
        .focused($attachmentFocused)
        .accessibilityFocused(attachmentAccessibilityFocused)
        .background {
            // Popover content is not mounted while it is closed, so a shortcut
            // declared on the row inside it disappears from AppKit's command
            // routing. Keep one zero-layout key-equivalent owner beside the
            // always-mounted trigger instead. Focus scopes it to the composer
            // the user is actually operating; the AppKit bridge adds the key-
            // window gate so another project window cannot answer the press.
            AcpAttachmentCommandKeyEquivalent(
                isEnabled: conversation.isConnected
                    && (focused || attachmentFocused || attachmentMenuPresented),
                panelPresenter: {
                    attachmentMenuPresented = false
                    openAttachmentPanel()
                }
            )
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
        .popover(isPresented: $attachmentMenuPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    attachmentMenuPresented = false
                    openAttachmentPanel()
                } label: {
                    Label("Add files or photos", systemImage: "paperclip")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }

                // "Add folder" and "Import GitHub issue" are deliberately absent:
                // `AcpAttachmentClassifier` rejects directories, and nothing in the
                // app turns an issue into a prompt. A greyed-out row would only
                // advertise a capability that does not exist.
                if !conversation.commands.isEmpty {
                    Divider()
                    Button {
                        attachmentMenuPresented = false
                        beginSlashCommand()
                    } label: {
                        Label("Slash commands", systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(8)
            .frame(minWidth: 190)
        }
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

    // MARK: - Settings pill

    /// The reference's `5.6 Sol Light ⌄`: the model, then the setting most
    /// likely to have moved since, then the caret. One chip now opens
    /// everything the old model chip and effort chip opened separately.
    private var settingsPill: some View {
        let values = AcpComposerMenu.chipValues(
            agentName: agentName,
            modelName: currentModelName,
            option: primaryOption
        )
        return Button {
            menuQuery = ""
            menuGeneration += 1
            menuPresented = true
        } label: {
            AcpComposerPillLabel(
                primary: values.primary,
                secondary: values.secondary,
                isPending: conversation.pendingConfigOptionID != nil
            ) {
                QuietIdentityMarkView(identity: identity, size: 13)
            }
        }
        .buttonStyle(AcpComposerChipButtonStyle(shape: AnyShape(Capsule()), restingOpacity: 0.32))
        .disabled(conversation.pendingConfigOptionID != nil)
        .help(conversation.pendingConfigOptionID == nil
            ? "Agent, model, and the settings this chat runs on"
            : "Waiting for the agent to confirm this setting")
        .accessibilityLabel(pillAccessibilityLabel(values))
        .accessibilityIdentifier("acp.composer.settings")
        .popover(isPresented: $menuPresented, arrowEdge: .top) {
            AcpComposerMenuView(
                rows: AcpComposerMenu.rows(agentName: agentName, surface: surface),
                advancedLines: AcpComposerMenu.advancedLines(
                    usage: conversation.usage,
                    surface: surface
                ),
                submenu: submenu,
                identity: { agentID in
                    QuietIdentity.identity(
                        agentName: AgentRegistry.profile(id: agentID)?.name,
                        processName: nil
                    )
                },
                choose: choose,
                toggleFavorite: { id in
                    favorites = favoritesStore.toggle(id, agentKey: agentName)
                },
                manageAgents: {
                    NSApp.sendAction(
                        #selector(KaisolaMacAppDelegate.openAgentSettings(_:)),
                        to: nil,
                        from: nil
                    )
                },
                dismiss: { menuPresented = false },
                isPresented: { menuPresented },
                query: $menuQuery
            )
            .id(menuGeneration)
        }
    }

    private func pillAccessibilityLabel(_ values: (primary: String, secondary: String?)) -> String {
        let tail = values.secondary.map { ", \($0)" } ?? ""
        let pending = conversation.pendingConfigOptionID == nil ? "" : ", change pending"
        return "Chat settings: \(values.primary)\(tail)\(pending)"
    }

    private func submenu(_ target: AcpComposerMenuRow.Target) -> AcpComposerSubmenu {
        switch target {
        case .agent:
            return AcpComposerMenu.agentSubmenu(
                agents: AgentRegistry.all,
                currentAgentID: currentAgentID,
                isChatCapable: { AcpAdapter.forAgent($0) != nil }
            )
        case .model:
            return AcpComposerMenu.modelSubmenu(
                surface: surface,
                favorites: favorites,
                query: menuQuery
            )
        case .option(let id):
            guard let option = surface.options.first(where: { $0.id == id }) else {
                return AcpComposerSubmenu(title: id, options: [])
            }
            return AcpComposerMenu.optionSubmenu(option)
        }
    }

    private func choose(_ target: AcpComposerMenuRow.Target, _ value: String) {
        switch target {
        case .agent:
            switchAgent(to: value)
        case .model:
            // Which request carries a model depends on where the surviving
            // model list came from: an adapter that lists model × effort pairs
            // takes `session/set_model`; one that also declares a base-model
            // option takes that, because setting it leaves the effort alone.
            switch surface.modelTarget {
            case .setModel:
                conversation.selectModel(value)
            case .configOption(let id):
                conversation.selectConfigOption(id, value: value)
            }
            menuPresented = false
        case .option(let id):
            conversation.selectConfigOption(id, value: value)
            menuPresented = false
        }
    }

    // MARK: - Agent switch

    /// The agent id driving this chat. `AcpChatHandle` holds it; the title is
    /// only a display string a rename can overwrite, so it is not the source.
    private var currentAgentID: String {
        model.chats.first { $0.conversation === conversation }?.agentID
            ?? AgentRegistry.profile(displayName: agentName)?.id
            ?? ""
    }

    /// An ACP conversation is one adapter process holding one session, and
    /// `AcpConversation` fixes its command and cwd at construction — the
    /// protocol has no handoff. So switching opens a *new* chat with the chosen
    /// agent in the same project and hands it the unsent draft. This chat stays
    /// open, transcript and all; that is why every other row in the submenu
    /// says "Starts a new chat" before it is pressed.
    private func switchAgent(to agentID: String) {
        menuPresented = false
        let decision = AcpAgentSwitch.decision(
            agentID: agentID,
            currentAgentID: currentAgentID,
            isChatCapable: { AcpAdapter.forAgent($0) != nil }
        )
        guard case .startNewChat(let chosenID) = decision,
              let agent = AgentRegistry.profile(id: chosenID) else { return }
        model.openChat(
            agent,
            inDirectory: conversation.workspaceURL,
            initialDraft: draft.isEmpty ? nil : draft
        )
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
                        sendEnabled ? Color.accentColor : Color.kaisolaDisabled,
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

/// The attachment shortcut has to outlive the popover it can dismiss.
///
/// SwiftUI's `.keyboardShortcut` is presentation-scoped: putting Command-U on
/// a button inside a closed popover leaves no registered command. This mounted
/// AppKit view participates in the normal key-equivalent traversal instead. It
/// deliberately refuses repeats, extra modifiers, inactive windows, and an
/// inactive/disconnected composer before invoking the injected panel action.
@MainActor
struct AcpAttachmentCommandKeyEquivalent: NSViewRepresentable {
    let isEnabled: Bool
    let panelPresenter: @MainActor () -> Void

    func makeNSView(context: Context) -> CommandView {
        let view = CommandView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: CommandView, context: Context) {
        nsView.isShortcutEnabled = isEnabled
        nsView.panelPresenter = panelPresenter
    }

    @MainActor
    final class CommandView: NSView {
        var isShortcutEnabled = false
        var panelPresenter: (@MainActor () -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard isShortcutEnabled,
                  window?.isKeyWindow == true,
                  event.type == .keyDown,
                  !event.isARepeat,
                  modifiers == [.command],
                  event.charactersIgnoringModifiers?.lowercased() == "u",
                  let panelPresenter else {
                return super.performKeyEquivalent(with: event)
            }
            panelPresenter()
            return true
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
                .foregroundStyle(.kaisolaTertiary)
        }
        .foregroundStyle(tint ?? .primary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .contentShape(RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius))
    }
}

/// The settings pill: `<primary> <secondary in grey> ⌄`, the one chip in the
/// row that carries a resting surface. It has one because it is the row's only
/// object with a menu behind *four* settings rather than one, and because the
/// reference gives it one — the eye needs somewhere to aim on the right edge.
struct AcpComposerPillLabel<Leading: View>: View {
    let primary: String
    var secondary: String?
    var isPending = false
    @ViewBuilder var leading: () -> Leading

    init(
        primary: String,
        secondary: String? = nil,
        isPending: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.primary = primary
        self.secondary = secondary
        self.isPending = isPending
        self.leading = leading
    }

    var body: some View {
        HStack(spacing: 5) {
            leading()
            Text(primary)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if let secondary {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                    .lineLimit(1)
            }
            if isPending {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.kaisolaTertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .contentShape(Capsule())
    }
}

/// A chip's only decoration: a faint surface on hover, matching what the
/// borderless menu style does for the chips that open menus. The pill passes a
/// capsule and a resting fill; everything else stays naked until hovered.
struct AcpComposerChipButtonStyle: ButtonStyle {
    var shape = AnyShape(RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius))
    var restingOpacity: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        // The hover state lives in a real `View`, not in the style struct.
        // SwiftUI does not allocate storage for `@State` declared on a
        // `ButtonStyle`, so a chip written that way would never light up.
        Surface(configuration: configuration, shape: shape, restingOpacity: restingOpacity)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let shape: AnyShape
        let restingOpacity: Double
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var fillOpacity: Double {
            (configuration.isPressed || hovering) ? 0.6 : restingOpacity
        }

        var body: some View {
            configuration.label
                .background(
                    fillOpacity > 0
                        ? AnyShapeStyle(.quaternary.opacity(fillOpacity))
                        : AnyShapeStyle(Color.clear),
                    in: shape
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
