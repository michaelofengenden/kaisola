import AppKit

/// When a file-tree row draws its "⋯" options button.
///
/// Every visible row used to carry one, so the rail read as a column of dots
/// running down the trailing edge beside the names — repeated chrome competing
/// with the only thing on the row anyone reads. The button now belongs to the
/// row the user is working with: hovered, keyboard-focused, or selected.
///
/// It is hidden by *transparency*, never by removal. The row already reserves
/// `optionsClearance` at its trailing edge, so revealing the button moves no
/// pixel of the name, and the control stays in the accessibility tree of every
/// row rather than appearing only for a gesture VoiceOver cannot make.
enum WorkspaceRowActions {
    /// The always-visible fallback: hover is not a gesture every input can
    /// make. VoiceOver and Full Keyboard Access both drive the tree without a
    /// pointer, so for them the button is simply always there.
    static func alwaysVisible(
        voiceOverEnabled: Bool,
        fullKeyboardAccessEnabled: Bool
    ) -> Bool {
        voiceOverEnabled || fullKeyboardAccessEnabled
    }

    static func isRevealed(
        isHovering: Bool,
        isFocused: Bool,
        isSelected: Bool,
        alwaysVisible: Bool
    ) -> Bool {
        isHovering || isFocused || isSelected || alwaysVisible
    }

    /// Read when the rail appears and again whenever the app comes forward.
    /// Both switches live in System Settings, so a change always arrives with
    /// an activation on the way back to Kaisola.
    @MainActor
    static func systemAlwaysVisible() -> Bool {
        alwaysVisible(
            voiceOverEnabled: NSWorkspace.shared.isVoiceOverEnabled,
            fullKeyboardAccessEnabled: NSApplication.shared.isFullKeyboardAccessEnabled
        )
    }
}
