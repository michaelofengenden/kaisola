import AppKit
import Carbon.HIToolbox

/// Where the summon lands, kept pure so the choice is testable: the selected
/// chat if there is one, else the most recently opened chat, else nothing —
/// summoning still activates the app, it just has no composer to focus.
enum SummonPolicy {
    static func chatToFocus(selectedChatID: String?, chatIDs: [String]) -> String? {
        if let selectedChatID, chatIDs.contains(selectedChatID) { return selectedChatID }
        return chatIDs.last
    }
}

/// One system-wide hotkey — ⌥⌘K — that summons Kaisola from any app: the
/// ChatGPT-app launcher pattern, scoped honestly. Carbon's
/// `RegisterEventHotKey` needs no Accessibility grant, unlike an NSEvent
/// global monitor, which is why it is the mechanism. Off by default: an app
/// that silently claims a global key combo on update has overstepped.
@MainActor
final class GlobalHotkeyCenter {
    static let shared = GlobalHotkeyCenter()

    /// What Settings prints next to the toggle.
    static let comboDisplay = "⌥⌘K"

    var onSummon: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let keyCode = UInt32(kVK_ANSI_K)
    private static let modifiers = UInt32(optionKey | cmdKey)
    private static let signature: OSType = 0x4B41_4953 // 'KAIS'

    private(set) var isRegistered = false

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard !isRegistered else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        // Carbon delivers hot-key events on the main thread; the C callback
        // below re-enters the MainActor through `assumeIsolated`.
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { center.onSummon?() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )
        guard status == noErr else { return }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus == noErr {
            isRegistered = true
        } else if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        isRegistered = false
    }
}
