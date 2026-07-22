import Foundation

let brokerBootstrapMachService = "com.kaisola.mac.preview.broker-bootstrap"
let brokerBootstrapPlistName = "com.kaisola.mac.preview.broker-bootstrap.plist"

@objc protocol BrokerBootstrapXPCProtocol {
    func launchBroker(
        configurationPath: String,
        withReply reply: @escaping (NSNumber?, NSString?) -> Void
    )
}
