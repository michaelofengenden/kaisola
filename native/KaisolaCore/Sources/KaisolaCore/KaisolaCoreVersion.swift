/// Version of the shared Apple-client contract surface.
///
/// This is intentionally independent from the macOS app, iPhone app, Companion
/// wire protocol, and terminal-broker protocol versions. Increment it only when
/// clients need to reason about a breaking `KaisolaCore` API or persisted-model
/// change.
public enum KaisolaCoreVersion {
    public static let current = 1
}
