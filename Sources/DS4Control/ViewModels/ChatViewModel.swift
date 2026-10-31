import Combine
import Foundation

/// Drives the built-in chat against ds4-server, across multiple persisted conversations.
///
/// The streaming source is injected (`streamProvider`) so tests can feed a
/// canned `AsyncThrowingStream` with no sockets or scheduler timing.
///
/// Multi-session model: `messages` stays the *active* transcript (the hot path the
/// flush loop mutates per token is untouched), while `sessions` holds the persisted
/// conversations, newest-first. `activeSessionID == nil` means a fresh draft that is
/// only written to disk once its first message is sent. The transcript is mirrored to
/// disk at conversation boundaries (send, stream end/stop, clear, switch, rename) —
/// never per streamed token.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var hasReceivedFirstToken = false
    @Published private(set) var contextUsedTokens = 0
    @Published var errorText: String?
    /// All persisted conversations, newest-first. Drives the history sidebar.
    @Published private(set) var sessions: [ChatSession] = []
    /// The persisted conversation `messages` mirrors; nil for a not-yet-sent draft.
    @Published var activeSessionID: UUID?
    /// The conversation that owns the in-flight reply. The user may switch conversations
    /// (or start a fresh draft) mid-stream — generation keeps writing into *this*
    /// session in the background, not into whatever transcript is on screen.
    @Published private(set) var streamingSessionID: UUID?

    let model: String
    private let port: () -> Int
    private let streamProvider: (Int, String, [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error>
    private let store: ChatSessionStore
    private var streamTask: Task<Void, Never>?

    // In-flight timing/usage for the current reply (MainActor-isolated state, not
    // captured locals — mutating captured vars inside the Task closure won't compile).
    private var genStart: Date?
    private var genFirstToken: Date?
    private var genCompletionTokens: Int?
    private var genPromptTokens: Int?
    private var genTotalTokens: Int?

    // Streaming throttle: every token from ds4-server triggers a `@Published`
    // mutation on `messages.last.content`, which kicks the AttributeGraph
    // walk. With ~50 bubbles in the chat window × ~50 tokens/sec, that's
    // 2,500 measurements/sec just from the streaming content. We buffer
    // incoming deltas in these strings and flush them on a 33ms timer (≈30Hz)
    // — the AttributeGraph walk drops 1.5×, no visible streaming delay (33ms
    // is well under one display frame), and the final token still flushes
    // synchronously in `finish(_:)` so nothing is dropped on stream end.
    //
    // The flush task is a long-lived polling loop on the main actor (it hops
    // in via MainActor.run for each sleep+flush iteration). It exists only
    // while a stream is active: started in `send()`, cancelled in `finish(_:)`
    // / `stop()`.
    private static let streamingFlushIntervalNanos: UInt64 = 33_000_000  // 33ms
    private var pendingContentDelta: String = ""
    private var pendingThinkingDelta: String = ""
    private var flushTask: Task<Void, Never>?

    // Thinking flushes on a coarser cadence than content: reasoning live-ness matters less
    // and Max-Think reasoning can be long. Content flushes every tick (~33ms); thinking
    // every Nth tick (~264ms).
    private var flushTickCount = 0
    private static let thinkingFlushEveryNTicks = 8  // 33ms × 8 ≈ 264ms

    // Single-in-flight guard (adaptive backpressure): a flush tick landing right after a
    // mutation treats the prior render as still settling and skips, clearing the flag so the
    // next tick resumes. SwiftUI has no literal "render finished" callback — this cooldown is
    // the serialization boundary. finish()/stop() bypass it with `force: true` so the final
    // tokens always land. Internal (with the cadence members) for deterministic testing.
    private(set) var updateInFlight = false

    // ID of the message currently being streamed — captured at `send()` time so the flush
    // loop knows which row to mutate. Nil when no stream is active. Internal so the guard /
    // cadence tests can drive a deterministic streaming row.
    var streamingMessageID: UUID?

    init(
        model: String,
        port: @escaping () -> Int,
        streamProvider: @escaping (Int, String, [ChatMessage]) -> AsyncThrowingStream<ChatStreamEvent, Error>,
        sessionStore: ChatSessionStore = ChatSessionStore()
    ) {
        self.model = model
        self.port = port
        self.streamProvider = streamProvider
        self.store = sessionStore

        // Reopen the most recent conversation, if any; otherwise start on a blank draft.
        let loaded = store.loadSessions()
        sessions = loaded
        if let latest = loaded.first {
            activeSessionID = latest.id
            messages = latest.messages
        }
    }

    var canSend: Bool {
        !isStreaming && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Title of the active persisted conversation (nil while on an unsent draft).
    var activeSessionTitle: String? {
        guard let id = activeSessionID else { return nil }
        return sessions.first(where: { $0.id == id })?.title
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        messages.append(ChatMessage(role: .user, content: text))
        input = ""
        errorText = nil

        // Persist the user's message immediately: a draft becomes a real session here
        // (titled from the prompt), and an existing session's transcript/updatedAt are
        // refreshed. The assistant placeholder below stays in-memory only until the
        // stream ends (finish/stop persist the completed reply).
        if let id = activeSessionID, let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].messages = messages
            sessions[index].updatedAt = Date()
            let updated = sessions.remove(at: index)
            sessions.insert(updated, at: 0)  // keep newest-first
            try? store.save(updated)
        } else {
            let now = Date()
            let session = ChatSession(
                title: ChatSession.title(fromFirstUserMessage: text),
                createdAt: now, updatedAt: now, messages: messages)
            sessions.insert(session, at: 0)
            activeSessionID = session.id
            try? store.save(session)
        }

        isStreaming = true
        streamingSessionID = activeSessionID
        hasReceivedFirstToken = false

        genStart = Date()
        genFirstToken = nil
        genCompletionTokens = nil
        genPromptTokens = nil
        genTotalTokens = nil

        let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id
        streamingMessageID = assistantID

        // Start the 33ms flush loop. Polling sleeps on a detached task and
        // hops back to the main actor for each flush; the loop ends when
        // `finish(_:)` or `stop()` cancels `flushTask`.
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.streamingFlushIntervalNanos)
                if Task.isCancelled { return }
                self?.tickFlush()
            }
        }

        let stream = streamProvider(port(), model, messages.dropLast().map { $0 })
        streamTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .text(let delta):
                        if self.genFirstToken == nil { self.genFirstToken = Date() }
                        if !self.hasReceivedFirstToken { self.hasReceivedFirstToken = true }
                        self.bufferContentDelta(delta)
                    case .reasoning(let delta):
                        // Reasoning streams before the answer; the first reasoning token is TTFT.
                        if self.genFirstToken == nil { self.genFirstToken = Date() }
                        if !self.hasReceivedFirstToken { self.hasReceivedFirstToken = true }
                        self.bufferThinkingDelta(delta)
                    case .usage(let completion, let prompt, let total):
                        self.genCompletionTokens = completion
                        self.genPromptTokens = prompt
                        self.genTotalTokens = total
                    }
                }
            } catch {
                self?.errorText = error.localizedDescription
            }
            self?.finish(assistantID)
        }
    }

    func stop() {
        // Flush any pending content the user would otherwise lose on cancel —
        // a 33ms buffer at most, but the user pressed Stop and expects to
        // see what was generated.
        applyPendingDeltas(includeThinking: true, force: true)
        streamTask?.cancel()
        streamTask = nil
        flushTask?.cancel()
        flushTask = nil
        let stoppedRowID = streamingMessageID
        let stoppedSessionID = streamingSessionID
        streamingMessageID = nil
        streamingSessionID = nil
        flushTickCount = 0
        updateInFlight = false
        pendingContentDelta = ""
        pendingThinkingDelta = ""
        if let rowID = stoppedRowID {
            mutateRow(rowID, in: stoppedSessionID) { $0.isStreaming = false }
        }
        isStreaming = false
        // Persist the conversation that owned the reply — the active one, or a
        // background session the user navigated away from.
        if let stoppedSessionID {
            persistSession(stoppedSessionID)
        } else {
            persistActiveSession()
        }
    }

    func clear() {
        stop()
        messages.removeAll()
        errorText = nil
        contextUsedTokens = 0
        persistActiveSession()
    }

    // MARK: - Sessions

    /// Starts a fresh draft conversation (persisted only once its first message is sent).
    /// A no-op when the current chat is already blank. Mid-stream the draft opens with
    /// the in-flight reply continuing in the background, into its own conversation.
    func newChat() {
        guard isStreaming || !messages.isEmpty else { return }
        if isStreaming { applyPendingDeltas(includeThinking: true, force: true) }
        persistActiveSession()
        activeSessionID = nil
        messages = []
        errorText = nil
        contextUsedTokens = 0
    }

    /// Switches the active transcript to another persisted conversation. The current
    /// one is flushed to disk first; a blank draft is simply dropped. Allowed mid-stream:
    /// the in-flight reply keeps generating into its owning conversation in the
    /// background (its sidebar row shows the live indicator) and lands there on finish.
    func selectSession(_ id: UUID) {
        guard id != activeSessionID,
            let session = sessions.first(where: { $0.id == id })
        else { return }
        if isStreaming { applyPendingDeltas(includeThinking: true, force: true) }
        persistActiveSession()
        activeSessionID = id
        // Normalize: a persisted session is never live (belt-and-braces alongside the
        // store's own normalization, in case an in-memory copy skipped a save) — except
        // the streaming row when re-selecting the conversation that is still generating,
        // so it renders with the live streaming markers again.
        messages = session.messages.map { message in
            var copy = message
            copy.isStreaming = message.id == streamingMessageID
            return copy
        }
        errorText = nil
        contextUsedTokens = 0
    }

    /// Deletes a conversation permanently. Deleting the active one — or the one still
    /// generating in the background — stops any in-flight stream (flushing its partial
    /// reply to disk first) and selects the next session.
    func deleteSession(_ id: UUID) {
        if id == activeSessionID || id == streamingSessionID { stop() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        store.delete(id)
        guard activeSessionID == id else { return }
        activeSessionID = nil
        messages = []
        errorText = nil
        contextUsedTokens = 0
        if let next = sessions.first {
            selectSession(next.id)
        }
    }

    /// Renames a conversation (trimmed, non-empty) and persists the new title.
    func renameSession(_ id: UUID, to rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = String(title.prefix(120))
        try? store.save(sessions[index])
    }

    /// Flush-and-save hook for app termination: keeps a reply that was mid-stream at
    /// quit time. The store normalizes `isStreaming` off in the encoded copy. A reply
    /// generating into a background conversation is saved there too.
    func persistBeforeQuit() {
        if isStreaming {
            applyPendingDeltas(includeThinking: true, force: true)
        }
        persistActiveSession()
        if let backgroundID = streamingSessionID, backgroundID != activeSessionID {
            persistSession(backgroundID)
        }
    }

    /// Mirrors the active transcript into `sessions` (newest-first) and writes it to
    /// disk. Called at conversation boundaries only — never per streamed token.
    private func persistActiveSession() {
        guard let id = activeSessionID else { return }
        persistSession(id)
    }

    /// Saves one conversation, newest-first. For the active conversation the visible
    /// transcript (`messages`) is the source of truth; for a background conversation
    /// (stream continuing while the user is elsewhere) its own entry in `sessions`
    /// already carries the latest content and is saved as-is.
    private func persistSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[index]
        if id == activeSessionID {
            session.messages = messages
        }
        session.updatedAt = Date()
        sessions.remove(at: index)
        sessions.insert(session, at: 0)
        try? store.save(session)
    }

    /// Append an incoming content delta to the pending buffer. Does NOT
    /// mutate `messages` — the flush loop applies the buffer every 33ms.
    func bufferContentDelta(_ delta: String) {
        pendingContentDelta += delta
    }

    /// Append an incoming reasoning delta to the pending buffer. Same
    /// throttle contract as `bufferContentDelta(_:)`.
    func bufferThinkingDelta(_ delta: String) {
        pendingThinkingDelta += delta
    }

    /// Timer entry point. Content flushes every tick; thinking every Nth tick. Hosts the
    /// single-in-flight cooldown: a tick landing right after a mutation is skipped, clearing
    /// the flag so the next tick resumes.
    @MainActor
    func tickFlush() {
        if updateInFlight {
            updateInFlight = false
            return
        }
        flushTickCount &+= 1
        let includeThinking = flushTickCount % Self.thinkingFlushEveryNTicks == 0
        applyPendingDeltas(includeThinking: includeThinking, force: false)
    }

    /// Drain the pending buffers into the streaming message's row — wherever it lives:
    /// the visible transcript when its conversation is on screen, otherwise its owning
    /// session in `sessions` (a background stream after a mid-stream switch). Skips while
    /// an update is in flight unless `force` (finish()/stop() use `force: true` to drain
    /// synchronously). A visible-transcript mutation marks in-flight (the render
    /// cooldown); background writes only touch the sidebar model and skip the cooldown.
    @MainActor
    func applyPendingDeltas(includeThinking: Bool, force: Bool) {
        if !force && updateInFlight { return }
        guard let id = streamingMessageID else { return }
        var mutated = false
        let location = mutateRow(id, in: streamingSessionID) { row in
            if !pendingContentDelta.isEmpty {
                row.content += pendingContentDelta
                pendingContentDelta = ""
                mutated = true
            }
            if includeThinking && !pendingThinkingDelta.isEmpty {
                row.thinking += pendingThinkingDelta
                pendingThinkingDelta = ""
                mutated = true
            }
        }
        guard mutated else { return }
        if !force, location == .visibleTranscript { updateInFlight = true }  // cooldown
    }

    /// Where `mutateRow(_:in:_:)` found the message row.
    enum StreamingRowLocation { case visibleTranscript, backgroundSession, notFound }

    /// Applies `mutate` to a message row by id: the visible transcript first, then its
    /// owning background session. `.notFound` covers a transcript cleared away.
    @discardableResult
    private func mutateRow(
        _ id: UUID, in sessionID: UUID?, _ mutate: (inout ChatMessage) -> Void
    ) -> StreamingRowLocation {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            mutate(&messages[index])
            return .visibleTranscript
        }
        guard let sessionID,
            let sIndex = sessions.firstIndex(where: { $0.id == sessionID }),
            let mIndex = sessions[sIndex].messages.lastIndex(where: { $0.id == id })
        else { return .notFound }
        mutate(&sessions[sIndex].messages[mIndex])
        return .backgroundSession
    }

    private func finish(_ id: UUID) {
        // Force-flush any pending deltas before mutating the message one
        // last time, so no token is lost when the stream ends between flush
        // ticks. Also cancel the flush loop — it has no work left.
        applyPendingDeltas(includeThinking: true, force: true)
        flushTask?.cancel()
        flushTask = nil
        let finishedSessionID = streamingSessionID
        streamingMessageID = nil
        streamingSessionID = nil
        flushTickCount = 0
        updateInFlight = false

        mutateRow(id, in: finishedSessionID) { row in
            row.isStreaming = false
            if let start = genStart, let first = genFirstToken {
                row.stats = GenerationStats(
                    ttftSeconds: first.timeIntervalSince(start),
                    decodeSeconds: Date().timeIntervalSince(first),
                    completionTokens: genCompletionTokens,
                    promptTokens: genPromptTokens
                )
            }
        }
        // The status-bar context meter tracks the conversation on screen; a background
        // reply's usage belongs to its own session, surfaced when the user returns.
        if let total = genTotalTokens, activeSessionID == finishedSessionID {
            contextUsedTokens = total
        }
        isStreaming = false
        streamTask = nil
        if let finishedSessionID {
            persistSession(finishedSessionID)
        } else {
            persistActiveSession()
        }
    }
}
