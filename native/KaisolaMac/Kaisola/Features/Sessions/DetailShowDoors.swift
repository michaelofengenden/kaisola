/// Which "show" doors the content surface draws at its top-right. The panes'
/// own minus buttons are the hide doors; a show door exists exactly while its
/// pane is hidden, so when everything is open the corner is clean.
struct DetailShowDoors: Equatable {
    let showFiles: Bool
    let showDocument: Bool

    var isEmpty: Bool { !showFiles && !showDocument }

    /// `hasProjectDirectory` gates the Files door: without a project root the
    /// rail cannot render, and a door that opens onto nothing teaches the user
    /// it is broken.
    static func resolve(
        railVisible: Bool,
        previewVisible: Bool,
        hasProjectDirectory: Bool
    ) -> DetailShowDoors {
        DetailShowDoors(
            showFiles: !railVisible && hasProjectDirectory,
            showDocument: !previewVisible
        )
    }
}
