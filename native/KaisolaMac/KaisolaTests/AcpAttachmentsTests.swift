import Foundation
import KaisolaCore
import XCTest
@testable import KaisolaMacPreview

/// Prompt-attachment coverage: the pure ACP content-block encoding
/// (image base64 + mime, embedded text-file `resource` block), the file
/// classifier's accept/reject size limits, and the conversation's
/// pendingAttachments add/remove round-trip. The "cleared after send" path is
/// not exercised here — it needs a live transport — see AcpClientTests.
final class AcpAttachmentsTests: XCTestCase {

    // MARK: - Prompt block encoding

    func testTextOnlyPromptIsASingleTextBlock() {
        let blocks = AcpClient.promptBlocks(text: "hello", attachments: [], promptImageOk: true)
        XCTAssertEqual(blocks, [.object(["type": .string("text"), "text": .string("hello")])])
    }

    func testImageAttachmentEncodesBase64AndMime() {
        let bytes = Data([0x00, 0x01, 0x02, 0xFF])
        let blocks = AcpClient.promptBlocks(
            text: "look",
            attachments: [.image(data: bytes, mimeType: "image/png", name: "a.png")],
            promptImageOk: true
        )
        XCTAssertEqual(blocks, [
            .object(["type": .string("text"), "text": .string("look")]),
            .object([
                "type": .string("image"),
                "mimeType": .string("image/png"),
                "data": .string(bytes.base64EncodedString()),
            ]),
        ])
    }

    /// Mirrors electron/ipc/acp.cjs's `promptImageOk` gate: an agent that never
    /// advertised promptCapabilities.image gets no image block (the filename
    /// still travels in the text the caller composed).
    func testImageBlockOmittedWhenAgentLacksImageCapability() {
        let blocks = AcpClient.promptBlocks(
            text: "x",
            attachments: [.image(data: Data([1, 2, 3]), mimeType: "image/png", name: "a.png")],
            promptImageOk: false
        )
        XCTAssertEqual(blocks, [.object(["type": .string("text"), "text": .string("x")])])
    }

    func testTextFileEncodesAsEmbeddedResourceBlock() {
        let blocks = AcpClient.promptBlocks(
            text: "review",
            attachments: [.textFile(path: "/tmp/notes.txt", contents: "line one\n", name: "notes.txt")],
            promptImageOk: true
        )
        XCTAssertEqual(blocks, [
            .object(["type": .string("text"), "text": .string("review")]),
            .object([
                "type": .string("resource"),
                "resource": .object([
                    "uri": .string("file:///tmp/notes.txt"),
                    "mimeType": .string("text/plain"),
                    "text": .string("line one\n"),
                ]),
            ]),
        ])
    }

    func testTextFileFallsBackToBaselineResourceLinkWithoutEmbeddedContextCapability() {
        let blocks = AcpClient.promptBlocks(
            text: "review",
            attachments: [.textFile(path: "/tmp/notes.txt", contents: "line one\n", name: "notes.txt")],
            promptImageOk: true,
            promptEmbeddedContextOk: false
        )
        XCTAssertEqual(blocks, [
            .object(["type": .string("text"), "text": .string("review")]),
            .object([
                "type": .string("resource_link"),
                "name": .string("notes.txt"),
                "uri": .string("file:///tmp/notes.txt"),
                "mimeType": .string("text/plain"),
                "size": .integer(9),
            ]),
        ])
    }

    func testFileURIPercentEncodesSpaces() {
        XCTAssertEqual(AcpClient.fileURI("/tmp/a b.txt"), "file:///tmp/a%20b.txt")
        XCTAssertEqual(AcpClient.fileURI("/tmp/plain.txt"), "file:///tmp/plain.txt")
    }

    func testMixedAttachmentsKeepTextFirstThenArrayOrder() {
        let blocks = AcpClient.promptBlocks(
            text: "t",
            attachments: [
                .image(data: Data([9]), mimeType: "image/jpeg", name: "p.jpg"),
                .textFile(path: "/tmp/a.txt", contents: "hi", name: "a.txt"),
            ],
            promptImageOk: true
        )
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].objectValue?["type"]?.stringValue, "text")
        XCTAssertEqual(blocks[1].objectValue?["type"]?.stringValue, "image")
        XCTAssertEqual(blocks[2].objectValue?["type"]?.stringValue, "resource")
    }

    // MARK: - userText suffix

    func testUserTextAppendsPaperclipSuffix() {
        let attachments: [AcpAttachment] = [
            .image(data: Data(), mimeType: "image/png", name: "one.png"),
            .textFile(path: "/tmp/two.txt", contents: "", name: "two.txt"),
        ]
        XCTAssertEqual(AcpConversation.userText("hi", attachments: attachments), "hi\n📎 one.png, two.txt")
        XCTAssertEqual(AcpConversation.userText("", attachments: attachments), "📎 one.png, two.txt")
        XCTAssertEqual(AcpConversation.userText("plain", attachments: []), "plain")
    }

    // MARK: - Classification / size limits

    func testClassifyAcceptsSmallTextFile() throws {
        let url = try writeTemp(name: "notes.txt", data: Data("hello world".utf8))
        defer { cleanup(url) }
        guard case let .accepted(.textFile(path, contents, name)) = AcpAttachmentClassifier.classify(fileURL: url) else {
            return XCTFail("expected an accepted textFile")
        }
        XCTAssertEqual(path, url.path)
        XCTAssertEqual(contents, "hello world")
        XCTAssertEqual(name, "notes.txt")
    }

    func testClassifyAcceptsImageByExtension() throws {
        let url = try writeTemp(name: "pixel.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        defer { cleanup(url) }
        guard case let .accepted(.image(data, mimeType, name)) = AcpAttachmentClassifier.classify(fileURL: url) else {
            return XCTFail("expected an accepted image")
        }
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertEqual(name, "pixel.png")
    }

    func testClassifyRejectsOversizeTextFile() throws {
        let big = Data(repeating: 0x61, count: AcpAttachmentClassifier.maxTextFileBytes + 1)
        let url = try writeTemp(name: "big.txt", data: big)
        defer { cleanup(url) }
        guard case let .rejected(reason) = AcpAttachmentClassifier.classify(fileURL: url) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("large"), "reason: \(reason)")
    }

    func testClassifyRejectsOversizeImage() throws {
        let big = Data(repeating: 0, count: AcpAttachmentClassifier.maxImageBytes + 1)
        let url = try writeTemp(name: "huge.png", data: big)
        defer { cleanup(url) }
        guard case let .rejected(reason) = AcpAttachmentClassifier.classify(fileURL: url) else {
            return XCTFail("expected a rejection")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("large"), "reason: \(reason)")
    }

    func testClassifyRejectsNonUTF8NonImageFile() throws {
        // 0xFF/0xFE are never valid UTF-8 lead bytes; a non-image extension →
        // rejected as neither text nor image.
        let url = try writeTemp(name: "blob.bin", data: Data([0xFF, 0xFE, 0xFD]))
        defer { cleanup(url) }
        guard case .rejected = AcpAttachmentClassifier.classify(fileURL: url) else {
            return XCTFail("expected a rejection")
        }
    }

    func testMimeTypeForCommonImageExtensions() {
        XCTAssertEqual(AcpAttachmentClassifier.mimeType(forExtension: "png"), "image/png")
        XCTAssertEqual(AcpAttachmentClassifier.mimeType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(AcpAttachmentClassifier.mimeType(forExtension: "gif"), "image/gif")
        XCTAssertEqual(AcpAttachmentClassifier.mimeType(forExtension: "webp"), "image/webp")
    }

    // MARK: - pendingAttachments add / remove round-trip

    @MainActor
    func testAddImageDataRoundTrip() {
        let conversation = makeConversation()
        XCTAssertTrue(conversation.pendingAttachments.isEmpty)

        conversation.addImageData(Data([1, 2, 3, 4]), name: "shot.png")
        XCTAssertEqual(conversation.pendingAttachments.count, 1)
        let pending = conversation.pendingAttachments[0]
        XCTAssertEqual(pending.name, "shot.png")
        XCTAssertEqual(pending.iconName, "photo")
        XCTAssertEqual(pending.byteSize, 4)
        XCTAssertEqual(pending.attachment, .image(data: Data([1, 2, 3, 4]), mimeType: "image/png", name: "shot.png"))

        conversation.removeAttachment(pending.id)
        XCTAssertTrue(conversation.pendingAttachments.isEmpty)
    }

    @MainActor
    func testPendingAttachmentsHaveAnAggregateCountLimit() {
        let conversation = makeConversation()
        for index in 0..<(AcpConversation.maxPendingAttachmentCount + 3) {
            conversation.addImageData(Data([UInt8(index)]), name: "shot-\(index).png")
        }
        XCTAssertEqual(conversation.pendingAttachments.count, AcpConversation.maxPendingAttachmentCount)
    }

    @MainActor
    func testAddFileAttachmentRoundTrip() throws {
        let url = try writeTemp(name: "readme.txt", data: Data("abc".utf8))
        defer { cleanup(url) }
        let conversation = makeConversation()

        conversation.addAttachment(fileURL: url)
        XCTAssertEqual(conversation.pendingAttachments.count, 1)
        XCTAssertEqual(conversation.pendingAttachments[0].iconName, "doc.text")
        XCTAssertEqual(conversation.pendingAttachments[0].byteSize, 3)
        XCTAssertEqual(conversation.pendingAttachments[0].attachment, .textFile(path: url.path, contents: "abc", name: "readme.txt"))
    }

    @MainActor
    func testPrepareAttachmentReturnsImmediatelyThenStagesOffActor() async throws {
        let url = try writeTemp(name: "async.txt", data: Data("prepared".utf8))
        defer { cleanup(url) }
        let conversation = makeConversation()

        conversation.prepareAttachment(fileURL: url)
        XCTAssertEqual(conversation.preparingAttachmentCount, 1)
        XCTAssertTrue(conversation.pendingAttachments.isEmpty)

        let deadline = Date().addingTimeInterval(2)
        while conversation.preparingAttachmentCount > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.preparingAttachmentCount, 0)
        XCTAssertEqual(conversation.pendingAttachments.first?.name, "async.txt")
    }

    @MainActor
    func testDuplicateAttachmentIsDeduped() {
        let conversation = makeConversation()
        conversation.addImageData(Data([7, 7]), name: "dup.png")
        conversation.addImageData(Data([7, 7]), name: "dup.png")
        XCTAssertEqual(conversation.pendingAttachments.count, 1)
    }

    @MainActor
    func testOversizeImageDataIsRejectedNoPending() {
        let conversation = makeConversation()
        conversation.addImageData(Data(repeating: 0, count: AcpAttachmentClassifier.maxImageBytes + 1), name: "big.png")
        XCTAssertTrue(conversation.pendingAttachments.isEmpty)
    }

    // MARK: - Helpers

    @MainActor
    private func makeConversation() -> AcpConversation {
        AcpConversation(title: "T", command: "mock", arguments: [], environment: [:], cwd: "/tmp")
    }

    private func writeTemp(name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-att-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
