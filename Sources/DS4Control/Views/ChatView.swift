// Chat UI ported from mlx-serve (MIT, Copyright 2026 David):
// app/Sources/MLXServe/Views/ChatView.swift. The transcript layout, auto-scroll to
// the latest message, MessageBubble and the iMessage-style input bar are adapted from
// that source, stripped of mlx-serve's agent/tools/MCP machinery. DS4-specific code:
// GeneratingIndicator (the original drove IOKit/Mach GPU telemetry on a polling
// Timer), the pinned-to-bottom follow guard with the Jump-to-latest affordance, and
// the multi-session history sidebar (ChatViewModel owns persistence; see
// ChatSessionStore).

import AppKit
import Combine
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var supervisor: SupervisorService
    @ObservedObject var viewModel: ChatViewModel

    @FocusState private var inputFocused: Bool

    /// History sidebar visibility (persisted). Toggle in the chat header.
    @AppStorage("chatSidebarVisible") private var sidebarVisible = true

    /// How many of the most recent messages stay in the active view tree. Older
    /// messages are *frozen* — excluded from the `ForEach` so the layout pass
    /// doesn't measure them on every streaming token. The chat freeze samples
    /// showed the layout pass iterating every message on every render; with a
    /// window of 50 the per-token work is bounded to 50 measurements regardless
    /// of total transcript length. A "Show earlier" button at the top of the
    /// list grows the window backward when the user wants to scroll back.
    private static let transcriptWindowSize = 50

    @State private var bottomSnapRequest = 0

    /// Extra older messages the user has explicitly expanded into the window via
    /// the "Show earlier" button. Reset to 0 on `clear` (handled by the
    /// `onChange` of `messages.count` — if the user clears, the window starts
    /// fresh; if they keep chatting, the window keeps whatever they've loaded).
    @State private var transcriptExtraAbove = 0

    /// Imperative scroll-follow bookkeeping. These values do not render UI, so they must not be
    /// SwiftUI-publishing state: scroll geometry callbacks can run during layout, and publishing
    /// from there dirties AttributeGraph while it is already placing the transcript.
    @State private var scrollCoordinator = ScrollCoordinator()

    /// Whether the transcript is currently NOT following the tail, i.e. the Jump-to-latest
    /// button is shown. Unlike the follow bookkeeping this *renders*, so it is published
    /// state — but it flips only on pinned→unpinned transitions, never per geometry tick.
    @State private var showsJumpToLatest = false

    /// Conversation being renamed via the sidebar context menu (drives the rename sheet).
    @State private var renamingSession: ChatSession?

    /// Conversation awaiting delete confirmation (drives the destructive alert).
    @State private var pendingDeleteSession: ChatSession?

    /// Scroll metrics observed (via `onScrollGeometryChange`) to drive the follow guard.
    /// Internal (not private) so the follow-rule decision table is unit-testable.
    struct ScrollMetrics: Equatable {
        var offsetY: CGFloat
        var distanceFromBottom: CGFloat
        var contentHeight: CGFloat
        var visibleHeight: CGFloat
    }

    /// Pure decision table for the pinned-to-bottom follow guard. Extracted so the
    /// unpin/re-pin logic is unit-testable without a live scroll view.
    ///
    /// Unpin rule: the viewport moved away from the tail *faster than the content grew*.
    /// Streaming growth alone keeps `Δdistance ≈ ΔcontentHeight` (with or without a snap
    /// — a snap drives distance to ~0, Δ strongly negative), so it never unpins; a user
    /// scroll-up adds to the distance beyond the growth and does. This survives coalesced
    /// growth+scroll geometry events (the norm while streaming at ~30 Hz) — the previous
    /// "offset decreased on a stable height" rule never fired mid-stream because the height
    /// changed on every flush tick. A stable viewport height is required so a window resize
    /// (which moves the tail distance without any scrolling) can't fake intent.
    enum ScrollFollowRule {
        /// Closer than this to the tail re-engages the follow.
        static let rePinDistance: CGFloat = 24
        /// Minimum distance growth beyond content growth that counts as deliberate.
        static let scrollAwayThreshold: CGFloat = 3
        /// Viewport-height change at or below this counts as "unchanged".
        static let viewportStableTolerance: CGFloat = 0.5

        /// True when the user deliberately scrolled away from the streaming tail.
        static func userScrolledAway(old: ScrollMetrics, new: ScrollMetrics) -> Bool {
            let viewportStable =
                abs(new.visibleHeight - old.visibleHeight) <= viewportStableTolerance
            let growth = max(0, new.contentHeight - old.contentHeight)
            let drift = new.distanceFromBottom - old.distanceFromBottom - growth
            return viewportStable && drift > scrollAwayThreshold
        }

        /// True when the viewport is close enough to the tail to re-engage the follow.
        static func atBottom(_ metrics: ScrollMetrics) -> Bool {
            metrics.distanceFromBottom < rePinDistance
        }
    }

    private struct StreamingTailRevision: Equatable {
        var messageID: UUID?
        var messageCount: Int
        var snapRequest: Int
        var contentLength: Int
        var thinkingLength: Int

        var isActive: Bool { messageID != nil }

        static let inactive = StreamingTailRevision(
            messageID: nil,
            messageCount: 0,
            snapRequest: 0,
            contentLength: 0,
            thinkingLength: 0)
    }

    private final class ScrollCoordinator {
        var userPinnedToBottom = true
    }

    private struct BottomScrollDriver: NSViewRepresentable {
        let shouldFollow: Bool
        let revision: StreamingTailRevision
        /// Live pin bookkeeping, read at snap-fire time. A snap scheduled just before the
        /// user scrolls away must not drag them back to the tail, so the delayed closures
        /// re-check `userPinnedToBottom` when they fire (not when they were scheduled).
        let pinState: ScrollCoordinator

        func makeNSView(context _: Context) -> NSView {
            let view = NSView(frame: .zero)
            view.setContentHuggingPriority(.required, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            let snapRequested = context.coordinator.lastRevision.snapRequest != revision.snapRequest
            guard shouldFollow || snapRequested else {
                context.coordinator.lastRevision = revision
                return
            }

            let rowCountChanged = context.coordinator.lastRevision.messageCount != revision.messageCount
            let changed = context.coordinator.lastRevision != revision || !context.coordinator.didInitialScroll
            context.coordinator.lastRevision = revision
            context.coordinator.didInitialScroll = true
            guard changed, !context.coordinator.scrollScheduled else { return }

            context.coordinator.scrollScheduled = true
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator, pinState] in
                coordinator?.scrollScheduled = false
                guard let view else { return }
                if pinState.userPinnedToBottom {
                    Self.scrollTranscriptToBottom(from: view)
                }
            }
            if rowCountChanged {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view, pinState] in
                    guard let view else { return }
                    if pinState.userPinnedToBottom {
                        Self.scrollTranscriptToBottom(from: view)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak view, pinState] in
                    guard let view else { return }
                    if pinState.userPinnedToBottom {
                        Self.scrollTranscriptToBottom(from: view)
                    }
                }
            }
        }

        private static func scrollTranscriptToBottom(from view: NSView) {
            guard let scrollView = findTranscriptScrollView(from: view),
                let documentView = scrollView.documentView
            else { return }

            scrollView.layoutSubtreeIfNeeded()
            documentView.layoutSubtreeIfNeeded()

            let bottomY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
            let point = NSPoint(x: scrollView.contentView.bounds.origin.x, y: bottomY)
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private static func findTranscriptScrollView(from view: NSView) -> NSScrollView? {
            if let enclosing = view.enclosingScrollView { return enclosing }

            var current: NSView? = view
            while let candidate = current {
                if let scrollView = findLargestVerticalScrollView(in: candidate) {
                    return scrollView
                }
                current = candidate.superview
            }

            guard let contentView = view.window?.contentView else { return nil }
            return findLargestVerticalScrollView(in: contentView)
        }

        private static func findLargestVerticalScrollView(in root: NSView) -> NSScrollView? {
            var best: NSScrollView?
            var bestArea: CGFloat = 0

            func visit(_ view: NSView) {
                if let scrollView = view as? NSScrollView,
                    let documentView = scrollView.documentView
                {
                    let scrollableHeight = documentView.frame.height - scrollView.contentView.bounds.height
                    let area = scrollView.bounds.width * scrollView.bounds.height
                    if scrollableHeight > 1, area > bestArea {
                        best = scrollView
                        bestArea = area
                    }
                }

                for subview in view.subviews {
                    visit(subview)
                }
            }

            visit(root)
            return best
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        final class Coordinator {
            var lastRevision = StreamingTailRevision.inactive
            var didInitialScroll = false
            var scrollScheduled = false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                ChatHistorySidebar(
                    viewModel: viewModel,
                    onRename: { renamingSession = $0 },
                    onDelete: { pendingDeleteSession = $0 }
                )
                .frame(width: 220)
                Divider()
            }

            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                inputBar
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 700, minHeight: 640)
        .onAppear { WindowChrome.windowOpened(title: "DS4 Chat") }
        .onDisappear { WindowChrome.windowClosed() }
        // Focus the input the instant the window becomes key. WindowChrome makes it key
        // asynchronously (after the accessory→regular switch), so the old fixed 0.3s delay
        // was racy — this fires exactly on the key transition, every open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            note in
            if (note.object as? NSWindow)?.title == "DS4 Chat" { inputFocused = true }
        }
        // Switching conversations must land at the fresh transcript's bottom even when the
        // previous one was left scrolled up — the explicit snap bypasses the follow guard.
        .onChange(of: viewModel.activeSessionID) { _, _ in
            setPinned(true)
            bottomSnapRequest &+= 1
        }
        .sheet(item: $renamingSession) { session in
            RenameChatSheet(initialTitle: session.title) { newTitle in
                viewModel.renameSession(session.id, to: newTitle)
            }
        }
        .alert(
            "Delete conversation?",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { if !$0 { pendingDeleteSession = nil } }),
            presenting: pendingDeleteSession
        ) { session in
            Button("Delete", role: .destructive) {
                pendingDeleteSession = nil
                viewModel.deleteSession(session.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text(
                "“\(session.title)” and its \(session.messages.count) message\(session.messages.count == 1 ? "" : "s") will be deleted permanently."
            )
        }
    }

    /// Bottom status bar: context window usage (used / total) with a thin bar.
    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("Context")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(
                value: Double(min(viewModel.contextUsedTokens, supervisor.ctx)),
                total: Double(max(supervisor.ctx, 1))
            )
            .progressViewStyle(.linear)
            .frame(width: 120)
            Text("\(viewModel.contextUsedTokens.formatted()) / \(supervisor.ctx.formatted())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            ThinkingModePicker()
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { sidebarVisible.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help(sidebarVisible ? "Hide conversation list" : "Show conversation list")

            VStack(alignment: .leading, spacing: 1) {
                Text(supervisor.activeModel ?? viewModel.model)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let title = viewModel.activeSessionTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            Button {
                viewModel.newChat()
            } label: {
                Label("New Chat", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(viewModel.messages.isEmpty)
            .help("Start a new conversation (⌘N)")

            Button("Clear") {
                viewModel.clear()
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.messages.isEmpty)
            .help("Remove every message from this conversation")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        List {
            let window = transcriptWindow()
            let hiddenAbove = viewModel.messages.count - window.count
            if hiddenAbove > 0 {
                // "Show earlier" affordance — tap to grow the window backward by another
                // `transcriptWindowSize`. The system list keeps rows outside the viewport
                // virtualized, so expanded history is not fully materialized during streaming.
                Button {
                    transcriptExtraAbove += min(hiddenAbove, Self.transcriptWindowSize)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle")
                        Text(
                            "Show \(min(hiddenAbove, Self.transcriptWindowSize)) earlier message\(hiddenAbove == 1 ? "" : "s")"
                        )
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                    .background(Color(.controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(window) { message in
                MessageBubble(message: message)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if viewModel.isStreaming && !viewModel.hasReceivedFirstToken {
                HStack {
                    GeneratingIndicator()
                    Spacer()
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottom) {
            BottomScrollDriver(
                shouldFollow: scrollCoordinator.userPinnedToBottom,
                revision: streamingTailRevision,
                pinState: scrollCoordinator
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
        .onChange(of: viewModel.messages.count) { _, _ in
            scrollCoordinator.userPinnedToBottom = true
            showsJumpToLatest = false
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offsetY: geometry.contentOffset.y,
                distanceFromBottom: geometry.contentSize.height - geometry.visibleRect.maxY,
                contentHeight: geometry.contentSize.height,
                visibleHeight: geometry.visibleRect.height)
        } action: { old, new in
            // Disengage the follow the moment the user scrolls away from the tail — the
            // distance-from-bottom grows beyond what streaming content growth explains
            // (see ScrollFollowRule; works mid-stream, where the height changes every
            // ~33ms flush). Re-engage once the view is back at the bottom.
            if ScrollFollowRule.userScrolledAway(old: old, new: new) {
                setPinned(false)
            } else if ScrollFollowRule.atBottom(new) {
                setPinned(true)
            }
        }
        .overlay {
            if viewModel.messages.isEmpty && !viewModel.isStreaming {
                emptyState
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsJumpToLatest {
                jumpToLatestButton
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsJumpToLatest)
    }

    /// Placeholder shown in a brand-new (or cleared) conversation.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No messages yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Ask anything below — conversations are saved automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// Floating affordance while the transcript is scrolled away from the tail — visible
    /// both mid-stream (reading back through the reply) and while idle.
    private var jumpToLatestButton: some View {
        Button(action: jumpToLatest) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white, Color.accentColor)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .help("Jump to the latest message")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var streamingTailRevision: StreamingTailRevision {
        let tail = viewModel.messages.last
        let streamingTail = viewModel.isStreaming && (tail?.isStreaming ?? false)

        // The revision is built even while idle: `snapRequest` must reach the driver so
        // Jump-to-latest / session-switch snaps work without a live stream. Everything
        // else collapses to the inactive shape when nothing is streaming.
        return StreamingTailRevision(
            messageID: streamingTail ? tail?.id : nil,
            messageCount: viewModel.messages.count,
            snapRequest: bottomSnapRequest,
            contentLength: streamingTail ? (tail?.content.utf8.count ?? 0) : 0,
            thinkingLength: streamingTail ? (tail?.thinking.utf8.count ?? 0) : 0)
    }

    /// Updates the follow bookkeeping and mirrors *transitions* into the published
    /// `showsJumpToLatest` (the Jump-to-latest button's visibility). Called from
    /// scroll-geometry callbacks — only a flip publishes state, never a steady tick.
    private func setPinned(_ pinned: Bool) {
        guard scrollCoordinator.userPinnedToBottom != pinned else { return }
        scrollCoordinator.userPinnedToBottom = pinned
        showsJumpToLatest = !pinned
    }

    /// Jump-to-latest: re-engage the follow and issue an explicit snap so the transcript
    /// scrolls even when nothing is streaming.
    private func jumpToLatest() {
        setPinned(true)
        bottomSnapRequest &+= 1
    }

    private func submitMessage() {
        guard supervisor.state == .ready, viewModel.canSend else { return }
        setPinned(true)
        viewModel.send()
        bottomSnapRequest &+= 1
    }

    /// Slices the message list to the active window: the last
    /// `transcriptWindowSize` messages plus any older ones the user has
    /// explicitly expanded via "Show earlier". Frozen (out-of-window) messages
    /// are not in the returned array, so the `ForEach` doesn't iterate them
    /// and the layout pass doesn't measure them.
    private func transcriptWindow() -> [ChatMessage] {
        let all = viewModel.messages
        let end = all.count
        let windowSize = Self.transcriptWindowSize + transcriptExtraAbove
        let start = max(0, end - windowSize)
        return Array(all[start..<end])
    }

    /// True while a reply is still generating into a *background* conversation (the user
    /// switched away mid-stream). The single-session server can't take a new request
    /// until it finishes, so the input bar says where generation is running instead of
    /// offering a stop button for a conversation that isn't on screen.
    private var viewingBackgroundStream: Bool {
        viewModel.isStreaming && viewModel.activeSessionID != viewModel.streamingSessionID
    }

    /// Stop control is shown only when the visible conversation is the one generating.
    private var stopButtonVisible: Bool {
        viewModel.isStreaming && !viewingBackgroundStream
    }

    private var inputBar: some View {
        VStack(spacing: 4) {
            if let error = viewModel.errorText {
                HStack {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }
            if viewingBackgroundStream,
                let title = viewModel.sessions.first(where: { $0.id == viewModel.streamingSessionID })?.title
            {
                HStack {
                    Text("Generating in “\(title)”… — switch back to stop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $viewModel.input, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...15)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .focused($inputFocused)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )
                    .onKeyPress(keys: [.return, .init("\u{03}")], phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            viewModel.input += "\n"
                            return .handled
                        }
                        if supervisor.state == .ready, viewModel.canSend {
                            submitMessage()
                        }
                        return .handled
                    }
                    .disabled(supervisor.state != .ready)

                Button {
                    if stopButtonVisible {
                        viewModel.stop()
                    } else {
                        submitMessage()
                    }
                } label: {
                    Image(systemName: stopButtonVisible ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(stopButtonVisible ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(
                    supervisor.state != .ready
                        || viewingBackgroundStream
                        || (viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !stopButtonVisible)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: viewModel.isStreaming) { _, streaming in
            if !streaming { inputFocused = true }
        }
    }
}

/// Symmetric chat bubble adapted from mlx-serve's MessageBubble (MIT). User
/// messages get a filled accent pill; assistant messages render via the selectable
/// MarkdownText renderer in a neutral pill.
struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant, !message.thinking.isEmpty {
                    ThinkingDisclosure(
                        text: message.thinking,
                        streaming: message.isStreaming && message.content.isEmpty,
                        stats: message.stats)
                }
                // Show the answer bubble once content arrives; while only reasoning is still
                // streaming (content empty, thinking present) the disclosure stands in for it,
                // so no empty bubble flashes. The non-thinking path keeps its streaming placeholder.
                if !message.content.isEmpty || (message.isStreaming && message.thinking.isEmpty) {
                    VStack(alignment: .leading, spacing: 4) {
                        if message.role == .assistant {
                            if message.isStreaming {
                                StreamingMarkdownText(message.content)
                            } else {
                                MarkdownText(message.content)
                            }
                        } else {
                            Text(message.content)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? Color.accentColor : Color(.controlBackgroundColor))
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                if message.role == .assistant, let stats = message.stats {
                    Text(Self.statsLine(stats))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
            }
        }
        // Collapse the bubble into a single accessibility node. Otherwise SwiftUI's
        // focus-responder walker recurses into every Text / HStack / padding /
        // background inside the bubble on every layout pass — the rebuild cost
        // scales with transcript size. (Dashwiz's chat does the same on its
        // MessageBubble for the same reason; their cramerpax freeze trace
        // pinned this as the dominant hot path on a long transcript.)
        .accessibilityElement(children: .combine)
    }

    /// e.g. "TTFT 640 ms · gen 1.8s · out 1204 tok · in 156 tok · 47.3 tok/s" — nil parts
    /// are omitted. tok/s keeps one decimal (47.3 vs the old rounded 47) because a
    /// 0.5 tok/s step is visible on a local decode; counts stay plain (locale-invariant,
    /// matching the duration formatting).
    static func statsLine(_ stats: GenerationStats) -> String {
        var parts: [String] = []
        if let ttft = stats.ttftSeconds { parts.append("TTFT \(formatDuration(ttft))") }
        if let decode = stats.decodeSeconds { parts.append("gen \(formatDuration(decode))") }
        if let tokens = stats.completionTokens { parts.append("out \(tokens) tok") }
        if let prompt = stats.promptTokens { parts.append("in \(prompt) tok") }
        if let tps = stats.tokensPerSecond { parts.append("\(String(format: "%.1f", tps)) tok/s") }
        return parts.joined(separator: " · ")
    }

    /// Sub-second durations render in ms, longer ones in seconds.
    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        return String(format: "%.1fs", seconds)
    }

    /// Totals for the collapsed thinking header, lighter than the bubble's stats line:
    /// total wall time (TTFT + decode) and the token count, e.g. "8.9s · 1204 tok".
    /// nil when nothing is known (no timing) — the header then shows just "Thinking".
    static func thinkingStatsLine(_ stats: GenerationStats) -> String? {
        var parts: [String] = []
        let total = (stats.ttftSeconds ?? 0) + (stats.decodeSeconds ?? 0)
        if total > 0 { parts.append(formatDuration(total)) }
        if let tokens = stats.completionTokens { parts.append("\(tokens) tok") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Think-Max reasoning, hidden by default in a collapsed disclosure. The reasoning is built
/// only when expanded, so collapsed reasoning costs nothing to render (the deltas just
/// accumulate in the model).
///
/// Expanded long reasoning gets its own bounded, independently scrollable pane: a Max-Think
/// chain can run for tens of thousands of tokens, and a row that tall inside the transcript
/// List breaks its scrolling (the view keeps snapping back to the tail while the user reads).
/// The pane keeps the transcript row a sane height and makes browsing the reasoning fully
/// independent of generation and of the transcript's follow-the-tail logic. Short reasoning
/// stays inline so a few lines don't get a scroll bar of their own.
///
/// When the reply finished, the collapsed header also shows its totals (duration · tokens)
/// in a lighter tertiary style — the same numbers the bubble's stats line carries.
struct ThinkingDisclosure: View {
    let text: String
    let streaming: Bool
    var stats: GenerationStats? = nil
    @State private var expanded = false

    /// Reasoning longer than this (≈20 lines) renders in the capped scroll pane.
    private static let scrollPaneThreshold = 900
    /// Cap for the expanded pane — tall enough to read comfortably, short enough that the
    /// transcript row never becomes the tallest thing in the window.
    private static let paneMaxHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 10)
                        Label(streaming ? "Thinking…" : "Thinking", systemImage: "brain")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !streaming, let stats, let line = MessageBubble.thinkingStatsLine(stats) {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if expanded {
                Group {
                    if text.count > Self.scrollPaneThreshold {
                        ScrollView {
                            MarkdownText(text)
                                .opacity(0.9)
                        }
                        .frame(maxHeight: Self.paneMaxHeight)
                    } else {
                        MarkdownText(text)
                            .opacity(0.9)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Minimal three-dot indicator shown while awaiting the first streamed token.
/// Fresh DS4 code (mlx-serve's original was a GPU-telemetry animation).
struct GeneratingIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                    .opacity(1.0 - Double(index) * 0.25)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// Conversation history sidebar: the persisted session list with new/select/rename/
/// delete. Selection routes through `ChatViewModel.selectSession(_:)`, which flushes
/// the outgoing conversation to disk and swaps the active transcript.
private struct ChatHistorySidebar: View {
    @ObservedObject var viewModel: ChatViewModel
    let onRename: (ChatSession) -> Void
    let onDelete: (ChatSession) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.newChat()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.messages.isEmpty)
                .help("Start a new conversation (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if viewModel.sessions.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No conversations yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Your chats will appear here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .multilineTextAlignment(.center)
                Spacer()
            } else {
                List(selection: Binding(
                    get: { viewModel.activeSessionID },
                    set: { if let id = $0 { viewModel.selectSession(id) } }
                )) {
                    ForEach(viewModel.sessions) { session in
                        ChatSessionRow(
                            session: session,
                            streaming: session.id == viewModel.streamingSessionID)
                            .tag(session.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button("Rename…") { onRename(session) }
                                Button("Delete", role: .destructive) { onDelete(session) }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
    }
}

/// One sidebar row: conversation title over a secondary metadata line. `streaming`
/// shows the live-generation dot — the conversation still receiving a background
/// reply after the user switched away mid-stream.
private struct ChatSessionRow: View {
    let session: ChatSession
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if streaming {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .help("Generating…")
                }
            }
            HStack(spacing: 4) {
                Text(session.updatedAt, format: .relative(presentation: .named))
                Text("·")
                Text("\(session.messages.count) message\(session.messages.count == 1 ? "" : "s")")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Compact rename sheet driven by the sidebar context menu. Enter commits, Esc cancels.
private struct RenameChatSheet: View {
    let initialTitle: String
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var focused: Bool

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Conversation")
                .font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            title = initialTitle
            focused = true
        }
    }

    private func commit() {
        guard !trimmedTitle.isEmpty else { return }
        onCommit(trimmedTitle)
        dismiss()
    }
}
