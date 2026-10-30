import SwiftUI

@main
struct DS4ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app: AppState
    @StateObject private var metrics = MetricsManager()
    @StateObject private var supervisor: SupervisorService
    @StateObject private var chat: ChatViewModel
    @State private var menuBarStartup = MenuBarStartupCoordinator()

    init() {
        MarkdownText.runResourceSelfTestIfRequested()  // headless bundle-resolution check (env-gated)
        HFDownloader.runSelfTestIfRequested()  // headless native-download check (env-gated)
        let app = AppState()
        _app = StateObject(wrappedValue: app)  // same instance the chat closures read, so the UI's toggles reach it
        let supervisor = SupervisorService(
            ds4Dir: bundledDS4Dir(), runner: RealProcessRunner(),
            ggufBaseURL: defaultGGUFDir(),
            // The Settings ▸ Downloads folder choice, validated live (nil = default above).
            // Re-read on every use, so changing it re-points downloads and installed-model
            // checks without restarting the app.
            ggufPreferredDir: { app.configuredDownloadsDirectory })
        _supervisor = StateObject(wrappedValue: supervisor)
        let service = ChatService()
        _chat = StateObject(
            wrappedValue: ChatViewModel(
                model: app.selectedVariant.modelId,
                port: { [weak supervisor] in supervisor?.port ?? app.port },
                streamProvider: { port, model, messages in
                    service.stream(
                        port: port, model: model, messages: messages, mode: app.thinkingMode,
                        maxTokens: app.maxOutputTokens, temperature: app.chatTemperature)
                }
            )
        )
        appDelegate.configure(app: app, supervisor: supervisor, chat: chat)
    }

    var body: some Scene {
        MenuBarExtra {
            PopupView()
                .environmentObject(app).environmentObject(metrics).environmentObject(supervisor)
                .onAppear { startMenuBarServicesIfNeeded() }
        } label: {
            MenuBarLabelView(state: supervisor.state)
        }
        .menuBarExtraStyle(.window)

        Window("DS4 Control Settings", id: "settings") {
            SettingsView().environmentObject(app).environmentObject(supervisor)
        }
        .windowResizability(.contentSize)

        Window("DS4 Metal Wired Limit Help", id: "wiredhelp") {
            WiredLimitHelpView().environmentObject(app)
        }
        .windowResizability(.contentSize)

        Window("DS4 Chat", id: "chat") {
            ChatView(viewModel: chat).environmentObject(app).environmentObject(supervisor)
        }
        .defaultSize(width: 980, height: 720)
    }

    private func startMenuBarServicesIfNeeded() {
        guard !menuBarStartup.started else { return }
        menuBarStartup.started = true
        DispatchQueue.main.async {
            // Metrics collection is visibility-driven: PopupView's onAppear/onDisappear call
            // metrics.setActive(_:) — visible samples at the fast cadence, hidden drops to the
            // slow background cadence (the graphs must not gap while the popup is closed).
            supervisor.resumeRunningServerIfAny(port: app.port)
            supervisor.resumeInFlightDownloadIfAny(
                selection: app.quantSelection, highPerformance: app.highPerformanceDownload)
        }
    }
}

private final class MenuBarStartupCoordinator {
    var started = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationCoordinator: AppTerminationCoordinator?
    private var chat: ChatViewModel?

    func configure(app: AppState, supervisor: SupervisorService, chat: ChatViewModel) {
        terminationCoordinator = AppTerminationCoordinator(app: app, supervisor: supervisor)
        self.chat = chat
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)  // menu-bar only (LSUIElement)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Flush a mid-stream reply to the session store before anything else — the
        // terminate flow below may stop the server (and the process) without returning
        // to the chat pipeline.
        chat?.persistBeforeQuit()
        guard let terminationCoordinator else {
            NSLog("DS4 Control termination coordination is unavailable; terminating immediately")
            return .terminateNow
        }
        return terminationCoordinator.applicationShouldTerminate { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }
}
