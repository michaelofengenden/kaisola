import SwiftUI

struct TerminalSessionView: View {
    @EnvironmentObject private var store: CompanionStore
    let sessionId: String

    private var session: CompanionSession? { store.session(for: sessionId) }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    terminalHeader(session)
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array((session.terminalLines ?? []).enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .foregroundStyle(index == 0 ? KaisolaTheme.done : Color.white.opacity(0.82))
                            }
                            if session.status == .running {
                                Text("▋")
                                    .foregroundStyle(KaisolaTheme.electric)
                            }
                        }
                        .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                    .background {
                        ZStack {
                            KaisolaTheme.terminalBackground
                            LinearGradient(
                                colors: [KaisolaTheme.accent.opacity(0.055), .clear],
                                startPoint: .topTrailing,
                                endPoint: .center
                            )
                        }
                    }

                    accessoryRow
                }
                .background(KaisolaTheme.terminalBackground)
                .navigationTitle(session.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 6) {
                            Image(systemName: "eye")
                            Text("READ ONLY")
                        }
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(KaisolaTheme.electric)
                    }
                }
            }
        }
    }

    private func terminalHeader(_ session: CompanionSession) -> some View {
        HStack(spacing: 11) {
            PulseDot(color: KaisolaTheme.done, size: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text("STREAM / BOUNDED SNAPSHOT")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                Text("Cursor 284 · local preview")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "lock")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var accessoryRow: some View {
        VStack(spacing: 9) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(["esc", "ctrl", "tab", "←", "↑", "↓", "→", "⌃C"], id: \.self) { key in
                        Text(key.uppercased())
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, minHeight: 32)
                            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                            }
                    }
                }
                .padding(.horizontal, 12)
            }
            Text("PAIR + GRANT TERMINAL CONTROL TO ENABLE INPUT")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.65)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
