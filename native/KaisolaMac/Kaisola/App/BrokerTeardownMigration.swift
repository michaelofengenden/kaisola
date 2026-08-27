import Darwin
import Foundation

/// One-shot cleanup for installs upgrading from the detached-broker era.
///
/// Older Kaisola versions kept terminals alive in a detached Node broker that
/// deliberately outlived the app. This build owns its PTYs in-process, so a
/// broker left running by the previous version would linger forever with live
/// shells nobody can reach, next to up to gigabytes of retained spool. Each
/// launch this sweeps the known profile roots: if broker metadata exists, the
/// recorded processes are verified by executable path and terminated, the
/// SMAppService bootstrap label is booted out, and the broker's state and
/// terminal cache directories are removed. Once clean, the metadata is gone
/// and every later launch is a two-stat no-op.
enum BrokerTeardownMigration {
    static let bootstrapLabel = "com.kaisola.mac.broker-bootstrap"
    /// Substrings that must appear in a recorded PID's executable path before
    /// this will signal it. PIDs recycle; a stale broker.json must never be
    /// able to aim a SIGKILL at an unrelated process.
    private static let brokerExecutableMarkers = [
        "BrokerHelper/bin/node",
        "kaisola-session-broker",
        "kaisola-broker-bootstrap",
    ]

    static func run(
        applicationSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    ) {
        for profile in ["Kaisola Native", "Kaisola Dev", "Kaisola", "Kaisola Preview"] {
            sweep(profileRoot: applicationSupport.appendingPathComponent(profile, isDirectory: true))
        }
    }

    private static func sweep(profileRoot: URL) {
        let brokerRoot = profileRoot.appendingPathComponent("session-broker", isDirectory: true)
        let terminalCache = profileRoot.appendingPathComponent("terminal-cache", isDirectory: true)
        let fileManager = FileManager.default
        let hasBrokerState = fileManager.fileExists(atPath: brokerRoot.path)
        let hasCache = fileManager.fileExists(atPath: terminalCache.path)
        guard hasBrokerState || hasCache else { return }

        if hasBrokerState {
            var pids: Set<pid_t> = []
            pids.formUnion(recordedPIDs(in: brokerRoot.appendingPathComponent("broker.json")))
            let generations = brokerRoot.appendingPathComponent("generations", isDirectory: true)
            if let entries = try? fileManager.contentsOfDirectory(
                at: generations,
                includingPropertiesForKeys: nil
            ) {
                for entry in entries where entry.pathExtension == "json" {
                    pids.formUnion(recordedPIDs(in: entry))
                }
            }
            for pid in pids { terminateVerifiedBroker(pid) }
            // The LaunchAgent pointed at a bundle path this build no longer
            // ships; an enabled registration would log launchd errors forever.
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "gui/\(getuid())/\(bootstrapLabel)"]
            try? bootout.run()
            bootout.waitUntilExit()
            try? fileManager.removeItem(at: brokerRoot)
        }
        if hasCache {
            try? fileManager.removeItem(at: terminalCache)
        }
    }

    private static func recordedPIDs(in file: URL) -> Set<pid_t> {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var pids: Set<pid_t> = []
        for key in ["pid", "bootstrapPid", "brokerPid"] {
            if let value = object[key] as? Int, let pid = pid_t(exactly: value), pid > 1 {
                pids.insert(pid)
            }
        }
        return pids
    }

    private static func terminateVerifiedBroker(_ pid: pid_t) {
        guard kill(pid, 0) == 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return }
        let executable = String(cString: buffer)
        guard brokerExecutableMarkers.contains(where: executable.contains) else { return }
        kill(pid, SIGTERM)
        // Give the broker its ordinary shutdown moment, then make sure.
        for _ in 0 ..< 20 where kill(pid, 0) == 0 {
            usleep(100_000)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
