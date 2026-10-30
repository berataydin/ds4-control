import Foundation

/// One persisted chat conversation. Sessions live as one JSON file each under the
/// app-support `Chats/` directory (see `ChatSessionStore`) and are fully independent —
/// switching sessions swaps the in-memory transcript the streaming pipeline mutates.
struct ChatSession: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    static let defaultTitle = "New Chat"

    /// Title cap — long first prompts must not blow up the sidebar row.
    private static let titleLengthLimit = 60

    init(
        id: UUID = UUID(), title: String = ChatSession.defaultTitle, createdAt: Date = Date(),
        updatedAt: Date = Date(), messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    /// Derives a short human title from the first user message: first line, trimmed,
    /// capped. Falls back to `defaultTitle` for blank prompts.
    static func title(fromFirstUserMessage text: String) -> String {
        let firstLine =
            text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return defaultTitle }
        return String(trimmed.prefix(titleLengthLimit))
    }
}
