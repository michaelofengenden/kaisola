import Foundation

/// A user mapping from file extensions to one of the preview's *text* kinds.
/// Deliberately narrower than the preview itself: image, PDF, and docx run
/// dedicated loaders with their own size caps and parsers, and letting a
/// mapping route arbitrary bytes into those loaders would be new attack
/// surface. Every mappable kind flows through the same size cap, binary
/// sniff, and text decode as plain text — a wrong mapping can only ever
/// mis-*style* a file, never mis-parse it.
struct PreviewMappingSpec: Codable, Equatable, Identifiable {
    /// The kinds a mapping may choose. Raw values are what the JSON says.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case text, markdown, csv, json, html
    }

    var id: String
    var extensions: [String]
    var kind: String

    static let maximumExtensions = 16

    var validationError: String? {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanID.isEmpty { return "The mapping has no id." }
        if cleanID.count > 64 { return "The id must be 64 characters or fewer." }
        if cleanID.unicodeScalars.contains(where: { !CharacterSet.alphanumerics.contains($0) && $0 != "-" && $0 != "_" }) {
            return "The id may only use letters, numbers, dashes, and underscores."
        }
        if Kind(rawValue: kind) == nil {
            let names = Kind.allCases.map(\.rawValue).joined(separator: ", ")
            return "\"\(kind)\" is not a preview kind (\(names))."
        }
        if extensions.isEmpty { return "The mapping claims no file extensions." }
        if extensions.count > Self.maximumExtensions {
            return "A mapping may claim at most \(Self.maximumExtensions) extensions."
        }
        for ext in extensions {
            let clean = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if clean.isEmpty || clean.count > 12
                || clean.unicodeScalars.contains(where: { !CharacterSet.alphanumerics.contains($0) }) {
                return "\"\(ext)\" is not a usable file extension (letters and numbers, 12 characters or fewer, no dot)."
            }
        }
        return nil
    }

    var normalizedExtensions: [String] {
        extensions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}

/// Persists preview mappings — the standard capped/atomic recipe, plus the
/// workspace archive's rule for bytes this build cannot read: damage is named,
/// kept, and never quietly replaced.
///
/// Reading used to answer every file problem with an empty array, so one
/// truncated byte looked exactly like "this user has no mappings" and the next
/// edit wrote a one-entry file over a catalog that was still recoverable.
/// Reads still degrade to no mappings — a preview that loses its custom
/// styling is a small, visible loss — but *writes* now ask what is actually on
/// disk first, and each answer gets its own handling.
///
/// Built-in classifications always win before a mapping is consulted, so a
/// mapping can never take over `.json`, an image, or the binary sniff; there is
/// nothing to reserve because the built-ins simply run first.
struct PreviewMappingStore: Sendable {
    /// The format this build writes. A file naming a higher version came from a
    /// newer Kaisola: good data this build must not reinterpret.
    static let formatVersion = 1

    /// What the mapping file turned out to be. Kept as separate states because
    /// they need opposite handling: no file is an ordinary first run, bytes we
    /// cannot decode are recoverable evidence, a newer format is data another
    /// build still needs intact, and a read that failed says nothing at all
    /// about the contents.
    enum State: Equatable, Sendable {
        /// Nothing on disk yet — the first run, and the only absent state a
        /// save may fill in.
        case missing
        case loaded([PreviewMappingSpec])
        /// Present, but not decodable as a mapping registry.
        case corrupt
        /// Written by a newer Kaisola than this one.
        case newerVersionData(formatVersion: Int)
        /// Present and possibly intact, but this build could not read it
        /// (permissions, ownership, an unexpected file type).
        case unreadable(reason: String)

        /// The mappings a preview may consult. Every damaged state reads as
        /// none: styling degrades, and that decision never reaches disk.
        var specs: [PreviewMappingSpec] {
            if case .loaded(let specs) = self { return specs }
            return []
        }

        /// Whether the app may move this file aside on its own. Only
        /// undecodable bytes qualify; anything that might still mean something
        /// to another build stays exactly where its owner expects it.
        var allowsPreservingAside: Bool {
            switch self {
            case .corrupt: true
            case .missing, .loaded, .newerVersionData, .unreadable: false
            }
        }
    }

    /// What a mutation did to the file.
    enum SaveResult: Equatable, Sendable {
        case saved
        /// The bytes this build could not decode were kept at this URL, and
        /// the change written to a fresh file beside them.
        case savedAfterPreserving(URL)
        /// The request changed nothing, so nothing was written.
        case nothingToDo
        /// Refused: the file on disk is not this build's to replace.
        case blocked(String)
        /// The write itself failed.
        case failed(String)

        var didPersist: Bool {
            switch self {
            case .saved, .savedAfterPreserving: true
            case .nothingToDo, .blocked, .failed: false
            }
        }

        /// What the mapping editor shows after this mutation, or nil when the
        /// user has nothing to learn from it.
        var message: String? {
            switch self {
            case .saved, .nothingToDo:
                nil
            case .savedAfterPreserving(let keptURL):
                "Your saved preview mappings couldn't be read, so Kaisola kept that file as "
                    + "\(keptURL.lastPathComponent) and started a fresh one. This change was saved; "
                    + "the earlier mappings are in the kept file."
            case .blocked(let reason):
                reason
            case .failed(let reason):
                "This change wasn't saved: \(reason)"
            }
        }
    }

    /// The outcome of storing one mapping. The two halves are independent: an
    /// invalid spec is still stored and listed so the editor can explain it,
    /// and a perfectly good spec can still fail to reach disk.
    struct Mutation: Equatable, Sendable {
        var save: SaveResult
        var validationError: String?

        /// The one line the editor shows. A save that did not land outranks a
        /// spec that will never match: the second is a note about a stored row,
        /// the first means there is no stored row at all.
        var message: String? { save.message ?? validationError }
    }

    /// What became of a file this build could not decode.
    enum Preservation: Equatable, Sendable {
        /// This call moved the undecodable bytes to the given URL.
        case movedAside(URL)
        /// There was nothing on disk left to move.
        case nothingToPreserve
    }

    enum PreservationError: Error, Equatable {
        /// Only bytes this build cannot decode may be moved aside.
        case fileIsNotCorrupt
    }

    private struct Payload: Codable {
        /// Absent in files written before the format was versioned. Those are
        /// version 1 by definition and load unchanged; the next save adds the
        /// key.
        var version: Int?
        var mappings: [PreviewMappingSpec]
    }

    /// The version is read on its own so a newer file whose *shape* this build
    /// cannot decode is recognized as newer rather than as damage.
    private struct VersionHeader: Decodable {
        var version: Int?
    }

    let fileURL: URL
    private let cap = 32

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("preview-mappings.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func specs() -> [PreviewMappingSpec] {
        state().specs
    }

    /// What is on disk right now. Every write path consults this before
    /// touching the file.
    func state() -> State {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // "Not there" is the ordinary first run. A read that failed on a
            // file that *is* there tells us nothing about the contents, so it
            // must not be rounded down to "no mappings".
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
            return .unreadable(reason: (error as NSError).localizedDescription)
        }
        let decoder = JSONDecoder()
        if let header = try? decoder.decode(VersionHeader.self, from: data),
           let version = header.version, version > Self.formatVersion {
            return .newerVersionData(formatVersion: version)
        }
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return .corrupt }
        return .loaded(payload.mappings)
    }

    @discardableResult
    func save(_ specs: [PreviewMappingSpec]) -> SaveResult {
        write(capped(specs), over: state())
    }

    @discardableResult
    func upsert(_ spec: PreviewMappingSpec) -> Mutation {
        let state = state()
        var current = state.specs
        if let index = current.firstIndex(where: { $0.id == spec.id }) {
            current[index] = spec
        } else {
            current.append(spec)
        }
        return Mutation(
            save: write(capped(current), over: state),
            validationError: spec.validationError
        )
    }

    @discardableResult
    func remove(id: String) -> SaveResult {
        let state = state()
        // A delete against a list we could not read must never report success:
        // the entry may well still be in the file. Unlike an upsert there is no
        // new content to keep, so damage is reported rather than repaired — not
        // even undecodable bytes are moved aside on a delete.
        if let reason = protectedReason(for: state) {
            return .blocked("\(reason) \"\(id)\" wasn't removed.")
        }
        guard case .loaded(let current) = state else { return .nothingToDo }
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return .nothingToDo }
        return persist(remaining)
    }

    /// The kind for an extension, or nil. First valid claim wins, in
    /// insertion order; invalid specs are kept for the settings roster and
    /// skipped here.
    func kind(forExtension ext: String) -> PreviewMappingSpec.Kind? {
        let clean = ext.lowercased()
        for spec in specs() where spec.validationError == nil {
            guard let kind = PreviewMappingSpec.Kind(rawValue: spec.kind) else { continue }
            if spec.normalizedExtensions.contains(clean) { return kind }
        }
        return nil
    }

    /// Move a mapping file this build cannot decode aside so a fresh one can
    /// take its place.
    ///
    /// Deliberately not a side effect of reading: `state()` keeps reporting the
    /// damage, so an ordinary read can never turn corruption into "no mappings"
    /// that something else later overwrites. Only undecodable bytes qualify — a
    /// newer format is good data, and a file we merely failed to read may be
    /// perfectly intact.
    @discardableResult
    func preserveCorruptFile(at date: Date = Date()) throws -> Preservation {
        let state = state()
        if case .missing = state { return .nothingToPreserve }
        guard state.allowsPreservingAside else { throw PreservationError.fileIsNotCorrupt }
        let manager = FileManager.default
        // The naming rule the workspace archive already uses, so every file
        // Kaisola keeps aside in Application Support reads alike.
        let destination = NativeWorkspaceStateStore.preservedCopyURL(
            for: fileURL,
            at: date,
            isTaken: { manager.fileExists(atPath: $0.path) }
        )
        try manager.moveItem(at: fileURL, to: destination)
        return .movedAside(destination)
    }

    /// Why the bytes on disk may not simply be replaced, in the words the
    /// editor shows, or nil when there is nothing in the way.
    private func protectedReason(for state: State) -> String? {
        switch state {
        case .missing, .loaded:
            nil
        case .corrupt:
            "Kaisola couldn't read the mappings in \(fileURL.lastPathComponent)."
        case .newerVersionData(let version):
            "Your preview mappings were saved by a newer version of Kaisola (data format \(version)); "
                + "they're left untouched so that version can still read them."
        case .unreadable(let reason):
            "Kaisola couldn't read \(fileURL.lastPathComponent) because \(reason); the file is untouched."
        }
    }

    private func capped(_ specs: [PreviewMappingSpec]) -> [PreviewMappingSpec] {
        specs.count > cap ? Array(specs.prefix(cap)) : specs
    }

    /// Write `specs`, given what the file already is. Undecodable bytes are
    /// kept beside the new file; data another build owns is never touched.
    private func write(_ specs: [PreviewMappingSpec], over state: State) -> SaveResult {
        if state.allowsPreservingAside {
            do {
                switch try preserveCorruptFile() {
                case .movedAside(let keptURL):
                    let result = persist(specs)
                    return result.didPersist ? .savedAfterPreserving(keptURL) : result
                case .nothingToPreserve:
                    // The damaged file went away between the read and now, so
                    // the path is clear and there is nothing left to keep.
                    return persist(specs)
                }
            } catch {
                let detail = (error as NSError).localizedDescription
                return .blocked(
                    "Kaisola couldn't read the mappings in \(fileURL.lastPathComponent) and couldn't "
                        + "move that file aside (\(detail)). The original file is untouched, so this "
                        + "change wasn't saved."
                )
            }
        }
        // Anything else still in the way is data this build does not own. A
        // state added later lands here too, which fails closed rather than
        // overwriting something new by default.
        if let reason = protectedReason(for: state) {
            return .blocked("\(reason) This change wasn't saved.")
        }
        return persist(specs)
    }

    private func persist(_ specs: [PreviewMappingSpec]) -> SaveResult {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let payload = Payload(version: Self.formatVersion, mappings: specs)
        guard let data = try? JSONEncoder().encode(payload) else {
            return .failed("the mappings could not be encoded")
        }
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            return .saved
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return .failed((error as NSError).localizedDescription)
        }
    }
}
