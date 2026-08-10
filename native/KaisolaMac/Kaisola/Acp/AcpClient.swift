import Darwin
import Dispatch
import Foundation
import KaisolaBrokerProtocol
import KaisolaCore

/// Streaming events the chat surface consumes, decoded from ACP
/// `session/update` notifications and the agent's callbacks.
enum AcpEvent: Sendable {
    case turnItem(AcpTurnItem)
    /// A `tool_call_update`. Optional collections are nil when the update
    /// didn't carry that field, so the merge leaves existing disclosure intact.
    case toolCallUpdate(
        id: String,
        status: AcpToolCall.Status?,
        content: [AcpToolContent]?,
        locations: [String]?,
        title: String?
    )
    case usage(AcpUsage)
    case modelChanged(id: String)
    case modeChanged(id: String)
    case commands([AcpCommand])
    case configOptions([AcpConfigOption])
    case permission(AcpPermissionRequest)
    case turnEnded
    case error(String)
    case exited(code: Int32)
}

/// Hard limits for one adapter-originated plan update. Plans live in the
/// transcript and render on the main path, so their retained budget is much
/// smaller than the transport's framing ceiling.
struct AcpPlanPayloadLimits: Equatable, Sendable {
    let maximumEntries: Int
    let maximumEntryBytes: Int
    let maximumAggregateBytes: Int

    static let production = AcpPlanPayloadLimits(
        maximumEntries: 64,
        maximumEntryBytes: 8 * 1_024,
        maximumAggregateBytes: 128 * 1_024
    )
}

enum AcpPlanParser {
    private static let contentTruncationSuffix = "\n[truncated]"
    private static let entriesTruncationNotice = "Plan entries truncated."

    /// Converts an untrusted plan array into one bounded transcript item. A
    /// content suffix identifies an individually shortened entry; a single
    /// reserved sentinel identifies omitted entries. The sentinel's stable,
    /// non-numeric id cannot collide with the wire-index ids, and callers still
    /// emit exactly one `.plan`, so truncation never creates a second plan row.
    static func parseEntries(
        _ value: JSONValue?,
        limits: AcpPlanPayloadLimits = .production
    ) -> [AcpPlanEntry] {
        let suffixBytes = contentTruncationSuffix.utf8.count
        let noticeBytes = entriesTruncationNotice.utf8.count
        guard limits.maximumEntries > 0,
              limits.maximumEntryBytes >= max(suffixBytes, noticeBytes),
              limits.maximumAggregateBytes >= noticeBytes else { return [] }

        let source = value?.arrayValue ?? []
        let countOverflow = source.count > limits.maximumEntries
        let maximumRealEntries = countOverflow
            ? limits.maximumEntries - 1
            : limits.maximumEntries
        // Always reserve the fixed notice bytes. That makes the failure path
        // bounded without first scanning every attacker-controlled string.
        let realContentBudget = limits.maximumAggregateBytes - noticeBytes
        var retainedBytes = 0
        var omittedEntries = countOverflow
        var entries: [AcpPlanEntry] = []
        entries.reserveCapacity(min(source.count, limits.maximumEntries))

        for (index, value) in source.prefix(maximumRealEntries).enumerated() {
            guard let entry = value.objectValue,
                  let content = entry["content"]?.stringValue else { continue }
            let remainingBytes = realContentBudget - retainedBytes
            guard remainingBytes >= suffixBytes else {
                omittedEntries = true
                break
            }
            let entryBudget = min(limits.maximumEntryBytes, remainingBytes)
            let bounded = boundedContent(content, maximumBytes: entryBudget)
            entries.append(AcpPlanEntry(
                id: "\(index)",
                content: bounded.text,
                priority: entry["priority"]?.stringValue ?? "medium",
                status: entry["status"]?.stringValue ?? "pending"
            ))
            retainedBytes += bounded.text.utf8.count

            // A per-entry truncation can continue to the next entry. If the
            // aggregate remainder was the tighter bound, later entries must be
            // represented by the one reserved sentinel instead.
            if bounded.truncated,
               entryBudget < limits.maximumEntryBytes,
               index + 1 < source.count {
                omittedEntries = true
                break
            }
        }

        if omittedEntries {
            entries.append(AcpPlanEntry(
                id: "truncation",
                content: entriesTruncationNotice,
                priority: "medium",
                status: "truncated"
            ))
        }
        return entries
    }

    /// Copies only the UTF-8 prefix that can be retained. Iteration stops at
    /// the first scalar beyond the limit, so a multi-megabyte string does not
    /// turn validation itself into an unbounded pre-scan and no scalar is split.
    private static func boundedContent(
        _ content: String,
        maximumBytes: Int
    ) -> (text: String, truncated: Bool) {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(min(maximumBytes, 1_024))
        var retainedBytes = 0
        var truncated = false
        for scalar in content.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard scalarBytes <= maximumBytes - retainedBytes else {
                truncated = true
                break
            }
            scalars.append(scalar)
            retainedBytes += scalarBytes
        }
        guard truncated else {
            return (String(String.UnicodeScalarView(scalars)), false)
        }

        let prefixBudget = maximumBytes - contentTruncationSuffix.utf8.count
        while retainedBytes > prefixBudget, let removed = scalars.popLast() {
            retainedBytes -= String(removed).utf8.count
        }
        return (
            String(String.UnicodeScalarView(scalars)) + contentTruncationSuffix,
            true
        )
    }
}

/// A file or image the user attached to a prompt, carried into the ACP prompt
/// as a real content block (never merely a path). `image` becomes an ACP
/// `image` block (base64 pixels + mime); `textFile` becomes an embedded
/// `resource` block when the adapter advertises embedded context, otherwise the
/// ACP-baseline `resource_link` form.
enum AcpAttachment: Codable, Equatable, Sendable {
    case image(data: Data, mimeType: String, name: String)
    case textFile(path: String, contents: String, name: String)

    /// The display filename used for chips and the prompt's "📎 …" suffix line.
    var name: String {
        switch self {
        case let .image(_, _, name): name
        case let .textFile(_, _, name): name
        }
    }
}

/// Hard limits for adapter-originated permission asks. They are lower than the
/// transport frame cap because a permission payload is retained, inspected,
/// rendered, and held awaiting a human decision.
struct AcpPermissionPayloadLimits: Sendable {
    static let maximumAggregateBytes = 512 * 1_024
    static let maximumAggregateNodes = 32_768
    static let maximumNestingDepth = 64
    static let maximumRawInputBytes = 256 * 1_024
    static let maximumRawInputNodes = 16_384
    static let maximumTitleBytes = 4 * 1_024
    static let maximumKindBytes = 128
    static let maximumSessionIDBytes = 1_024
    static let maximumToolCallIDBytes = 1_024
    static let maximumOptionCount = 64
    static let maximumOptionIDBytes = 256
    static let maximumOptionNameBytes = 1_024
    static let maximumOptionKindBytes = 128
    static let maximumPathCount = 256
    static let maximumPathBytes = 4 * 1_024
}

enum AcpPermissionPayloadRejection: String, Equatable, Sendable {
    case malformed
    case aggregateBytes = "aggregate_bytes"
    case complexity
    case rawInputBytes = "raw_input_bytes"
    case titleBytes = "title_bytes"
    case kindBytes = "kind_bytes"
    case sessionIDBytes = "session_id_bytes"
    case toolCallIDBytes = "tool_call_id_bytes"
    case optionCount = "option_count"
    case optionIDBytes = "option_id_bytes"
    case optionNameBytes = "option_name_bytes"
    case optionKindBytes = "option_kind_bytes"
    case pathCount = "path_count"
    case pathBytes = "path_bytes"
    case incompleteReviewContext = "incomplete_review_context"

    var safeSummary: String {
        switch self {
        case .malformed: "Permission request fields are malformed."
        case .aggregateBytes: "Permission request exceeds the aggregate byte limit."
        case .complexity: "Permission request exceeds the structural complexity limit."
        case .rawInputBytes: "Permission raw input exceeds its byte limit."
        case .titleBytes: "Permission title exceeds its byte limit."
        case .kindBytes: "Permission kind exceeds its byte limit."
        case .sessionIDBytes: "Permission session identifier exceeds its byte limit."
        case .toolCallIDBytes: "Permission tool-call identifier exceeds its byte limit."
        case .optionCount: "Permission request has too many options."
        case .optionIDBytes: "Permission option identifier exceeds its byte limit."
        case .optionNameBytes: "Permission option name exceeds its byte limit."
        case .optionKindBytes: "Permission option kind exceeds its byte limit."
        case .pathCount: "Permission request has too many distinct paths."
        case .pathBytes: "Permission path exceeds its byte limit."
        case .incompleteReviewContext:
            "Permission request depends on review details that are no longer available."
        }
    }
}

/// A bounded, non-sensitive receipt for an inbound ACP message that named no
/// active session (or named the wrong one). Raw session identifiers are never
/// retained: their byte counts are enough to distinguish malformed, stale,
/// and adversarially oversized traffic without copying attacker-controlled
/// identity strings into diagnostics.
struct AcpSessionIdentityDiagnostic: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case staleConnectionGeneration = "stale_connection_generation"
        case missingSessionID = "missing_session_id"
        case noActiveSession = "no_active_session"
        case identityMismatch = "identity_mismatch"
    }

    let method: String
    let reason: Reason
    let connectionGeneration: UInt64
    let receivedSessionIDBytes: Int?
    let expectedSessionIDBytes: Int?
}

struct AcpPermissionPayloadValidation: Equatable, Sendable {
    let rejection: AcpPermissionPayloadRejection?
    let aggregateBytes: Int
    let inspectedNodes: Int
}

private enum AcpJSONBudgetFailure: Equatable {
    case bytes
    case complexity
}

/// Measures JSON without encoding or rendering it. Every visit is budgeted and
/// traversal stops at the first over-limit node, so a huge rawInput cannot turn
/// validation itself into an unbounded pre-scan.
private struct AcpJSONBudgetScanner {
    let maximumBytes: Int
    let maximumNodes: Int
    let maximumDepth: Int
    private(set) var bytes = 0
    private(set) var nodes = 0

    mutating func scan(_ value: JSONValue, depth: Int = 0) -> AcpJSONBudgetFailure? {
        guard depth <= maximumDepth else { return .complexity }
        nodes += 1
        guard nodes <= maximumNodes else { return .complexity }
        switch value {
        case .null:
            return add(4)
        case let .bool(value):
            return add(value ? 4 : 5)
        case let .integer(value):
            return add(String(value).utf8.count)
        case .number:
            // A finite JSON number is far shorter; use a conservative constant
            // so measurement never undercounts an encoder representation.
            return add(32)
        case let .string(value):
            return add(jsonStringBytes(value))
        case let .array(values):
            if let failure = add(2 + max(0, values.count - 1)) { return failure }
            for value in values {
                if let failure = scan(value, depth: depth + 1) { return failure }
            }
            return nil
        case let .object(values):
            if let failure = add(2 + max(0, values.count - 1)) { return failure }
            for (key, value) in values {
                if let failure = add(jsonStringBytes(key) + 1) { return failure }
                if let failure = scan(value, depth: depth + 1) { return failure }
            }
            return nil
        }
    }

    private mutating func add(_ count: Int) -> AcpJSONBudgetFailure? {
        guard count >= 0, bytes <= maximumBytes - min(count, maximumBytes + 1) else {
            bytes = maximumBytes + 1
            return .bytes
        }
        bytes += count
        return bytes <= maximumBytes ? nil : .bytes
    }

    private func jsonStringBytes(_ value: String) -> Int {
        var result = 2 // quotes
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
                result += 2
            case 0x00 ... 0x1F:
                result += 6
            case 0x00 ... 0x7F:
                result += 1
            case 0x80 ... 0x7FF:
                result += 2
            case 0x800 ... 0xFFFF:
                result += 3
            default:
                result += 4
            }
            if result > maximumBytes { return maximumBytes + 1 }
        }
        return result
    }
}

/// Review fields that can be inherited from an earlier tool-call update. If a
/// field could not be retained inside the cache budget, a later partial
/// permission request must replace it explicitly instead of silently asking a
/// human to decide from incomplete evidence.
enum AcpToolCallReviewField: CaseIterable, Hashable, Sendable {
    case title
    case kind
    case rawInput
    case locationPaths
    case diffPaths
}

struct AcpToolCallReviewContextLimits: Equatable, Sendable {
    static let production = AcpToolCallReviewContextLimits(
        maximumContextBytes: 128 * 1_024,
        maximumAggregateBytes: 2 * 1_024 * 1_024,
        maximumCount: 512
    )

    let maximumContextBytes: Int
    let maximumAggregateBytes: Int
    let maximumCount: Int

    init(maximumContextBytes: Int, maximumAggregateBytes: Int, maximumCount: Int) {
        precondition(maximumContextBytes > 0)
        precondition(maximumAggregateBytes > 0)
        precondition(maximumCount > 0)
        self.maximumContextBytes = maximumContextBytes
        self.maximumAggregateBytes = maximumAggregateBytes
        self.maximumCount = maximumCount
    }
}

struct AcpToolCallReviewContextLookup: Equatable, Sendable {
    let context: AcpToolCallReviewContext?
    let unavailableFields: Set<AcpToolCallReviewField>
}

/// A payload-byte-bounded, least-recently-updated cache. The byte accounting
/// covers tool-call identifiers plus every retained UTF-8/JSON field. Aggregate
/// eviction records a bounded gap bit: an unknown partial ask after any gap is
/// therefore rejected instead of being mistaken for a context-free request.
struct AcpToolCallReviewContextStore: Sendable {
    private struct Entry: Sendable {
        var context: AcpToolCallReviewContext
        var unavailableFields: Set<AcpToolCallReviewField>
        var bytes: Int
    }

    let limits: AcpToolCallReviewContextLimits
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private(set) var retainedBytes = 0
    private(set) var hasEvictedContext = false

    init(limits: AcpToolCallReviewContextLimits = .production) {
        self.limits = limits
    }

    var count: Int { entries.count }

    mutating func record(id: String, update: [String: JSONValue]) {
        // A permission carrying a larger id is rejected by the request boundary,
        // so retaining such a session/update key could only waste memory.
        guard !id.isEmpty,
              id.utf8.count <= AcpPermissionPayloadLimits.maximumToolCallIDBytes else {
            return
        }

        let prior = entries[id]
        var context = AcpClient.mergeToolCallReviewContext(prior?.context, update: update)
        var unavailableFields = prior?.unavailableFields
            ?? (hasEvictedContext ? Set(AcpToolCallReviewField.allCases) : [])
        updateAvailability(
            update,
            context: &context,
            unavailableFields: &unavailableFields
        )
        trimToPerContextLimit(
            id: id,
            context: &context,
            unavailableFields: &unavailableFields
        )
        let bytes = Self.byteCount(
            id: id,
            context: context,
            unavailableFields: unavailableFields,
            maximumBytes: limits.maximumContextBytes
        )

        if let prior { retainedBytes -= prior.bytes }
        order.removeAll(where: { $0 == id })
        guard bytes <= limits.maximumContextBytes else {
            entries.removeValue(forKey: id)
            hasEvictedContext = true
            return
        }
        entries[id] = Entry(
            context: context,
            unavailableFields: unavailableFields,
            bytes: bytes
        )
        retainedBytes += bytes
        order.append(id)
        trimAggregate()
    }

    func lookup(id: String) -> AcpToolCallReviewContextLookup {
        if let entry = entries[id] {
            return AcpToolCallReviewContextLookup(
                context: entry.context,
                unavailableFields: entry.unavailableFields
            )
        }
        return AcpToolCallReviewContextLookup(
            context: nil,
            unavailableFields: hasEvictedContext
                ? Set(AcpToolCallReviewField.allCases)
                : []
        )
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        order.removeAll(keepingCapacity: keepingCapacity)
        retainedBytes = 0
        hasEvictedContext = false
    }

    private mutating func updateAvailability(
        _ update: [String: JSONValue],
        context: inout AcpToolCallReviewContext,
        unavailableFields: inout Set<AcpToolCallReviewField>
    ) {
        if let value = update["title"] {
            if value == .null || value.stringValue != nil {
                unavailableFields.remove(.title)
            } else {
                context.title = nil
                unavailableFields.insert(.title)
            }
        }
        if let value = update["kind"] {
            if value == .null || value.stringValue != nil {
                unavailableFields.remove(.kind)
            } else {
                context.kind = nil
                unavailableFields.insert(.kind)
            }
        }
        if update["rawInput"] != nil {
            unavailableFields.remove(.rawInput)
        }
        if let value = update["locations"] {
            if Self.locationsAreWellFormed(value) {
                unavailableFields.remove(.locationPaths)
            } else {
                context.locationPaths = []
                unavailableFields.insert(.locationPaths)
            }
        }
        if let value = update["content"] {
            if Self.contentIsWellFormed(value) {
                unavailableFields.remove(.diffPaths)
            } else {
                context.diffPaths = []
                unavailableFields.insert(.diffPaths)
            }
        }

        if let title = context.title,
           title.utf8.count > AcpPermissionPayloadLimits.maximumTitleBytes {
            context.title = nil
            unavailableFields.insert(.title)
        }
        if let kind = context.kind,
           kind.utf8.count > AcpPermissionPayloadLimits.maximumKindBytes {
            context.kind = nil
            unavailableFields.insert(.kind)
        }
        if let rawInput = context.rawInput {
            var scanner = AcpJSONBudgetScanner(
                maximumBytes: limits.maximumContextBytes,
                maximumNodes: AcpPermissionPayloadLimits.maximumRawInputNodes,
                maximumDepth: AcpPermissionPayloadLimits.maximumNestingDepth
            )
            if scanner.scan(rawInput) != nil {
                context.rawInput = nil
                unavailableFields.insert(.rawInput)
            }
        }
        context.locationPaths = boundedPaths(
            context.locationPaths,
            field: .locationPaths,
            unavailableFields: &unavailableFields
        )
        context.diffPaths = boundedPaths(
            context.diffPaths,
            field: .diffPaths,
            unavailableFields: &unavailableFields
        )
    }

    private func boundedPaths(
        _ paths: [String],
        field: AcpToolCallReviewField,
        unavailableFields: inout Set<AcpToolCallReviewField>
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard !path.isEmpty,
                  path.utf8.count <= AcpPermissionPayloadLimits.maximumPathBytes else {
                unavailableFields.insert(field)
                return []
            }
            if seen.insert(path).inserted { result.append(path) }
            guard result.count <= AcpPermissionPayloadLimits.maximumPathCount else {
                unavailableFields.insert(field)
                return []
            }
        }
        return result
    }

    private func trimToPerContextLimit(
        id: String,
        context: inout AcpToolCallReviewContext,
        unavailableFields: inout Set<AcpToolCallReviewField>
    ) {
        // Prefer the compact rule/path evidence over arbitrary raw input. Any
        // removed field is explicitly marked unavailable, making inheritance
        // fail closed rather than turning truncation into silent approval.
        let discardOrder: [AcpToolCallReviewField] = [
            .rawInput, .title, .diffPaths, .locationPaths, .kind,
        ]
        while Self.byteCount(
            id: id,
            context: context,
            unavailableFields: unavailableFields,
            maximumBytes: limits.maximumContextBytes
        ) > limits.maximumContextBytes {
            guard let field = discardOrder.first(where: {
                fieldHasRetainedValue($0, context: context)
            }) else {
                break
            }
            discard(field, context: &context)
            unavailableFields.insert(field)
        }
    }

    private func fieldHasRetainedValue(
        _ field: AcpToolCallReviewField,
        context: AcpToolCallReviewContext
    ) -> Bool {
        switch field {
        case .title: context.title != nil
        case .kind: context.kind != nil
        case .rawInput: context.rawInput != nil
        case .locationPaths: !context.locationPaths.isEmpty
        case .diffPaths: !context.diffPaths.isEmpty
        }
    }

    private func discard(
        _ field: AcpToolCallReviewField,
        context: inout AcpToolCallReviewContext
    ) {
        switch field {
        case .title: context.title = nil
        case .kind: context.kind = nil
        case .rawInput: context.rawInput = nil
        case .locationPaths: context.locationPaths = []
        case .diffPaths: context.diffPaths = []
        }
    }

    private mutating func trimAggregate() {
        while entries.count > limits.maximumCount
            || retainedBytes > limits.maximumAggregateBytes {
            guard let oldestID = order.first else { break }
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldestID) {
                retainedBytes -= removed.bytes
                hasEvictedContext = true
            }
        }
    }

    private static func byteCount(
        id: String,
        context: AcpToolCallReviewContext,
        unavailableFields: Set<AcpToolCallReviewField>,
        maximumBytes: Int
    ) -> Int {
        // Fixed tags/separators make this a conservative serialized-payload
        // budget rather than pretending Swift collection overhead is exact.
        var total = 32 + id.utf8.count + unavailableFields.count
        total += context.title.map { 8 + $0.utf8.count } ?? 0
        total += context.kind.map { 8 + $0.utf8.count } ?? 0
        total += context.locationPaths.reduce(0) { $0 + 8 + $1.utf8.count }
        total += context.diffPaths.reduce(0) { $0 + 8 + $1.utf8.count }
        if let rawInput = context.rawInput {
            var scanner = AcpJSONBudgetScanner(
                maximumBytes: maximumBytes,
                maximumNodes: AcpPermissionPayloadLimits.maximumRawInputNodes,
                maximumDepth: AcpPermissionPayloadLimits.maximumNestingDepth
            )
            if scanner.scan(rawInput) == nil {
                total += 8 + scanner.bytes
            } else {
                return maximumBytes + 1
            }
        }
        return total
    }

    private static func locationsAreWellFormed(_ value: JSONValue) -> Bool {
        guard let locations = value.arrayValue else { return false }
        return locations.allSatisfy { $0.objectValue?["path"]?.stringValue != nil }
    }

    private static func contentIsWellFormed(_ value: JSONValue) -> Bool {
        guard let content = value.arrayValue else { return false }
        return content.allSatisfy { item in
            guard let object = item.objectValue else { return false }
            guard let type = object["type"] else { return true }
            guard let typeName = type.stringValue else { return false }
            return typeName != "diff" || object["path"]?.stringValue != nil
        }
    }
}

enum AcpJSONRPCEnvelopeViolation: String, Equatable, Sendable {
    case parseError = "parse_error"
    case unsupportedBatch = "unsupported_batch"
    case topLevelNotObject = "top_level_not_object"
    case invalidVersion = "invalid_version"
    case invalidID = "invalid_id"
    case invalidMethod = "invalid_method"
    case invalidParams = "invalid_params"
    case mixedMessageShape = "mixed_message_shape"
    case missingResponseID = "missing_response_id"
    case invalidResponseShape = "invalid_response_shape"
    case invalidErrorObject = "invalid_error_object"
    case missingMessageShape = "missing_message_shape"
}

enum AcpJSONRPCInboundEnvelope: Equatable, Sendable {
    enum ResponsePayload: Equatable, Sendable {
        case result(JSONValue)
        case error(message: String)
    }

    case request(method: String, id: JSONValue?, params: JSONValue?)
    case response(id: JSONValue, payload: ResponsePayload)
}

enum AcpJSONRPCEnvelopeValidation: Equatable, Sendable {
    case valid(AcpJSONRPCInboundEnvelope)
    /// `replyID == nil` means the invalid value was response-shaped and must
    /// not itself receive a response. `pendingRequestID` fails only a matching
    /// client-owned integer request instead of leaving it to time out.
    case invalid(
        reason: AcpJSONRPCEnvelopeViolation,
        replyID: JSONValue?,
        pendingRequestID: Int?
    )
}

private enum AcpJSONRPCReadLoopError: LocalizedError {
    case violationLimitReached

    var errorDescription: String? {
        "The agent sent too many invalid JSON-RPC messages."
    }
}

/// Outbound ACP frames are measured before `JSONEncoder` is allowed to build
/// its `Data`. The global ceiling mirrors the inbound decoder. Prompts use a
/// smaller ceiling that still carries the conversation's existing 20 MiB
/// staged-attachment budget after base64 expansion, while file and terminal
/// responses get bounded headroom above their existing 8 MiB source caps.
struct AcpOutboundFrameLimits: Equatable, Sendable {
    let globalMaximumBytes: Int
    let promptMaximumBytes: Int
    let toolResponseMaximumBytes: Int

    static let production = AcpOutboundFrameLimits(
        globalMaximumBytes: 64 * 1_024 * 1_024,
        promptMaximumBytes: 32 * 1_024 * 1_024,
        toolResponseMaximumBytes: 12 * 1_024 * 1_024
    )

    init(
        globalMaximumBytes: Int,
        promptMaximumBytes: Int,
        toolResponseMaximumBytes: Int
    ) {
        precondition(globalMaximumBytes > 0)
        precondition((1...globalMaximumBytes).contains(promptMaximumBytes))
        precondition((1...globalMaximumBytes).contains(toolResponseMaximumBytes))
        self.globalMaximumBytes = globalMaximumBytes
        self.promptMaximumBytes = promptMaximumBytes
        self.toolResponseMaximumBytes = toolResponseMaximumBytes
    }

    func maximumBytes(for purpose: AcpOutboundFramePurpose) -> Int {
        switch purpose {
        case let .request(method) where method == "session/prompt":
            promptMaximumBytes
        case let .response(method)
            where method == "fs/read_text_file" || method == "terminal/output":
            toolResponseMaximumBytes
        default:
            globalMaximumBytes
        }
    }
}

enum AcpOutboundFramePurpose: Equatable, Sendable {
    case request(method: String)
    case notification(method: String)
    case response(method: String)
}

struct AcpOutboundFrameMeasurement: Equatable, Sendable {
    let encodedBytes: Int
    let maximumBytes: Int
    let inspectedNodes: Int
}

struct AcpOutboundEncodedFrame: Equatable, Sendable {
    let data: Data
    let measurement: AcpOutboundFrameMeasurement
}

enum AcpOutboundFrameError: Error, Equatable, LocalizedError {
    case tooLarge(maximumBytes: Int)
    case invalidNumber
    case measurementMismatch

    var reason: String {
        switch self {
        case .tooLarge: "frame_too_large"
        case .invalidNumber: "invalid_number"
        case .measurementMismatch: "encoding_mismatch"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .tooLarge(maximumBytes):
            "The outbound ACP message exceeds its \(maximumBytes)-byte frame limit."
        case .invalidNumber:
            "The outbound ACP message contains a non-finite number."
        case .measurementMismatch:
            "The outbound ACP message could not be measured safely."
        }
    }
}

/// Exact byte preflight for the JSON formatting used below. Oversized values
/// stop at the first byte beyond the selected limit, before a frame-sized
/// buffer exists. Node counting is diagnostic only: this change does not add a
/// new structural schema restriction to otherwise valid ACP JSON.
struct AcpOutboundFrameEncoder: Sendable {
    let limits: AcpOutboundFrameLimits

    init(limits: AcpOutboundFrameLimits = .production) {
        self.limits = limits
    }

    func measure(
        _ value: JSONValue,
        purpose: AcpOutboundFramePurpose
    ) throws -> AcpOutboundFrameMeasurement {
        let maximumBytes = limits.maximumBytes(for: purpose)
        var scanner = Scanner(maximumBytes: maximumBytes)
        try scanner.scan(value)
        return AcpOutboundFrameMeasurement(
            encodedBytes: scanner.bytes,
            maximumBytes: maximumBytes,
            inspectedNodes: scanner.nodes
        )
    }

    func encode(
        _ value: JSONValue,
        purpose: AcpOutboundFramePurpose
    ) throws -> AcpOutboundEncodedFrame {
        let measurement = try measure(value, purpose: purpose)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        guard data.count == measurement.encodedBytes else {
            throw AcpOutboundFrameError.measurementMismatch
        }
        return AcpOutboundEncodedFrame(data: data, measurement: measurement)
    }

    private struct Scanner {
        let maximumBytes: Int
        /// Every outbound frame ends in one newline delimiter.
        private(set) var bytes = 1
        private(set) var nodes = 0

        mutating func scan(_ value: JSONValue) throws {
            nodes += 1
            switch value {
            case .null:
                try add(4)
            case let .bool(value):
                try add(value ? 4 : 5)
            case let .integer(value):
                try add(String(value).utf8.count)
            case let .number(value):
                guard value.isFinite else { throw AcpOutboundFrameError.invalidNumber }
                // A number encoding is at most a few dozen bytes. Measuring
                // that scalar independently keeps the full-frame allocation
                // behind the preflight while matching Foundation exactly.
                try add(try JSONEncoder().encode(value).count)
            case let .string(value):
                try scanString(value)
            case let .array(values):
                try add(2 + max(0, values.count - 1))
                for value in values { try scan(value) }
            case let .object(values):
                try add(2 + max(0, values.count - 1))
                for (key, value) in values {
                    try scanString(key)
                    try add(1)
                    try scan(value)
                }
            }
        }

        private mutating func scanString(_ value: String) throws {
            try add(2) // quotes
            for scalar in value.unicodeScalars {
                let count: Int
                switch scalar.value {
                case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
                    count = 2
                case 0x00 ... 0x1F:
                    count = 6
                case 0x00 ... 0x7F:
                    count = 1
                case 0x80 ... 0x7FF:
                    count = 2
                case 0x800 ... 0xFFFF:
                    count = 3
                default:
                    count = 4
                }
                try add(count)
            }
        }

        private mutating func add(_ count: Int) throws {
            guard count >= 0, count <= maximumBytes - bytes else {
                throw AcpOutboundFrameError.tooLarge(maximumBytes: maximumBytes)
            }
            bytes += count
        }
    }
}

/// The Kaisola-owned read boundary for ACP `fs/read_text_file` requests. The
/// path is opened once, and every later size, type, and payload decision is
/// made against that descriptor. Reading one byte beyond the retained budget
/// detects files that grow after the initial metadata check without ever
/// allocating or decoding the unbounded payload.
enum AcpWorkspaceFileReader {
    typealias AfterOpen = () throws -> Void

    static func readTextFile(
        at path: String,
        maximumBytes: Int,
        afterOpen: AfterOpen? = nil
    ) throws -> String {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw AcpClientError.requestFailed("Text file has an invalid ACP byte limit")
        }

        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw AcpClientError.requestFailed("Text file is not a regular file")
        }
        guard metadata.st_size <= off_t(maximumBytes) else {
            throw tooLarge(maximumBytes)
        }

        try afterOpen?()

        var payload = Data()
        payload.reserveCapacity(min(maximumBytes, 64 * 1_024))
        while true {
            let remaining = maximumBytes - payload.count
            let requestCount = min(64 * 1_024, remaining + 1)
            var buffer = [UInt8](repeating: 0, count: requestCount)
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestCount)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            guard bytesRead <= remaining else { throw tooLarge(maximumBytes) }
            payload.append(contentsOf: buffer.prefix(bytesRead))
        }

        guard let content = String(data: payload, encoding: .utf8) else {
            throw AcpClientError.requestFailed("Text file is not valid UTF-8")
        }
        return content
    }

    private static func tooLarge(_ maximumBytes: Int) -> AcpClientError {
        .requestFailed("Text file exceeds the \(maximumBytes)-byte ACP limit")
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// A serial filesystem executor for adapter callbacks. Foundation's file APIs
/// are synchronous; keeping them on this private utility queue prevents a slow
/// volume from occupying `AcpClient`'s actor while it must continue decoding
/// output, permissions, heartbeats, and other callback requests.
final class AcpFilesystemWorker: @unchecked Sendable {
    enum Operation: Equatable, Sendable {
        case read
        case write
    }

    typealias OperationHook = @Sendable (Operation) -> Void

    private let queue: DispatchQueue
    private let operationHook: OperationHook?

    init(
        label: String = "com.kaisola.acp-filesystem",
        operationHook: OperationHook? = nil
    ) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.operationHook = operationHook
    }

    func readTextFile(
        path: String?,
        workspaceRoot: String,
        sensitiveGlobs: [String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, any Error>) in
            queue.async { [operationHook] in
                do {
                    operationHook?(.read)
                    let confined = try AcpClient.workspacePath(
                        path,
                        workspaceRoot: workspaceRoot,
                        mustExist: true
                    )
                    guard !AcpPermissionRules.pathIsSensitive(
                        globs: sensitiveGlobs,
                        pathish: confined
                    ) else {
                        throw AcpClientError.requestFailed(
                            "Blocked: sensitive file (Kaisola guardrails)"
                        )
                    }
                    continuation.resume(
                        returning: try AcpWorkspaceFileReader.readTextFile(
                            at: confined,
                            maximumBytes: AcpClient.maxTextFileBytes
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func writeTextFile(
        path: String?,
        content: String,
        workspaceRoot: String,
        sensitiveGlobs: [String]
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [operationHook] in
                do {
                    operationHook?(.write)
                    guard content.utf8.count <= AcpClient.maxTextFileBytes else {
                        throw AcpClientError.requestFailed(
                            "Text file exceeds the \(AcpClient.maxTextFileBytes)-byte ACP limit"
                        )
                    }
                    let confined = try AcpWorkspaceFileWriter.normalizedTargetPath(
                        path,
                        workspaceRoot: workspaceRoot
                    )
                    guard !AcpPermissionRules.pathIsSensitive(
                        globs: sensitiveGlobs,
                        pathish: confined
                    ) else {
                        throw AcpClientError.requestFailed(
                            "Blocked: sensitive file (Kaisola guardrails)"
                        )
                    }
                    try AcpWorkspaceFileWriter.write(
                        Data(content.utf8),
                        to: confined,
                        workspaceRoot: workspaceRoot
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// A native ACP client: spawns the adapter, runs the JSON-RPC handshake
/// (initialize → session/new), sends prompts, and streams the agent's
/// `session/update` notifications plus permission callbacks. Newline-delimited
/// JSON-RPC 2.0 over stdio for native ACP adapters.
actor AcpClient {
    typealias EventHandler = @Sendable (AcpEvent) -> Void

    private let transport: any AcpByteTransport
    private let outboundFrameEncoder: AcpOutboundFrameEncoder
    private let filesystemWorker: AcpFilesystemWorker
    private var decoder = BrokerLineFrameDecoder(maximumFrameBytes: 64 * 1_024 * 1_024)
    private var eventHandler: EventHandler?
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    /// One retained sleeper per in-flight request, cancelled the moment that
    /// request settles. An unretained timer outlives the answer it was guarding
    /// and keeps waking the actor for the rest of its window, so a busy session
    /// accumulates tasks that can only report on requests already finished.
    private var requestTimeouts: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 0
    private var readerTask: Task<Void, Never>?
    /// Invalidates callbacks that were awaiting a user decision when an adapter
    /// exits or a client is stopped/restarted. Without this guard, a resumed
    /// permission task could write its JSON-RPC response into the next adapter.
    private var connectionGeneration: UInt64 = 0
    /// The reader and callback writers can discover the same broken connection
    /// concurrently. Claim the generation before terminating it so exactly one
    /// path owns the health transition and a stale send failure cannot close a
    /// replacement adapter.
    private var failingConnectionGeneration: UInt64?
    private var filesystemCallbacksInFlight = 0
    private var sessionID: String?
    private struct ScopedSessionIdentity: Sendable {
        let sessionID: String
        let connectionGeneration: UInt64
    }
    /// The established identity for normal notifications in this connection.
    private var activeSessionIdentity: ScopedSessionIdentity?
    /// `session/load` must replay notifications before its response, so a load
    /// temporarily authorizes only the exact requested identity and generation.
    private var restoringSessionIdentity: ScopedSessionIdentity?
    private var sessionIdentityDiagnosticTail: [AcpSessionIdentityDiagnostic] = []
    private var sessionIdentityRejectionCount = 0
    static let maximumSessionIdentityDiagnostics = 32
    private var inboundProtocolViolationTail: [AcpJSONRPCEnvelopeViolation] = []
    private var inboundProtocolViolationCount = 0
    static let maximumInboundProtocolViolations = 8
    static let maximumInboundProtocolDiagnostics = 8
    private var capabilities = AcpAgentCapabilities()
    private var permissionCounter = 0
    private enum PermissionResolution: Sendable {
        case selected(String)
        case cancelled
    }
    private struct ActivePermissionRequest: Sendable {
        let connectionGeneration: UInt64
        let offeredOptionIDs: Set<String>
    }
    private var permissionWaiters: [Int: CheckedContinuation<PermissionResolution, Never>] = [:]
    /// A permission event is delivered synchronously, so a fast policy/UI can
    /// answer before the continuation task gets its first actor turn. Track the
    /// request first and retain that early resolution instead of dropping it.
    private var activePermissionIDs: Set<Int> = []
    /// The exact option set is scoped to this local request and adapter
    /// generation. It is consumed by the first valid resolution and discarded
    /// on every completion/cancellation boundary, so a stale UI path cannot
    /// select an option that a new adapter never offered.
    private var activePermissionRequests: [Int: ActivePermissionRequest] = [:]
    private var earlyPermissionResolutions: [Int: PermissionResolution] = [:]
    /// Permission requests are partial ToolCallUpdates. Retain a bounded set of
    /// prior review fields so a later ask can disclose paths/raw input already
    /// streamed for the same tool-call id.
    private var toolCallReviewContextStore: AcpToolCallReviewContextStore
    /// Host for agent-requested terminals (`terminal/create` …).
    private let terminalHost = AcpTerminalHost()
    /// The session workspace; fs/terminal callbacks are confined inside it.
    private var workspaceRoot: String?
    /// Sensitive globs the fs bridge refuses to read or write (set by the
    /// conversation from the user's guardrails; defaults applied otherwise).
    private var fsSensitiveGlobs = AcpPermissionRules.defaultSensitiveGlobs
    /// Built-ins retain the historical full client bridge. A custom adapter's
    /// reviewed containment grant narrows advertised MCP/fs/terminal services
    /// and is enforced again when a request arrives.
    private var access = AcpAdapterAccess.unrestricted
    /// The immutable launch profile is retained separately from adapter
    /// containment so a refused callback can name the user-visible policy that
    /// blocked it. Both boundaries are intersected before advertisement.
    private var runProfile = AcpRunProfile.write
    /// Mirrors Electron's MAX_TEXT_FILE_BYTES ACP fs limit.
    static let maxTextFileBytes = 8 * 1024 * 1024

    init(
        transport: any AcpByteTransport = AcpProcessTransport(),
        toolCallReviewContextLimits: AcpToolCallReviewContextLimits = .production,
        outboundFrameLimits: AcpOutboundFrameLimits = .production,
        filesystemWorker: AcpFilesystemWorker = AcpFilesystemWorker()
    ) {
        self.transport = transport
        outboundFrameEncoder = AcpOutboundFrameEncoder(limits: outboundFrameLimits)
        self.filesystemWorker = filesystemWorker
        toolCallReviewContextStore = AcpToolCallReviewContextStore(
            limits: toolCallReviewContextLimits
        )
    }

    func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    func configureFsGuard(sensitiveGlobs: [String]) {
        fsSensitiveGlobs = sensitiveGlobs
    }

    /// Live output snapshot for an agent-spawned terminal (tool-card rendering).
    func terminalSnapshot(_ id: String) async -> AcpTerminalHost.Snapshot? {
        await terminalHost.output(id)
    }

    /// Spawn the adapter and complete the ACP handshake, returning the new
    /// session. `mcpServers` is the array produced by the MCP registry.
    func start(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        mcpServers: [JSONValue],
        resumeSessionID: String? = nil,
        access: AcpAdapterAccess = .unrestricted,
        runProfile: AcpRunProfile = .write
    ) async throws -> AcpSessionInfo {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let session = try await startConnection(
                command: command,
                arguments: arguments,
                environment: environment,
                cwd: cwd,
                mcpServers: mcpServers,
                resumeSessionID: resumeSessionID,
                access: access,
                runProfile: runProfile
            )
            if Task.isCancelled {
                await stop()
                throw CancellationError()
            }
            return session
        } onCancel: {
            // GUI task cancellation is an ownership close, including while the
            // initialize/session handshake is still waiting for its first byte.
            Task { await self.stop() }
        }
    }

    private func startConnection(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        mcpServers: [JSONValue],
        resumeSessionID: String?,
        access: AcpAdapterAccess,
        runProfile: AcpRunProfile
    ) async throws -> AcpSessionInfo {
        connectionGeneration &+= 1
        let startGeneration = connectionGeneration
        failingConnectionGeneration = nil
        decoder = BrokerLineFrameDecoder(maximumFrameBytes: 64 * 1_024 * 1_024)
        sessionID = nil
        activeSessionIdentity = nil
        restoringSessionIdentity = nil
        inboundProtocolViolationTail.removeAll(keepingCapacity: true)
        inboundProtocolViolationCount = 0
        cancelPermissionRequests()
        toolCallReviewContextStore.removeAll(keepingCapacity: true)
        workspaceRoot = (cwd as NSString).standardizingPath
        self.runProfile = runProfile
        self.access = runProfile.restricting(access)
        do {
            try await transport.start(command: command, arguments: arguments, environment: environment, cwd: cwd)
            readerTask = Task { await readLoop(sourceConnectionGeneration: startGeneration) }

            let initResult = try await request("initialize", params: AcpBooleanConfigWire.advertise(in: .object([
            "protocolVersion": .integer(Int64(AcpWire.protocolVersion)),
            "clientCapabilities": .object([
                "fs": .object([
                    "readTextFile": .bool(self.access.workspaceRead),
                    "writeTextFile": .bool(self.access.workspaceWrite),
                ]),
                "terminal": .bool(self.access.hostTerminal),
                "auth": .object(["terminal": .bool(self.access.hostTerminal)]),
                "_meta": .object(["terminal-auth": .bool(self.access.hostTerminal)]),
            ]),
        ])))
        // ACP requires the client to disconnect when the negotiated protocol is
        // not one it speaks. Silently continuing here can make a newer adapter
        // look connected while every later request is subtly malformed.
            guard initResult.objectValue?["protocolVersion"]?.intValue == Int64(AcpWire.protocolVersion) else {
                throw AcpClientError.unsupportedProtocol(
                    initResult.objectValue?["protocolVersion"]?.intValue.map(Int.init) ?? -1
                )
            }
            capabilities = Self.parseCapabilities(initResult)

            let sessionServers = sessionMcpServers(runProfile.filterMCPServers(mcpServers))
            func openSession(_ method: String, priorID: String? = nil) async throws -> JSONValue {
                if let priorID {
                    restoringSessionIdentity = ScopedSessionIdentity(
                        sessionID: priorID,
                        connectionGeneration: startGeneration
                    )
                }
                defer {
                    if restoringSessionIdentity?.connectionGeneration == startGeneration,
                       restoringSessionIdentity?.sessionID == priorID {
                        restoringSessionIdentity = nil
                    }
                }
                func parameters(servers: [JSONValue]) -> JSONValue {
                    var values: [String: JSONValue] = [
                        "cwd": .string(cwd),
                        "mcpServers": .array(servers),
                    ]
                    if let priorID { values["sessionId"] = .string(priorID) }
                    return .object(values)
                }
                do {
                    return try await request(method, params: parameters(servers: sessionServers))
                } catch let AcpClientError.requestFailed(message)
                    where !sessionServers.isEmpty
                        && message.localizedCaseInsensitiveContains("invalid params") {
                    // Match Electron: one malformed/rejected tool entry must
                    // degrade to a working tool-less chat, including resume.
                    return try await request(method, params: parameters(servers: []))
                }
            }

            var sessionResult: JSONValue?
            var resumedID: String?
            if let resumeSessionID {
                if capabilities.resumeSession,
                   let result = try? await openSession("session/resume", priorID: resumeSessionID) {
                    sessionResult = result
                    resumedID = resumeSessionID
                }
                if sessionResult == nil,
                   capabilities.loadSession,
                   let result = try? await openSession("session/load", priorID: resumeSessionID) {
                    sessionResult = result
                    resumedID = resumeSessionID
                }
            }
            if sessionResult == nil {
                sessionResult = try await openSession("session/new")
            }
            guard let object = sessionResult?.objectValue,
                  let sessionID = object["sessionId"]?.stringValue ?? resumedID else {
                throw AcpClientError.malformedResponse
            }
            guard connectionGeneration == startGeneration else {
                throw AcpClientError.notRunning
            }
            self.sessionID = sessionID
            activeSessionIdentity = ScopedSessionIdentity(
                sessionID: sessionID,
                connectionGeneration: startGeneration
            )
        // Adapters vary: some return a flat `models: [...]` + top-level
        // `currentModelId`; the standard (and our mock) nests them under
        // `models: { availableModels, currentModelId }`. Handle both.
        let modelsNode = object["models"]?.objectValue
        let modelArray = modelsNode?["availableModels"]?.arrayValue ?? object["models"]?.arrayValue ?? []
        let models = modelArray.compactMap { value -> AcpSessionInfo.Model? in
            guard let m = value.objectValue,
                  let id = (m["modelId"] ?? m["id"])?.stringValue else { return nil }
            return AcpSessionInfo.Model(id: id, name: m["name"]?.stringValue ?? id)
        }
        let modesNode = object["modes"]?.objectValue
        let modeArray = modesNode?["availableModes"]?.arrayValue ?? object["modes"]?.arrayValue ?? []
        let modes = modeArray.compactMap { value -> AcpSessionInfo.Mode? in
            guard let m = value.objectValue,
                  let id = (m["id"] ?? m["modeId"])?.stringValue else { return nil }
            return AcpSessionInfo.Mode(id: id, name: m["name"]?.stringValue ?? id)
        }
            return AcpSessionInfo(
                sessionID: sessionID,
                models: models,
                currentModelID: modelsNode?["currentModelId"]?.stringValue ?? object["currentModelId"]?.stringValue,
                modes: modes,
                currentModeID: modesNode?["currentModeId"]?.stringValue ?? object["currentModeId"]?.stringValue,
                configOptions: AcpBooleanConfigWire.parseOptions(object["configOptions"]),
                supportsSteering: capabilities.steering
            )
        } catch {
            // A failed initialize/session-new must not leave a live adapter or a
            // reader task behind. This is especially important while users swap
            // agent profiles rapidly from the project menu.
            await stop()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Send a user prompt; the turn's updates arrive on the event handler and
    /// this returns when the turn fully ends. `attachments` ride as real ACP
    /// content blocks alongside the text (see `promptBlocks`). The no-attachment
    /// call stays source-compatible via the default.
    func prompt(_ text: String, attachments: [AcpAttachment] = []) async throws {
        guard let sessionID else { throw AcpClientError.notRunning }
        _ = try await request("session/prompt", params: .object([
            "sessionId": .string(sessionID),
            "prompt": .array(Self.promptBlocks(
                text: text,
                attachments: attachments,
                promptImageOk: capabilities.promptImage,
                promptEmbeddedContextOk: capabilities.promptEmbeddedContext
            )),
        ]), timeoutNanoseconds: 0)
        eventHandler?(.turnEnded)
    }

    /// Build the ACP `session/prompt` content-block array for a user turn: the
    /// text block first, then a real `image` block per image attachment (base64
    /// pixels + mime, gated on the agent having
    /// advertised `promptCapabilities.image`, exactly like Electron's
    /// `promptImageOk`), then either an embedded `resource` or baseline
    /// `resource_link` per text-file attachment according to negotiated prompt
    /// capabilities. Pure and static so wire encoding stays unit-testable.
    static func promptBlocks(
        text: String,
        attachments: [AcpAttachment],
        promptImageOk: Bool,
        promptEmbeddedContextOk: Bool = true
    ) -> [JSONValue] {
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        for attachment in attachments {
            switch attachment {
            case let .image(data, mimeType, _):
                // Image blocks only reach agents that take them; a text-only
                // agent still learns the filename from the prompt text (the
                // caller appends a "📎 <name>" line), never a rejected block.
                guard promptImageOk else { continue }
                blocks.append(.object([
                    "type": .string("image"),
                    "mimeType": .string(mimeType),
                    "data": .string(data.base64EncodedString()),
                ]))
            case let .textFile(path, contents, name):
                if promptEmbeddedContextOk {
                    blocks.append(.object([
                        "type": .string("resource"),
                        "resource": .object([
                            "uri": .string(fileURI(path)),
                            "mimeType": .string("text/plain"),
                            "text": .string(contents),
                        ]),
                    ]))
                } else {
                    // Resource links are ACP baseline prompt content. Agents that
                    // did not advertise embeddedContext receive a standards-safe
                    // link instead of an unsupported inline resource block.
                    blocks.append(.object([
                        "type": .string("resource_link"),
                        "name": .string(name),
                        "uri": .string(fileURI(path)),
                        "mimeType": .string("text/plain"),
                        "size": .integer(Int64(contents.utf8.count)),
                    ]))
                }
            }
        }
        return blocks
    }

    /// A `file://` URI for an attachment path, percent-encoding only bytes that
    /// aren't URL-path-legal (spaces etc.); an encoding-free absolute path
    /// becomes `file://` + path verbatim (e.g. `file:///tmp/notes.txt`).
    static func fileURI(_ path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file://" + encoded
    }

    func cancel() async {
        guard let sessionID else { return }
        notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
        cancelPermissionRequests()
    }

    /// Inject one message into the turn that is already running, via the
    /// `_session/steering` extension both adapters advertise. Unlike `prompt`,
    /// this returns as soon as the adapter has decided what it did with the
    /// message — the injected message's own output streams through the RUNNING
    /// turn's `session/update` notifications, not through this response.
    ///
    /// Never throws: every failure — no session, a JSON-RPC error, an outcome
    /// this client does not recognize — comes back as `.rejected`, because the
    /// caller's only safe response to "we do not know what happened" is to keep
    /// the message queued.
    func steer(_ text: String) async -> AcpSteerOutcome {
        guard let sessionID else { return .rejected(AcpClientError.notRunning.localizedDescription) }
        do {
            let result = try await request(
                AcpSteering.method,
                params: AcpSteering.requestParams(sessionID: sessionID, text: text)
            )
            return AcpSteering.parseOutcome(result)
        } catch {
            return .rejected(errorText(error))
        }
    }

    func setModel(_ modelID: String) async {
        guard let sessionID else { return }
        do {
            _ = try await request("session/set_model", params: .object([
                "sessionId": .string(sessionID),
                "modelId": .string(modelID),
            ]))
        } catch {
            eventHandler?(.error(errorText(error)))
        }
    }

    func setMode(_ modeID: String) async {
        guard let sessionID else { return }
        do {
            _ = try await request("session/set_mode", params: .object([
                "sessionId": .string(sessionID),
                "modeId": .string(modeID),
            ]))
        } catch {
            eventHandler?(.error(errorText(error)))
        }
    }

    /// Set an adapter config option (e.g. reasoning effort) and return only the
    /// option set the adapter confirmed. Callers must not present the requested
    /// value before this succeeds: adapters can reject a level for one model or
    /// normalize it to another supported value.
    func setConfigOption(id: String, value: String) async throws -> [AcpConfigOption] {
        guard let sessionID else { throw AcpClientError.notRunning }
        let result = try await request("session/set_config_option", params: .object([
            "sessionId": .string(sessionID),
            "configId": .string(id),
            "value": .string(value),
        ]))
        let options = Self.parseConfigOptions(result.objectValue?["configOptions"])
        guard options.contains(where: { $0.id == id && $0.currentValue != nil }) else {
            throw AcpClientError.malformedResponse
        }
        return options
    }

    /// Boolean ACP config mutations retain their JSON type on the wire. Select
    /// options continue through the established string path above unchanged.
    func setConfigOption(
        id: String,
        value: AcpConfigOption.Value
    ) async throws -> [AcpConfigOption] {
        if case let .select(selected) = value {
            return try await setConfigOption(id: id, value: selected)
        }
        guard case let .boolean(enabled) = value, let sessionID else {
            throw AcpClientError.notRunning
        }
        let result = try await request("session/set_config_option", params: .object([
            "sessionId": .string(sessionID),
            "configId": .string(id),
            "type": .string("boolean"),
            "value": .bool(enabled),
        ]))
        let options = AcpBooleanConfigWire.parseOptions(result.objectValue?["configOptions"])
        guard options.contains(where: { $0.id == id && $0.booleanValue != nil }) else {
            throw AcpClientError.malformedResponse
        }
        return options
    }

    /// Resolve a pending permission request with the user's chosen option.
    func resolvePermission(id: Int, optionID: String) {
        guard !optionID.isEmpty,
              let active = activePermissionRequests[id],
              active.connectionGeneration == connectionGeneration,
              active.offeredOptionIDs.contains(optionID) else { return }
        // Consume before resuming the waiter. Duplicate calls must not mutate
        // the early-resolution slot while the first response task is waking.
        activePermissionIDs.remove(id)
        activePermissionRequests.removeValue(forKey: id)
        let resolution = PermissionResolution.selected(optionID)
        if let waiter = permissionWaiters.removeValue(forKey: id) {
            waiter.resume(returning: resolution)
        } else {
            earlyPermissionResolutions[id] = resolution
        }
    }

    /// Decline an ask without selecting an adapter-owned `reject_always`
    /// option. ACP's cancelled outcome denies the pending operation without
    /// granting the adapter an undisclosed persistent decision.
    func cancelPermission(id: Int) {
        guard let active = activePermissionRequests[id],
              active.connectionGeneration == connectionGeneration else { return }
        activePermissionIDs.remove(id)
        activePermissionRequests.removeValue(forKey: id)
        let resolution = PermissionResolution.cancelled
        if let waiter = permissionWaiters.removeValue(forKey: id) {
            waiter.resume(returning: resolution)
        } else {
            earlyPermissionResolutions[id] = resolution
        }
    }

    func stop() async {
        connectionGeneration &+= 1
        failingConnectionGeneration = nil
        let reader = readerTask
        readerTask = nil
        reader?.cancel()
        cancelPermissionRequests()
        await transport.terminate()
        await reader?.value
        await terminalHost.releaseAll()
        failAllPending(with: AcpClientError.notRunning)
        sessionID = nil
        activeSessionIdentity = nil
        restoringSessionIdentity = nil
        workspaceRoot = nil
        capabilities = AcpAgentCapabilities()
        toolCallReviewContextStore.removeAll(keepingCapacity: true)
    }

    private func cancelPermissionRequests() {
        let ids = activePermissionIDs
            .union(activePermissionRequests.keys)
            .union(permissionWaiters.keys)
            .union(earlyPermissionResolutions.keys)
        activePermissionIDs.removeAll(keepingCapacity: false)
        activePermissionRequests.removeAll(keepingCapacity: false)
        for id in ids {
            earlyPermissionResolutions.removeValue(forKey: id)
            if let waiter = permissionWaiters.removeValue(forKey: id) {
                waiter.resume(returning: .cancelled)
            }
        }
    }

    // MARK: - MCP filtering (mirrors acp.cjs sessionMcpServers)

    private func sessionMcpServers(_ servers: [JSONValue]) -> [JSONValue] {
        servers.filter { entry in
            switch entry.objectValue?["type"]?.stringValue {
            case "http": access.network && capabilities.mcpHTTP
            case "sse": access.network && capabilities.mcpSSE
            case nil: access.childProcess
            default:
                // Preserve the historical pass-through for built-ins, but a
                // contained adapter must never gain an unclassified transport
                // through the broader child-process grant.
                access == .unrestricted
            }
        }
    }

    // MARK: - JSON-RPC

    private func request(
        _ method: String,
        params: JSONValue,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async throws -> JSONValue {
        nextRequestID += 1
        // Ids never repeat for the life of a client — not across a stop, a
        // restart, or a resumed session — so a response that arrives after its
        // entry is gone (cancelled, timed out, adapter exited) cannot alias a
        // later request's id. `handle` drops it.
        let id = nextRequestID
        let frame = try encode(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(Int64(id)),
            "method": .string(method),
            "params": params,
        ]), purpose: .request(method: method))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // An already-cancelled caller must fail here rather than
                // register: the handler below reaches this actor on a later
                // turn, so its removal would have run before the entry existed
                // and the request would wait on the adapter forever.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                if timeoutNanoseconds > 0 {
                    requestTimeouts[id] = Task {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        guard !Task.isCancelled else { return }
                        failRequest(id, error: AcpClientError.requestFailed("\(method) timed out"))
                    }
                }
                Task {
                    do { try await transport.send(frame) }
                    catch { failRequest(id, error: error) }
                }
            }
        } onCancel: {
            // A caller that walked away — a closed chat view cancels its
            // `.task`, a restart abandons startup — must not leave its entry in
            // `pending` until the adapter answers. `session/prompt` in
            // particular has no timeout, so that wait is unbounded. For timed
            // requests this also cancels the retained sleeper immediately.
            Task { await self.failRequest(id, error: CancellationError()) }
        }
    }

    private enum OutboundCallbackKind {
        case notification
        case response

        var failure: AcpClientError {
            switch self {
            case .notification:
                .requestFailed(
                    "Kaisola could not send an ACP notification. The agent connection was closed."
                )
            case .response:
                .requestFailed(
                    "Kaisola could not send an ACP callback response. The agent connection was closed."
                )
            }
        }
    }

    /// Callback delivery is part of connection health, not best-effort
    /// telemetry. A failed notification can leave cancellation unapplied and a
    /// failed response leaves the adapter waiting forever, so either failure
    /// retires only the generation that attempted the write.
    private func sendCallbackFrame(
        _ frame: Data,
        kind: OutboundCallbackKind,
        sourceConnectionGeneration: UInt64
    ) {
        Task {
            do {
                try await transport.send(frame)
            } catch {
                await failConnection(
                    kind.failure,
                    sourceConnectionGeneration: sourceConnectionGeneration
                )
            }
        }
    }

    private func failCallbackEncoding(
        kind: OutboundCallbackKind,
        sourceConnectionGeneration: UInt64
    ) {
        Task {
            await failConnection(
                kind.failure,
                sourceConnectionGeneration: sourceConnectionGeneration
            )
        }
    }

    private func notify(_ method: String, params: JSONValue) {
        let generation = connectionGeneration
        let frame: Data
        do {
            frame = try encode(.object([
                "jsonrpc": .string("2.0"),
                "method": .string(method),
                "params": params,
            ]), purpose: .notification(method: method))
        } catch {
            failCallbackEncoding(kind: .notification, sourceConnectionGeneration: generation)
            return
        }
        sendCallbackFrame(
            frame,
            kind: .notification,
            sourceConnectionGeneration: generation
        )
    }

    private func respond(id: JSONValue, method: String, result: JSONValue) {
        let generation = connectionGeneration
        do {
            let frame = try encode(.object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": result,
            ]), purpose: .response(method: method))
            sendCallbackFrame(
                frame,
                kind: .response,
                sourceConnectionGeneration: generation
            )
        } catch {
            respondError(
                id: id,
                method: method,
                code: -32001,
                message: "Outbound ACP response rejected",
                data: outboundFrameRejectionData(error)
            )
        }
    }

    private func respondError(
        id: JSONValue,
        method: String? = nil,
        code: Int,
        message: String,
        data: JSONValue? = nil
    ) {
        let generation = connectionGeneration
        var error: [String: JSONValue] = [
            "code": .integer(Int64(code)),
            "message": .string(message),
        ]
        if let data { error["data"] = data }
        let purpose = AcpOutboundFramePurpose.response(method: method ?? "")
        let value = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(error),
        ])
        let frame: Data
        do {
            frame = try encode(value, purpose: purpose)
        } catch {
            // The adapter still needs a terminal response. Never copy an
            // oversized error/result into this fallback or silently leave its
            // request hanging.
            let fallback = JSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "error": .object([
                    "code": .integer(-32001),
                    "message": .string("Outbound ACP response rejected"),
                    "data": outboundFrameRejectionData(error),
                ]),
            ])
            guard let bounded = try? encode(fallback, purpose: purpose) else {
                failCallbackEncoding(
                    kind: .response,
                    sourceConnectionGeneration: generation
                )
                return
            }
            frame = bounded
        }
        sendCallbackFrame(
            frame,
            kind: .response,
            sourceConnectionGeneration: generation
        )
    }

    private func encode(
        _ value: JSONValue,
        purpose: AcpOutboundFramePurpose
    ) throws -> Data {
        try outboundFrameEncoder.encode(value, purpose: purpose).data
    }

    private func outboundFrameRejectionData(_ error: any Error) -> JSONValue {
        var data: [String: JSONValue] = [
            "type": .string("outbound_frame_rejected"),
            "reason": .string(
                (error as? AcpOutboundFrameError)?.reason ?? "encoding_failed"
            ),
        ]
        if case let .tooLarge(maximumBytes) = error as? AcpOutboundFrameError {
            data["maximumBytes"] = .integer(Int64(maximumBytes))
        }
        return .object(data)
    }

    /// Remove `id` and fail whoever was waiting on it. A no-op once the entry is
    /// gone, so a timeout firing after a cancellation (or an adapter exit after
    /// either) can never resume the same continuation twice.
    private func failRequest(_ id: Int, error: any Error) {
        takePending(id)?.resume(throwing: error)
    }

    /// Take one request off the in-flight table and stop its timeout task.
    /// Every single-request settlement — a response, a send failure, a fired
    /// timeout, a cancelled caller — goes through here.
    private func takePending(_ id: Int) -> CheckedContinuation<JSONValue, any Error>? {
        requestTimeouts.removeValue(forKey: id)?.cancel()
        return pending.removeValue(forKey: id)
    }

    /// Settle every in-flight request at once (stop, adapter exit, read
    /// failure), cancelling the timers along with the continuations.
    private func failAllPending(with error: any Error) {
        for timeout in requestTimeouts.values { timeout.cancel() }
        requestTimeouts.removeAll()
        let waiters = pending
        pending.removeAll()
        for continuation in waiters.values { continuation.resume(throwing: error) }
    }

    // MARK: - Request testing hooks

    /// In-flight request timers, so tests can prove a settled request leaves
    /// none behind.
    func outstandingRequestTimeoutCountForTesting() -> Int { requestTimeouts.count }

    /// Drive one raw JSON-RPC request with a caller-chosen timeout. Tests need
    /// a window far shorter than the 30s default to exercise the timeout path.
    func requestForTesting(
        _ method: String,
        params: JSONValue = .object([:]),
        timeoutNanoseconds: UInt64
    ) async throws -> JSONValue {
        try await request(method, params: params, timeoutNanoseconds: timeoutNanoseconds)
    }

    // MARK: - Read loop

    private func readLoop(sourceConnectionGeneration: UInt64) async {
        do {
            while !Task.isCancelled {
                guard sourceConnectionGeneration == connectionGeneration else { return }
                guard let data = try await transport.receive(maximumBytes: 256 * 1_024) else {
                    guard sourceConnectionGeneration == connectionGeneration else { return }
                    guard !Task.isCancelled else { return }
                    // A callback writer already owns this generation's health
                    // transition. Its terminate() wakes receive with EOF; the
                    // reader must not emit a second exit or terminate twice.
                    guard failingConnectionGeneration != sourceConnectionGeneration else { return }
                    // EOF is the transport connection closing. Reap the whole
                    // adapter-owned process group before publishing the exit;
                    // the adapter may have closed stdout while remaining alive.
                    await transport.terminate()
                    guard !Task.isCancelled,
                          sourceConnectionGeneration == connectionGeneration else { return }
                    let code = await transport.exitCode() ?? 0
                    connectionGeneration &+= 1
                    cancelPermissionRequests()
                    sessionID = nil
                    activeSessionIdentity = nil
                    restoringSessionIdentity = nil
                    workspaceRoot = nil
                    eventHandler?(.exited(code: code))
                    failAllPending(with: AcpClientError.adapterExited(code: code))
                    return
                }
                guard sourceConnectionGeneration == connectionGeneration else { return }
                if data.isEmpty { continue }
                var active = decoder
                try active.consume(data) { frame in
                    // ACP's stdout carries nothing but JSON-RPC, so a frame the
                    // decoder rejects means the stream can no longer be trusted:
                    // those bytes may have been the response or the permission
                    // request this turn is waiting on. Skipping them (the old
                    // `try?`) left the turn hanging until an unrelated timeout.
                    guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame) else {
                        throw AcpClientError.malformedFrame(Self.framePreview(frame))
                    }
                    if handle(value, sourceConnectionGeneration: sourceConnectionGeneration) {
                        throw AcpJSONRPCReadLoopError.violationLimitReached
                    }
                }
                decoder = active
            }
        } catch {
            guard !Task.isCancelled,
                  sourceConnectionGeneration == connectionGeneration else { return }
            await failConnection(
                Self.protocolFailure(error),
                sourceConnectionGeneration: sourceConnectionGeneration
            )
        }
    }

    /// End a connection that broke below the JSON-RPC layer. The adapter is
    /// terminated rather than left half-read, every awaiting request and
    /// permission is failed instead of waiting out a timeout, and the reason is
    /// reported once: `.exited` marks the connection gone (so the chat offers a
    /// restart) and `.error` carries the diagnostic the user actually needs.
    private func failConnection(
        _ error: AcpClientError,
        sourceConnectionGeneration: UInt64
    ) async {
        guard !Task.isCancelled,
              sourceConnectionGeneration == connectionGeneration,
              failingConnectionGeneration == nil else { return }
        failingConnectionGeneration = sourceConnectionGeneration
        await transport.terminate()
        guard !Task.isCancelled,
              sourceConnectionGeneration == connectionGeneration else {
            if failingConnectionGeneration == sourceConnectionGeneration {
                failingConnectionGeneration = nil
            }
            return
        }
        let code = await transport.exitCode() ?? -1
        guard !Task.isCancelled,
              sourceConnectionGeneration == connectionGeneration else {
            if failingConnectionGeneration == sourceConnectionGeneration {
                failingConnectionGeneration = nil
            }
            return
        }
        connectionGeneration &+= 1
        failingConnectionGeneration = nil
        cancelPermissionRequests()
        sessionID = nil
        activeSessionIdentity = nil
        restoringSessionIdentity = nil
        workspaceRoot = nil
        failAllPending(with: error)
        eventHandler?(.exited(code: code))
        eventHandler?(.error(errorText(error)))
    }

    /// Bytes of a rejected frame kept for its diagnostic. Adapter output can be
    /// megabytes wide; a status line and a log entry cannot.
    static let framePreviewByteLimit = 160

    /// A short single-line excerpt of a frame the client refused, safe for a
    /// status line: control bytes are flattened and everything past the limit
    /// becomes the frame's real size.
    static func framePreview(_ frame: Data, limit: Int = framePreviewByteLimit) -> String {
        let head = String(decoding: frame.prefix(limit), as: UTF8.self)
        let flattened = String(String.UnicodeScalarView(head.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return "\(frame.count) unreadable bytes" }
        return frame.count > limit ? "\(flattened)… (\(frame.count) bytes)" : flattened
    }

    /// Map a framing failure onto the client's own error vocabulary, so the chat
    /// shows a sentence instead of `BrokerWireError error 1`.
    static func protocolFailure(_ error: any Error) -> AcpClientError {
        if let error = error as? AcpClientError { return error }
        switch error as? BrokerWireError {
        case .invalidUTF8: return .malformedFrame("the bytes are not valid UTF-8")
        case .incompleteFrame: return .malformedFrame("the message ended mid-frame")
        case .invalidEnvelope: return .malformedFrame("the message envelope is invalid")
        case .frameTooLarge: return .frameTooLarge
        case nil: return .requestFailed(
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
        }
    }

    /// Returns true once the bounded invalid-envelope threshold is reached and
    /// the reader must close the adapter connection.
    @discardableResult
    private func handle(_ message: JSONValue, sourceConnectionGeneration: UInt64) -> Bool {
        switch Self.validateInboundEnvelope(message) {
        case let .invalid(reason, replyID, pendingRequestID):
            if let pendingRequestID {
                failRequest(pendingRequestID, error: AcpClientError.malformedResponse)
            }
            if let replyID {
                let invalidParams = reason == .invalidParams
                respondError(
                    id: replyID,
                    code: invalidParams ? -32602 : -32600,
                    message: invalidParams ? "Invalid params" : "Invalid Request"
                )
            }
            return recordInboundProtocolViolation(reason)

        case let .valid(.response(idValue, payload)):
            guard let id = idValue.intValue.flatMap(Int.init(exactly:)) else { return false }
            let continuation = takePending(id)
            switch payload {
            case let .result(result):
                continuation?.resume(returning: result)
            case let .error(message):
                continuation?.resume(throwing: AcpClientError.requestFailed(message))
            }
            return false

        case let .valid(.request(method, id, params)):
            return dispatchInboundRequest(
                method: method,
                id: id,
                params: params,
                sourceConnectionGeneration: sourceConnectionGeneration
            )
        }
    }

    @discardableResult
    private func dispatchInboundRequest(
        method: String,
        id: JSONValue?,
        params: JSONValue?,
        sourceConnectionGeneration: UInt64
    ) -> Bool {
        switch method {
        case "session/update":
            let params = params?.objectValue
            guard acceptsSessionScopedMessage(
                method: method,
                receivedSessionID: params?["sessionId"]?.stringValue,
                sourceConnectionGeneration: sourceConnectionGeneration
            ) else { return false }
            if let update = params?["update"] {
                handleSessionUpdate(update)
            }
        case "session/request_permission":
            // Preserve the malformed-payload contract for non-object params;
            // once params is an object, its session identity is mandatory and
            // must belong to the reader generation that delivered the ask.
            if let scopedParams = params?.objectValue,
               !acceptsSessionScopedMessage(
                   method: method,
                   receivedSessionID: scopedParams["sessionId"]?.stringValue,
                   sourceConnectionGeneration: sourceConnectionGeneration
               ) {
                if let id { respondStalePermissionSessionError(id: id) }
                return false
            }
            handlePermissionRequest(id: id, params: params)
        case "fs/read_text_file":
            handleReadTextFile(id: id, params: params)
        case "fs/write_text_file":
            handleWriteTextFile(id: id, params: params)
        case "terminal/create", "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release":
            handleTerminalMethod(method, id: id, params: params)
        default:
            // An unanswered request would hang the agent — fail it explicitly.
            if let id {
                respondError(
                    id: id,
                    method: method,
                    code: -32601,
                    message: "Method not handled: \(method)"
                )
            }
        }
        return false
    }

    static func validateInboundEnvelope(_ message: JSONValue) -> AcpJSONRPCEnvelopeValidation {
        guard let object = message.objectValue else {
            // ACP stdio frames are individual requests, notifications, or
            // responses. A top-level array is therefore not a valid ACP frame,
            // even though generic JSON-RPC transports may negotiate batching.
            let reason: AcpJSONRPCEnvelopeViolation = message.arrayValue == nil
                ? .topLevelNotObject
                : .unsupportedBatch
            return .invalid(reason: reason, replyID: .null, pendingRequestID: nil)
        }

        let id = object["id"]
        let methodValue = object["method"]
        let hasResult = object["result"] != nil
        let hasError = object["error"] != nil
        let requestLike = methodValue != nil
        let responseLike = !requestLike && (id != nil || hasResult || hasError)
        let pendingRequestID = responseLike
            ? id?.intValue.flatMap(Int.init(exactly:))
            : nil
        let invalidReplyID: JSONValue? = requestLike
            ? (id.flatMap { isValidACPRequestID($0) ? $0 : nil } ?? .null)
            : (responseLike ? nil : .null)

        guard object["jsonrpc"] == .string("2.0") else {
            return .invalid(
                reason: .invalidVersion,
                replyID: invalidReplyID,
                pendingRequestID: pendingRequestID
            )
        }

        if requestLike {
            guard let method = methodValue?.stringValue else {
                return .invalid(reason: .invalidMethod, replyID: invalidReplyID, pendingRequestID: nil)
            }
            if let id, !isValidACPRequestID(id) {
                return .invalid(reason: .invalidID, replyID: .null, pendingRequestID: nil)
            }
            if let params = object["params"], params.objectValue == nil, params.arrayValue == nil {
                return .invalid(reason: .invalidParams, replyID: invalidReplyID, pendingRequestID: nil)
            }
            guard !hasResult, !hasError else {
                return .invalid(reason: .mixedMessageShape, replyID: invalidReplyID, pendingRequestID: nil)
            }
            return .valid(.request(method: method, id: id, params: object["params"]))
        }

        guard responseLike else {
            return .invalid(reason: .missingMessageShape, replyID: .null, pendingRequestID: nil)
        }
        guard let id else {
            return .invalid(reason: .missingResponseID, replyID: nil, pendingRequestID: nil)
        }
        guard isValidACPRequestID(id) else {
            return .invalid(reason: .invalidID, replyID: nil, pendingRequestID: pendingRequestID)
        }
        guard hasResult != hasError else {
            return .invalid(
                reason: .invalidResponseShape,
                replyID: nil,
                pendingRequestID: pendingRequestID
            )
        }
        if let result = object["result"] {
            return .valid(.response(id: id, payload: .result(result)))
        }
        guard let error = object["error"]?.objectValue,
              case .integer = error["code"],
              let message = error["message"]?.stringValue else {
            return .invalid(
                reason: .invalidErrorObject,
                replyID: nil,
                pendingRequestID: pendingRequestID
            )
        }
        return .valid(.response(id: id, payload: .error(message: message)))
    }

    private static func isValidACPRequestID(_ id: JSONValue) -> Bool {
        switch id {
        case .null, .integer, .string: true
        case .bool, .number, .array, .object: false
        }
    }

    private func recordInboundProtocolViolation(_ reason: AcpJSONRPCEnvelopeViolation) -> Bool {
        if inboundProtocolViolationCount < Int.max {
            inboundProtocolViolationCount += 1
        }
        inboundProtocolViolationTail.append(reason)
        if inboundProtocolViolationTail.count > Self.maximumInboundProtocolDiagnostics {
            inboundProtocolViolationTail.removeFirst(
                inboundProtocolViolationTail.count - Self.maximumInboundProtocolDiagnostics
            )
        }
        return inboundProtocolViolationCount >= Self.maximumInboundProtocolViolations
    }

    func inboundProtocolViolationCountForTesting() -> Int {
        inboundProtocolViolationCount
    }

    func inboundProtocolViolationDiagnosticsForTesting() -> [AcpJSONRPCEnvelopeViolation] {
        inboundProtocolViolationTail
    }

    /// Shared fail-closed boundary for ACP messages scoped to the current
    /// session. Permission requests use the same contract in the next stacked
    /// change, while notifications simply drop after recording the receipt.
    func acceptsSessionScopedMessage(
        method: String,
        receivedSessionID: String?,
        sourceConnectionGeneration: UInt64
    ) -> Bool {
        let expected = [activeSessionIdentity, restoringSessionIdentity]
            .compactMap { $0 }
            .first { $0.connectionGeneration == sourceConnectionGeneration }
        let reason: AcpSessionIdentityDiagnostic.Reason?
        if sourceConnectionGeneration != connectionGeneration {
            reason = .staleConnectionGeneration
        } else if receivedSessionID == nil {
            reason = .missingSessionID
        } else if expected == nil {
            reason = .noActiveSession
        } else if receivedSessionID != expected?.sessionID {
            reason = .identityMismatch
        } else {
            reason = nil
        }
        guard let reason else { return true }

        if sessionIdentityRejectionCount < Int.max {
            sessionIdentityRejectionCount += 1
        }
        sessionIdentityDiagnosticTail.append(AcpSessionIdentityDiagnostic(
            method: method,
            reason: reason,
            connectionGeneration: connectionGeneration,
            receivedSessionIDBytes: receivedSessionID?.utf8.count,
            expectedSessionIDBytes: expected?.sessionID.utf8.count
        ))
        if sessionIdentityDiagnosticTail.count > Self.maximumSessionIdentityDiagnostics {
            sessionIdentityDiagnosticTail.removeFirst(
                sessionIdentityDiagnosticTail.count - Self.maximumSessionIdentityDiagnostics
            )
        }
        return false
    }

    /// Test/diagnostic receipt. The tail is bounded and intentionally contains
    /// lengths rather than raw adapter-provided session identifiers.
    func sessionIdentityDiagnostics() -> (total: Int, tail: [AcpSessionIdentityDiagnostic]) {
        (sessionIdentityRejectionCount, sessionIdentityDiagnosticTail)
    }

    /// Deterministic adversarial seam for proving that a late frame from a
    /// retired reader cannot become current merely because an adapter reused
    /// the same opaque session id after restart.
    func handleSessionUpdateForTesting(
        sessionID: String?,
        update: JSONValue,
        sourceConnectionGeneration: UInt64
    ) {
        var params: [String: JSONValue] = ["update": update]
        if let sessionID { params["sessionId"] = .string(sessionID) }
        handle(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object(params),
        ]), sourceConnectionGeneration: sourceConnectionGeneration)
    }

    /// Deterministic adversarial seam for a permission request that was
    /// decoded by a specific reader generation. This exercises the complete
    /// request dispatch and wire-response path without scheduler timing.
    func handlePermissionRequestForTesting(
        wireID: Int64?,
        params: JSONValue?,
        sourceConnectionGeneration: UInt64
    ) {
        var message: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string("session/request_permission"),
        ]
        if let wireID { message["id"] = .integer(wireID) }
        if let params { message["params"] = params }
        handle(.object(message), sourceConnectionGeneration: sourceConnectionGeneration)
    }

    func connectionGenerationForTesting() -> UInt64 {
        connectionGeneration
    }

    func filesystemCallbacksInFlightForTesting() -> Int {
        filesystemCallbacksInFlight
    }

    // MARK: - Agent-requested terminals

    private func handleTerminalMethod(_ method: String, id: JSONValue?, params: JSONValue?) {
        guard let id else { return }
        guard access.hostTerminal else {
            respondError(
                id: id,
                code: -32000,
                message: runProfile.allows(.terminal)
                    ? "Blocked by custom adapter containment: host terminals are unavailable; use a reviewed in-sandbox child-process grant instead."
                    : "Blocked by run profile “\(runProfile.name)”: host terminals are disabled."
            )
            return
        }
        let object = params?.objectValue ?? [:]
        Task {
            do {
                switch method {
                case "terminal/create":
                    guard let command = object["command"]?.stringValue, !command.isEmpty else {
                        throw AcpClientError.requestFailed("terminal/create requires a command")
                    }
                    let args = (object["args"]?.arrayValue ?? []).compactMap(\.stringValue)
                    let env = Dictionary(
                        (object["env"]?.arrayValue ?? []).compactMap { pair -> (String, String)? in
                            guard let p = pair.objectValue, let name = p["name"]?.stringValue else { return nil }
                            return (name, p["value"]?.stringValue ?? "")
                        },
                        uniquingKeysWith: { _, last in last }
                    )
                    let cwd = try workspacePath(object["cwd"]?.stringValue, mustExist: true)
                    let limit = object["outputByteLimit"]?.intValue.map { Int($0) }
                    let terminalID = try await terminalHost.create(
                        command: command, args: args, env: env, cwd: cwd, outputByteLimit: limit
                    )
                    respond(
                        id: id,
                        method: method,
                        result: .object(["terminalId": .string(terminalID)])
                    )
                case "terminal/output":
                    guard let terminalID = object["terminalId"]?.stringValue,
                          let snapshot = await terminalHost.output(terminalID) else {
                        throw AcpClientError.requestFailed("unknown terminal")
                    }
                    var result: [String: JSONValue] = [
                        "output": .string(snapshot.output),
                        "truncated": .bool(snapshot.truncated),
                    ]
                    if let status = snapshot.exitStatus { result["exitStatus"] = Self.encode(status) }
                    respond(id: id, method: method, result: .object(result))
                case "terminal/wait_for_exit":
                    guard let terminalID = object["terminalId"]?.stringValue,
                          let status = await terminalHost.waitForExit(terminalID) else {
                        throw AcpClientError.requestFailed("unknown terminal")
                    }
                    respond(
                        id: id,
                        method: method,
                        result: .object(["exitStatus": Self.encode(status)])
                    )
                case "terminal/kill":
                    guard let terminalID = object["terminalId"]?.stringValue else {
                        throw AcpClientError.requestFailed("terminal/kill requires terminalId")
                    }
                    await terminalHost.kill(terminalID)
                    respond(id: id, method: method, result: .object([:]))
                case "terminal/release":
                    guard let terminalID = object["terminalId"]?.stringValue else {
                        throw AcpClientError.requestFailed("terminal/release requires terminalId")
                    }
                    await terminalHost.release(terminalID)
                    respond(id: id, method: method, result: .object([:]))
                default:
                    respondError(
                        id: id,
                        method: method,
                        code: -32601,
                        message: "Method not handled: \(method)"
                    )
                }
            } catch {
                respondError(id: id, method: method, code: -32000, message: errorText(error))
            }
        }
    }

    private static func encode(_ status: AcpTerminalHost.ExitStatus) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let code = status.exitCode { fields["exitCode"] = .integer(Int64(code)) }
        if let signal = status.signal { fields["signal"] = .string(signal) }
        return .object(fields)
    }

    /// Resolve a path inside the session workspace, refusing escapes — the
    /// same confinement Electron's `_workspacePath` applies. Symlinks are
    /// resolved on both sides before the containment check, so a link inside
    /// the workspace cannot smuggle reads or terminal working directories
    /// outside it. Agent writes use `AcpWorkspaceFileWriter` instead because a
    /// resolved path cannot distinguish an ordinary file from a symlink leaf.
    private func workspacePath(_ path: String?, mustExist: Bool = false) throws -> String {
        guard let root = workspaceRoot else { throw AcpClientError.notRunning }
        return try Self.workspacePath(path, workspaceRoot: root, mustExist: mustExist)
    }

    /// Pure, explicit-root form used by the filesystem worker after the actor
    /// snapshots the active workspace. It must remain synchronous so the whole
    /// resolution/read/write sequence stays on the worker queue.
    fileprivate static func workspacePath(
        _ path: String?,
        workspaceRoot root: String,
        mustExist: Bool = false
    ) throws -> String {
        let raw = path?.isEmpty == false ? path! : root
        let resolved = raw.hasPrefix("/")
            ? (raw as NSString).standardizingPath
            : ((root as NSString).appendingPathComponent(raw) as NSString).standardizingPath
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard Self.isContained(resolved, in: root) || Self.isContained(resolved, in: realRoot) else {
            throw AcpClientError.requestFailed("Path escapes the session project")
        }
        // Resolve symlinks through the NEAREST EXISTING ancestor, so neither an
        // existing symlinked file nor a not-yet-created file under a symlinked
        // parent (write path) can escape the workspace.
        let real = Self.realPathViaNearestExistingAncestor(resolved)
        guard Self.isContained(real, in: realRoot) else {
            throw AcpClientError.requestFailed("Path escapes the session project")
        }
        if mustExist, !FileManager.default.fileExists(atPath: real) {
            throw AcpClientError.requestFailed("No such path: \(resolved)")
        }
        // Return the symlink-RESOLVED path: callers run the sensitive-glob
        // guard against it and then read/write it, so an in-workspace symlink
        // with an innocuous name (link.txt → ./.env) can't slip past the
        // guardrail on its lexical name and be read through the link.
        return real
    }

    /// Resolve symlinks in the deepest existing ancestor and re-append the
    /// not-yet-existing suffix, mirroring Electron's real-parent check.
    static func realPathViaNearestExistingAncestor(_ path: String) -> String {
        var existing = path
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            suffix.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var real = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        for component in suffix.reversed() {
            real = (real as NSString).appendingPathComponent(component)
        }
        return real
    }

    private static func isContained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func errorText(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func handleSessionUpdate(_ update: JSONValue) {
        guard let object = update.objectValue, let kind = object["sessionUpdate"]?.stringValue else { return }
        switch kind {
        case "agent_message_chunk":
            if let text = object["content"]?.objectValue?["text"]?.stringValue {
                eventHandler?(.turnItem(.message(id: "live", text: text)))
            }
        case "agent_thought_chunk":
            if let text = object["content"]?.objectValue?["text"]?.stringValue {
                eventHandler?(.turnItem(.thought(id: "live", text: text)))
            }
        case "user_message_chunk":
            // The user's OWN prompts. Adapters emit these when they replay a
            // loaded session's history, which is how a resumed chat gets back
            // the questions that produced the replies beside them; Claude also
            // echoes any prompt that carried more than a single text block.
            // Dropping them (the old `default: break`) is what made a resumed
            // conversation read as the agent talking to itself.
            if let text = object["content"]?.objectValue?["text"]?.stringValue {
                eventHandler?(.turnItem(.userMessage(
                    id: object["messageId"]?.stringValue,
                    text: text
                )))
            }
        case "tool_call":
            recordToolCallReviewContext(object)
            if let call = Self.parseToolCall(object) {
                eventHandler?(.turnItem(.toolCall(call)))
            }
        case "tool_call_update":
            recordToolCallReviewContext(object)
            if let id = object["toolCallId"]?.stringValue {
                let status = object["status"]?.stringValue.flatMap(AcpToolCall.Status.init)
                // Only treat content as present when the key exists — an absent
                // key must not clear artifacts an earlier update already set.
                let content = object["content"] != nil ? Self.parseToolContent(object["content"]) : nil
                let locations = object["locations"] != nil
                    ? Self.locationPaths(object["locations"])
                    : nil
                eventHandler?(.toolCallUpdate(
                    id: id,
                    status: status,
                    content: content,
                    locations: locations,
                    title: object["title"]?.stringValue
                ))
            }
        case "plan":
            let entries = AcpPlanParser.parseEntries(object["entries"])
            eventHandler?(.turnItem(.plan(entries: entries)))
        case "usage_update":
            // ACP 1.x standardized these fields as `used` + `size`. Older
            // adapters (and Kaisola's original mock) emitted
            // `usedTokens` + `maxTokens`, so accept both without making the
            // modern wire path depend on a legacy alias. This mismatch was why
            // real SDK usage stayed blank while the mock looked healthy.
            let used = (object["used"] ?? object["usedTokens"])?.intValue
            let size = (object["size"] ?? object["maxTokens"])?.intValue
            if let used, let size {
                let cost = object["cost"]?.objectValue
                eventHandler?(.usage(AcpUsage(
                    used: Int(used),
                    max: Int(size),
                    costAmount: Self.finiteDouble(cost?["amount"]),
                    costCurrency: cost?["currency"]?.stringValue
                )))
            }
        case "current_model_update":
            if let id = object["currentModelId"]?.stringValue {
                eventHandler?(.modelChanged(id: id))
            }
        case "current_mode_update":
            if let id = (object["currentModeId"] ?? object["modeId"])?.stringValue {
                eventHandler?(.modeChanged(id: id))
            }
        case "available_commands_update":
            let commands = (object["availableCommands"]?.arrayValue ?? []).compactMap { value -> AcpCommand? in
                guard let c = value.objectValue, let name = c["name"]?.stringValue else { return nil }
                return AcpCommand(name: name, description: c["description"]?.stringValue ?? "")
            }
            eventHandler?(.commands(commands))
        case "config_option_update":
            if let options = object["configOptions"] {
                eventHandler?(.configOptions(AcpBooleanConfigWire.parseOptions(options)))
            }
        default:
            break
        }
    }

    /// JSON-RPC 2.0 "Invalid params" — the answer an ask we cannot put in front
    /// of a human has to carry.
    private static let invalidParamsCode = -32602

    private func handlePermissionRequest(id: JSONValue?, params: JSONValue?) {
        // No id means the agent sent this as a notification; JSON-RPC forbids
        // answering one, and there is no decision to route back.
        guard let id else { return }
        // Every remaining path must reply. Dropping a malformed ask left the
        // adapter blocked forever on a decision the user was never shown.
        guard let sessionID else {
            respondError(
                id: id,
                code: Self.invalidParamsCode,
                message: "session/request_permission arrived with no active session"
            )
            return
        }
        permissionCounter += 1
        let localID = permissionCounter
        let toolCallID = params?.objectValue?["toolCall"]?.objectValue?["toolCallId"]?.stringValue
        guard toolCallID?.utf8.count ?? 0 <= AcpPermissionPayloadLimits.maximumToolCallIDBytes else {
            respondPermissionRequestError(id: id, rejection: .toolCallIDBytes)
            return
        }
        let priorLookup = toolCallID.map { toolCallReviewContextStore.lookup(id: $0) }
        let priorContext = priorLookup?.context
        let validation = Self.validatePermissionRequestPayload(
            params,
            priorContext: priorContext,
            unavailablePriorFields: priorLookup?.unavailableFields ?? []
        )
        if let rejection = validation.rejection {
            respondPermissionRequestError(id: id, rejection: rejection)
            return
        }
        guard let request = Self.parsePermissionRequest(
            localID: localID,
            sessionID: sessionID,
            params: params,
            priorContext: priorContext
        ) else {
            respondError(
                id: id,
                code: Self.invalidParamsCode,
                message: "session/request_permission needs object params with at least one option"
            )
            return
        }
        activePermissionIDs.insert(localID)
        let generation = connectionGeneration
        activePermissionRequests[localID] = ActivePermissionRequest(
            connectionGeneration: generation,
            offeredOptionIDs: Set(request.options.map(\.id))
        )
        eventHandler?(.permission(request))
        Task {
            let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionResolution, Never>) in
                if let early = earlyPermissionResolutions.removeValue(forKey: localID) {
                    continuation.resume(returning: early)
                } else if activePermissionIDs.contains(localID),
                          activePermissionRequests[localID]?.connectionGeneration == generation {
                    permissionWaiters[localID] = continuation
                } else {
                    continuation.resume(returning: .cancelled)
                }
            }
            activePermissionIDs.remove(localID)
            activePermissionRequests.removeValue(forKey: localID)
            earlyPermissionResolutions.removeValue(forKey: localID)
            guard connectionGeneration == generation else { return }
            let outcome: JSONValue
            switch resolution {
            case let .selected(optionID):
                outcome = .object(["outcome": .string("selected"), "optionId": .string(optionID)])
            case .cancelled:
                outcome = .object(["outcome": .string("cancelled")])
            }
            respond(
                id: id,
                method: "session/request_permission",
                result: .object(["outcome": outcome])
            )
        }
    }

    private func respondPermissionRequestError(
        id: JSONValue,
        rejection: AcpPermissionPayloadRejection
    ) {
        respondError(
            id: id,
            code: -32602,
            message: "Permission request rejected",
            data: .object([
                "type": .string("permission_request_rejected"),
                "reason": .string(rejection.rawValue),
                "summary": .string(rejection.safeSummary),
            ])
        )
    }

    private func respondStalePermissionSessionError(id: JSONValue) {
        respondError(
            id: id,
            code: Self.invalidParamsCode,
            message: "Permission request rejected",
            data: .object([
                "type": .string("stale_session"),
                "reason": .string("session_scope_mismatch"),
                "summary": .string("Permission request does not belong to the active session."),
            ])
        )
    }

    static func validatePermissionRequestPayload(
        _ value: JSONValue?,
        priorContext: AcpToolCallReviewContext? = nil,
        unavailablePriorFields: Set<AcpToolCallReviewField> = []
    ) -> AcpPermissionPayloadValidation {
        var inspectedNodes = 0
        func rejected(
            _ rejection: AcpPermissionPayloadRejection,
            aggregateBytes: Int = 0
        ) -> AcpPermissionPayloadValidation {
            AcpPermissionPayloadValidation(
                rejection: rejection,
                aggregateBytes: aggregateBytes,
                inspectedNodes: inspectedNodes
            )
        }

        guard let params = value?.objectValue else { return rejected(.malformed) }
        let toolCall: [String: JSONValue]?
        if let candidate = params["toolCall"] {
            guard let object = candidate.objectValue else { return rejected(.malformed) }
            toolCall = object
        } else {
            toolCall = nil
        }

        let inheritedFields = Set(AcpToolCallReviewField.allCases.filter { field in
            switch field {
            case .title: toolCall?["title"] == nil
            case .kind: toolCall?["kind"] == nil
            case .rawInput: toolCall?["rawInput"] == nil
            case .locationPaths: toolCall?["locations"] == nil
            case .diffPaths: toolCall?["content"] == nil
            }
        })
        guard inheritedFields.isDisjoint(with: unavailablePriorFields) else {
            return rejected(.incompleteReviewContext)
        }

        let inheritsTitle = toolCall?["title"] == nil
        let inheritsKind = toolCall?["kind"] == nil
        let inheritsRawInput = toolCall?["rawInput"] == nil
        let inheritsLocations = toolCall?["locations"] == nil
        let inheritsDiffPaths = toolCall?["content"] == nil
        let rawInput: JSONValue?
        if let current = toolCall?["rawInput"] {
            rawInput = current == .null ? nil : current
        } else {
            rawInput = priorContext?.rawInput
        }

        // Inspect arbitrary raw input before measuring the complete request.
        // This stricter node budget bounds work even when the outer payload is
        // still under its aggregate byte allowance.
        if let rawInput {
            var rawScanner = AcpJSONBudgetScanner(
                maximumBytes: AcpPermissionPayloadLimits.maximumRawInputBytes,
                maximumNodes: AcpPermissionPayloadLimits.maximumRawInputNodes,
                maximumDepth: AcpPermissionPayloadLimits.maximumNestingDepth
            )
            if let failure = rawScanner.scan(rawInput) {
                inspectedNodes += rawScanner.nodes
                return rejected(failure == .bytes ? .rawInputBytes : .complexity)
            }
            inspectedNodes += rawScanner.nodes
        }

        var aggregateScanner = AcpJSONBudgetScanner(
            maximumBytes: AcpPermissionPayloadLimits.maximumAggregateBytes,
            maximumNodes: AcpPermissionPayloadLimits.maximumAggregateNodes,
            maximumDepth: AcpPermissionPayloadLimits.maximumNestingDepth
        )
        guard let value else { return rejected(.malformed) }
        if let failure = aggregateScanner.scan(value) {
            inspectedNodes += aggregateScanner.nodes
            return rejected(
                failure == .bytes ? .aggregateBytes : .complexity,
                aggregateBytes: aggregateScanner.bytes
            )
        }
        func includeInherited(_ inherited: JSONValue?) -> AcpPermissionPayloadRejection? {
            guard let inherited else { return nil }
            if let failure = aggregateScanner.scan(inherited) {
                return failure == .bytes ? .aggregateBytes : .complexity
            }
            return nil
        }
        if inheritsTitle,
           let rejection = includeInherited(priorContext?.title.map(JSONValue.string)) {
            inspectedNodes += aggregateScanner.nodes
            return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
        }
        if inheritsKind,
           let rejection = includeInherited(priorContext?.kind.map(JSONValue.string)) {
            inspectedNodes += aggregateScanner.nodes
            return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
        }
        if inheritsRawInput,
           let rejection = includeInherited(priorContext?.rawInput) {
            inspectedNodes += aggregateScanner.nodes
            return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
        }
        if inheritsLocations,
           let rejection = includeInherited(.array((priorContext?.locationPaths ?? []).map(JSONValue.string))) {
            inspectedNodes += aggregateScanner.nodes
            return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
        }
        if inheritsDiffPaths,
           let rejection = includeInherited(.array((priorContext?.diffPaths ?? []).map(JSONValue.string))) {
            inspectedNodes += aggregateScanner.nodes
            return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
        }
        inspectedNodes += aggregateScanner.nodes

        func checkedString(
            _ candidate: JSONValue?,
            fallback: String?,
            maximumBytes: Int,
            rejection: AcpPermissionPayloadRejection
        ) -> AcpPermissionPayloadRejection? {
            let text: String?
            if let candidate {
                guard let decoded = candidate.stringValue else { return .malformed }
                text = decoded
            } else {
                text = fallback
            }
            guard let text else { return nil }
            return text.utf8.count <= maximumBytes ? nil : rejection
        }

        if let rejection = checkedString(
            params["sessionId"],
            fallback: nil,
            maximumBytes: AcpPermissionPayloadLimits.maximumSessionIDBytes,
            rejection: .sessionIDBytes
        ) { return rejected(rejection, aggregateBytes: aggregateScanner.bytes) }
        if let rejection = checkedString(
            toolCall?["toolCallId"],
            fallback: nil,
            maximumBytes: AcpPermissionPayloadLimits.maximumToolCallIDBytes,
            rejection: .toolCallIDBytes
        ) { return rejected(rejection, aggregateBytes: aggregateScanner.bytes) }
        if let rejection = checkedString(
            toolCall?["title"],
            fallback: priorContext?.title,
            maximumBytes: AcpPermissionPayloadLimits.maximumTitleBytes,
            rejection: .titleBytes
        ) { return rejected(rejection, aggregateBytes: aggregateScanner.bytes) }
        if let rejection = checkedString(
            toolCall?["kind"],
            fallback: priorContext?.kind,
            maximumBytes: AcpPermissionPayloadLimits.maximumKindBytes,
            rejection: .kindBytes
        ) { return rejected(rejection, aggregateBytes: aggregateScanner.bytes) }

        guard let options = params["options"]?.arrayValue,
              !options.isEmpty else {
            return rejected(.malformed, aggregateBytes: aggregateScanner.bytes)
        }
        guard options.count <= AcpPermissionPayloadLimits.maximumOptionCount else {
            return rejected(.optionCount, aggregateBytes: aggregateScanner.bytes)
        }
        for value in options {
            guard let option = value.objectValue,
                  let optionID = option["optionId"]?.stringValue,
                  !optionID.isEmpty else {
                return rejected(.malformed, aggregateBytes: aggregateScanner.bytes)
            }
            guard optionID.utf8.count <= AcpPermissionPayloadLimits.maximumOptionIDBytes else {
                return rejected(.optionIDBytes, aggregateBytes: aggregateScanner.bytes)
            }
            if let rejection = checkedString(
                option["name"],
                fallback: nil,
                maximumBytes: AcpPermissionPayloadLimits.maximumOptionNameBytes,
                rejection: .optionNameBytes
            ) { return rejected(rejection, aggregateBytes: aggregateScanner.bytes) }
            if let rejection = checkedString(
                option["kind"],
                fallback: nil,
                maximumBytes: AcpPermissionPayloadLimits.maximumOptionKindBytes,
                rejection: .optionKindBytes
            ) { return rejected(rejection, aggregateBytes: aggregateScanner.bytes) }
        }

        var seenPaths = Set<String>()
        func includePath(_ path: String) -> AcpPermissionPayloadRejection? {
            guard !path.isEmpty else { return .malformed }
            guard path.utf8.count <= AcpPermissionPayloadLimits.maximumPathBytes else {
                return .pathBytes
            }
            guard seenPaths.insert(path).inserted else { return nil }
            return seenPaths.count <= AcpPermissionPayloadLimits.maximumPathCount ? nil : .pathCount
        }
        if let locations = toolCall?["locations"] {
            guard let array = locations.arrayValue else {
                return rejected(.malformed, aggregateBytes: aggregateScanner.bytes)
            }
            for location in array {
                guard let path = location.objectValue?["path"]?.stringValue else {
                    return rejected(.malformed, aggregateBytes: aggregateScanner.bytes)
                }
                if let rejection = includePath(path) {
                    return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
                }
            }
        } else {
            for path in priorContext?.locationPaths ?? [] {
                if let rejection = includePath(path) {
                    return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
                }
            }
        }
        if let content = toolCall?["content"] {
            guard let array = content.arrayValue else {
                return rejected(.malformed, aggregateBytes: aggregateScanner.bytes)
            }
            for item in array {
                guard let object = item.objectValue else {
                    return rejected(.malformed, aggregateBytes: aggregateScanner.bytes)
                }
                if let type = object["type"], type.stringValue == nil {
                    return rejected(.malformed, aggregateBytes: aggregateScanner.bytes)
                }
                guard object["type"]?.stringValue == "diff" else { continue }
                guard let path = object["path"]?.stringValue else {
                    return rejected(.malformed, aggregateBytes: aggregateScanner.bytes)
                }
                if let rejection = includePath(path) {
                    return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
                }
            }
        } else {
            for path in priorContext?.diffPaths ?? [] {
                if let rejection = includePath(path) {
                    return rejected(rejection, aggregateBytes: aggregateScanner.bytes)
                }
            }
        }

        return AcpPermissionPayloadValidation(
            rejection: nil,
            aggregateBytes: aggregateScanner.bytes,
            inspectedNodes: inspectedNodes
        )
    }

    /// Test-visible lifecycle count for the security metadata introduced at
    /// this boundary. It must describe active asks only, never request history.
    var retainedPermissionOptionSetCount: Int { activePermissionRequests.count }

    var retainedToolCallReviewContextCount: Int { toolCallReviewContextStore.count }
    var retainedToolCallReviewContextBytes: Int { toolCallReviewContextStore.retainedBytes }
    var hasEvictedToolCallReviewContext: Bool { toolCallReviewContextStore.hasEvictedContext }

    /// Decode the complete permission review payload, including ACP v1's
    /// arbitrary `rawInput`. Kept pure for wire-contract tests.
    ///
    /// Returns nil for an ask no user could answer — params that are not an
    /// object, or an `options` list with nothing selectable in it. The caller
    /// turns that into a JSON-RPC error, because a review card with no buttons
    /// blocks the adapter just as thoroughly as no card at all. A missing
    /// `toolCall` is NOT malformed: partial asks fall back to the disclosure an
    /// earlier `session/update` already streamed.
    static func parsePermissionRequest(
        localID: Int,
        sessionID: String,
        params value: JSONValue?,
        priorContext: AcpToolCallReviewContext? = nil
    ) -> AcpPermissionRequest? {
        guard let params = value?.objectValue else { return nil }
        let toolCall = params["toolCall"]?.objectValue
        let title = toolCall?["title"] != nil
            ? (toolCall?["title"]?.stringValue ?? "Permission requested")
            : (priorContext?.title ?? "Permission requested")
        let kind = toolCall?["kind"] != nil
            ? (toolCall?["kind"]?.stringValue ?? "other")
            : (priorContext?.kind ?? "other")
        let rawInput: JSONValue?
        if toolCall?["rawInput"] != nil {
            if let value = toolCall?["rawInput"], value != .null {
                rawInput = value
            } else {
                rawInput = nil
            }
        } else {
            rawInput = priorContext?.rawInput
        }
        let locationPaths = toolCall?["locations"] != nil
            ? Self.locationPaths(toolCall?["locations"])
            : (priorContext?.locationPaths ?? [])
        let diffPaths = toolCall?["content"] != nil
            ? Self.diffPaths(toolCall?["content"])
            : (priorContext?.diffPaths ?? [])
        let options = (params["options"]?.arrayValue ?? []).compactMap { value -> AcpPermissionRequest.Option? in
            guard let o = value.objectValue, let optionID = o["optionId"]?.stringValue else { return nil }
            return AcpPermissionRequest.Option(
                id: optionID,
                name: o["name"]?.stringValue ?? optionID,
                kind: o["kind"]?.stringValue ?? "other"
            )
        }
        guard !options.isEmpty else { return nil }
        var seenPaths = Set<String>()
        let paths = (locationPaths + diffPaths).filter {
            !$0.isEmpty && seenPaths.insert($0).inserted
        }
        return AcpPermissionRequest(
            id: localID, sessionID: sessionID, title: title, options: options,
            rawInput: rawInput, kind: kind, paths: paths
        )
    }

    private func recordToolCallReviewContext(_ update: [String: JSONValue]) {
        guard let id = update["toolCallId"]?.stringValue else { return }
        toolCallReviewContextStore.record(id: id, update: update)
    }

    /// Merge ACP's replace-when-present ToolCallUpdate semantics. Pure so the
    /// partial-request correlation contract can be tested without a process.
    static func mergeToolCallReviewContext(
        _ prior: AcpToolCallReviewContext?,
        update: [String: JSONValue]
    ) -> AcpToolCallReviewContext {
        var context = prior ?? AcpToolCallReviewContext()
        if update["title"] != nil { context.title = update["title"]?.stringValue }
        if update["kind"] != nil { context.kind = update["kind"]?.stringValue }
        if update["rawInput"] != nil {
            if let value = update["rawInput"], value != .null {
                context.rawInput = value
            } else {
                context.rawInput = nil
            }
        }
        if update["locations"] != nil {
            context.locationPaths = locationPaths(update["locations"])
        }
        if update["content"] != nil {
            context.diffPaths = diffPaths(update["content"])
        }
        return context
    }

    private static func locationPaths(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { $0.objectValue?["path"]?.stringValue }
    }

    private static func diffPaths(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { item in
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "diff" else { return nil }
            return object["path"]?.stringValue
        }
    }

    private func handleReadTextFile(id: JSONValue?, params: JSONValue?) {
        guard let id else { return }
        guard access.workspaceRead else {
            respondError(
                id: id,
                code: -32000,
                message: runProfile.allows(.readTextFile)
                    ? "Blocked by custom adapter containment: workspace read was not approved."
                    : "Blocked by run profile “\(runProfile.name)”: workspace read is disabled."
            )
            return
        }
        guard let workspaceRoot else {
            respondError(
                id: id,
                method: "fs/read_text_file",
                code: -32000,
                message: errorText(AcpClientError.notRunning)
            )
            return
        }
        let generation = connectionGeneration
        let path = params?.objectValue?["path"]?.stringValue
        let sensitiveGlobs = fsSensitiveGlobs
        filesystemCallbacksInFlight += 1
        Task {
            defer { filesystemCallbacksInFlight -= 1 }
            do {
                let content = try await filesystemWorker.readTextFile(
                    path: path,
                    workspaceRoot: workspaceRoot,
                    sensitiveGlobs: sensitiveGlobs
                )
                guard generation == connectionGeneration else { return }
                respond(
                    id: id,
                    method: "fs/read_text_file",
                    result: .object(["content": .string(content)])
                )
            } catch {
                guard generation == connectionGeneration else { return }
                respondError(
                    id: id,
                    method: "fs/read_text_file",
                    code: -32000,
                    message: errorText(error)
                )
            }
        }
    }

    private func handleWriteTextFile(id: JSONValue?, params: JSONValue?) {
        guard let id else { return }
        guard access.workspaceWrite else {
            respondError(
                id: id,
                code: -32000,
                message: runProfile.allows(.writeTextFile)
                    ? "Blocked by custom adapter containment: workspace write was not approved."
                    : "Blocked by run profile “\(runProfile.name)”: workspace write is disabled."
            )
            return
        }
        guard let workspaceRoot else {
            respondError(
                id: id,
                method: "fs/write_text_file",
                code: -32000,
                message: errorText(AcpClientError.notRunning)
            )
            return
        }
        let generation = connectionGeneration
        let path = params?.objectValue?["path"]?.stringValue
        let content = params?.objectValue?["content"]?.stringValue ?? ""
        let sensitiveGlobs = fsSensitiveGlobs
        filesystemCallbacksInFlight += 1
        Task {
            defer { filesystemCallbacksInFlight -= 1 }
            do {
                try await filesystemWorker.writeTextFile(
                    path: path,
                    content: content,
                    workspaceRoot: workspaceRoot,
                    sensitiveGlobs: sensitiveGlobs
                )
                guard generation == connectionGeneration else { return }
                respond(id: id, method: "fs/write_text_file", result: .object([:]))
            } catch {
                guard generation == connectionGeneration else { return }
                respondError(
                    id: id,
                    method: "fs/write_text_file",
                    code: -32000,
                    message: errorText(error)
                )
            }
        }
    }

    // MARK: - Parsing helpers

    static func parseCapabilities(_ result: JSONValue) -> AcpAgentCapabilities {
        var caps = AcpAgentCapabilities()
        // The steering extension is advertised on the response's OWN `_meta`,
        // beside `agentCapabilities` rather than inside it, so it is read before
        // (and independently of) the capability block — an adapter that offers
        // steering without an `agentCapabilities` object still counts.
        caps.steering = result.objectValue?["_meta"]?.objectValue?["steering"]?
            .objectValue?["supported"]?.boolValue ?? false
        guard let agent = result.objectValue?["agentCapabilities"]?.objectValue else { return caps }
        caps.loadSession = agent["loadSession"]?.boolValue ?? false
        let session = agent["sessionCapabilities"]?.objectValue
        caps.resumeSession = session?["resume"]?.boolValue ?? false
        caps.closeSession = session?["close"]?.boolValue ?? false
        caps.promptQueueing = agent["_meta"]?.objectValue?["claudeCode"]?.objectValue?["promptQueueing"]?.boolValue ?? false
        let mcp = agent["mcpCapabilities"]?.objectValue
        caps.mcpHTTP = mcp?["http"]?.boolValue ?? false
        caps.mcpSSE = mcp?["sse"]?.boolValue ?? false
        let prompt = agent["promptCapabilities"]?.objectValue
        caps.promptImage = prompt?["image"]?.boolValue ?? false
        caps.promptEmbeddedContext = prompt?["embeddedContext"]?.boolValue ?? false
        return caps
    }

    /// JSON numbers decode as either `.integer` or `.number`; ACP cost accepts
    /// both. Keep non-finite values out of UI/accounting state.
    private static func finiteDouble(_ value: JSONValue?) -> Double? {
        let number: Double?
        switch value {
        case let .integer(integer): number = Double(integer)
        case let .number(double): number = double
        default: number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func parseToolCall(_ object: [String: JSONValue]) -> AcpToolCall? {
        guard let id = object["toolCallId"]?.stringValue else { return nil }
        let locations = (object["locations"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["path"]?.stringValue
        }
        return AcpToolCall(
            id: id,
            title: object["title"]?.stringValue ?? id,
            kind: object["kind"]?.stringValue ?? "other",
            status: object["status"]?.stringValue.flatMap(AcpToolCall.Status.init) ?? .pending,
            content: parseToolContent(object["content"]),
            locations: locations
        )
    }

    /// Parse the adapter's `configOptions` array (select-type options only —
    /// the only kind current adapters emit).
    static func parseConfigOptions(_ value: JSONValue?) -> [AcpConfigOption] {
        (value?.arrayValue ?? []).compactMap { item -> AcpConfigOption? in
            guard let o = item.objectValue, let id = o["id"]?.stringValue else { return nil }
            let choices = (o["options"]?.arrayValue ?? []).compactMap { choice -> AcpConfigOption.Choice? in
                guard let c = choice.objectValue, let value = c["value"]?.stringValue else { return nil }
                return AcpConfigOption.Choice(value: value, name: c["name"]?.stringValue ?? value)
            }
            return AcpConfigOption(
                id: id,
                name: o["name"]?.stringValue ?? id,
                category: o["category"]?.stringValue,
                currentValue: o["currentValue"]?.stringValue,
                choices: choices
            )
        }
    }

    /// Parse an ACP `ToolCallContent[]` into our display artifacts. Recognizes
    /// `{type:"diff", path, oldText, newText}` and `{type:"content", content:{...}}`
    /// (text / resource blocks); a `{type:"terminal"}` reference degrades to a
    /// short text placeholder.
    static func parseToolContent(_ value: JSONValue?) -> [AcpToolContent] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { item -> AcpToolContent? in
            guard let object = item.objectValue else { return nil }
            switch object["type"]?.stringValue {
            case "diff":
                guard let path = object["path"]?.stringValue,
                      let newText = object["newText"]?.stringValue else { return nil }
                return .diff(path: path, oldText: object["oldText"]?.stringValue, newText: newText)
            case "content":
                let block = object["content"]?.objectValue
                if let text = block?["text"]?.stringValue { return .text(text) }
                if let resource = block?["resource"]?.objectValue?["text"]?.stringValue { return .text(resource) }
                if block?["type"]?.stringValue == "image" { return .text("[image]") }
                return nil
            case "terminal":
                guard let terminalID = object["terminalId"]?.stringValue else { return nil }
                return .terminal(id: terminalID)
            default:
                // Bare content block (no wrapper type) with inline text.
                if let text = object["text"]?.stringValue { return .text(text) }
                return nil
            }
        }
    }
}

/// The Kaisola-owned mutation boundary for ACP `fs/write_text_file` requests.
/// Paths are reviewed and then walked from an open workspace descriptor one
/// component at a time. Final replacement is relative to the verified parent,
/// never a path that can be redirected through a symbolic link after review.
enum AcpWorkspaceFileWriter {
    typealias BeforeMutation = () throws -> Void

    enum ExtendedAttributeDisposition: Equatable {
        case preserve
        case remove
    }

    private struct ExtendedAttribute {
        let name: String
        let value: Data
    }

    private final class AccessControlList {
        let rawValue: acl_t

        init(_ rawValue: acl_t) {
            self.rawValue = rawValue
        }

        deinit {
            _ = acl_free(UnsafeMutableRawPointer(rawValue))
        }
    }

    private enum AccessControlListSnapshot {
        case unsupported
        case absent
        case value(AccessControlList)
    }

    private struct MetadataSnapshot {
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let extendedAttributes: [ExtendedAttribute]
        let accessControlList: AccessControlListSnapshot
    }

    private static let maximumExtendedAttributeCount = 128
    private static let maximumExtendedAttributeNameBytes = 64 * 1_024
    private static let maximumExtendedAttributeValueBytes = 1 * 1_024 * 1_024
    private static let maximumExtendedAttributeTotalBytes = 4 * 1_024 * 1_024

    private final class Descriptor {
        private(set) var rawValue: Int32

        init(_ rawValue: Int32) {
            self.rawValue = rawValue
        }

        deinit {
            if rawValue >= 0 { _ = Darwin.close(rawValue) }
        }
    }

    /// Resolve only lexical `.`/`..` components. Deliberately do not resolve
    /// symlinks: doing so would erase the distinction this boundary must reject.
    static func normalizedTargetPath(_ requestedPath: String?, workspaceRoot: String) throws -> String {
        let root = (workspaceRoot as NSString).standardizingPath
        guard root.hasPrefix("/") else {
            throw rejected("the session project is unavailable")
        }
        let raw = requestedPath?.isEmpty == false ? requestedPath! : root
        let target = raw.hasPrefix("/")
            ? (raw as NSString).standardizingPath
            : ((root as NSString).appendingPathComponent(raw) as NSString).standardizingPath
        guard target != root,
              target.hasPrefix(root + "/"),
              !target.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw rejected("the target escapes the session project")
        }
        return target
    }

    static func write(
        _ data: Data,
        to requestedPath: String,
        workspaceRoot: String,
        beforeMutation: BeforeMutation? = nil,
        beforeReplacementCommit: BeforeMutation? = nil
    ) throws {
        let rootPath = (workspaceRoot as NSString).standardizingPath
        let targetPath = try normalizedTargetPath(requestedPath, workspaceRoot: rootPath)
        let suffix = targetPath.dropFirst(rootPath.count + 1)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let leaf = components.last, !leaf.isEmpty else {
            throw rejected("the target is not a regular file")
        }

        let root = try openRoot(rootPath)
        let parentComponents = Array(components.dropLast())
        let parent = try openParent(
            components: parentComponents,
            root: root,
            createMissingDirectories: true
        )
        let reviewedParent = try descriptorMetadata(parent)
        let reviewedEntry = try entryMetadata(named: leaf, in: parent)
        var reviewedMetadata: MetadataSnapshot?
        if let reviewedEntry {
            guard !isSymbolicLink(reviewedEntry) else {
                throw rejected("symbolic-link targets are not writable")
            }
            guard isRegularFile(reviewedEntry) else {
                throw rejected("the target is not a regular file")
            }
            let reviewedDescriptor = try openReviewedEntry(
                named: leaf,
                in: parent,
                expected: reviewedEntry
            )
            reviewedMetadata = try captureMetadata(
                from: reviewedDescriptor,
                expected: reviewedEntry
            )
        }

        // Deterministic test seam: production has no callback. Re-open the
        // lexical parent afterwards and require it plus the leaf identity to
        // remain exactly what was reviewed before creating any temporary file.
        try beforeMutation?()
        let currentParent = try openParent(
            components: parentComponents,
            root: root,
            createMissingDirectories: false
        )
        guard sameIdentity(reviewedParent, try descriptorMetadata(currentParent)) else {
            throw rejected("the target changed after review")
        }
        try validateCurrentEntry(
            try entryMetadata(named: leaf, in: currentParent),
            matches: reviewedEntry
        )

        let mode = reviewedMetadata?.mode
            ?? mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        let temporary = try createTemporaryFile(in: parent, mode: mode)
        do {
            try writeAll(data, to: temporary.descriptor.rawValue)
            if let reviewedMetadata {
                try applyMetadata(reviewedMetadata, to: temporary.descriptor)
            }
            guard Darwin.fsync(temporary.descriptor.rawValue) == 0 else {
                throw rejected("the target metadata could not be preserved")
            }
            let installationParent = try openParent(
                components: parentComponents,
                root: root,
                createMissingDirectories: false
            )
            guard sameIdentity(
                reviewedParent,
                try descriptorMetadata(installationParent)
            ) else {
                throw rejected("the target changed after review")
            }
            try validateCurrentEntry(
                try entryMetadata(named: leaf, in: installationParent),
                matches: reviewedEntry
            )
            if let reviewedEntry {
                try replaceExisting(
                    leaf: leaf,
                    reviewedEntry: reviewedEntry,
                    temporaryLeaf: temporary.leaf,
                    parent: parent,
                    beforeCommit: beforeReplacementCommit
                )
            } else {
                try installNew(
                    leaf: leaf,
                    temporaryLeaf: temporary.leaf,
                    parent: parent
                )
            }
        } catch {
            unlinkIfOwned(
                named: temporary.leaf,
                descriptor: temporary.descriptor,
                in: parent
            )
            throw error
        }
    }

    /// Preserve ordinary metadata but deliberately discard attributes whose
    /// bytes describe the old file contents or duplicate policy restored via
    /// the ACL API. Quarantine, Finder tags, and application-defined metadata
    /// remain attached to the replacement.
    static func extendedAttributeDisposition(for name: String) -> ExtendedAttributeDisposition {
        if name == XATTR_RESOURCEFORK_NAME
            || name == "com.apple.decmpfs"
            || name == "com.apple.system.Security"
            || name.hasPrefix("com.apple.cs.") {
            return .remove
        }
        return .preserve
    }

    private static func openReviewedEntry(
        named leaf: String,
        in parent: Descriptor,
        expected: stat
    ) throws -> Descriptor {
        let raw = leaf.withCString { name in
            Darwin.openat(parent.rawValue, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard raw >= 0 else {
            if errno == ELOOP { throw rejected("symbolic-link targets are not writable") }
            throw rejected("the target metadata could not be read")
        }
        let descriptor = Descriptor(raw)
        let actual = try descriptorMetadata(descriptor)
        guard isRegularFile(actual), sameIdentity(expected, actual) else {
            throw rejected("the target changed after review")
        }
        return descriptor
    }

    private static func captureMetadata(
        from descriptor: Descriptor,
        expected: stat
    ) throws -> MetadataSnapshot {
        let actual = try descriptorMetadata(descriptor)
        guard isRegularFile(actual), sameIdentity(expected, actual) else {
            throw rejected("the target changed after review")
        }
        return MetadataSnapshot(
            mode: mode_t(actual.st_mode & 0o777),
            owner: actual.st_uid,
            group: actual.st_gid,
            extendedAttributes: try captureExtendedAttributes(from: descriptor),
            accessControlList: try captureAccessControlList(from: descriptor)
        )
    }

    private static func captureExtendedAttributes(
        from descriptor: Descriptor
    ) throws -> [ExtendedAttribute] {
        let listSize = Darwin.flistxattr(descriptor.rawValue, nil, 0, 0)
        if listSize < 0 {
            if errno == ENOTSUP { return [] }
            throw rejected("the target metadata could not be read")
        }
        guard listSize <= ssize_t(maximumExtendedAttributeNameBytes) else {
            throw rejected("the target metadata exceeds safe limits")
        }
        if listSize == 0 { return [] }

        var names = [CChar](repeating: 0, count: Int(listSize))
        let readSize = names.withUnsafeMutableBufferPointer { buffer in
            Darwin.flistxattr(descriptor.rawValue, buffer.baseAddress, buffer.count, 0)
        }
        guard readSize >= 0, readSize <= ssize_t(names.count) else {
            throw rejected("the target metadata changed during review")
        }

        var attributes: [ExtendedAttribute] = []
        var totalBytes = 0
        var start = 0
        let namesRead = Int(readSize)
        for index in 0..<namesRead where names[index] == 0 {
            guard index > start else {
                throw rejected("the target metadata could not be read")
            }
            let nameBytes = names[start..<index].map { UInt8(bitPattern: $0) }
            guard let name = String(bytes: nameBytes, encoding: .utf8),
                  name.utf8.count <= Int(XATTR_MAXNAMELEN) else {
                throw rejected("the target metadata could not be read")
            }
            start = index + 1
            guard extendedAttributeDisposition(for: name) == .preserve else { continue }
            guard attributes.count < maximumExtendedAttributeCount else {
                throw rejected("the target metadata exceeds safe limits")
            }
            guard let value = try readExtendedAttribute(named: name, from: descriptor) else {
                continue
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(value.count)
            guard !overflow, nextTotal <= maximumExtendedAttributeTotalBytes else {
                throw rejected("the target metadata exceeds safe limits")
            }
            totalBytes = nextTotal
            attributes.append(ExtendedAttribute(name: name, value: value))
        }
        guard start == namesRead else {
            throw rejected("the target metadata could not be read")
        }
        return attributes
    }

    private static func readExtendedAttribute(
        named name: String,
        from descriptor: Descriptor
    ) throws -> Data? {
        let size = name.withCString { attributeName in
            Darwin.fgetxattr(descriptor.rawValue, attributeName, nil, 0, 0, 0)
        }
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw rejected("the target metadata could not be read")
        }
        guard size <= ssize_t(maximumExtendedAttributeValueBytes) else {
            throw rejected("the target metadata exceeds safe limits")
        }
        if size == 0 { return Data() }

        var value = Data(count: Int(size))
        let readSize = value.withUnsafeMutableBytes { bytes in
            name.withCString { attributeName in
                Darwin.fgetxattr(
                    descriptor.rawValue,
                    attributeName,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        if readSize < 0, errno == ENOATTR { return nil }
        guard readSize == size else {
            throw rejected("the target metadata changed during review")
        }
        return value
    }

    private static func captureAccessControlList(
        from descriptor: Descriptor
    ) throws -> AccessControlListSnapshot {
        errno = 0
        if let accessControlList = Darwin.acl_get_fd_np(
            descriptor.rawValue,
            ACL_TYPE_EXTENDED
        ) {
            return .value(AccessControlList(accessControlList))
        }
        if errno == ENOENT { return .absent }
        if errno == ENOTSUP { return .unsupported }
        throw rejected("the target metadata could not be read")
    }

    private static func applyMetadata(
        _ metadata: MetadataSnapshot,
        to descriptor: Descriptor
    ) throws {
        let current = try descriptorMetadata(descriptor)
        if current.st_uid != metadata.owner || current.st_gid != metadata.group {
            guard Darwin.fchown(descriptor.rawValue, metadata.owner, metadata.group) == 0 else {
                throw rejected("the target ownership could not be preserved")
            }
        }

        for attribute in metadata.extendedAttributes {
            let result = attribute.value.withUnsafeBytes { bytes in
                attribute.name.withCString { name in
                    Darwin.fsetxattr(
                        descriptor.rawValue,
                        name,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        0
                    )
                }
            }
            guard result == 0 else {
                throw rejected("the target metadata could not be preserved")
            }
        }
        try applyAccessControlList(metadata.accessControlList, to: descriptor)
        guard Darwin.fchmod(descriptor.rawValue, metadata.mode) == 0 else {
            throw rejected("the target mode could not be preserved")
        }

        let applied = try descriptorMetadata(descriptor)
        guard applied.st_uid == metadata.owner,
              applied.st_gid == metadata.group,
              mode_t(applied.st_mode & 0o777) == metadata.mode else {
            throw rejected("the target metadata could not be preserved")
        }
    }

    private static func applyAccessControlList(
        _ snapshot: AccessControlListSnapshot,
        to descriptor: Descriptor
    ) throws {
        switch snapshot {
        case .unsupported:
            return
        case .absent:
            guard let empty = Darwin.acl_init(0) else {
                throw rejected("the target ACL could not be preserved")
            }
            defer { _ = acl_free(UnsafeMutableRawPointer(empty)) }
            guard Darwin.acl_set_fd_np(descriptor.rawValue, empty, ACL_TYPE_EXTENDED) == 0 else {
                throw rejected("the target ACL could not be preserved")
            }
        case let .value(accessControlList):
            guard Darwin.acl_set_fd_np(
                descriptor.rawValue,
                accessControlList.rawValue,
                ACL_TYPE_EXTENDED
            ) == 0 else {
                throw rejected("the target ACL could not be preserved")
            }
        }
    }

    private static func openRoot(_ rootPath: String) throws -> Descriptor {
        let raw = rootPath.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard raw >= 0 else {
            if errno == ELOOP { throw rejected("the session project is a symbolic link") }
            throw rejected("the session project is unavailable")
        }
        return Descriptor(raw)
    }

    private static func openParent(
        components: [String],
        root: Descriptor,
        createMissingDirectories: Bool
    ) throws -> Descriptor {
        var current = root
        for component in components {
            var raw = openDirectory(named: component, in: current)
            if raw < 0, errno == ENOENT, createMissingDirectories {
                let created = component.withCString { name in
                    Darwin.mkdirat(current.rawValue, name, 0o777)
                }
                if created != 0, errno != EEXIST {
                    throw descriptorFailure(errno, component: component, parent: current)
                }
                raw = openDirectory(named: component, in: current)
            }
            guard raw >= 0 else {
                throw descriptorFailure(errno, component: component, parent: current)
            }
            current = Descriptor(raw)
        }
        return current
    }

    private static func openDirectory(named component: String, in parent: Descriptor) -> Int32 {
        component.withCString { name in
            Darwin.openat(
                parent.rawValue,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
    }

    private static func descriptorFailure(
        _ code: Int32,
        component: String,
        parent: Descriptor
    ) -> AcpClientError {
        if code == ELOOP || entryIsSymbolicLink(named: component, in: parent) {
            return rejected("symbolic-link parents are not writable")
        }
        if code == ENOENT {
            return rejected("the target changed after review")
        }
        if code == ENOTDIR {
            return rejected("a target parent is not a directory")
        }
        if code == EACCES || code == EPERM {
            return rejected("the target is not writable")
        }
        return rejected("the target could not be safely opened")
    }

    private static func descriptorMetadata(_ descriptor: Descriptor) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor.rawValue, &metadata) == 0 else {
            throw rejected("the target changed after review")
        }
        return metadata
    }

    private static func entryMetadata(named leaf: String, in parent: Descriptor) throws -> stat? {
        var metadata = stat()
        let result = leaf.withCString { name in
            Darwin.fstatat(parent.rawValue, name, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw descriptorFailure(errno, component: leaf, parent: parent)
    }

    private static func entryIsSymbolicLink(named leaf: String, in parent: Descriptor) -> Bool {
        var metadata = stat()
        let result = leaf.withCString { name in
            Darwin.fstatat(parent.rawValue, name, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 && isSymbolicLink(metadata)
    }

    private static func validateCurrentEntry(_ current: stat?, matches reviewed: stat?) throws {
        if let current, isSymbolicLink(current) {
            throw rejected("symbolic-link targets are not writable")
        }
        switch (reviewed, current) {
        case (nil, nil):
            return
        case let (.some(expected), .some(actual))
            where isRegularFile(actual) && sameIdentity(expected, actual):
            return
        default:
            throw rejected("the target changed after review")
        }
    }

    private static func createTemporaryFile(
        in parent: Descriptor,
        mode: mode_t
    ) throws -> (leaf: String, descriptor: Descriptor) {
        for _ in 0..<128 {
            let leaf = ".kaisola-acp-write-\(UUID().uuidString)"
            let raw = leaf.withCString { name in
                Darwin.openat(
                    parent.rawValue,
                    name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode
                )
            }
            if raw >= 0 {
                let descriptor = Descriptor(raw)
                guard Darwin.fchmod(raw, mode) == 0 else {
                    unlinkIfOwned(named: leaf, descriptor: descriptor, in: parent)
                    throw rejected("the target is not writable")
                }
                return (leaf, descriptor)
            }
            if errno != EEXIST {
                throw rejected("the target is not writable")
            }
        }
        throw rejected("the target is not writable")
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw rejected("the target could not be written") }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw rejected("the target could not be written")
        }
    }

    private static func installNew(
        leaf: String,
        temporaryLeaf: String,
        parent: Descriptor
    ) throws {
        let result = temporaryLeaf.withCString { temporaryName in
            leaf.withCString { destinationName in
                Darwin.renameatx_np(
                    parent.rawValue,
                    temporaryName,
                    parent.rawValue,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw rejected("the target changed after review") }
            throw rejected("the target could not be written")
        }
    }

    private static func replaceExisting(
        leaf: String,
        reviewedEntry: stat,
        temporaryLeaf: String,
        parent: Descriptor,
        beforeCommit: BeforeMutation?
    ) throws {
        guard exchange(temporaryLeaf, leaf, in: parent) == 0 else {
            if errno == ENOENT { throw rejected("the target changed after review") }
            throw rejected("the target could not be safely replaced")
        }

        do {
            let displaced = try entryMetadata(named: temporaryLeaf, in: parent)
            guard let displaced,
                  !isSymbolicLink(displaced),
                  sameIdentity(reviewedEntry, displaced) else {
                throw rejected("the target changed after review")
            }
            try beforeCommit?()
            let stillDisplaced = try entryMetadata(named: temporaryLeaf, in: parent)
            guard let stillDisplaced,
                  !isSymbolicLink(stillDisplaced),
                  sameIdentity(reviewedEntry, stillDisplaced) else {
                throw rejected("the target changed before replacement committed")
            }
            guard unlink(named: temporaryLeaf, in: parent) == 0 else {
                throw rejected("the target could not be safely replaced")
            }
        } catch {
            guard exchange(temporaryLeaf, leaf, in: parent) == 0 else {
                throw rejected("the target could not be safely restored")
            }
            throw error
        }
    }

    private static func exchange(_ first: String, _ second: String, in parent: Descriptor) -> Int32 {
        first.withCString { firstName in
            second.withCString { secondName in
                Darwin.renameatx_np(
                    parent.rawValue,
                    firstName,
                    parent.rawValue,
                    secondName,
                    UInt32(RENAME_SWAP)
                )
            }
        }
    }

    private static func unlink(named leaf: String, in parent: Descriptor) -> Int32 {
        leaf.withCString { name in Darwin.unlinkat(parent.rawValue, name, 0) }
    }

    /// After an exchange, the temporary *name* can refer to the displaced
    /// target while the temporary descriptor still refers to our new bytes.
    /// Cleanup only when both identities match, so a failed rollback can never
    /// turn error handling into deletion of somebody else's entry.
    private static func unlinkIfOwned(
        named leaf: String,
        descriptor: Descriptor,
        in parent: Descriptor
    ) {
        var owned = stat()
        guard Darwin.fstat(descriptor.rawValue, &owned) == 0,
              let named = try? entryMetadata(named: leaf, in: parent),
              sameIdentity(owned, named) else {
            return
        }
        _ = unlink(named: leaf, in: parent)
    }

    private static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private static func isSymbolicLink(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFLNK
    }

    private static func isRegularFile(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
    }

    private static func rejected(_ reason: String) -> AcpClientError {
        .requestFailed("Blocked agent file write: \(reason).")
    }
}
