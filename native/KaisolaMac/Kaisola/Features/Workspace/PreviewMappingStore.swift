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

/// Persists preview mappings — the standard capped/atomic/corrupt-empty
/// recipe. Built-in classifications always win before a mapping is consulted,
/// so a mapping can never take over `.json`, an image, or the binary sniff;
/// there is nothing to reserve because the built-ins simply run first.
struct PreviewMappingStore: Sendable {
    private struct Payload: Codable {
        var mappings: [PreviewMappingSpec]
    }

    let fileURL: URL
    private let cap = 32

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("preview-mappings.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func specs() -> [PreviewMappingSpec] {
        read()?.mappings ?? []
    }

    func save(_ specs: [PreviewMappingSpec]) {
        let capped = specs.count > cap ? Array(specs.prefix(cap)) : specs
        write(Payload(mappings: capped))
    }

    @discardableResult
    func upsert(_ spec: PreviewMappingSpec) -> String? {
        var current = specs()
        if let index = current.firstIndex(where: { $0.id == spec.id }) {
            current[index] = spec
        } else {
            current.append(spec)
        }
        save(current)
        return spec.validationError
    }

    @discardableResult
    func remove(id: String) -> Bool {
        let current = specs()
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return false }
        save(remaining)
        return true
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

    private func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
