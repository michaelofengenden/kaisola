import KaisolaCore
import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import Security
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct FirebaseAuthConfiguration: Equatable, Sendable {
    let projectId: String
    let apiKey: String
    let serverURL: URL
    let relayURL: URL?

    init(projectId: String, apiKey: String, serverURL: URL, relayURL: URL? = nil) {
        self.projectId = projectId
        self.apiKey = apiKey
        self.serverURL = serverURL
        self.relayURL = relayURL
    }

    static func load(from bundle: Bundle = .main) throws -> FirebaseAuthConfiguration {
        guard let url = bundle.url(forResource: "FirebaseAuthConfig", withExtension: "json")
            ?? bundle.url(forResource: "FirebaseAuthConfig", withExtension: "json", subdirectory: "Account") else {
            throw FirebaseAuthError.missingConfiguration
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> FirebaseAuthConfiguration {
        let decoded: RawConfiguration
        do {
            decoded = try JSONDecoder().decode(RawConfiguration.self, from: data)
        } catch {
            throw FirebaseAuthError.invalidConfiguration
        }

        let projectId = decoded.projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = decoded.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverURLText = decoded.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayURLText = decoded.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let projectRange = projectId.range(
            of: #"^[a-z0-9][a-z0-9-]{4,60}$"#,
            options: .regularExpression
        )
        let apiKeyRange = apiKey.range(
            of: #"^[A-Za-z0-9_-]{20,200}$"#,
            options: .regularExpression
        )
        guard projectRange == projectId.startIndex..<projectId.endIndex,
              apiKeyRange == apiKey.startIndex..<apiKey.endIndex,
              let serverURL = URL(string: serverURLText),
              serverURL.scheme?.lowercased() == "https",
              serverURL.host?.isEmpty == false,
              relayURLText.isEmpty || (
                URL(string: relayURLText)?.scheme?.lowercased() == "https"
                    && URL(string: relayURLText)?.host?.isEmpty == false
              ) else {
            throw FirebaseAuthError.invalidConfiguration
        }
        return FirebaseAuthConfiguration(
            projectId: projectId,
            apiKey: apiKey,
            serverURL: serverURL,
            relayURL: relayURLText.isEmpty ? nil : URL(string: relayURLText)
        )
    }

    private struct RawConfiguration: Decodable {
        let projectId: String
        let apiKey: String
        let serverURL: String
        let relayURL: String?

        private enum CodingKeys: String, CodingKey {
            case projectId
            case apiKey
            case serverURL = "serverUrl"
            case relayURL = "relayUrl"
        }
    }
}

struct FirebaseAuthCallback: Equatable, Sendable {
    let requestURI: String
    let postBody: String

    /// Validate the intercepted `callbackURL` against the app's custom-scheme
    /// `expectedCallback` (kaisola://auth), but report `requestURI` as the https
    /// `continueURI` that Firebase actually redirected to — signInWithIdp keys
    /// on the continue URI, while the browser session only sees the custom
    /// scheme the hosted redirector bounced to.
    static func parse(_ callbackURL: URL, expectedCallback: URL, continueURI: URL) throws -> FirebaseAuthCallback {
        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: expectedCallback, resolvingAgainstBaseURL: false),
              callback.scheme?.lowercased() == expected.scheme?.lowercased(),
              callback.host?.lowercased() == expected.host?.lowercased(),
              callback.port == expected.port,
              callback.path == expected.path,
              callback.user == nil,
              callback.password == nil,
              callback.fragment == nil else {
            throw FirebaseAuthError.invalidCallback
        }

        if let oauthError = callback.queryItems?.first(where: { $0.name == "error" })?.value {
            if oauthError == "access_denied" {
                throw CancellationError()
            }
            throw FirebaseAuthError.googleSignIn(oauthError)
        }

        guard let postBody = callback.percentEncodedQuery,
              !postBody.isEmpty,
              postBody.utf8.count <= 20_000 else {
            throw FirebaseAuthError.invalidCallback
        }
        return FirebaseAuthCallback(requestURI: continueURI.absoluteString, postBody: postBody)
    }
}

protocol AuthSecureStoring: AnyObject, Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func removeData(for key: String) throws
}

enum KeychainAuthInteractionPolicy: Equatable, Sendable {
    case allowUserInteraction
    case failIfInteractionRequired

    var operationPrompt: String? {
        switch self {
        case .allowUserInteraction:
            "Kaisola was updated and needs access to your saved sign-in."
        case .failIfInteractionRequired:
            nil
        }
    }

    func makeAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = operationPrompt
            ?? "Kaisola is checking whether a saved sign-in is available."
        context.interactionNotAllowed = self == .failIfInteractionRequired
        return context
    }
}

enum KeychainAuthQueryMode: Equatable, Sendable {
    case dataProtection
    case legacy
}

/// Process-wide mode for one secure-store instance. A missing entitlement may
/// move an operation from the data-protection keychain to the legacy keychain,
/// but a legacy attempt is terminal. Keeping the attempted mode explicit also
/// lets a stale concurrent data-protection query join an already activated
/// fallback without ever retrying the legacy query.
final class KeychainAuthFallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMode = KeychainAuthQueryMode.dataProtection

    var queryMode: KeychainAuthQueryMode {
        lock.lock()
        defer { lock.unlock() }
        return storedMode
    }

    func retryMode(
        afterMissingEntitlementIn attemptedMode: KeychainAuthQueryMode
    ) -> KeychainAuthQueryMode? {
        guard attemptedMode == .dataProtection else { return nil }
        lock.lock()
        defer { lock.unlock() }
        storedMode = .legacy
        return .legacy
    }
}

struct KeychainAuthSecurityOperations: @unchecked Sendable {
    let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let update: (CFDictionary, CFDictionary) -> OSStatus
    let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let delete: (CFDictionary) -> OSStatus

    static let live = KeychainAuthSecurityOperations(
        copyMatching: { SecItemCopyMatching($0, $1) },
        update: { SecItemUpdate($0, $1) },
        add: { SecItemAdd($0, $1) },
        delete: { SecItemDelete($0) }
    )
}

/// Once-per-install bookkeeping for the legacy-keychain protection refresh.
///
/// A legacy (file-based) keychain item keeps the access control recorded when
/// it was CREATED, forever: `SecItemUpdate` rewrites the value but never the
/// creator's ACL or partition. Items created by pre-Developer-ID builds are
/// therefore keyed to one exact binary (a cdhash), and every Sparkle update
/// re-triggers the "Kaisola wants to access your saved sign-in" prompt — the
/// lived "sign in again after every update". The refresh deletes and
/// re-creates the item once, so the CURRENT app — whose Developer ID
/// designated requirement is stable across updates — becomes the recorded
/// creator and later updates read silently. The marker keeps that a one-time
/// migration instead of a delete/re-add on every launch.
struct KeychainAuthLegacyRefreshMarker: @unchecked Sendable {
    let needsRefresh: (String) -> Bool
    let markRefreshed: (String) -> Void

    static func defaultsKey(service: String, key: String) -> String {
        "firebase-auth.legacy-acl-refresh-v1.\(service).\(key)"
    }

    static func userDefaults(
        service: String,
        defaults: UserDefaults = .standard
    ) -> KeychainAuthLegacyRefreshMarker {
        KeychainAuthLegacyRefreshMarker(
            needsRefresh: { key in
                !defaults.bool(forKey: defaultsKey(service: service, key: key))
            },
            markRefreshed: { key in
                defaults.set(true, forKey: defaultsKey(service: service, key: key))
            }
        )
    }

    /// No refresh ever — for stores whose tests pin unrelated invariants.
    static let disabled = KeychainAuthLegacyRefreshMarker(
        needsRefresh: { _ in false },
        markRefreshed: { _ in }
    )
}

final class KeychainAuthSecureStore: AuthSecureStoring, @unchecked Sendable {
    private let service: String
    private let interactionPolicy: KeychainAuthInteractionPolicy
    private let securityOperations: KeychainAuthSecurityOperations
    private let legacyRefreshMarker: KeychainAuthLegacyRefreshMarker
    /// Reentrancy latch: the refresh's failure fallback goes back through the
    /// ordinary write path, which must not restart the refresh it came from.
    private var legacyRefreshInFlight = false
    /// The data-protection keychain needs an application-identifier
    /// entitlement on macOS; a build signed without one gets
    /// errSecMissingEntitlement on EVERY operation — which shipped as
    /// "sign-in doesn't work" in 0.1.109. Once the modern keychain refuses,
    /// this store falls back to the legacy keychain for the process; builds
    /// that do carry the entitlement keep the modern, never-prompting path.
    private let fallbackState = KeychainAuthFallbackState()
    /// One authentication context per store, allocated lazily — building one
    /// per QUERY exhausted iOS's per-process LAContext allocation cap under
    /// the companion test suite (the fallback/migration paths issue several
    /// queries per operation), crashing with "exceeded number of allocated
    /// contexts". The context carries no per-operation state, so sharing is
    /// semantically identical.
    private let authenticationContextLock = NSLock()
    private var cachedAuthenticationContext: LAContext?

    private func authenticationContext() -> LAContext {
        authenticationContextLock.lock()
        defer { authenticationContextLock.unlock() }
        if let cachedAuthenticationContext { return cachedAuthenticationContext }
        let context = interactionPolicy.makeAuthenticationContext()
        cachedAuthenticationContext = context
        return context
    }

    /// Stable signed-product namespace. Passing the bundle identifier in tests
    /// makes the identity contract observable without touching the Keychain.
    static func defaultService(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        "\(bundleIdentifier ?? "com.kaisola.companion").firebase-auth"
    }

    init(
        service: String = KeychainAuthSecureStore.defaultService(),
        interactionPolicy: KeychainAuthInteractionPolicy = .allowUserInteraction,
        securityOperations: KeychainAuthSecurityOperations = .live,
        legacyRefreshMarker: KeychainAuthLegacyRefreshMarker? = nil
    ) {
        self.service = service
        self.interactionPolicy = interactionPolicy
        self.securityOperations = securityOperations
        self.legacyRefreshMarker = legacyRefreshMarker
            ?? .userDefaults(service: service)
    }

    func data(for key: String) throws -> Data? {
        var mode = fallbackState.queryMode
        while true {
            var query = baseQuery(for: key, mode: mode)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = securityOperations.copyMatching(query as CFDictionary, &result)
            if status == errSecMissingEntitlement {
                guard let retryMode = fallbackState.retryMode(
                    afterMissingEntitlementIn: mode
                ) else {
                    throw KeychainStoreError(status: status)
                }
                mode = retryMode
                continue
            }
            if status == errSecItemNotFound {
                guard mode == .dataProtection else { return nil }
                return try migrateLegacyItemIfPresent(for: key)
            }
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainStoreError(status: status)
            }
            if mode == .legacy { refreshLegacyItemIfNeeded(for: key, data: data) }
            return data
        }
    }

    /// One-time rescue of an item written by an older build into the legacy
    /// file-based keychain. Legacy items gate access on an ACL bound to the
    /// exact code signature, and Kaisola re-signs itself on every update — the
    /// source of the endless "Kaisola wants to access …" prompts. Reading the
    /// legacy item may prompt ONE last time; the copy then lives in the
    /// data-protection keychain, where access is granted by the app's signed
    /// identity and never prompts again.
    ///
    /// The legacy original is deleted ONLY when the rewrite provably landed
    /// in the data-protection keychain. `write` can fall back to the legacy
    /// keychain mid-call (an unentitled build's normal path), and the old
    /// unconditional delete then removed the very item the write had just
    /// refreshed — the user granted the prompt, was signed in for one
    /// session, and woke up signed out. That was the recurring
    /// sign-out-after-update.
    private func migrateLegacyItemIfPresent(for key: String) throws -> Data? {
        var legacy = legacyQuery(for: key)
        legacy[kSecReturnData as String] = true
        legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = securityOperations.copyMatching(legacy as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let landedIn = try write(data, for: key)
        if landedIn == .dataProtection {
            _ = securityOperations.delete(legacyQuery(for: key) as CFDictionary)
        }
        return data
    }

    func set(_ data: Data, for key: String) throws {
        _ = try write(data, for: key)
    }

    /// The write, reporting which keychain actually took it — the migration
    /// path's delete decision depends on that answer.
    @discardableResult
    private func write(_ data: Data, for key: String) throws -> KeychainAuthQueryMode {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var mode = fallbackState.queryMode
        while true {
            let query = baseQuery(for: key, mode: mode)
            let updateStatus = securityOperations.update(
                query as CFDictionary,
                attributes as CFDictionary
            )
            if updateStatus == errSecSuccess {
                // The update rewrote the VALUE but kept the item's original
                // creator ACL/partition. If that creator was a pre-Developer-ID
                // binary, refresh the item's protection once so this and every
                // later build reads it silently.
                if mode == .legacy { refreshLegacyItemIfNeeded(for: key, data: data) }
                return mode
            }
            if updateStatus == errSecMissingEntitlement {
                guard let retryMode = fallbackState.retryMode(
                    afterMissingEntitlementIn: mode
                ) else {
                    throw KeychainStoreError(status: updateStatus)
                }
                mode = retryMode
                continue
            }
            guard updateStatus == errSecItemNotFound else {
                throw KeychainStoreError(status: updateStatus)
            }

            var addQuery = query
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = securityOperations.add(addQuery as CFDictionary, nil)
            if addStatus == errSecMissingEntitlement {
                guard let retryMode = fallbackState.retryMode(
                    afterMissingEntitlementIn: mode
                ) else {
                    throw KeychainStoreError(status: addStatus)
                }
                mode = retryMode
                continue
            }
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError(status: addStatus)
            }
            // A fresh legacy add is already owned by the current app's stable
            // signed identity; nothing is left to refresh for this key.
            if mode == .legacy { legacyRefreshMarker.markRefreshed(key) }
            return mode
        }
    }

    /// One-time protection refresh for a legacy item this process can read.
    ///
    /// `SecItemUpdate` can never fix a stale ACL — only re-creation records the
    /// current app as the item's creator. The value is held in memory across
    /// the delete + add, and the marker is set only when the re-add provably
    /// landed, so a failure leaves the next launch to retry rather than losing
    /// the only copy of the credential. Best-effort by design: the caller's
    /// read or write has already succeeded and must not fail retroactively.
    /// Headless stores (`failIfInteractionRequired`) never mutate items they
    /// were only asked to observe.
    private func refreshLegacyItemIfNeeded(for key: String, data: Data) {
        guard interactionPolicy == .allowUserInteraction,
              legacyRefreshMarker.needsRefresh(key),
              !legacyRefreshInFlight else { return }
        legacyRefreshInFlight = true
        defer { legacyRefreshInFlight = false }
        let deleteStatus = securityOperations.delete(legacyQuery(for: key) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { return }
        var addQuery = legacyQuery(for: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = securityOperations.add(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            legacyRefreshMarker.markRefreshed(key)
        } else {
            // Put the credential back through the ordinary write path so the
            // deleted original cannot become a silent sign-out; the marker
            // stays unset so a later launch retries the refresh.
            try? set(data, for: key)
        }
    }

    func removeData(for key: String) throws {
        var mode = fallbackState.queryMode
        while true {
            let status = securityOperations.delete(
                baseQuery(for: key, mode: mode) as CFDictionary
            )
            if status == errSecMissingEntitlement {
                guard let retryMode = fallbackState.retryMode(
                    afterMissingEntitlementIn: mode
                ) else {
                    throw KeychainStoreError(status: status)
                }
                mode = retryMode
                continue
            }
            // Sweep any stale legacy copy too, so sign-out removes both worlds.
            _ = securityOperations.delete(legacyQuery(for: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError(status: status)
            }
            return
        }
    }

    private func baseQuery(
        for key: String,
        mode: KeychainAuthQueryMode
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseAuthenticationContext as String: authenticationContext(),
        ]
        // The data-protection keychain grants access by signed identity, not
        // by a per-binary ACL — the fix for the per-update re-prompt. It
        // requires the application-identifier entitlement; a build without it
        // trips the errSecMissingEntitlement fallback above and stays legacy.
        if mode == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// The pre-migration item's home: identical query minus the
    /// data-protection flag, addressing the legacy file-based keychain.
    private func legacyQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseAuthenticationContext as String: authenticationContext(),
        ]
    }
}

private struct KeychainStoreError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Kaisola could not access the saved sign-in: \(detail)."
    }
}

actor AuthSessionVault {
    private enum Key {
        static let refreshToken = "firebase-refresh-token"
        static let account = "firebase-account"
    }

    private let store: any AuthSecureStoring

    init(store: any AuthSecureStoring) {
        self.store = store
    }

    func save(refreshToken: String, account: AuthAccount) throws {
        guard !refreshToken.isEmpty else { throw FirebaseAuthError.incompleteSignIn }
        let accountData = try JSONEncoder().encode(account)
        try store.set(accountData, for: Key.account)
        do {
            try store.set(Data(refreshToken.utf8), for: Key.refreshToken)
        } catch {
            try? store.removeData(for: Key.account)
            throw error
        }
    }

    func updateRefreshToken(_ refreshToken: String) throws {
        guard !refreshToken.isEmpty else { throw FirebaseAuthError.incompleteRefresh }
        try store.set(Data(refreshToken.utf8), for: Key.refreshToken)
    }

    func refreshToken() throws -> String? {
        guard let data = try store.data(for: Key.refreshToken) else { return nil }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw FirebaseAuthError.invalidSavedSession
        }
        return value
    }

    func account() throws -> AuthAccount? {
        guard let data = try store.data(for: Key.account) else { return nil }
        do {
            return try JSONDecoder().decode(AuthAccount.self, from: data)
        } catch {
            throw FirebaseAuthError.invalidSavedSession
        }
    }

    func clear() throws {
        var firstError: Error?
        do { try store.removeData(for: Key.refreshToken) } catch { firstError = error }
        do { try store.removeData(for: Key.account) } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }
}

protocol AuthHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAuthHTTPClient: AuthHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FirebaseAuthError.invalidServerResponse
        }
        return (data, httpResponse)
    }
}

@MainActor
final class FirebaseAuthBackend: AuthBackend {
    // Firebase requires an https continueUri on an authorized domain
    // (PROJECT.web.app is auto-authorized). Google redirects here after sign-in;
    // the hosted page at hosting/companion-auth.html bounces the OAuth result to
    // `callbackURI`, which ASWebAuthenticationSession intercepts.
    private static let continueURI = URL(string: "https://kaisola-a9ab7.web.app/companion-auth")!
    private static let callbackURI = URL(string: "kaisola://auth")!
    private static let terminalRefreshErrors: Set<String> = [
        "INVALID_REFRESH_TOKEN",
        "TOKEN_EXPIRED",
        "USER_DISABLED",
        "USER_NOT_FOUND",
        "INVALID_GRANT",
    ]

    private let configurationResult: Result<FirebaseAuthConfiguration, Error>
    private let vault: AuthSessionVault
    private let httpClient: any AuthHTTPClient
    private let presentationContext = AuthWebPresentationContext()
    private var webAuthenticationSession: ASWebAuthenticationSession?

    init(
        bundle: Bundle = .main,
        secureStore: any AuthSecureStoring = KeychainAuthSecureStore(),
        httpClient: any AuthHTTPClient = URLSessionAuthHTTPClient()
    ) {
        configurationResult = Result { try FirebaseAuthConfiguration.load(from: bundle) }
        vault = AuthSessionVault(store: secureStore)
        self.httpClient = httpClient
    }

    init(
        configuration: FirebaseAuthConfiguration,
        secureStore: any AuthSecureStoring,
        httpClient: any AuthHTTPClient = URLSessionAuthHTTPClient()
    ) {
        configurationResult = .success(configuration)
        vault = AuthSessionVault(store: secureStore)
        self.httpClient = httpClient
    }

    func restore() async throws -> AuthAccount? {
        guard let refreshToken = try await vault.refreshToken() else {
            if try await vault.account() != nil { try await vault.clear() }
            return nil
        }
        let cachedAccount = try await vault.account()
        let configuration = try resolvedConfiguration()

        let refreshed: SecureTokenResponse
        do {
            refreshed = try await refresh(refreshToken, configuration: configuration)
        } catch let error as FirebaseAuthError where error.isTerminalRefreshFailure {
            try? await vault.clear()
            return nil
        } catch {
            // A transient refresh failure (network blip, 5xx) must NOT log the
            // user out — mirror the desktop and keep the cached identity. The
            // Keychain is untouched, so the next launch retries cleanly.
            if Task.isCancelled { throw CancellationError() }
            if let cachedAccount { return cachedAccount }
            throw error
        }

        try await vault.updateRefreshToken(refreshed.refreshToken ?? refreshToken)
        let claims = Self.decodeClaims(from: refreshed.idToken)

        // The token and the profile blob are two keychain items with
        // independent fates. A refresh token that just proved itself must
        // never be destroyed because the *profile cache* is unreadable — the
        // fresh ID token names the account, so rebuild the profile from its
        // claims and carry on. Only a token that cannot say who it is gives
        // the session up.
        let knownAccount: AuthAccount
        if let cachedAccount {
            knownAccount = cachedAccount
        } else if let uid = claims?.userID, let derived = try? Self.makeAccount(
            uid: uid,
            email: claims?.email,
            displayName: claims?.name,
            photoURL: claims?.picture.flatMap(Self.safeAvatarURL)
        ) {
            try await vault.save(
                refreshToken: refreshed.refreshToken ?? refreshToken,
                account: derived
            )
            knownAccount = derived
        } else {
            try await vault.clear()
            return nil
        }

        // Desktop treats server re-verification as best-effort during restore:
        // a fresh Firebase token still restores the cached identity if the
        // Cloud Function is temporarily unavailable.
        do {
            let verifiedUser = try await verifyServerSession(
                idToken: refreshed.idToken,
                configuration: configuration
            )
            let verifiedAccount = try Self.makeAccount(
                uid: verifiedUser.uid,
                email: verifiedUser.email ?? claims?.email ?? knownAccount.email,
                displayName: verifiedUser.name ?? claims?.name ?? knownAccount.displayName,
                photoURL: claims?.picture.flatMap(Self.safeAvatarURL) ?? knownAccount.avatarURL
            )
            try await vault.save(
                refreshToken: refreshed.refreshToken ?? refreshToken,
                account: verifiedAccount
            )
            return verifiedAccount
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return knownAccount
        }
    }

    func signInWithGoogle() async throws -> AuthAccount {
        let configuration = try resolvedConfiguration()
        let context = Self.randomContext()
        let authSession = try await createAuthURI(configuration: configuration, context: context)
        let callbackURL = try await openAuthenticationSession(at: authSession.authURL)
        let callback = try FirebaseAuthCallback.parse(
            callbackURL,
            expectedCallback: Self.callbackURI,
            continueURI: Self.continueURI
        )
        let firebaseSession = try await signInWithIdentityProvider(
            callback: callback,
            sessionId: authSession.sessionId,
            context: context,
            configuration: configuration
        )
        guard firebaseSession.context == context else {
            throw FirebaseAuthError.mismatchedSession
        }

        let verifiedUser = try await verifyServerSession(
            idToken: firebaseSession.idToken,
            configuration: configuration
        )
        let claims = Self.decodeClaims(from: firebaseSession.idToken)
        let account = try Self.makeAccount(
            uid: verifiedUser.uid.isEmpty ? firebaseSession.localId : verifiedUser.uid,
            email: verifiedUser.email ?? firebaseSession.email ?? claims?.email,
            displayName: verifiedUser.name ?? firebaseSession.displayName ?? claims?.name,
            photoURL: Self.safeAvatarURL(firebaseSession.photoURL)
                ?? claims?.picture.flatMap(Self.safeAvatarURL)
        )
        try await vault.save(refreshToken: firebaseSession.refreshToken, account: account)
        return account
    }

    func freshIDToken() async throws -> String {
        guard let refreshToken = try await vault.refreshToken() else {
            throw FirebaseAuthError.invalidSavedSession
        }
        let configuration = try resolvedConfiguration()
        do {
            let refreshed = try await refresh(refreshToken, configuration: configuration)
            try await vault.updateRefreshToken(refreshed.refreshToken ?? refreshToken)
            return refreshed.idToken
        } catch let error as FirebaseAuthError where error.isTerminalRefreshFailure {
            try? await vault.clear()
            throw error
        }
    }

    func signOut() async {
        webAuthenticationSession?.cancel()
        webAuthenticationSession = nil
        try? await vault.clear()
    }

    private func resolvedConfiguration() throws -> FirebaseAuthConfiguration {
        try configurationResult.get()
    }

    private func createAuthURI(
        configuration: FirebaseAuthConfiguration,
        context: String
    ) async throws -> FirebaseAuthURI {
        let endpoint = try Self.endpoint(
            "https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri",
            apiKey: configuration.apiKey
        )
        let body = CreateAuthURIRequest(
            providerId: "google.com",
            continueUri: Self.continueURI.absoluteString,
            oauthScope: "openid email profile",
            authFlowType: "CODE_FLOW",
            context: context
        )
        let response: CreateAuthURIResponse = try await postJSON(
            endpoint,
            body: body,
            stage: "Starting Google sign-in"
        )
        guard let authURL = URL(string: response.authUri),
              authURL.scheme?.lowercased() == "https",
              authURL.host?.lowercased() == "accounts.google.com",
              !response.sessionId.isEmpty,
              response.sessionId.utf8.count <= 4_096 else {
            throw FirebaseAuthError.invalidGoogleSession
        }
        return FirebaseAuthURI(authURL: authURL, sessionId: response.sessionId)
    }

    private func signInWithIdentityProvider(
        callback: FirebaseAuthCallback,
        sessionId: String,
        context: String,
        configuration: FirebaseAuthConfiguration
    ) async throws -> IdentityProviderSession {
        let endpoint = try Self.endpoint(
            "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp",
            apiKey: configuration.apiKey
        )
        let request = SignInWithIdentityProviderRequest(
            postBody: callback.postBody,
            requestUri: callback.requestURI,
            sessionId: sessionId,
            returnIdpCredential: true,
            returnSecureToken: true
        )
        let response: IdentityProviderSession = try await postJSON(
            endpoint,
            body: request,
            stage: "Completing Google sign-in"
        )
        guard !response.idToken.isEmpty,
              !response.refreshToken.isEmpty,
              !response.localId.isEmpty else {
            throw FirebaseAuthError.incompleteSignIn
        }
        if response.context != context {
            throw FirebaseAuthError.mismatchedSession
        }
        return response
    }

    private func refresh(
        _ refreshToken: String,
        configuration: FirebaseAuthConfiguration
    ) async throws -> SecureTokenResponse {
        let endpoint = try Self.endpoint(
            "https://securetoken.googleapis.com/v1/token",
            apiKey: configuration.apiKey
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            "grant_type=refresh_token&refresh_token=\(Self.formEncode(refreshToken))".utf8
        )
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let code = Self.firebaseErrorCode(from: data)
            throw FirebaseAuthError.refreshRejected(
                code: code,
                terminal: Self.terminalRefreshErrors.contains(code)
            )
        }
        guard let refreshed = try? JSONDecoder().decode(SecureTokenResponse.self, from: data),
              !refreshed.idToken.isEmpty else {
            throw FirebaseAuthError.incompleteRefresh
        }
        return refreshed
    }

    private func verifyServerSession(
        idToken: String,
        configuration: FirebaseAuthConfiguration
    ) async throws -> ServerUser {
        var request = URLRequest(url: configuration.serverURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await httpClient.data(for: request)
        let payload = try? JSONDecoder().decode(ServerSessionResponse.self, from: data)
        guard (200..<300).contains(response.statusCode),
              payload?.ok == true,
              let user = payload?.user,
              !user.uid.isEmpty else {
            throw FirebaseAuthError.serverVerification(
                payload?.message ?? "Kaisola's login server could not verify this session (\(response.statusCode))."
            )
        }
        return user
    }

    private func postJSON<Request: Encodable, Response: Decodable>(
        _ endpoint: URL,
        body: Request,
        stage: String
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw FirebaseAuthError.firebaseAPI(
                stage: stage,
                code: Self.firebaseErrorCode(from: data),
                status: response.statusCode
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw FirebaseAuthError.invalidServerResponse
        }
    }

    private func openAuthenticationSession(at authURL: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: Self.callbackURI.scheme
                ) { @Sendable [weak self] callbackURL, error in
                    // AuthenticationServices invokes this ObjC completion on
                    // its XPC callback queue. Without an explicitly Sendable
                    // closure Swift inherits FirebaseAuthBackend's MainActor
                    // isolation and traps before the body can perform its hop.
                    Task { @MainActor in
                        self?.webAuthenticationSession = nil
                        if let sessionError = error as? ASWebAuthenticationSessionError,
                           sessionError.code == .canceledLogin {
                            continuation.resume(throwing: CancellationError())
                        } else if let error {
                            continuation.resume(throwing: error)
                        } else if let callbackURL {
                            continuation.resume(returning: callbackURL)
                        } else {
                            continuation.resume(throwing: FirebaseAuthError.invalidCallback)
                        }
                    }
                }
                session.presentationContextProvider = presentationContext
                session.prefersEphemeralWebBrowserSession = true
                webAuthenticationSession = session
                guard session.start() else {
                    webAuthenticationSession = nil
                    continuation.resume(throwing: FirebaseAuthError.browserUnavailable)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.webAuthenticationSession?.cancel()
                self?.webAuthenticationSession = nil
            }
        }
    }

    private static func endpoint(_ string: String, apiKey: String) throws -> URL {
        guard var components = URLComponents(string: string) else {
            throw FirebaseAuthError.invalidConfiguration
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw FirebaseAuthError.invalidConfiguration }
        return url
    }

    private static func randomContext() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { bytes in
            Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    private static func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func firebaseErrorCode(from data: Data) -> String {
        guard let envelope = try? JSONDecoder().decode(FirebaseErrorEnvelope.self, from: data) else {
            return ""
        }
        return (envelope.error.message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == ":" })
            .first
            .map(String.init) ?? ""
    }

    private static func makeAccount(
        uid: String,
        email: String?,
        displayName: String?,
        photoURL: URL?
    ) throws -> AuthAccount {
        let cleanUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanUID.isEmpty, !cleanEmail.isEmpty else {
            throw FirebaseAuthError.incompleteSignIn
        }
        let cleanName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AuthAccount(
            uid: cleanUID,
            email: cleanEmail,
            displayName: cleanName?.isEmpty == false ? cleanName : nil,
            avatarURL: photoURL
        )
    }

    private static func safeAvatarURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 2_000,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private static func decodeClaims(from idToken: String) -> FirebaseIDTokenClaims? {
        let pieces = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(FirebaseIDTokenClaims.self, from: data)
    }
}

@MainActor
private final class AuthWebPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        if let visibleWindow = scenes.flatMap(\.windows).first(where: { !$0.isHidden }) {
            return visibleWindow
        }
        return ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
            ?? ASPresentationAnchor()
        #endif
    }
}

private struct FirebaseAuthURI {
    let authURL: URL
    let sessionId: String
}

private struct CreateAuthURIRequest: Encodable {
    let providerId: String
    let continueUri: String
    let oauthScope: String
    let authFlowType: String
    let context: String
}

private struct CreateAuthURIResponse: Decodable {
    let authUri: String
    let sessionId: String
}

private struct SignInWithIdentityProviderRequest: Encodable {
    let postBody: String
    let requestUri: String
    let sessionId: String
    let returnIdpCredential: Bool
    let returnSecureToken: Bool
}

private struct IdentityProviderSession: Decodable {
    let idToken: String
    let refreshToken: String
    let localId: String
    let email: String?
    let displayName: String?
    let photoURL: String?
    let context: String?

    private enum CodingKeys: String, CodingKey {
        case idToken
        case refreshToken
        case localId
        case email
        case displayName
        case photoURL = "photoUrl"
        case context
    }
}

private struct SecureTokenResponse: Decodable {
    let idToken: String
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case refreshToken = "refresh_token"
    }
}

private struct ServerSessionResponse: Decodable {
    let ok: Bool
    let user: ServerUser?
    let message: String?
}

private struct ServerUser: Decodable {
    let uid: String
    let email: String?
    let name: String?
}

private struct FirebaseIDTokenClaims: Decodable {
    let email: String?
    let name: String?
    let picture: String?
    /// Firebase's stable uid claim, so a session can be restored even when
    /// the cached profile blob is gone: the token itself says who it is.
    let userID: String?

    private enum CodingKeys: String, CodingKey {
        case email
        case name
        case picture
        case userID = "user_id"
    }
}

private struct FirebaseErrorEnvelope: Decodable {
    let error: FirebaseErrorDetail
}

private struct FirebaseErrorDetail: Decodable {
    let message: String?
}

enum FirebaseAuthError: LocalizedError {
    case missingConfiguration
    case invalidConfiguration
    case invalidCallback
    case googleSignIn(String)
    case browserUnavailable
    case invalidGoogleSession
    case mismatchedSession
    case incompleteSignIn
    case incompleteRefresh
    case invalidSavedSession
    case invalidServerResponse
    case firebaseAPI(stage: String, code: String, status: Int)
    case refreshRejected(code: String, terminal: Bool)
    case serverVerification(String)

    var isTerminalRefreshFailure: Bool {
        if case let .refreshRejected(_, terminal) = self { return terminal }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .missingConfiguration, .invalidConfiguration:
            return "This build is missing its Firebase public configuration."
        case .invalidCallback:
            return "Google returned an invalid sign-in callback."
        case let .googleSignIn(code):
            return "Google sign-in failed: \(code)."
        case .browserUnavailable:
            return "Kaisola could not open the secure Google sign-in page."
        case .invalidGoogleSession:
            return "Firebase returned an invalid Google sign-in session."
        case .mismatchedSession:
            return "Firebase returned a sign-in response for a different session."
        case .incompleteSignIn:
            return "Google returned an incomplete sign-in."
        case .incompleteRefresh:
            return "Google returned an incomplete session refresh. Kaisola kept the saved sign-in."
        case .invalidSavedSession:
            return "The saved Firebase session is unavailable."
        case .invalidServerResponse:
            return "The sign-in service returned an invalid response."
        case let .firebaseAPI(stage, code, status):
            switch code {
            case "OPERATION_NOT_ALLOWED":
                return "Google sign-in is not enabled for this Firebase project."
            case "INVALID_IDP_RESPONSE", "INVALID_PENDING_TOKEN":
                return "Google returned a sign-in response that Firebase could not verify."
            case "FEDERATED_USER_ID_ALREADY_LINKED":
                return "This Google account is already linked to another Kaisola account."
            default:
                let detail = code.isEmpty
                    ? " (\(status))"
                    : ": \(code.replacingOccurrences(of: "_", with: " ").lowercased())"
                return "\(stage) failed\(detail)."
            }
        case let .refreshRejected(_, terminal):
            return terminal
                ? "The saved Firebase session has expired. Sign in again."
                : "Kaisola could not refresh Google sign-in right now."
        case let .serverVerification(message):
            return message
        }
    }
}
