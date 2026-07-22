import Foundation
import Sparkle

@MainActor
final class NativeUpdateController: NSObject {
    enum Availability: Equatable {
        case ready
        case unavailable(String)

        var canCheck: Bool {
            if case .ready = self { return true }
            return false
        }

        var detail: String? {
            if case let .unavailable(message) = self { return message }
            return nil
        }
    }

    private(set) var availability: Availability
    private var standardController: SPUStandardUpdaterController?

    override convenience init() {
        self.init(bundle: .main)
    }

    init(bundle: Bundle) {
        do {
            _ = try NativeUpdateConfiguration.bundled(bundle)
            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            try controller.updater.start()
            standardController = controller
            availability = .ready
        } catch {
            standardController = nil
            availability = .unavailable(
                (error as? LocalizedError)?.errorDescription
                    ?? "The native preview updater could not start."
            )
        }
        super.init()
    }

    func checkForUpdates(_ sender: Any?) {
        guard availability.canCheck, let standardController else { return }
        standardController.checkForUpdates(sender)
    }
}
