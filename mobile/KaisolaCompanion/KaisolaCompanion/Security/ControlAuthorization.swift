import KaisolaCore
import Foundation
import LocalAuthentication

enum CompanionControlAuthorizationError: LocalizedError {
    case unavailable
    case denied

    var errorDescription: String? {
        switch self {
        case .unavailable: "Device authentication is required before remote control can be enabled."
        case .denied: "Kaisola control stayed locked. Authenticate and try again."
        }
    }
}

/// Keeps a short local unlock window. Desktop capability checks and terminal
/// leases still apply independently; this only gates entering control mode on
/// the physical iPhone.
@MainActor
final class CompanionControlAuthorization {
    private let validity: TimeInterval
    private var validUntil: Date?

    init(validity: TimeInterval = 5 * 60) {
        self.validity = validity
    }

    var isAuthorized: Bool {
        guard let validUntil else { return false }
        return validUntil > .now
    }

    func authorize(reason: String) async throws {
        if isAuthorized { return }
        let context = LAContext()
        context.localizedCancelTitle = "Keep read only"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw CompanionControlAuthorizationError.unavailable
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw CompanionControlAuthorizationError.denied
            }
            validUntil = Date.now.addingTimeInterval(validity)
        } catch {
            throw CompanionControlAuthorizationError.denied
        }
    }

    func lock() {
        validUntil = nil
    }
}
