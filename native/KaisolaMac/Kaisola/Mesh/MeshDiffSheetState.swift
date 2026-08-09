import Foundation

/// The Mesh diff sheet's load state, scoped to the one column it is showing.
///
/// The sheet used to keep a single shared patch string: opening a second column
/// rendered the previous agent's diff — or claimed "No changes yet." — until the
/// new request landed, and a slow diff could still arrive after the user had
/// switched columns or dismissed the sheet. Content is now keyed by column and
/// every request carries a token, so opening drops whatever the last column left
/// behind and a late result is discarded instead of applied.
struct MeshDiffSheetState: Equatable {
    /// What the sheet renders for the column it is currently showing. `.loading`
    /// is distinct from `.loaded("")` on purpose: an empty patch means the
    /// column really has no changes, and only its own completed request can say
    /// so.
    enum Content: Equatable {
        case loading
        case loaded(String)
    }

    /// The column whose diff the sheet is showing, or nil when dismissed.
    private(set) var columnID: String?
    private(set) var content: Content = .loading
    /// Bumped on every open and close. A completed diff applies only while it
    /// still carries the token of the request the sheet is waiting on.
    private(set) var token: UInt64 = 0

    var isPresented: Bool { columnID != nil }

    var isLoading: Bool { content == .loading }

    /// The patch to render, or nil while this column's own diff is still in
    /// flight.
    var patch: String? {
        guard case let .loaded(patch) = content else { return nil }
        return patch
    }

    /// Point the sheet at `columnID` and clear the previous column's content.
    /// The returned token is the one the resulting request must carry back.
    @discardableResult
    mutating func open(columnID: String) -> UInt64 {
        self.columnID = columnID
        content = .loading
        token &+= 1
        return token
    }

    /// Apply a completed diff. A result for another column, or for a request the
    /// sheet has already moved on from, is dropped; the return value says
    /// whether it was taken.
    @discardableResult
    mutating func apply(patch: String, from columnID: String, token: UInt64) -> Bool {
        guard self.token == token, self.columnID == columnID else { return false }
        content = .loaded(patch)
        return true
    }

    /// Dismiss the sheet and invalidate whatever request is still in flight.
    mutating func close() {
        columnID = nil
        content = .loading
        token &+= 1
    }
}
