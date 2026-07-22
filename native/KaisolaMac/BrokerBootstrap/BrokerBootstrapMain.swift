import Darwin
import Foundation

private final class BrokerBootstrapListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = BrokerBootstrapService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: BrokerBootstrapXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

@main
enum BrokerBootstrapMain {
    static func main() {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--verify-package" {
            do {
                let package = try BrokerBootstrapService().verifiedPackage()
                print("BROKER_BOOTSTRAP_VERIFY=PASS package=\(package.manifest.packageVersion)")
                exit(0)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "The broker helper package is invalid."
                FileHandle.standardError.write(Data("BROKER_BOOTSTRAP_VERIFY=FAIL \(message)\n".utf8))
                exit(1)
            }
        }

        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--launch" {
            do {
                let pid = try BrokerBootstrapService().launchBroker(configurationPath: CommandLine.arguments[2])
                print("BROKER_BOOTSTRAP_PID=\(pid)")
                exit(0)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "The broker helper refused the launch request."
                FileHandle.standardError.write(Data("BROKER_BOOTSTRAP_ERROR=\(message)\n".utf8))
                exit(1)
            }
        }

        let delegate = BrokerBootstrapListenerDelegate()
        let listener = NSXPCListener(machServiceName: brokerBootstrapMachService)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
