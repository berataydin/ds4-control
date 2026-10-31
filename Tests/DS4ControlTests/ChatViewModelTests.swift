import Combine
import XCTest

@testable import DS4Control

@MainActor
final class ChatViewModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    /// Fresh temp directory per VM so session persistence in tests never touches the
    /// user's real `~/Library/Application Support/DS4 Control/Chats`.
    private func makeTempStore() -> ChatSessionStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-vm-tests-\(UUID().uuidString)", isDirectory: true)
        return ChatSessionStore(directory: dir)
    }

    /// Builds a VM whose stream yields the given text deltas (and an optional
    /// trailing usage event) then finishes.
    private func makeViewModel(
        deltas: [String],
        usage: (completion: Int, prompt: Int, total: Int)? = nil,
        error: Error? = nil
    ) -> ChatViewModel {
        ChatViewModel(
            model: "deepseek-v4-pro",
            port: { 8000 },
            streamProvider: { _, _, _ in
                AsyncThrowingStream { continuation in
                    for delta in deltas { continuation.yield(.text(delta)) }
                    if let usage {
                        continuation.yield(
                            .usage(
                                completionTokens: usage.completion, promptTokens: usage.prompt, totalTokens: usage.total
                            ))
                    }
                    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
                }
            },
            sessionStore: makeTempStore()
        )
    }

    /// Awaits the streaming completion deterministically (driven by data, not a timer):
    /// fulfils once `isStreaming` flips back to false.
    private func awaitStreamCompletion(_ viewModel: ChatViewModel) async {
        let expectation = expectation(description: "stream finished")
        viewModel.$isStreaming
            .dropFirst()
            .filter { !$0 }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 5)
    }

    func testSendAppendsUserAndAssistantMessages() async {
        let viewModel = makeViewModel(deltas: ["Hi", " there"])
        viewModel.input = "Hello"
        viewModel.send()
        await awaitStreamCompletion(viewModel)

        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "Hello")
        XCTAssertEqual(viewModel.messages[1].role, .assistant)
        XCTAssertEqual(viewModel.messages[1].content, "Hi there")
        XCTAssertFalse(viewModel.messages[1].isStreaming)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertTrue(viewModel.input.isEmpty)
    }

    func testFirstTokenFlagSet() async {
        let viewModel = makeViewModel(deltas: ["x"])
        XCTAssertFalse(viewModel.hasReceivedFirstToken)
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertTrue(viewModel.hasReceivedFirstToken)
    }

    func testSendIgnoresEmptyInput() {
        let viewModel = makeViewModel(deltas: ["x"])
        viewModel.input = "   "
        viewModel.send()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isStreaming)
    }

    func testCanSendGating() {
        let viewModel = makeViewModel(deltas: [])
        XCTAssertFalse(viewModel.canSend)
        viewModel.input = "hi"
        XCTAssertTrue(viewModel.canSend)
    }

    func testErrorSurfacesAndStopsStreaming() async {
        struct Boom: Error {}
        let viewModel = makeViewModel(deltas: ["partial"], error: Boom())
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertNotNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertEqual(viewModel.messages.last?.content, "partial")
    }

    func testClearRemovesMessages() async {
        let viewModel = makeViewModel(deltas: ["x"])
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        viewModel.clear()
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.errorText)
    }

    func testStreamingDeltasMutateLastMessage() async {
        let viewModel = makeViewModel(deltas: ["a", "b", "c"])
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertEqual(viewModel.messages.last?.content, "abc")
    }

    func testUsagePopulatesStatsAndContextUsage() async {
        let viewModel = makeViewModel(deltas: ["Hello"], usage: (completion: 90, prompt: 100, total: 190))
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        let stats = viewModel.messages.last?.stats
        XCTAssertEqual(stats?.completionTokens, 90)
        XCTAssertNotNil(stats?.ttftSeconds)
        XCTAssertNotNil(stats?.decodeSeconds)
        XCTAssertEqual(viewModel.contextUsedTokens, 190)
    }

    func testStatsWithoutUsageHasTimingButNoTokenCount() async {
        let viewModel = makeViewModel(deltas: ["a", "b"])
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertNotNil(viewModel.messages.last?.stats)
        XCTAssertNil(viewModel.messages.last?.stats?.completionTokens)
        XCTAssertEqual(viewModel.contextUsedTokens, 0)
    }

    func testClearResetsContextUsage() async {
        let viewModel = makeViewModel(deltas: ["x"], usage: (completion: 5, prompt: 10, total: 15))
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertEqual(viewModel.contextUsedTokens, 15)
        viewModel.clear()
        XCTAssertEqual(viewModel.contextUsedTokens, 0)
    }

    /// The streaming flush loop must drain the buffer synchronously on
    /// `finish(_:)` so the final token isn't lost when the stream ends
    /// between flush ticks. This test drives a 5-delta stream with no flush
    /// tick in between (the test never yields to the main run loop, so the
    /// 33ms flush never fires); the final content is only correct if
    /// `finish(_:)` flushes synchronously.
    func testFinishFlushesBufferSynchronously() async {
        let viewModel = makeViewModel(deltas: ["a", "b", "c", "d", "e"])
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages[1].content, "abcde")
    }

    func testThinkingDeltasDeliveredAfterStream() async {
        let viewModel = ChatViewModel(
            model: "deepseek-v4-pro", port: { 8000 },
            streamProvider: { _, _, _ in
                AsyncThrowingStream { c in
                    c.yield(.reasoning("step one. "))
                    c.yield(.reasoning("step two."))
                    c.yield(.text("Answer."))
                    c.finish()
                }
            },
            sessionStore: makeTempStore())
        viewModel.input = "go"
        viewModel.send()
        await awaitStreamCompletion(viewModel)
        XCTAssertEqual(viewModel.messages.last?.thinking, "step one. step two.")
        XCTAssertEqual(viewModel.messages.last?.content, "Answer.")
    }

    func testInFlightGuardSkipsThenForceDrains() {
        let viewModel = makeViewModel(deltas: [])
        let id = UUID()
        viewModel.messages = [ChatMessage(id: id, role: .assistant, content: "", isStreaming: true)]
        viewModel.streamingMessageID = id

        viewModel.bufferContentDelta("X")
        viewModel.applyPendingDeltas(includeThinking: true, force: false)
        XCTAssertEqual(viewModel.messages[0].content, "X")
        XCTAssertTrue(viewModel.updateInFlight)

        viewModel.bufferContentDelta("Y")
        viewModel.applyPendingDeltas(includeThinking: true, force: false)
        XCTAssertEqual(viewModel.messages[0].content, "X")

        viewModel.applyPendingDeltas(includeThinking: true, force: true)
        XCTAssertEqual(viewModel.messages[0].content, "XY")
    }

    func testTickFlushCooldownSkipsNextTick() {
        let viewModel = makeViewModel(deltas: [])
        let id = UUID()
        viewModel.messages = [ChatMessage(id: id, role: .assistant, content: "", isStreaming: true)]
        viewModel.streamingMessageID = id
        viewModel.bufferContentDelta("A")
        viewModel.tickFlush()  // applies → in-flight
        XCTAssertEqual(viewModel.messages[0].content, "A")
        viewModel.bufferContentDelta("B")
        viewModel.tickFlush()  // cooldown → skipped
        XCTAssertEqual(viewModel.messages[0].content, "A")
        viewModel.tickFlush()  // resumes → applies "B"
        XCTAssertEqual(viewModel.messages[0].content, "AB")
    }

    // MARK: - Mid-stream conversation switching

    /// A stream the test drives by hand: deltas are yielded when the test chooses and the
    /// stream stays open until the test finishes it, so mid-stream state is observable.
    private final class GatedStream {
        private(set) var continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation?
        var provider: (Int, String, [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error> {
            { [weak self] _, _, _ in
                AsyncThrowingStream { continuation in
                    self?.continuation = continuation
                }
            }
        }
    }

    private func makeGatedViewModel() -> (viewModel: ChatViewModel, stream: GatedStream) {
        let stream = GatedStream()
        let viewModel = ChatViewModel(
            model: "deepseek-v4-pro", port: { 8000 },
            streamProvider: stream.provider,
            sessionStore: makeTempStore())
        return (viewModel, stream)
    }

    /// Lets the live 33ms flush loop apply whatever was just yielded (a couple of ticks,
    /// well within the sleep) — mid-stream content assertions stay deterministic.
    private func letFlushApply() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    func testSelectSessionMidStreamContinuesReplyInBackgroundSession() async throws {
        let (viewModel, stream) = makeGatedViewModel()

        // Conversation A: complete quickly so it exists in the sidebar.
        viewModel.input = "first question"
        viewModel.send()
        stream.continuation?.yield(.text("first answer"))
        stream.continuation?.finish()
        await awaitStreamCompletion(viewModel)
        let aID = try XCTUnwrap(viewModel.activeSessionID)
        XCTAssertEqual(viewModel.messages.last?.content, "first answer")

        // Conversation B: start a stream the test keeps open.
        viewModel.newChat()
        viewModel.input = "second question"
        viewModel.send()
        let bID = try XCTUnwrap(viewModel.activeSessionID)
        XCTAssertEqual(viewModel.streamingSessionID, bID)
        stream.continuation?.yield(.text("partial "))
        await letFlushApply()

        // Switch back to A mid-stream: the transcript shows A; the reply keeps landing in B.
        viewModel.selectSession(aID)
        XCTAssertEqual(viewModel.activeSessionID, aID)
        XCTAssertEqual(viewModel.streamingSessionID, bID)
        XCTAssertEqual(viewModel.messages.last?.content, "first answer")
        XCTAssertTrue(viewModel.isStreaming)

        stream.continuation?.yield(.text("more "))
        stream.continuation?.yield(.text("tokens"))
        await letFlushApply()
        XCTAssertEqual(viewModel.messages.last?.content, "first answer")  // A untouched
        XCTAssertEqual(
            viewModel.sessions.first { $0.id == bID }?.messages.last?.content,
            "partial more tokens")  // B accumulated in the background

        // Returning mid-stream keeps the live streaming markers on the reply row.
        viewModel.selectSession(bID)
        XCTAssertEqual(viewModel.messages.last?.content, "partial more tokens")
        XCTAssertTrue(viewModel.messages.last?.isStreaming == true)
        viewModel.selectSession(aID)

        stream.continuation?.finish()
        await awaitStreamCompletion(viewModel)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertNil(viewModel.streamingSessionID)
        XCTAssertEqual(
            viewModel.sessions.first { $0.id == bID }?.messages.last?.content,
            "partial more tokens")

        viewModel.selectSession(bID)
        XCTAssertEqual(viewModel.messages.last?.content, "partial more tokens")
        XCTAssertTrue(viewModel.messages.last?.isStreaming == false)
    }

    func testNewChatMidStreamKeepsReplyInOriginSession() async throws {
        let (viewModel, stream) = makeGatedViewModel()
        viewModel.input = "question"
        viewModel.send()
        let aID = try XCTUnwrap(viewModel.activeSessionID)
        stream.continuation?.yield(.text("part one "))
        await letFlushApply()

        viewModel.newChat()
        XCTAssertNil(viewModel.activeSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.streamingSessionID, aID)  // reply still owned by A

        stream.continuation?.yield(.text("part two"))
        stream.continuation?.finish()
        await awaitStreamCompletion(viewModel)

        XCTAssertTrue(viewModel.messages.isEmpty)  // the draft stayed blank
        XCTAssertEqual(
            viewModel.sessions.first { $0.id == aID }?.messages.last?.content,
            "part one part two")
        XCTAssertNil(viewModel.streamingSessionID)

        viewModel.selectSession(aID)
        XCTAssertEqual(viewModel.messages.last?.content, "part one part two")
    }

    func testDeleteBackgroundStreamingSessionStopsStream() async throws {
        let (viewModel, stream) = makeGatedViewModel()
        viewModel.input = "first"
        viewModel.send()
        stream.continuation?.yield(.text("answer one"))
        stream.continuation?.finish()
        await awaitStreamCompletion(viewModel)
        let aID = try XCTUnwrap(viewModel.activeSessionID)

        viewModel.newChat()
        viewModel.input = "second"
        viewModel.send()
        let bID = try XCTUnwrap(viewModel.activeSessionID)
        viewModel.selectSession(aID)
        XCTAssertTrue(viewModel.isStreaming)

        viewModel.deleteSession(bID)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertNil(viewModel.streamingSessionID)
        XCTAssertFalse(viewModel.sessions.contains { $0.id == bID })
        XCTAssertEqual(viewModel.activeSessionID, aID)  // still viewing A
        XCTAssertEqual(viewModel.messages.last?.content, "answer one")
    }
}
