import SwiftUI

struct AgentSessionView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var coordinator: CompanionConnectionCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @State private var sending = false
    let sessionId: String

    private var session: CompanionSession? { store.session(for: sessionId) }
    private var transcriptRevision: String {
        guard let session, let last = session.turns?.last else { return "empty:\(session?.updatedAt ?? 0)" }
        return "\(session.turns?.count ?? 0):\(last.wireId ?? last.role.rawValue):\(last.text.utf8.count):\(last.status ?? ""):\(session.updatedAt)"
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            if let session {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            metaLine(session)
                            ForEach(session.turns ?? []) { turn in
                                TranscriptTurnView(turn: turn).id(turn.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 15)
                        .padding(.top, 8)
                        .padding(.bottom, 74)
                    }
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.bottom)
                    .onAppear {
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: transcriptRevision) {
                        Task { @MainActor in
                            await Task.yield()
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { composer(session) }
            } else {
                ContentUnavailableView("Session ended", systemImage: "sparkle.slash")
            }
        }
        .navigationTitle(session?.title ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session {
                    HStack(spacing: 10) {
                        StatusBadge(status: session.status)
                        if session.status == .running && (store.canControlAgents || store.isPreview) {
                            Button {
                                Task { _ = await coordinator.cancelAgent(session) }
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.caption2)
                            }
                            .accessibilityLabel("Stop agent")
                        }
                    }
                }
            }
        }
    }

    private func metaLine(_ session: CompanionSession) -> some View {
        HStack(spacing: 6) {
            if let provider = session.provider { Text(provider).foregroundStyle(KaisolaTheme.accent) }
            ForEach([session.model, session.mode, session.branch].compactMap { $0 }, id: \.self) { part in
                Text("·"); Text(part)
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }

    private func composer(_ session: CompanionSession) -> some View {
        HStack(spacing: 10) {
            TextField("Message \(session.provider ?? "agent")", text: $draft, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...5)
                .disabled(!canCompose || sending)
                .submitLabel(.send)
                .onSubmit { Task { await send(session) } }
            Button {
                Task { await send(session) }
            } label: {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(KaisolaTheme.darkFrame)
                        .frame(width: 30, height: 30)
                        .background(KaisolaTheme.accent, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .disabled(!canCompose || sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(session.status == .running ? "Steer agent" : "Send message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .topLeading) {
            if !canCompose {
                Text("Enable agent control on your Mac")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .offset(y: -16)
            }
        }
    }

    private var canCompose: Bool {
        (store.canControlAgents || store.isPreview) && store.connection != .offline
    }

    private func send(_ session: CompanionSession) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCompose, !text.isEmpty, !sending else { return }
        sending = true
        if await coordinator.sendAgentMessage(to: session, text: text) { draft = "" }
        sending = false
    }
}

private struct TranscriptTurnView: View {
    let turn: CompanionTurn
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(turn.text)
                    .font(.subheadline)
                    .foregroundStyle(KaisolaTheme.darkFrame)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(KaisolaTheme.accent, in: BubbleShape(tail: .trailing))
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(turn.text)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if turn.status == "streaming" {
                        HStack(spacing: 5) {
                            PulseDot(color: KaisolaTheme.running, size: 4)
                            Text("working").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KaisolaTheme.panel(for: colorScheme), in: BubbleShape(tail: .leading))
                .overlay { BubbleShape(tail: .leading).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
                Spacer(minLength: 32)
            }
        case .thought, .tool:
            ToolPill(turn: turn)
        }
    }
}

private struct ToolPill: View {
    let turn: CompanionTurn
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var isThought: Bool { turn.role == .thought }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: isThought ? "brain" : "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isThought ? KaisolaTheme.info : KaisolaTheme.done)
                    Text(isThought ? "Reasoning" : firstLine)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(turn.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
    }

    private var firstLine: String {
        turn.text.split(separator: "\n").first.map(String.init) ?? "Tool result"
    }
}

/// A chat bubble with one squared-off corner on the tail side.
private struct BubbleShape: Shape {
    enum Tail { case leading, trailing }
    let tail: Tail
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 15, small: CGFloat = 5
        let tl = tail == .leading ? small : r
        let bl = tail == .leading ? small : r
        let tr = tail == .trailing ? small : r
        let br = tail == .trailing ? small : r
        return Path { p in
            p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
            p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
    }
}

#Preview {
    let store = CompanionStore.preview()
    let coordinator = CompanionConnectionCoordinator(store: store)
    return NavigationStack {
        if let agent = store.sessions.first(where: { $0.kind == .agent }) {
            AgentSessionView(sessionId: agent.id)
        } else { Text("no agent") }
    }
    .environmentObject(store)
    .environmentObject(coordinator)
}
