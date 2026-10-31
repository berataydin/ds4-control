import XCTest

@testable import DS4Control

final class ChatMessageTests: XCTestCase {
    func testDefaults() {
        let message = ChatMessage(role: .user, content: "hi")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "hi")
        XCTAssertFalse(message.isStreaming)
    }

    func testUniqueIDs() {
        let a = ChatMessage(role: .assistant, content: "")
        let b = ChatMessage(role: .assistant, content: "")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testStreamingFlag() {
        let message = ChatMessage(role: .assistant, content: "", isStreaming: true)
        XCTAssertTrue(message.isStreaming)
    }

    func testEquatableByValue() {
        let id = UUID()
        let a = ChatMessage(id: id, role: .user, content: "x")
        let b = ChatMessage(id: id, role: .user, content: "x")
        XCTAssertEqual(a, b)
    }

    func testTokensPerSecond() {
        let stats = GenerationStats(ttftSeconds: 0.5, decodeSeconds: 2.0, completionTokens: 90)
        XCTAssertEqual(stats.tokensPerSecond, 45)
    }

    func testTokensPerSecondNilWhenIncomplete() {
        XCTAssertNil(GenerationStats(decodeSeconds: 2.0, completionTokens: nil).tokensPerSecond)
        XCTAssertNil(GenerationStats(decodeSeconds: 0, completionTokens: 90).tokensPerSecond)
    }

    func testPromptTokensDefaultNilAndBackwardCompatibleDecode() throws {
        // New field: existing stats (and persisted older JSON without the key) decode nil.
        XCTAssertNil(GenerationStats(ttftSeconds: 1, decodeSeconds: 2, completionTokens: 3).promptTokens)
        let legacyJSON = """
            {"ttftSeconds":0.5,"decodeSeconds":2.0,"completionTokens":90}
            """
        let decoded = try JSONDecoder().decode(GenerationStats.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.completionTokens, 90)
        XCTAssertNil(decoded.promptTokens)

        let roundTrip = try JSONDecoder().decode(
            GenerationStats.self,
            from: JSONEncoder().encode(GenerationStats(promptTokens: 12)))
        XCTAssertEqual(roundTrip.promptTokens, 12)
    }

    // MARK: - stats line (MessageBubble.statsLine)

    func testStatsLineShowsDecimalTokensPerSecondAndCounts() {
        let stats = GenerationStats(
            ttftSeconds: 0.64, decodeSeconds: 1.8, completionTokens: 85,
            promptTokens: 156)
        XCTAssertEqual(
            MessageBubble.statsLine(stats),
            "TTFT 640 ms · gen 1.8s · out 85 tok · in 156 tok · 47.2 tok/s")
    }

    func testStatsLineOmitsMissingParts() {
        // No usage event → no counts; timing-only line keeps its shape.
        XCTAssertEqual(
            MessageBubble.statsLine(GenerationStats(ttftSeconds: 0.5, decodeSeconds: 2.0)),
            "TTFT 500 ms · gen 2.0s")
        // Counts without prompt tokens omit only the "in" segment.
        XCTAssertEqual(
            MessageBubble.statsLine(GenerationStats(decodeSeconds: 2.0, completionTokens: 90)),
            "gen 2.0s · out 90 tok · 45.0 tok/s")
    }

    // MARK: - thinking header totals (MessageBubble.thinkingStatsLine)

    func testThinkingStatsLineShowsTotalDurationAndTokens() {
        // Total wall time = TTFT + decode; tokens = server completion count.
        XCTAssertEqual(
            MessageBubble.thinkingStatsLine(
                GenerationStats(ttftSeconds: 0.9, decodeSeconds: 8.0, completionTokens: 1204)),
            "8.9s · 1204 tok")
        // Sub-second totals render in ms, like the bubble line.
        XCTAssertEqual(
            MessageBubble.thinkingStatsLine(
                GenerationStats(ttftSeconds: 0.2, decodeSeconds: 0.3, completionTokens: 9)),
            "500 ms · 9 tok")
    }

    func testThinkingStatsLineOmitsUnknownPartsAndCanReturnNil() {
        XCTAssertEqual(
            MessageBubble.thinkingStatsLine(GenerationStats(completionTokens: 40)),
            "40 tok")
        XCTAssertEqual(
            MessageBubble.thinkingStatsLine(GenerationStats(decodeSeconds: 2.0)),
            "2.0s")
        XCTAssertNil(MessageBubble.thinkingStatsLine(GenerationStats()))
    }
}
