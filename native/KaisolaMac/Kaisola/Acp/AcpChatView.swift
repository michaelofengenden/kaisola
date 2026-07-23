import SwiftUI

/// The ACP conversation surface: streaming messages, thinking blocks,
/// tool-call cards, a plan, a live permission prompt, model picker, usage, and
/// a composer. Mirrors the Electron Assistant transcript.
struct AcpChatView: View {
    @ObservedObject var conversation: AcpConversation
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if let permission = conversation.pendingPermission {
                PermissionBar(request: permission) { conversation.answerPermission($0) }
            }
            Divider()
            composer
        }
        .task { await conversation.start() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(conversation.isConnected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(conversation.title).font(.subheadline.weight(.medium))
            if conversation.isRunning {
                ProgressView().controlSize(.small)
                Text("Working…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !conversation.models.isEmpty {
                Picker("Model", selection: Binding(
                    get: { conversation.currentModelID ?? conversation.models.first?.id ?? "" },
                    set: { conversation.selectModel($0) }
                )) {
                    ForEach(conversation.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            if let usage = conversation.usage {
                Text("\(usage.used / 1000)k / \(usage.max / 1000)k")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let status = conversation.statusMessage {
                        Label(status, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(conversation.rows) { row in
                        TranscriptRowView(row: row).id(row.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation.rows.count) { _, _ in
                if let last = conversation.rows.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(sendDraft)
            if conversation.isRunning {
                Button(action: conversation.cancel) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop the current turn")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !conversation.isConnected)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        conversation.send(text)
    }
}

private struct TranscriptRowView: View {
    let row: AcpTranscriptRow

    var body: some View {
        switch row {
        case let .user(_, text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }
        case let .message(_, text):
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .thought(_, text):
            DisclosureGroup {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case let .tool(call):
            ToolCallCard(call: call)
        case let .plan(_, entries):
            PlanCard(entries: entries)
        }
    }
}

private struct ToolCallCard: View {
    let call: AcpToolCall
    @State private var expanded = false

    private var hasArtifacts: Bool { !call.content.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if hasArtifacts { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                    Text(call.title).lineLimit(1)
                    Spacer()
                    if hasArtifacts {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(call.kind).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasArtifacts)

            if !call.locations.isEmpty {
                Text(call.locations.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            if expanded {
                ForEach(call.content) { artifact in
                    switch artifact {
                    case let .diff(path, oldText, newText):
                        DiffView(path: path, oldText: oldText, newText: newText)
                    case let .text(text):
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusSymbol: String {
        switch call.status {
        case .pending, .inProgress: "gearshape"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .pending, .inProgress: .secondary
        case .completed: .green
        case .failed: .red
        }
    }
}

/// A compact unified diff for a tool-call file edit: removed lines tinted red,
/// added lines tinted green, mirroring the Electron chat's inline diff card.
private struct DiffView: View {
    let path: String
    let oldText: String?
    let newText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((path as NSString).lastPathComponent)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(AcpDiff.lines(old: oldText ?? "", new: newText).enumerated()), id: \.offset) { _, line in
                        Text(line.kind.prefix + line.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 1)
                            .background(tint(for: line.kind))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func tint(for kind: AcpDiff.LineKind) -> Color {
        switch kind {
        case .context: .clear
        case .removed: .red.opacity(0.18)
        case .added: .green.opacity(0.18)
        }
    }
}

private struct PlanCard: View {
    let entries: [AcpPlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Plan", systemImage: "checklist").font(.caption.weight(.semibold))
            ForEach(entries) { entry in
                HStack(spacing: 7) {
                    Image(systemName: entry.status == "completed" ? "checkmark.square" : "square")
                        .foregroundStyle(entry.status == "completed" ? .green : .secondary)
                    Text(entry.content).strikethrough(entry.status == "completed")
                    Spacer()
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PermissionBar: View {
    let request: AcpPermissionRequest
    let answer: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text(request.title).font(.callout).lineLimit(2)
            Spacer()
            ForEach(request.options) { option in
                Button(option.name) { answer(option.id) }
                    .buttonStyle(.bordered)
                    .tint(option.kind.contains("reject") ? .red : .accentColor)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }
}
