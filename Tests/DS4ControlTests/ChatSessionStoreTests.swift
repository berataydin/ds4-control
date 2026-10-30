import XCTest

@testable import DS4Control

final class ChatSessionStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSession(
        title: String = "Test", updatedAt: Date = Date(), messages: [ChatMessage] = []
    ) -> ChatSession {
        ChatSession(title: title, createdAt: updatedAt, updatedAt: updatedAt, messages: messages)
    }

    func testSaveLoadRoundtripPreservesMessagesThinkingAndStats() throws {
        let store = ChatSessionStore(directory: tempDir)
        let stats = GenerationStats(ttftSeconds: 0.64, decodeSeconds: 1.8, completionTokens: 47)
        let session = makeSession(messages: [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there", thinking: "hmm", stats: stats),
        ])
        try store.save(session)

        let loaded = ChatSessionStore(directory: tempDir).loadSessions()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, session.id)
        XCTAssertEqual(loaded[0].title, "Test")
        XCTAssertEqual(loaded[0].messages.count, 2)
        XCTAssertEqual(loaded[0].messages[1].thinking, "hmm")
        XCTAssertEqual(loaded[0].messages[1].stats, stats)
    }

    func testLoadSortsNewestFirst() throws {
        let store = ChatSessionStore(directory: tempDir)
        let older = makeSession(title: "older", updatedAt: Date(timeIntervalSinceNow: -3600))
        let newer = makeSession(title: "newer", updatedAt: Date())
        try store.save(older)
        try store.save(newer)

        let loaded = ChatSessionStore(directory: tempDir).loadSessions()
        XCTAssertEqual(loaded.map(\.title), ["newer", "older"])
    }

    func testLoadSkipsCorruptFilesButKeepsValidOnes() throws {
        let store = ChatSessionStore(directory: tempDir)
        let good = makeSession(title: "good")
        try store.save(good)
        try Data("{not json".utf8)
            .write(to: tempDir.appendingPathComponent("broken.json"))

        let loaded = ChatSessionStore(directory: tempDir).loadSessions()
        XCTAssertEqual(loaded.map(\.title), ["good"])
    }

    func testDeleteRemovesOnlyTheTargetFile() throws {
        let store = ChatSessionStore(directory: tempDir)
        let a = makeSession(title: "a")
        let b = makeSession(title: "b")
        try store.save(a)
        try store.save(b)

        store.delete(a.id)

        let loaded = ChatSessionStore(directory: tempDir).loadSessions()
        XCTAssertEqual(loaded.map(\.title), ["b"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL(for: a.id).path))
    }

    func testSaveNormalizesStreamingFlag() throws {
        let store = ChatSessionStore(directory: tempDir)
        var message = ChatMessage(role: .assistant, content: "partial", isStreaming: true)
        message.isStreaming = true
        try store.save(makeSession(messages: [message]))

        let loaded = ChatSessionStore(directory: tempDir).loadSessions()
        XCTAssertEqual(loaded[0].messages[0].content, "partial")
        XCTAssertFalse(loaded[0].messages[0].isStreaming)
    }

    func testLoadNormalizesStreamingFlagFromRawEncodedJSON() throws {
        // A file written by something that did NOT normalize (or by hand) must still
        // never resurrect a live-streaming row.
        let store = ChatSessionStore(directory: tempDir)
        var message = ChatMessage(role: .assistant, content: "x", isStreaming: true)
        message.isStreaming = true
        let session = makeSession(messages: [message])
        let raw = try JSONEncoder().encode(session)  // no store normalization
        try raw.write(to: store.fileURL(for: session.id))

        let loaded = ChatSessionStore(directory: tempDir).loadSessions()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertFalse(loaded[0].messages[0].isStreaming)
    }

    func testLoadEmptyDirectoryReturnsNoSessions() {
        let loaded = ChatSessionStore(directory: tempDir).loadSessions()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Title derivation

    func testTitleUsesFirstLineTrimmed() {
        XCTAssertEqual(ChatSession.title(fromFirstUserMessage: "  Fix this bug  \nand more"), "Fix this bug")
    }

    func testTitleCapsLongPrompts() {
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(ChatSession.title(fromFirstUserMessage: long).count, 60)
    }

    func testTitleFallsBackForBlankPrompt() {
        XCTAssertEqual(ChatSession.title(fromFirstUserMessage: "   \n  \t "), ChatSession.defaultTitle)
    }
}
