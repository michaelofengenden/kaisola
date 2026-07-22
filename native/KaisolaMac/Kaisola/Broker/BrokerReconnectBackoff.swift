import Foundation

struct BrokerReconnectBackoff: Equatable, Sendable {
    let baseNanoseconds: UInt64
    let maximumNanoseconds: UInt64
    let jitterFraction: Double

    init(
        baseNanoseconds: UInt64 = 250_000_000,
        maximumNanoseconds: UInt64 = 8_000_000_000,
        jitterFraction: Double = 0.2
    ) {
        precondition(baseNanoseconds > 0)
        precondition(maximumNanoseconds >= baseNanoseconds)
        precondition((0...0.5).contains(jitterFraction))
        self.baseNanoseconds = baseNanoseconds
        self.maximumNanoseconds = maximumNanoseconds
        self.jitterFraction = jitterFraction
    }

    /// `jitterUnit` is deliberately injectable so the schedule can be tested
    /// without weakening the production jitter which prevents reconnect herds.
    func delayNanoseconds(forAttempt attempt: Int, jitterUnit: Double) -> UInt64 {
        let exponent = min(max(attempt, 0), 30)
        let scale = UInt64(1) << UInt64(exponent)
        let multiplied = baseNanoseconds.multipliedReportingOverflow(by: scale)
        let exponential = multiplied.overflow ? maximumNanoseconds : min(multiplied.partialValue, maximumNanoseconds)
        let boundedJitter = min(max(jitterUnit, -1), 1)
        let adjusted = Double(exponential) * (1 + boundedJitter * jitterFraction)
        return min(maximumNanoseconds, max(1, UInt64(adjusted.rounded())))
    }
}
