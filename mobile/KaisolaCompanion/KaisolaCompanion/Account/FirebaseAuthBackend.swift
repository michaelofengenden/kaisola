import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct FirebaseAuthConfiguration: Equatable, Sendable {
    let projectId: String
    let apiKey: String
    let serverURL: URL

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
              serverURL.host?.isEmpty == false else {
            throw FirebaseAuthError.invalidConfiguration
        }
        return FirebaseAuthConfiguration(projectId: projectId, apiKey: apiKey, serverURL: serverURL)
    }

    private struct RawConfiguration: Decodable {
        let projectId: String
        let apiKey: String
        let serverURL: String

        private enum CodingKeys: String, CodingKey {
            case projectId
            case apiKey
            case serverURL = "serverUrl"
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

protocol AuthSecureStoring: AnyObject {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func removeData(for key: String) throws
}

final class KeychainAuthSecureStore: AuthSecureStoring {
    private let service: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "com.kaisola.companion").firebase-auth") {
        self.service = service
    }

    func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStoreError(status: status)
        }
        return data
    }

    func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError(status: updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError(status: addStatus)
        }
    }

    func removeData(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
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

struct AuthSessionVault {
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
        guard let refreshToken = try vault.refreshToken() else {
            if try vault.account() != nil { try vault.clear() }
            return nil
        }
        let cachedAccount = try vault.account()
        let configuration = try resolvedConfiguration()

        let refreshed: SecureTokenResponse
        do {
            refreshed = try await refresh(refreshToken, configuration: configuration)
        } catch let error as FirebaseAuthError where error.isTerminalRefreshFailure {
            try? vault.clear()
            return nil
        } catch {
            // A transient refresh failure (network blip, 5xx) must NOT log the
            // user out — mirror the desktop and keep the cached identity. The
            // Keychain is untouched, so the next launch retries cleanly.
            if Task.isCancelled { throw CancellationError() }
            if let cachedAccount { return cachedAccount }
            throw error
        }

        try vault.updateRefreshToken(refreshed.refreshToken ?? refreshToken)
        guard let cachedAccount else {
            try vault.clear()
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
            let claims = Self.decodeClaims(from: refreshed.idToken)
            let verifiedAccount = try Self.makeAccount(
                uid: verifiedUser.uid,
                email: verifiedUser.email ?? claims?.email ?? cachedAccount.email,
                displayName: verifiedUser.name ?? claims?.name ?? cachedAccount.displayName,
                photoURL: claims?.picture.flatMap(Self.safeAvatarURL) ?? cachedAccount.avatarURL
            )
            try vault.save(refreshToken: refreshed.refreshToken ?? refreshToken, account: verifiedAccount)
            return verifiedAccount
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return cachedAccount
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
        try vault.save(refreshToken: firebaseSession.refreshToken, account: account)
        return account
    }

    func freshIDToken() async throws -> String {
        guard let refreshToken = try vault.refreshToken() else {
            throw FirebaseAuthError.invalidSavedSession
        }
        let configuration = try resolvedConfiguration()
        do {
            let refreshed = try await refresh(refreshToken, configuration: configuration)
            try vault.updateRefreshToken(refreshed.refreshToken ?? refreshToken)
            return refreshed.idToken
        } catch let error as FirebaseAuthError where error.isTerminalRefreshFailure {
            try? vault.clear()
            throw error
        }
    }

    func signOut() async {
        webAuthenticationSession?.cancel()
        webAuthenticationSession = nil
        try? vault.clear()
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
                ) { [weak self] callbackURL, error in
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
