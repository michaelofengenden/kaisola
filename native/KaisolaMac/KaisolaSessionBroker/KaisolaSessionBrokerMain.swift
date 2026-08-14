import Darwin
import Dispatch
import Foundation
import KaisolaSessionBrokerCore

@main
enum KaisolaSessionBrokerMain {
    static func main() async {
        // This is the only accepted PTY-child argv shape. Its launch payload
        // arrives through inherited private descriptors, so commands,
        // environment values, and working directories never become broker
        // process arguments. An ordinary invocation cannot enter this path.
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "--pty-child" {
            DarwinPTYChild.run()
        }

        // Arm termination before configuration I/O or socket preparation. A
        // signal received in either phase remains buffered until the server
        // exists, at which point the shutdown task stops it normally.
        let terminationSignals = TerminationSignalMonitor()
        if ProcessInfo.processInfo.environment["KAISOLA_SWIFT_BROKER_TEST_SIGNAL_READY"] == "1" {
            FileHandle.standardOutput.write(Data("signal-ready\n".utf8))
        }
        defer { terminationSignals.cancel() }

        do {
            let configuration = try ShadowBrokerConfiguration.load()
            let server = try BrokerServer(configuration: configuration)
            let shutdownTask = Task {
                await terminationSignals.wait()
                guard !Task.isCancelled else { return }
                await server.stop()
            }
            defer { shutdownTask.cancel() }
            try await server.run()
        } catch {
            let message = "kaisola-session-broker: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

/// Dispatch signal sources turn process termination into an orderly server
/// stop. `BrokerServer.run()` then performs its normal listener/socket cleanup
/// before the executable exits.
private final class TerminationSignalMonitor: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let sources: [DispatchSourceSignal]

    init() {
        _ = Darwin.signal(SIGTERM, SIG_IGN)
        _ = Darwin.signal(SIGINT, SIG_IGN)

        let streamPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = streamPair.stream
        continuation = streamPair.continuation

        let sourceQueue = DispatchQueue(label: "com.kaisola.session-broker.signals")
        sources = [SIGTERM, SIGINT].map {
            DispatchSource.makeSignalSource(signal: $0, queue: sourceQueue)
        }
        let continuation = streamPair.continuation
        for source in sources {
            source.setEventHandler {
                continuation.yield(())
                continuation.finish()
            }
            source.activate()
        }
    }

    func wait() async {
        for await _ in stream { return }
    }

    func cancel() {
        continuation.finish()
        sources.forEach { $0.cancel() }
    }
}
