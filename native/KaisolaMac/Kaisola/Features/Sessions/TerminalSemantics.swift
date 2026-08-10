import AppKit

enum TerminalSemanticEvent: Equatable, Sendable {
    case promptStart(isSecondary: Bool)
    case commandStart
    case commandExecuted
    case commandFinished(exitCode: Int?)

    /// FinalTerm/OSC 133 and VS Code/OSC 633 lifecycle payloads are deliberately
    /// tiny. Refuse malformed or oversized strings before interpreting them so
    /// untrusted command output cannot turn navigation into an unbounded parser.
    static func parse(_ payload: ArraySlice<UInt8>) -> TerminalSemanticEvent? {
        guard !payload.isEmpty, payload.count <= 1_024,
              let value = String(bytes: payload, encoding: .utf8) else { return nil }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard let marker = fields.first else { return nil }
        switch marker {
        case "A":
            return .promptStart(isSecondary: fields.dropFirst().contains("k=s"))
        case "B":
            return fields.count == 1 ? .commandStart : nil
        case "C":
            return .commandExecuted
        case "D":
            guard fields.count <= 2 else { return nil }
            guard fields.count == 2, !fields[1].isEmpty else {
                return .commandFinished(exitCode: nil)
            }
            guard fields[1].count <= 10,
                  let status = Int(fields[1]),
                  (0...Int(Int32.max)).contains(status) else { return nil }
            return .commandFinished(exitCode: status)
        default:
            return nil
        }
    }
}
struct TerminalSemanticPosition: Equatable, Comparable, Sendable {
    let row: Int
    let column: Int

    static func < (lhs: TerminalSemanticPosition, rhs: TerminalSemanticPosition) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

struct TerminalSemanticCommand: Equatable, Sendable {
    let id: Int
    var promptStart: TerminalSemanticPosition
    var inputStart: TerminalSemanticPosition?
    var executedAt: TerminalSemanticPosition?
    var finishedAt: TerminalSemanticPosition?
    var exitCode: Int?
    var maximumInputRow: Int
    var secondaryPromptRows: [Int]
}

enum TerminalSemanticDecorationPhase: Equatable, Sendable {
    case input
    case running
    case succeeded
    case failed
    case completed
}

struct TerminalSemanticDecoration: Equatable, Sendable {
    let startViewportRow: Int
    let endViewportRow: Int
    let phase: TerminalSemanticDecorationPhase
}

/// Bounded semantic command state reconstructed directly from the terminal
/// stream. Because OSC bytes stay in the broker spool, replay after a GUI
/// replacement rebuilds this index without a second persistence authority.
struct TerminalSemanticTracker: Equatable, Sendable {
    static let maximumCommands = 512

    private(set) var commands: [TerminalSemanticCommand] = []
    private var currentCommandID: Int?
    private var nextID = 1

    mutating func receive(_ event: TerminalSemanticEvent, at position: TerminalSemanticPosition) {
        switch event {
        case let .promptStart(isSecondary):
            if isSecondary, let index = currentIndex {
                if commands[index].secondaryPromptRows.last != position.row {
                    commands[index].secondaryPromptRows.append(position.row)
                }
                commands[index].maximumInputRow = max(commands[index].maximumInputRow, position.row)
                return
            }
            let command = TerminalSemanticCommand(
                id: nextID,
                promptStart: position,
                inputStart: nil,
                executedAt: nil,
                finishedAt: nil,
                exitCode: nil,
                maximumInputRow: position.row,
                secondaryPromptRows: []
            )
            nextID += 1
            commands.append(command)
            currentCommandID = command.id
            trimToBound()
        case .commandStart:
            ensureCurrent(at: position)
            guard let index = currentIndex else { return }
            commands[index].inputStart = position
            commands[index].maximumInputRow = max(commands[index].maximumInputRow, position.row)
        case .commandExecuted:
            ensureCurrent(at: position)
            guard let index = currentIndex else { return }
            commands[index].executedAt = position
        case let .commandFinished(exitCode):
            guard let index = currentIndex else { return }
            // FinalTerm defines D before C as an aborted edit. It is not a
            // command block and must not remain navigable as if it had run.
            guard commands[index].executedAt != nil else {
                commands.remove(at: index)
                currentCommandID = nil
                return
            }
            commands[index].finishedAt = position
            commands[index].exitCode = exitCode
            currentCommandID = nil
        }
    }

    mutating func observeCursor(at position: TerminalSemanticPosition) {
        guard let index = currentIndex,
              commands[index].inputStart != nil,
              commands[index].executedAt == nil else { return }
        commands[index].maximumInputRow = max(commands[index].maximumInputRow, position.row)
    }

    mutating func prune(before firstRetainedRow: Int) {
        commands.removeAll { command in
            let lastRow = command.finishedAt?.row
                ?? command.executedAt?.row
                ?? command.maximumInputRow
            return lastRow < firstRetainedRow
        }
        if let currentCommandID,
           !commands.contains(where: { $0.id == currentCommandID }) {
            self.currentCommandID = nil
        }
    }

    var activeInputRows: ClosedRange<Int>? {
        guard let index = currentIndex,
              let start = commands[index].inputStart,
              commands[index].executedAt == nil else { return nil }
        return start.row...max(start.row, commands[index].maximumInputRow)
    }

    func previousPrompt(before row: Int) -> TerminalSemanticPosition? {
        commands.lazy.reversed().map(\.promptStart).first { $0.row < row }
    }

    func nextPrompt(after row: Int) -> TerminalSemanticPosition? {
        commands.lazy.map(\.promptStart).first { $0.row > row }
    }

    func prompt(at row: Int) -> TerminalSemanticPosition? {
        commands.lazy.map(\.promptStart).first { $0.row == row }
    }

    /// Clips semantic command spans into the visible terminal viewport. The
    /// renderer consumes only these bounded rows; command text never enters the
    /// decoration model, and a partially visible command remains identifiable
    /// while the user scrolls through its output.
    func decorations(viewportTop: Int, rowCount: Int) -> [TerminalSemanticDecoration] {
        guard rowCount > 0 else { return [] }
        let viewportBottom = viewportTop + rowCount - 1
        return commands.enumerated().compactMap { index, command in
            let recordedEnd = command.finishedAt?.row
                ?? command.executedAt?.row
                ?? command.maximumInputRow
            let commandEnd: Int
            if command.finishedAt != nil, commands.indices.contains(index + 1) {
                commandEnd = min(recordedEnd, commands[index + 1].promptStart.row - 1)
            } else {
                commandEnd = recordedEnd
            }
            guard commandEnd >= viewportTop,
                  command.promptStart.row <= viewportBottom else { return nil }
            let phase: TerminalSemanticDecorationPhase
            if command.finishedAt != nil {
                if command.exitCode == 0 {
                    phase = .succeeded
                } else if command.exitCode != nil {
                    phase = .failed
                } else {
                    phase = .completed
                }
            } else if command.executedAt != nil {
                phase = .running
            } else {
                phase = .input
            }
            return TerminalSemanticDecoration(
                startViewportRow: max(0, command.promptStart.row - viewportTop),
                endViewportRow: min(rowCount - 1, commandEnd - viewportTop),
                phase: phase
            )
        }
    }

    private var currentIndex: Int? {
        guard let currentCommandID else { return nil }
        return commands.lastIndex { $0.id == currentCommandID }
    }

    private mutating func ensureCurrent(at position: TerminalSemanticPosition) {
        guard currentIndex == nil else { return }
        let command = TerminalSemanticCommand(
            id: nextID,
            promptStart: position,
            inputStart: nil,
            executedAt: nil,
            finishedAt: nil,
            exitCode: nil,
            maximumInputRow: position.row,
            secondaryPromptRows: []
        )
        nextID += 1
        commands.append(command)
        currentCommandID = command.id
        trimToBound()
    }

    private mutating func trimToBound() {
        guard commands.count > Self.maximumCommands else { return }
        commands.removeFirst(commands.count - Self.maximumCommands)
        if let currentCommandID,
           !commands.contains(where: { $0.id == currentCommandID }) {
            self.currentCommandID = nil
        }
    }
}

/// Draws quiet, noninteractive command separators over marked terminal rows.
/// Row-boundary rules and an extremely light wash give shell output visible
/// block structure without changing the PTY grid or intercepting selection and
/// link clicks.
final class TerminalSemanticDecorationView: NSView {
    private var decorations: [TerminalSemanticDecoration] = []
    private var rowCount = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func update(decorations: [TerminalSemanticDecoration], rowCount: Int) {
        guard self.decorations != decorations || self.rowCount != rowCount else { return }
        self.decorations = decorations
        self.rowCount = rowCount
        isHidden = decorations.isEmpty || rowCount <= 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard rowCount > 0, !decorations.isEmpty else { return }
        let rowHeight = bounds.height / CGFloat(rowCount)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixel = 1 / max(1, scale)

        for decoration in decorations {
            let color: NSColor
            switch decoration.phase {
            case .input: color = .controlAccentColor
            case .running: color = .systemOrange
            case .succeeded: color = .systemGreen
            case .failed: color = .systemRed
            case .completed: color = .secondaryLabelColor
            }
            let top = bounds.maxY - CGFloat(decoration.startViewportRow) * rowHeight
            let bottom = bounds.maxY - CGFloat(decoration.endViewportRow + 1) * rowHeight
            let contentWidth = max(0, bounds.width - 16)
            color.withAlphaComponent(0.025).setFill()
            NSBezierPath.fill(
                NSRect(x: 0, y: bottom, width: contentWidth, height: max(0, top - bottom))
            )
            color.withAlphaComponent(0.72).setFill()
            NSBezierPath.fill(
                NSRect(
                    x: 0,
                    y: top - 2 * pixel,
                    width: min(42, contentWidth),
                    height: 2 * pixel
                )
            )
        }
    }
}
