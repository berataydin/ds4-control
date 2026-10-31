import XCTest

final class ThinkingDisclosureTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let root =
            testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testThinkingDisclosureUsesExplicitToggleButton() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertFalse(chatView.contains("DisclosureGroup(isExpanded: $expanded)"))
        XCTAssertTrue(chatView.contains("Button {"))
        XCTAssertTrue(chatView.contains("expanded.toggle()"))
        XCTAssertTrue(chatView.contains(#"Image(systemName: expanded ? "chevron.down" : "chevron.right")"#))
        XCTAssertTrue(chatView.contains("if expanded {"))
        XCTAssertTrue(chatView.contains("MarkdownText(text)"))
    }

    /// Long expanded reasoning lives in its own bounded, independently scrollable pane —
    /// a transcript row tens of thousands of points tall is what kept snapping the view
    /// back to the tail while the user read.
    func testExpandedLongThinkingUsesBoundedScrollPane() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertTrue(chatView.contains("private static let scrollPaneThreshold"))
        XCTAssertTrue(chatView.contains("private static let paneMaxHeight"))
        XCTAssertTrue(chatView.contains("text.count > Self.scrollPaneThreshold"))
        XCTAssertTrue(chatView.contains(".frame(maxHeight: Self.paneMaxHeight)"))
    }

    /// The collapsed header shows the finished reply's totals (duration · tokens) in a
    /// lighter tertiary style, fed from the message stats.
    func testCollapsedThinkingHeaderShowsLightTotals() throws {
        let chatView = try source("Sources/DS4Control/Views/ChatView.swift")

        XCTAssertTrue(chatView.contains("MessageBubble.thinkingStatsLine(stats)"))
        XCTAssertTrue(chatView.contains(".foregroundStyle(.tertiary)"))
        XCTAssertTrue(chatView.contains("streaming: message.isStreaming && message.content.isEmpty,"))
        XCTAssertTrue(chatView.contains("stats: message.stats)"))
    }
}
