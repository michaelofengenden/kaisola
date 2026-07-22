import Foundation

struct TerminalDocument: Equatable, Sendable {
    static let maximumRetainedBytes = 8 * 1_024 * 1_024

    var sessionID: String?
    var output: String
    var cursor: TerminalCursor?
    var truncated: Bool
    var exited: Bool
    var errorMessage: String?

    static let empty = TerminalDocument(
        sessionID: nil,
        output: "",
        cursor: nil,
        truncated: false,
        exited: false,
        errorMessage: nil
    )

    static func failure(sessionID: String, message: String) -> TerminalDocument {
        TerminalDocument(
            sessionID: sessionID,
            output: "",
            cursor: nil,
            truncated: false,
            exited: false,
            errorMessage: message
        )
    }

    func applying(_ result: TerminalSubscriptionResult, sessionID: String) -> TerminalDocument {
        switch result {
        case let .snapshot(snapshot, resetReason):
            // A cursor-based resubscribe returns only bytes after the cursor.
            // Preserve the already-rendered prefix when the broker proves the
            // suffix is exactly contiguous; reset snapshots still replace it.
            if resetReason == nil,
               self.sessionID == sessionID,
               let cursor,
               cursor.streamEpoch == snapshot.streamEpoch,
               cursor.offset == snapshot.startOffset {
                var document = self
                document.output.append(snapshot.output)
                document.cursor = TerminalCursor(
                    streamEpoch: snapshot.streamEpoch,
                    offset: snapshot.endOffset
                )
                document.exited = snapshot.exited
                document.errorMessage = nil
                document.trimRetainedOutputIfNeeded()
                return document
            }
            var document = TerminalDocument(
                sessionID: sessionID,
                output: snapshot.output,
                cursor: TerminalCursor(streamEpoch: snapshot.streamEpoch, offset: snapshot.endOffset),
                truncated: snapshot.truncated || resetReason != nil,
                exited: snapshot.exited,
                errorMessage: nil
            )
            document.trimRetainedOutputIfNeeded()
            return document
        case let .current(cursor):
            return TerminalDocument(
                sessionID: sessionID,
                output: self.sessionID == sessionID ? output : "",
                cursor: cursor,
                truncated: self.sessionID == sessionID && truncated,
                exited: self.sessionID == sessionID && exited,
                errorMessage: nil
            )
        }
    }

    mutating func append(epoch: String, startOffset: Int64, endOffset: Int64, data: String) -> Bool {
        guard let cursor,
              cursor.streamEpoch == epoch,
              cursor.offset == startOffset,
              startOffset + Int64(data.utf8.count) == endOffset else { return false }
        output.append(data)
        self.cursor = TerminalCursor(streamEpoch: epoch, offset: endOffset)
        trimRetainedOutputIfNeeded()
        return true
    }

    private mutating func trimRetainedOutputIfNeeded() {
        let byteCount = output.utf8.count
        guard byteCount > Self.maximumRetainedBytes else { return }

        let bytesToDrop = byteCount - Self.maximumRetainedBytes
        let utf8 = output.utf8
        var boundary = utf8.index(utf8.startIndex, offsetBy: bytesToDrop)
        while boundary < utf8.endIndex,
              boundary.samePosition(in: output) == nil {
            boundary = utf8.index(after: boundary)
        }
        guard let stringBoundary = boundary.samePosition(in: output) else {
            output = ""
            truncated = true
            return
        }
        output.removeSubrange(output.startIndex..<stringBoundary)
        truncated = true
    }
}
