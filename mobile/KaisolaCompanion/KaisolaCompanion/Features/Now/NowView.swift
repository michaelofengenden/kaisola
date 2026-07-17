import SwiftUI

struct NowView: View {
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.colorScheme) private var colorScheme

    var onOpenInbox: () -> Void = {}
    var onOpenSessions: () -> Void = {}

    private var runningCount: Int {
        store.visibleSessions.filter { $0.status == .running }.count
    }

    private var selectedProjectName: String {
        guard let id = store.selectedProjectId else { return "All" }
        return store.project(for: id)?.name ?? "All"
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        appHeader

                        Spacer(minLength: 34)

                        Button(action: onOpenSessions) {
                            SystemFocus(state: store.connection, running: runningCount)
                                .contentShape(Circle())
                        }
                        .buttonStyle(QuietPressStyle())
                        .accessibilityLabel("\(runningCount) running sessions")
                        .accessibilityHint("Opens Sessions")

                        Spacer(minLength: 38)

                        if store.needsYouCount > 0 {
                            needsYouButton
                        }

                        Spacer(minLength: 24)
                    }
                    .frame(minHeight: proxy.size.height)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
                }
                .scrollIndicators(.hidden)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .animation(.smooth(duration: 0.38), value: store.selectedProjectId)
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            Text("KAISOLA")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2.8)

            Spacer()

            Menu {
                Button {
                    withAnimation(.snappy) { store.selectedProjectId = nil }
                } label: {
                    Label("All workspaces", systemImage: store.selectedProjectId == nil ? "checkmark" : "square.stack")
                }

                ForEach(store.projects) { project in
                    Button {
                        withAnimation(.snappy) { store.selectedProjectId = project.id }
                    } label: {
                        Label(project.name, systemImage: store.selectedProjectId == project.id ? "checkmark" : "folder")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedProjectName)
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(KaisolaTheme.panel(for: colorScheme), in: Capsule())
                .overlay { Capsule().stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
            }
            .accessibilityLabel("Workspace, \(selectedProjectName)")
        }
    }

    private var needsYouButton: some View {
        Button(action: onOpenInbox) {
            HStack(spacing: 12) {
                PulseDot(color: KaisolaTheme.waiting, size: 6)
                Text("Needs you")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(store.needsYouCount, format: .number)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(KaisolaTheme.waiting)
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(KaisolaTheme.panel(for: colorScheme), in: Capsule())
            .overlay { Capsule().stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
        }
        .buttonStyle(QuietPressStyle())
        .accessibilityHint("Opens Inbox")
    }
}

#Preview {
    NavigationStack { NowView() }
        .environmentObject(CompanionStore.preview())
}
