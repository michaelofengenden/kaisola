import Foundation

/// The signed-in identity, mirroring the desktop `AppIdentity`.
struct AuthAccount: Equatable, Codable, Sendable {
    var uid: String
    var email: String
    var displayName: String?
    var avatarURL: URL?

    var initials: String {
        let source = (displayName?.isEmpty == false ? displayName! : email)
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

enum AuthPhase: Equatable, Sendable {
    case restoring          // checking the Keychain on launch
    case signedOut
    case signingIn
    case signedIn(AuthAccount)
    case failed(String)
}

/// The account layer's plug point. The concrete `FirebaseAuthBackend`
/// (Identity Toolkit REST + ASWebAuthenticationSession + Keychain) implements
/// this; SwiftUI never touches it directly — it observes `AuthModel`.
@MainActor
protocol AuthBackend: AnyObject {
    /// Silent restore from the Keychain refresh token; nil if signed out.
    func restore() async throws -> AuthAccount?
    /// Interactive Google sign-in; returns the account on success.
    func signInWithGoogle() async throws -> AuthAccount
    /// A fresh Firebase ID token for short-lived same-account services. The
    /// token never leaves the native account layer except as bearer auth.
    func freshIDToken() async throws -> String
    /// Clear the Keychain, session, and any cached state.
    func signOut() async
}

/// Observable auth state the whole app binds to. Owns phase transitions and
/// error copy; delegates the actual credential work to an `AuthBackend`.
@MainActor
final class AuthModel: ObservableObject {
    @Published private(set) var phase: AuthPhase = .restoring

    private let backend: AuthBackend

    init(backend: AuthBackend) {
        self.backend = backend
    }

    var account: AuthAccount? {
        if case let .signedIn(account) = phase { return account }
        return nil
    }

    var isSignedIn: Bool { account != nil }

    func restore() async {
        do {
            if let account = try await backend.restore() {
                phase = .signedIn(account)
            } else {
                phase = .signedOut
            }
        } catch {
            phase = .signedOut // a failed silent restore is just "signed out"
        }
    }

    func signInWithGoogle() async {
        phase = .signingIn
        do {
            phase = .signedIn(try await backend.signInWithGoogle())
        } catch is CancellationError {
            phase = .signedOut
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func signOut() async {
        await backend.signOut()
        phase = .signedOut
    }

    func freshIDToken() async throws -> String {
        guard isSignedIn else { throw FirebaseAuthError.invalidSavedSession }
        return try await backend.freshIDToken()
    }

    /// Dismiss a `.failed` phase back to the sign-in screen.
    func clearError() {
        if case .failed = phase { phase = .signedOut }
    }

    private static func message(for error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.isEmpty ? "Sign-in didn't complete. Try again." : text
    }
}

/// Previews and the visual build path run against this — a scripted backend so
/// SwiftUI previews never open a browser or hit the network.
@MainActor
final class PreviewAuthBackend: AuthBackend {
    var scriptedAccount: AuthAccount
    var startSignedIn: Bool

    init(
        account: AuthAccount = AuthAccount(uid: "preview-uid", email: "michaelofengend@gmail.com", displayName: "Michael Ofengenden", avatarURL: nil),
        startSignedIn: Bool = true
    ) {
        self.scriptedAccount = account
        self.startSignedIn = startSignedIn
    }

    func restore() async throws -> AuthAccount? { startSignedIn ? scriptedAccount : nil }
    func signInWithGoogle() async throws -> AuthAccount {
        try? await Task.sleep(for: .milliseconds(400))
        return scriptedAccount
    }
    func freshIDToken() async throws -> String { "preview-firebase-id-token" }
    func signOut() async { startSignedIn = false }
}

extension AuthModel {
    /// Signed-in model for previews and the visual build path.
    static func previewSignedIn() -> AuthModel {
        let model = AuthModel(backend: PreviewAuthBackend(startSignedIn: true))
        model.phase = .signedIn(AuthAccount(uid: "preview-uid", email: "michaelofengend@gmail.com", displayName: "Michael Ofengenden", avatarURL: nil))
        return model
    }

    static func previewSignedOut() -> AuthModel {
        AuthModel(backend: PreviewAuthBackend(startSignedIn: false))
    }
}
