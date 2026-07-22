import Foundation

struct NativeUpdateConfiguration: Equatable, Sendable {
    static let feedURLKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"

    let feedURL: URL
    let publicEDKey: String

    static func bundled(_ bundle: Bundle = .main) throws -> Self {
        try parse(bundle.infoDictionary ?? [:])
    }

    static func parse(_ info: [String: Any]) throws -> Self {
        guard let rawFeed = nonemptyString(info[feedURLKey]),
              let rawKey = nonemptyString(info[publicKeyKey]) else {
            throw NativeUpdateConfigurationError.notConfigured
        }
        guard let feedURL = URL(string: rawFeed),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil,
              feedURL.user == nil,
              feedURL.password == nil,
              feedURL.fragment == nil else {
            throw NativeUpdateConfigurationError.unsafeFeedURL
        }
        guard let keyData = Data(base64Encoded: rawKey), keyData.count == 32 else {
            throw NativeUpdateConfigurationError.invalidPublicKey
        }
        return Self(feedURL: feedURL, publicEDKey: rawKey)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum NativeUpdateConfigurationError: Error, Equatable, LocalizedError {
    case notConfigured
    case unsafeFeedURL
    case invalidPublicKey

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Native preview updates are not configured in this build."
        case .unsafeFeedURL:
            "The native preview update feed must be an HTTPS URL without credentials or a fragment."
        case .invalidPublicKey:
            "The native preview update signing key is invalid."
        }
    }
}
