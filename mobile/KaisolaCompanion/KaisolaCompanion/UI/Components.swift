import KaisolaCore
import SwiftUI

struct PulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    var animated = true
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !animated)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.8) / 1.8
            let wave = (sin(phase * .pi * 2) + 1) / 2

            ZStack {
                Circle()
                    .stroke(color.opacity(animated && !reduceMotion ? 0.38 - wave * 0.18 : 0.22), lineWidth: 1)
                    .frame(width: size + 7 + wave * 3, height: size + 7 + wave * 3)
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size + 12, height: size + 12)
        .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let status: CompanionSessionStatus

    var body: some View {
        HStack(spacing: 6) {
            PulseDot(color: KaisolaTheme.color(for: status), animated: status == .running, size: 5)
            Text(status.title.uppercased())
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .tracking(0.7)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct SessionCard: View {
    let session: CompanionSession
    let project: CompanionProject?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KaisolaTheme.color(for: session.status))
                .frame(width: 30, height: 30)
                .background(KaisolaTheme.color(for: session.status).opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(contextLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                StatusBadge(status: session.status)
                Text(relativeTime)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.quaternary)
        }
        .kaisolaCard(padding: 13)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch session.kind {
        case .agent: "sparkle"
        case .terminal: "terminal"
        case .panel: "rectangle.3.group"
        }
    }

    private var relativeTime: String {
        let activityAt: Int64
        if session.kind == .terminal {
            activityAt = session.completedAt ?? (session.status == .running ? 0 : session.updatedAt)
        } else {
            activityAt = session.updatedAt
        }
        guard activityAt > 0 else { return session.kind == .terminal ? "NO FINISH" : "NO REPLY" }
        let date = Date(timeIntervalSince1970: TimeInterval(activityAt) / 1_000)
        let relative = date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return session.kind == .terminal ? "FINISHED \(relative)" : "REPLIED \(relative)"
    }

    private var contextLine: String {
        let parts = [project?.name, session.provider].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
        }
        return parts.isEmpty ? session.kind.rawValue.capitalized : parts.joined(separator: " · ")
    }
}

struct SectionHeading: View {
    let title: String
    let count: Int
    let color: Color
    var subtitle: String?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.15)
            Text(count, format: .number)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .contentTransition(.numericText())
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct ControlLockedBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KaisolaTheme.accent)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .kaisolaInset(radius: 13)
    }
}

struct QuietPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}
