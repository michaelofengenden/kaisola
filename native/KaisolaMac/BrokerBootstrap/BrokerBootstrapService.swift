import Darwin
import Foundation

final class BrokerBootstrapService: NSObject, BrokerBootstrapXPCProtocol {
    func launchBroker(
        configurationPath: String,
        withReply reply: @escaping (NSNumber?, NSString?) -> Void
    ) {
        do {
            let pid = try launchBroker(configurationPath: configurationPath)
            reply(NSNumber(value: pid), nil)
        } catch {
            reply(nil, (error as? LocalizedError)?.errorDescription as NSString? ?? "The broker helper refused the launch request.")
        }
    }

    func launchBroker(configurationPath: String) throws -> pid_t {
        let package = try verifiedPackage()
        let configurationURL = URL(fileURLWithPath: configurationPath).standardizedFileURL
        try validatePrivateConfiguration(configurationURL)
        let configuration: BrokerLaunchConfiguration
        do {
            configuration = try JSONDecoder().decode(
                BrokerLaunchConfiguration.self,
                from: Data(contentsOf: configurationURL, options: [.mappedIfSafe])
            )
        } catch {
            throw BrokerLaunchConfigurationError.invalidConfiguration
        }
        try configuration.validate(configurationURL: configurationURL)
        guard configuration.implementationVersion == package.manifest.brokerImplementationVersion,
              configuration.packageSchema == package.manifest.schemaVersion,
              configuration.packageVersion == package.manifest.packageVersion else {
            throw BrokerHelperPackageError.incompatibleManifest
        }

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        environment.removeValue(forKey: "KAISOLA_DEV_URL")
        environment.removeValue(forKey: "PASOLA_DEV_URL")
        environment["KAISOLA_SESSION_BROKER"] = "1"
        return try DetachedBrokerProcess.spawn(
            executable: package.nodeExecutable,
            arguments: [package.brokerScript.path, "--launch", configurationURL.path],
            environment: environment
        )
    }

    func verifiedPackage() throws -> VerifiedBrokerHelperPackage {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let packageRoot = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try BrokerHelperPackageVerification.verify(
            root: packageRoot,
            requireSignatures: ProcessInfo.processInfo.environment["KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER"] != "1"
        )
    }

    private func validatePrivateConfiguration(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_uid == getuid(),
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o077 == 0,
              value.st_size > 0,
              value.st_size <= 64 * 1_024 else {
            throw BrokerLaunchConfigurationError.unsafePermissions
        }
    }
}
