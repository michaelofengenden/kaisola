import Foundation

public enum RepositoryFixtures {
    public enum Error: Swift.Error, Equatable {
        case repositoryRootNotFound
        case missingFixture(String)
    }

    /// Locates the checked-in cross-language fixtures without copying them into
    /// the package, preserving one source of truth for Node and Swift tests.
    public static func companionFixture(named name: String) throws -> URL {
        try repositoryFixture(path: "electron/companion/fixtures/\(name).json", name: name)
    }

    public static func brokerFixture(named name: String) throws -> URL {
        try repositoryFixture(path: "protocol/broker/\(name).json", name: name)
    }

    private static func repositoryFixture(path: String, name: String) throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            candidate.deleteLastPathComponent()
            let package = candidate.appendingPathComponent("native/KaisolaCore/Package.swift")
            if FileManager.default.fileExists(atPath: package.path) {
                let fixture = candidate.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: fixture.path) else {
                    throw Error.missingFixture(name)
                }
                return fixture
            }
        }
        throw Error.repositoryRootNotFound
    }
}
