import SwiftUI

struct PreviewModePill: View {
    var body: some View {
        HStack(spacing: 7) {
            PulseDot(color: KaisolaTheme.electric, animated: false, size: 5)
            Text("LOCAL PREVIEW")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.1)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Local preview data. No Mac is connected.")
    }
}

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

struct OrbitalStatusMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var diameter: CGFloat = 82
    var centerSymbol: String? = "waveform.path.ecg"

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? 24 : elapsed.truncatingRemainder(dividingBy: 14) / 14 * 360

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.075), lineWidth: 1)
                    .frame(width: diameter - 4, height: diameter - 4)
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    .frame(width: diameter * 0.62, height: diameter * 0.62)
                Circle()
                    .trim(from: 0.05, to: 0.48)
                    .stroke(
                        LinearGradient(colors: [KaisolaTheme.accent, KaisolaTheme.electric], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .frame(width: diameter - 4, height: diameter - 4)
                    .rotationEffect(.degrees(angle))
                Circle()
                    .fill(KaisolaTheme.electric)
                    .frame(width: 5, height: 5)
                    .offset(y: -(diameter - 4) / 2)
                    .rotationEffect(.degrees(angle + 18))
                    .shadow(color: KaisolaTheme.electric.opacity(0.6), radius: 5)
                if let centerSymbol {
                    Image(systemName: centerSymbol)
                        .font(.system(size: diameter * 0.21, weight: .medium))
                        .foregroundStyle(KaisolaTheme.accent)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

struct SystemFocus: View {
    let state: CompanionConnectionState
    let running: Int

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                OrbitalStatusMark(diameter: 222, centerSymbol: nil)
                VStack(spacing: 2) {
                    Text(running, format: .number)
                        .font(.system(size: 70, weight: .ultraLight, design: .rounded))
                        .contentTransition(.numericText())
                    Text("RUNNING")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                PulseDot(color: state == .live ? KaisolaTheme.done : KaisolaTheme.electric, animated: state == .live, size: 5)
                Text(state == .live ? "CONNECTED" : "LOCAL PREVIEW")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.25)
                    .foregroundStyle(.secondary)
            }
        }
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
        guard session.updatedAt > 0 else { return "NO REPLY" }
        let date = Date(timeIntervalSince1970: TimeInterval(session.updatedAt) / 1_000)
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
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

struct ConsoleHeader: View {
    let eyebrow: String
    let title: String
    var detail: String?
    var symbol: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(KaisolaTheme.accent)
                Text(title)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .tracking(-0.7)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: Circle())
                    .overlay { Circle().stroke(Color.primary.opacity(0.07), lineWidth: 0.5) }
            }
        }
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
