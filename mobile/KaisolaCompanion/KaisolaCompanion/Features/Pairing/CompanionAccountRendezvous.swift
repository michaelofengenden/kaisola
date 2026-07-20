import Foundation

struct CompanionAccountOffer: Identifiable, Hashable, Sendable {
    var id: String { payload.pairingNonce }
    let desktopName: String
    let payload: CompanionPairingPayload
}

enum CompanionAccountRendezvousError: LocalizedError {
    case unavailable
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Account pairing isn't configured in this build."
        case let .rejected(message):
            return message.isEmpty ? "Account pairing is temporarily unavailable." : message
        case .invalidResponse:
            return "Account pairing returned an invalid response."
        }
    }
}

protocol CompanionAccountRendezvousServing: Sendable {
    func listOffers(idToken: String) async throws -> [CompanionAccountOffer]
}

struct CompanionAccountRendezvousService: CompanionAccountRendezvousServing, Sendable {
    private let configuration: FirebaseAuthConfiguration?
    private let httpClient: any AuthHTTPClient

    init(
        bundle: Bundle = .main,
        httpClient: any AuthHTTPClient = URLSessionAuthHTTPClient()
    ) {
        configuration = try? FirebaseAuthConfiguration.load(from: bundle)
        self.httpClient = httpClient
    }

    init(configuration: FirebaseAuthConfiguration, httpClient: any AuthHTTPClient) {
        self.configuration = configuration
        self.httpClient = httpClient
    }

    func listOffers(idToken: String) async throws -> [CompanionAccountOffer] {
        guard let configuration,
              let endpoint = Self.endpoint(from: configuration.serverURL),
              !idToken.isEmpty,
              idToken.utf8.count <= 20_000 else {
            throw CompanionAccountRendezvousError.unavailable
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action":"list"}"#.utf8)
        let (data, response) = try await httpClient.data(for: request)
        guard data.count <= 64 * 1_024 else { throw CompanionAccountRendezvousError.invalidResponse }
        let decoded = try? JSONDecoder().decode(Response.self, from: data)
        guard (200..<300).contains(response.statusCode), decoded?.ok == true else {
            throw CompanionAccountRendezvousError.rejected(decoded?.message ?? "")
        }
        return (decoded?.offers ?? []).prefix(8).map {
            CompanionAccountOffer(desktopName: Self.safeName($0.desktopName), payload: $0.payload)
        }
    }

    static func endpoint(from sessionURL: URL) -> URL? {
        guard sessionURL.scheme?.lowercased() == "https",
              sessionURL.host?.isEmpty == false,
              sessionURL.user == nil,
              sessionURL.password == nil,
              var components = URLComponents(url: sessionURL, resolvingAgainstBaseURL: false) else { return nil }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last == "session" { segments[segments.count - 1] = "companionRendezvous" }
        else { segments.append("companionRendezvous") }
        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func safeName(_ value: String) -> String {
        let clean = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Kaisola Mac" : String(clean.prefix(80))
    }

    private struct Response: Decodable {
        let ok: Bool
        let offers: [Offer]?
        let message: String?
    }

    private struct Offer: Decodable {
        let desktopName: String
        let payload: CompanionPairingPayload
    }
}
