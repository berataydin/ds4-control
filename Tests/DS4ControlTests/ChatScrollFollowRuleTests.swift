import XCTest

@testable import DS4Control

/// Decision table for the pinned-to-bottom follow guard (`ChatView.ScrollFollowRule`).
/// The rule must survive streaming: content grows on every ~33ms flush, so "the offset
/// moved" alone can't mean the user scrolled — only distance-from-bottom growth BEYOND
/// content growth does. Each case pins one geometry transition from the live transcript.
final class ChatScrollFollowRuleTests: XCTestCase {
    private func metrics(
        bottom: CGFloat, height: CGFloat, visible: CGFloat = 600
    ) -> ChatView.ScrollMetrics {
        ChatView.ScrollMetrics(
            offsetY: 0, distanceFromBottom: bottom, contentHeight: height, visibleHeight: visible)
    }

    func testPureScrollUpUnpins() {
        // Same height, distance grows 40 — a deliberate scroll-up with no streaming growth.
        XCTAssertTrue(
            ChatView.ScrollFollowRule.userScrolledAway(
                old: metrics(bottom: 0, height: 5000),
                new: metrics(bottom: 40, height: 5000)))
    }

    func testTinyScrollDoesNotUnpinAndStaysPinned() {
        // A 2pt drift is below the 3pt intent threshold — and 2pt from the bottom is
        // inside the re-pin distance, so the follow stays engaged.
        let new = metrics(bottom: 2, height: 5000)
        XCTAssertFalse(
            ChatView.ScrollFollowRule.userScrolledAway(
                old: metrics(bottom: 0, height: 5000), new: new))
        XCTAssertTrue(ChatView.ScrollFollowRule.atBottom(new))
    }

    func testStreamingGrowthAloneNeverUnpins() {
        // Content grows 30pt with the viewport untouched: distance grows by exactly
        // the growth (the pre-snap state on every flush tick while pinned).
        XCTAssertFalse(
            ChatView.ScrollFollowRule.userScrolledAway(
                old: metrics(bottom: 0, height: 5000),
                new: metrics(bottom: 30, height: 5030)))
    }

    func testGrowthCoalescedWithScrollUpUnpins() {
        // One coalesced event carries 30pt growth + 40pt of user scrolling:
        // distance grew 70 — more than the 30pt growth explains.
        XCTAssertTrue(
            ChatView.ScrollFollowRule.userScrolledAway(
                old: metrics(bottom: 0, height: 5000),
                new: metrics(bottom: 70, height: 5030)))
    }

    func testSnapToBottomKeepsFollow() {
        // The driver snaps to the tail: distance collapses 200 → 0 while content grew.
        let new = metrics(bottom: 0, height: 5030)
        XCTAssertFalse(
            ChatView.ScrollFollowRule.userScrolledAway(
                old: metrics(bottom: 200, height: 5000), new: new))
        XCTAssertTrue(ChatView.ScrollFollowRule.atBottom(new))
    }

    func testWindowSlideShrinkDoesNotUnpin() {
        // The 50-message window drops rows at send: height shrinks 400pt, distance
        // stays ~0 — growth is clamped at 0 and the drift is nil, so no false intent.
        XCTAssertFalse(
            ChatView.ScrollFollowRule.userScrolledAway(
                old: metrics(bottom: 0, height: 5000),
                new: metrics(bottom: 0, height: 4600)))
    }

    func testViewportResizeDoesNotUnpin() {
        // A taller window moves the tail distance (600 → 680 visible) with no scrolling;
        // the unstable viewport disqualifies the event even though the drift is 80pt.
        XCTAssertFalse(
            ChatView.ScrollFollowRule.userScrolledAway(
                old: metrics(bottom: 0, height: 5000, visible: 600),
                new: metrics(bottom: 80, height: 5000, visible: 680)))
    }

    func testScrollDownTowardBottomDoesNotUnpin() {
        // Scrolling down shrinks the distance — negative drift, and it re-pins at the tail.
        let new = metrics(bottom: 10, height: 5000)
        XCTAssertFalse(
            ChatView.ScrollFollowRule.userScrolledAway(
                old: metrics(bottom: 200, height: 5000), new: new))
        XCTAssertTrue(ChatView.ScrollFollowRule.atBottom(new))
    }

    func testAtBottomThresholdIsStrict() {
        XCTAssertTrue(ChatView.ScrollFollowRule.atBottom(metrics(bottom: 23.9, height: 5000)))
        XCTAssertFalse(ChatView.ScrollFollowRule.atBottom(metrics(bottom: 24, height: 5000)))
        XCTAssertFalse(ChatView.ScrollFollowRule.atBottom(metrics(bottom: 500, height: 5000)))
    }
}
