import Foundation

/// An opaque, stable account partition shared by the Mac and iPhone.
///
/// Firebase UIDs never enter pairing QR codes, roster filenames, or saved
/// desktop tickets. Both apps derive the same domain-separated digest locally
/// and bind that value into the authenticated Companion transcript.
public struct CompanionAccountScope: Hashable, Sendable, Codable {
    private static let domain = Data("kaisola-companion-account-scope-v1\0".utf8)

    public let rawValue: String

    public init(accountID: String) throws {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 512,
              accountID == accountID.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CompanionCryptoError.invalidIdentity("accountId")
        }
        rawValue = CompanionCrypto.sha256(
            Self.domain,
            Data(accountID.utf8)
        ).base64URLEncodedString()
    }

    public init(rawValue: String) throws {
        guard let decoded = Data(base64URLString: rawValue),
              decoded.count == 32,
              decoded.base64URLEncodedString() == rawValue else {
            throw CompanionCryptoError.invalidIdentity("accountScope")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
