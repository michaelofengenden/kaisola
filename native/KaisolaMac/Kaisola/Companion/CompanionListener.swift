import Foundation
import KaisolaCore
import Network

struct CompanionListenerAdvertisement: Equatable, Sendable {
    static let serviceType = "_kaisola._tcp"
    let instanceName: String
    let txtRecord: Data

    init(desktopID: String) throws {
        _ = try CompanionCrypto.validateIdentifier(desktopID, label: "desktopId")
        instanceName = "Kaisola-\(desktopID.suffix(16))"
        txtRecord = NetService.data(fromTXTRecord: [
            "v": Data("1".utf8),
            "id": Data(desktopID.utf8),
        ])
    }
}

@MainActor
final class CompanionListener: ObservableObject {
    enum State: Equatable {
        case disabled
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .disabled
    var onConnection: (@Sendable (NWConnection) -> Void)?

    private let queue = DispatchQueue(label: "com.kaisola.mac.companion-listener", qos: .userInitiated)
    private var listener: NWListener?

    func start(identity: CompanionIdentity) throws {
        guard listener == nil else { return }
        let advertisement = try CompanionListenerAdvertisement(desktopID: identity.id)
        state = .starting
        do {
            try startListener(port: 49_321, advertisement: advertisement, permitsFallback: true)
        } catch {
            state = .failed(Self.safeMessage(error))
            throw error
        }
    }

    func stop() {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        state = .disabled
    }

    private func startListener(
        port: UInt16?,
        advertisement: CompanionListenerAdvertisement,
        permitsFallback: Bool
    ) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.other]
        let candidate: NWListener
        if let port, let endpointPort = NWEndpoint.Port(rawValue: port) {
            candidate = try NWListener(using: parameters, on: endpointPort)
        } else {
            candidate = try NWListener(using: parameters)
        }
        var service = NWListener.Service(
            name: advertisement.instanceName,
            type: CompanionListenerAdvertisement.serviceType,
            domain: nil,
            txtRecord: advertisement.txtRecord
        )
        service.noAutoRename = true
        candidate.service = service
        candidate.newConnectionLimit = 8
        let connectionHandler = onConnection
        candidate.newConnectionHandler = { connection in
            guard let connectionHandler else {
                connection.cancel()
                return
            }
            connectionHandler(connection)
        }
        candidate.stateUpdateHandler = { [weak self, weak candidate] next in
            Task { @MainActor in
                guard let self, self.listener === candidate else { return }
                switch next {
                case .ready:
                    if let port = candidate?.port?.rawValue {
                        self.state = .ready(port: port)
                    } else {
                        self.state = .failed("Kaisola's Companion listener did not receive a port.")
                    }
                case let .failed(error):
                    candidate?.cancel()
                    self.listener = nil
                    if permitsFallback {
                        do {
                            try self.startListener(
                                port: nil,
                                advertisement: advertisement,
                                permitsFallback: false
                            )
                        } catch {
                            self.state = .failed(Self.safeMessage(error))
                        }
                    } else {
                        self.state = .failed(Self.safeMessage(error))
                    }
                case .cancelled:
                    if self.listener == nil { self.state = .disabled }
                default:
                    break
                }
            }
        }
        listener = candidate
        candidate.start(queue: queue)
    }

    private static func safeMessage(_ error: any Error) -> String {
        if let networkError = error as? NWError {
            return "Kaisola could not start Companion on the local network (\(networkError))."
        }
        return "Kaisola could not start Companion on the local network."
    }
}
