import Combine
import XCTest

@testable import DS4Control

/// Multi-session behavior of `ChatViewModel`: draft→persisted promotion on first send,
/// transcript swapping, delete/rename, and boundary persistence (never per token).
@MainActor
final class ChatViewModelSessionsTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-vm-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> ChatSessionStore {
        ChatSessionStore(directory: tempDir)
    }

    /// A stream that finishes after the given deltas — for full send→finish flows.
    private func finishingStream(_ deltas: [String]) -> (Int, String, [ChatMessage]) -> AsyncThrowingStream<
        ChatStreamEvent, Error
    > {
        { _, _, _ in
            AsyncThrowingStream { continuation in
                for delta in deltas { continuation.yield(.text(delta)) }
                continuation.finish()
            }
        }
    }

    private func makeViewModel(
        streamProvider: @escaping (Int, String, [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error>
    ) -> ChatViewModel {
        ChatViewModel(
            model: "deepseek-v4-pro", port: { 8000 },
            streamProvider: streamProvider, sessionStore: makeStore())
    }

    /// Awaits `isStreaming` flipping back to false (data-driven, no timer sleeps).
    private func awaitStreamCompletion(_ viewModel: ChatViewModel) async {
        if !viewModel.isStreaming { return }
        let expectation = expectation(description: "stream finished")
        viewModel.$isStreaming
            .dropFirst()
            .filter { !$0 }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 5)
    }

    /// Awaits a published boolean flip (used for `hasReceivedFirstToken`).
    private func awaitFirstToken(_ viewModel: ChatViewModel) async {
        if viewModel.hasReceivedFirstToken { return }
        let expectation = expectation(description: "first token")
        viewModel.$hasReceivedFirstToken
            .dropFirst()
            .filter { $0 }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 5)
    }

    @discardableResult
    private func send(_ viewModel: ChatViewModel, _ text: String) async {
        viewModel.input = text
        viewModel.send()
        await awaitStreamCompletion(viewModel)
    }

    func testFirstSendPromotesDraftToPersistedSessionWithDerivedTitle() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["Hi"]))
        XCTAssertNil(viewModel.activeSessionID)
        XCTAssertTrue(viewModel.sessions.isEmpty)

        await send(viewModel, "  Explain KV caches  \nbriefly")

        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.sessions[0].title, "Explain KV caches")
        XCTAssertEqual(viewModel.activeSessionID, viewModel.sessions[0].id)

        let persisted = makeStore().loadSessions()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].title, "Explain KV caches")
        XCTAssertEqual(persisted[0].messages.map(\.content), ["Explain KV caches  \nbriefly", "Hi"])
        XCTAssertFalse(persisted[0].messages[1].isStreaming)
    }

    func testSubsequentSendsUpdateSameSession() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["one", "two"]))
        await send(viewModel, "first question")
        await send(viewModel, "second question")

        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.messages.count, 4)  // 2 exchanges
        XCTAssertEqual(makeStore().loadSessions().count, 1)
    }

    func testNewChatKeepsPreviousAndPersistsIt() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["a"]))
        await send(viewModel, "first prompt")

        viewModel.newChat()
        XCTAssertNil(viewModel.activeSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.sessions.count, 1)

        // A no-op on an already-blank draft.
        viewModel.newChat()
        XCTAssertEqual(viewModel.sessions.count, 1)

        await send(viewModel, "second prompt")
        XCTAssertEqual(viewModel.sessions.count, 2)
        XCTAssertEqual(viewModel.sessions[0].title, "second prompt")  // newest first
        XCTAssertEqual(viewModel.activeSessionID, viewModel.sessions[0].id)
    }

    func testSelectSessionSwapsTranscriptsAndPersistsOutgoing() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["a"]))
        await send(viewModel, "first prompt")
        let firstID = viewModel.activeSessionID
        viewModel.newChat()
        await send(viewModel, "second prompt")
        let secondID = viewModel.activeSessionID

        viewModel.selectSession(firstID!)
        XCTAssertEqual(viewModel.activeSessionID, firstID)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].content, "first prompt")

        viewModel.selectSession(secondID!)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].content, "second prompt")

        // The outgoing conversation was persisted at each switch — round-trip from disk.
        XCTAssertEqual(makeStore().loadSessions().count, 2)
    }

    func testSelectSessionDuringStreamIsRefused() async throws {
        // Pre-seed one older session WITH a message (an empty one can't be left via
        // newChat()); the VM opens it, then a draft send promotes a new session whose
        // gated stream never finishes — select must be refused mid-stream.
        try makeStore().save(
            ChatSession(
                title: "older", updatedAt: Date(timeIntervalSinceNow: -60),
                messages: [ChatMessage(role: .user, content: "old message")]))
        let gated = GatedStream()
        let viewModel = makeViewModel(streamProvider: { _, _, _ in gated.stream })
        let olderID = viewModel.sessions[0].id
        XCTAssertFalse(viewModel.messages.isEmpty)

        viewModel.newChat()  // blank draft (persists "older" back)
        viewModel.input = "prompt"
        viewModel.send()  // draft promoted to a live session; stream stays open
        XCTAssertTrue(viewModel.isStreaming)
        let streamingID = viewModel.activeSessionID
        XCTAssertEqual(viewModel.sessions.count, 2)

        viewModel.selectSession(olderID)

        XCTAssertEqual(viewModel.activeSessionID, streamingID)  // refused, unchanged
        XCTAssertEqual(viewModel.messages.last?.isStreaming, true)

        viewModel.stop()
    }

    func testDeleteActiveSessionStopsStreamAndSelectsNext() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["a"]))
        await send(viewModel, "first")
        viewModel.newChat()
        await send(viewModel, "second")
        XCTAssertEqual(viewModel.sessions.count, 2)
        let olderID = viewModel.sessions[1].id

        viewModel.deleteSession(viewModel.activeSessionID!)

        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.activeSessionID, olderID)
        XCTAssertEqual(makeStore().loadSessions().map(\.id), [olderID])
    }

    func testDeleteLastSessionLeavesBlankDraft() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["a"]))
        await send(viewModel, "only")

        viewModel.deleteSession(viewModel.activeSessionID!)

        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.activeSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(makeStore().loadSessions().isEmpty)
    }

    func testRenamePersistsNewTitle() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["a"]))
        await send(viewModel, "original prompt")
        let id = viewModel.activeSessionID!

        viewModel.renameSession(id, to: "  Renamed  ")

        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == id })?.title, "Renamed")
        XCTAssertEqual(makeStore().loadSessions().first?.title, "Renamed")
    }

    func testRenameRejectsBlankTitles() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["a"]))
        await send(viewModel, "original prompt")
        let id = viewModel.activeSessionID!

        viewModel.renameSession(id, to: "   ")

        XCTAssertEqual(viewModel.sessions.first?.title, "original prompt")
    }

    func testClearEmptiesActiveSessionAndPersists() async {
        let viewModel = makeViewModel(streamProvider: finishingStream(["a"]))
        await send(viewModel, "prompt")

        viewModel.clear()

        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.sessions.count, 1)  // session kept, transcript emptied
        XCTAssertTrue(makeStore().loadSessions()[0].messages.isEmpty)
    }

    func testInitReopensMostRecentSession() async throws {
        // Pre-seed the store with two sessions; the VM must open the newest.
        let store = makeStore()
        let older = ChatSession(title: "older", updatedAt: Date(timeIntervalSinceNow: -60))
        let newer = ChatSession(title: "newer", updatedAt: Date())
        try store.save(older)
        try store.save(newer)

        let viewModel = makeViewModel(streamProvider: finishingStream([]))

        XCTAssertEqual(viewModel.activeSessionID, newer.id)
        XCTAssertTrue(viewModel.messages.isEmpty)  // seeded sessions carry no messages
    }

    func testPersistBeforeQuitFlushesMidStreamReply() async throws {
        let gated = GatedStream()
        let viewModel = makeViewModel(streamProvider: { _, _, _ in gated.stream })
        viewModel.input = "prompt"
        viewModel.send()
        gated.yield(.text("partial answer"))
        await awaitFirstToken(viewModel)
        XCTAssertTrue(viewModel.isStreaming)

        viewModel.persistBeforeQuit()

        let persisted = makeStore().loadSessions()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].messages.count, 2)
        XCTAssertEqual(persisted[0].messages[1].content, "partial answer")
        XCTAssertFalse(persisted[0].messages[1].isStreaming)

        viewModel.stop()
    }

    func testSendHistoryExcludesStreamingPlaceholder() async {
        var captured: [ChatMessage]?
        let viewModel = makeViewModel(streamProvider: { _, _, history in
            captured = history
            return AsyncThrowingStream { $0.finish() }
        })

        await send(viewModel, "hello")

        XCTAssertEqual(captured?.map(\.content), ["hello"])
    }
}

/// Stream source whose continuation outlives the provider call, for mid-stream tests.
@MainActor
private final class GatedStream {
    private var continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation?
    private(set) var stream: AsyncThrowingStream<ChatStreamEvent, Error>!

    init() {
        stream = AsyncThrowingStream { [weak self] continuation in
            self?.continuation = continuation
        }
    }

    func yield(_ event: ChatStreamEvent) {
        continuation?.yield(event)
    }
}
