import Foundation

/// Persists chat sessions as one JSON file per session (`<uuid>.json`) under the
/// app-support `Chats/` directory.
///
/// Deliberately synchronous and boundary-driven: transcripts are tens of KB, and
/// writes happen only at conversation boundaries (first message, stream end/stop,
/// clear, switch, rename, delete) — never per streamed token. A crash mid-write can
/// leave one truncated file; `loadSessions()` skips undecodable files so the rest of
/// the history still opens.
struct ChatSessionStore {
    /// Directory holding the `<uuid>.json` session files.
    let directory: URL

    /// Production store under `~/Library/Application Support/DS4 Control/Chats`.
    init(directory: URL = ChatSessionStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        ds4AppSupportDir().appendingPathComponent("Chats", isDirectory: true)
    }

    /// Loads every decodable session file, newest-first. Files that fail to decode are
    /// skipped rather than failing the whole load.
    func loadSessions() -> [ChatSession] {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let files =
            (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []
        var sessions: [ChatSession] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file), let session = Self.decode(data)
            else { continue }
            sessions.append(session)
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Atomically writes one session. Messages still flagged `isStreaming` are
    /// normalized to false in the encoded copy — a persisted session is never live.
    func save(_ session: ChatSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Self.normalized(session))
        try data.write(to: fileURL(for: session.id), options: .atomic)
    }

    /// Removes the session's file (and its directory entry only — sibling sessions stay).
    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// `isStreaming` never survives a round-trip: on load it is false (a saved session
    /// was, by definition, not live), and a quit-time save of a mid-stream reply must
    /// not resurrect a spinner on relaunch.
    private static func normalized(_ session: ChatSession) -> ChatSession {
        var copy = session
        for index in copy.messages.indices { copy.messages[index].isStreaming = false }
        return copy
    }

    private static func decode(_ data: Data) -> ChatSession? {
        guard var session = try? JSONDecoder().decode(ChatSession.self, from: data) else {
            return nil
        }
        for index in session.messages.indices { session.messages[index].isStreaming = false }
        return session
    }

    private static let encoder: JSONEncoder = {
        // Default `deferredToDate` strategy keeps full sub-second precision so
        // `updatedAt` ordering never ties between quickly-written sessions.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }()
}
