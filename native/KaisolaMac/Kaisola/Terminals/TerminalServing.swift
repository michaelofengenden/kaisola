import Foundation
import KaisolaCore

/// The seams the app's windows use to reach the terminal engine. These
/// protocols predate the in-process engine — they were the broker client
/// surface — and keep their shapes so test doubles and call sites carry over
/// unchanged. `InProcessTerminalService` is the production implementation of
/// all three.
protocol BrokerInfoPreparing: Sendable {
    func prepare() async throws -> BrokerInfo
}

enum BrokerDiscoveryError: Error, Equatable, Sendable {
    case notRunning
}

/// A preparer that can never produce a terminal engine. Fixture and
/// command-availability tests use it to hold a model in the not-connected
/// state and to prove an isolated fixture cannot reach real terminals.
struct BrokerFreeFixturePreparer: BrokerInfoPreparing {
    func prepare() async throws -> BrokerInfo {
        throw BrokerDiscoveryError.notRunning
    }
}

/// Adapts a locating seam to the preparing seam; reconnect tests drive the
/// connect path through scripted locators with this.
struct LocatedBrokerInfoPreparer: BrokerInfoPreparing {
    let locator: any BrokerInfoLocating

    func prepare() async throws -> BrokerInfo {
        try locator.locate()
    }
}

protocol ObserveOnlyBrokerServing: Sendable {
    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async
    func connect(to info: BrokerInfo) async throws -> BrokerHello
    func inventory() async throws -> BrokerStatus
    func inventoryActivityEpoch() async throws -> Int64?
    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult
    func historyPage(
        for terminal: BrokerTerminalRecord,
        ownerID: String,
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) async throws -> TerminalHistoryPage
    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws
    func subscribeBounded(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?,
        maximumSnapshotBytes: Int
    ) async throws -> TerminalSubscriptionResult
    func disconnect() async
}

extension ObserveOnlyBrokerServing {
    func inventoryActivityEpoch() async throws -> Int64? {
        try await inventory().activityEpoch
    }

    func subscribeBounded(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?,
        maximumSnapshotBytes: Int
    ) async throws -> TerminalSubscriptionResult {
        throw BrokerClientError.requestFailed("bounded terminal subscribe unavailable")
    }

    /// Test doubles remain source-compatible; the production engine performs
    /// the additive read-only history request.
    func historyPage(
        for terminal: BrokerTerminalRecord,
        ownerID: String,
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) async throws -> TerminalHistoryPage {
        throw BrokerClientError.requestFailed("terminal.history unavailable")
    }
}

enum TerminalWriteError: Error, Equatable, LocalizedError {
    case ended
    case missing

    var errorDescription: String? {
        switch self {
        case .ended: "This terminal has ended and cannot accept input."
        case .missing: "This terminal is no longer available."
        }
    }
}

struct TerminalCreation: Equatable, Sendable {
    let terminalID: String
    let projectID: String
    /// Nil for a cold record: a restore of a terminal that ended before the
    /// engine restart serves history without spawning a shell.
    let pid: Int32?
    /// True when create adopted a stable id that was already live. Stale
    /// callers must not compensate by releasing another window's terminal.
    var existed: Bool = false
    /// True when the create resolved to an ended terminal (cold record).
    var exited: Bool = false
    let streamEpoch: String?
    /// Cold scrollback captured from a retained spool when the spawn carried
    /// `restore: true`. Informational; the in-process engine has no outlived
    /// spool, so this is nil there.
    var recovered: TerminalRecoveredScrollback?
}

struct TerminalRecoveredScrollback: Equatable, Sendable {
    let text: String
    let truncated: Bool
}

/// A terminal release is complete both when the engine acknowledges the
/// idempotent request and when the terminal provably no longer exists.
/// Transport/identity errors throw and remain retryable instead of being
/// confused with either safe outcome.
enum BrokerTerminalReleaseDisposition: Equatable, Sendable {
    case released
    case terminalAbsent
    case generationAbsent
}

protocol BrokerControlServing: Sendable {
    var connectionInstanceID: String { get }
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async
    func connect(to info: BrokerInfo, ownerID: String) async throws
    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int,
        restore: Bool
    ) async throws -> TerminalCreation
    func attach(projectID: String, terminalID: String) async throws
    func write(projectID: String, terminalID: String, data: String) async throws
    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws
    func kill(projectID: String, terminalID: String) async throws
    func release(projectID: String, terminalID: String) async throws
    func release(
        projectID: String,
        terminalID: String,
        brokerGenerationID: String?
    ) async throws -> BrokerTerminalReleaseDisposition
    func detachOwner(projectID: String, terminalID: String) async throws
    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws
    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws
    func disconnect() async
}

extension BrokerControlServing {
    var connectionInstanceID: String { "" }

    /// Source compatibility for callers and doubles that predate resurrection.
    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int
    ) async throws -> TerminalCreation {
        try await createTerminal(
            projectID: projectID,
            terminalID: terminalID,
            command: command,
            arguments: arguments,
            cwd: cwd,
            columns: columns,
            rows: rows,
            restore: false
        )
    }

    /// Focused test doubles stay source-compatible. The production engine
    /// reports a lane-only disconnect so AppModel can stop accepting writes
    /// and reattach ownership.
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {}

    /// Focused doubles need no routing metadata: their ordinary idempotent
    /// release is an acknowledgement.
    func release(
        projectID: String,
        terminalID: String,
        brokerGenerationID: String?
    ) async throws -> BrokerTerminalReleaseDisposition {
        try await release(projectID: projectID, terminalID: terminalID)
        return .released
    }
}
