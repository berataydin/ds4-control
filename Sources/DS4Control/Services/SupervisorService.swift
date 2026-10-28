import Foundation
import Combine

/// Reference box so the `@Sendable` stderr callback can accumulate downloader output
/// across invocations. The process reader calls the callback serially, so the single
/// mutable field is never touched concurrently — hence `@unchecked Sendable`.
private final class DownloadStderrBuffer: @unchecked Sendable {
    var text = ""
}

enum RestartResult: Equatable {
    case accepted
    case rejected(Feasibility)
    case ignored
}

enum ListeningPIDResult: Equatable {
    case found([pid_t])
    case none
    case failure
}

/// The Server-group settings a launch was started with. Published by `SupervisorService` so
/// Settings can enable "Apply & Restart Server" only while its controls differ from the
/// running server. `nil` for a server adopted from a previous app run — its launch flags
/// aren't knowable — in which case Apply stays available.
struct LaunchConfig: Equatable {
    var selection: QuantSelection
    var ctx: Int
    var host: String
    var port: Int
    /// Effective GPU power duty. ds4 defaults to 100 and V4.1 always forces full power
    /// (`SupervisorService.memoryArgs`), so unset and explicit 100 compare equal.
    var power: Int
    var sessions: Int
    var kvDiskCache: Bool

    init(
        selection: QuantSelection, ctx: Int, host: String, port: Int, power: Int?,
        sessions: Int, kvDiskCache: Bool
    ) {
        self.selection = selection
        self.ctx = ctx
        self.host = host
        self.port = port
        self.power = selection.variant == .flash41 ? 100 : (power ?? 100)
        self.sessions = sessions
        self.kvDiskCache = kvDiskCache
    }
}

@MainActor
final class SupervisorService: ObservableObject {
    @Published private(set) var state: ServerState = .idle
    @Published private(set) var activeModel: String?
    /// The launch config of the ds4-server this supervisor started (nil while idle/error,
    /// and for a server adopted from a previous app run). Drives Settings' dirty check.
    @Published private(set) var activeConfig: LaunchConfig?
    @Published private(set) var port: Int = 8000
    @Published private(set) var ctx: Int = 393_216
    @Published private(set) var health: HealthStatus?
    // Populated by download(variant:) — see Task 9.
    @Published private(set) var download: DownloadProgress?
    /// True only while a download process is confirmed alive — our own, or (for a download
    /// resumed from a prior session) one found via pgrep. Drives the live spinner; refreshed
    /// every poll tick so it clears within ~1s of the process stopping or being killed.
    @Published private(set) var downloadProcessLive = false
    @Published private(set) var recentLog: [String] = []
    /// Bumped whenever the on-disk gguf set changes via cleanup, so SwiftUI views that read
    /// `isFlashQuantDownloaded` (the Settings picker) re-render.
    @Published private(set) var ggufStoreVersion = 0
    /// Re-render hook for the same views after an external on-disk change — notably a
    /// Settings downloads-folder switch, which moves every installed/partial check to a
    /// different directory without touching files.
    func noteGGUFStoreChanged() { ggufStoreVersion += 1 }

    let ds4Dir: URL
    let runner: ProcessRunner
    /// Probes a port for a running ds4-server; returns the /v1/models body on HTTP 200,
    /// else nil. Injectable so tests don't depend on a live socket (default hits the
    /// real local server via URLSession).
    let serverProbe: (Int) async -> Data?
    private var stderrTail: [String] = []
    private var expectingExit = false
    private var healthTimer: Timer?
    private var startupTimer: Timer?
    /// Last (bytes, time) sample from the download progress callback, for the transfer-rate delta.
    private var lastDownloadSample: (bytes: Int64, time: Date)?
    /// True when attached to a ds4-server started by a previous session (we don't
    /// own the process; Stop terminates it by port — see resumeRunningServerIfAny).
    private var serverAttached = false
    /// Deferred start used by `restart`: when stopping an owned process, the relaunch
    /// can't happen until it has fully exited (port freed). `handleExit` runs this.
    private var pendingRestart: (() -> Void)?
    /// When set, the in-flight owned teardown settles in `.error(this)` through
    /// `completeStop` instead of `.idle`. Runtime failures must not be published (and Retry
    /// enabled) while the process that caused them is still alive.
    private var pendingStopError: ServerError?
    /// Identifies the runner callback belonging to the current owned server. A runner can
    /// deliver an old process's exit or stderr readiness after a replacement launch has
    /// already started; both are matched against this before touching state.
    private var serverGeneration = 0
    private var activeServerGeneration: Int?
    /// Callers waiting for a confirmed stop (notably app termination). Multiple quit/stop
    /// requests coalesce onto the same in-flight shutdown and are drained exactly once.
    private var pendingStopCompletions: [(Bool) -> Void] = []
    /// Foundation normally delivers `Process.terminationHandler` after SIGKILL, but an
    /// unresolved owned process must not leave app termination waiting forever.
    private var ownedStopWatchdog: Task<Void, Never>?
    private let ownedStopWatchdogDelay: TimeInterval
    /// Startup watchdog: how long a loading ds4-server may stay in `.starting` before it is
    /// torn down. Injectable so tests can drive the timeout without waiting ten minutes.
    private let startupTimeout: TimeInterval
    typealias ListeningPIDLookup = @Sendable (Int) -> ListeningPIDResult
    private let listeningPIDLookup: ListeningPIDLookup

    /// Where downloaded gguf models live. Resolution order: the `DS4_GGUF_DIR` env
    /// override (dev), then the user's Settings ▸ Downloads folder choice (nil in tests),
    /// then the injected base (production: App Support/gguf; tests: a fixture dir), then
    /// `ds4Dir/gguf`. Re-read on every call so a Settings change applies immediately.
    private let ggufPreferredDir: (() -> URL?)?
    private let ggufBaseOverride: URL?
    /// Parent directory for generation-specific KV caches. Injectable so migration tests
    /// never inspect or remove the developer's real App Support cache.
    private let cacheBaseOverride: URL?

    /// The pluggable file fetch — defaults to the native parallel `HFDownloader`. Tests inject a fake
    /// that simulates progress/completion/failure without touching the network. `repo` selects the
    /// Hugging Face repo (per-model-generation), `highPerformance` the worker count (8 vs 64).
    typealias FetchFile =
        @Sendable (
            _ repo: String, _ revision: String, _ file: String, _ destDir: URL, _ token: String?,
            _ highPerformance: Bool,
            _ onProgress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws -> Void
    private let fetchFile: FetchFile
    typealias FetchPrefix =
        @Sendable (
            _ repo: String, _ revision: String, _ file: String, _ count: Int,
            _ expectedBytes: Int64, _ token: String?
        ) async throws -> Data
    private let fetchPrefix: FetchPrefix

    /// Returns the launch config's feasibility. Injectable so tests don't depend on the
    /// host's RAM/sysctl state (CI runners are far smaller than any supported machine).
    typealias WiredLimitGate =
        (_ selection: QuantSelection, _ ctx: Int, _ sessions: Int) -> Feasibility
    static let defaultWiredLimitGate: WiredLimitGate = { selection, ctx, sessions in
        let ram = systemRamGiB()
        return feasibility(
            ramGiB: ram, selection: selection, ctx: ctx,
            wiredLimitMB: effectiveWiredLimitMB(ramGiB: ram), sessions: sessions)
    }
    private let wiredLimitGate: WiredLimitGate

    init(
        ds4Dir: URL, runner: ProcessRunner, serverProbe: ((Int) async -> Data?)? = nil,
        ggufBaseURL: URL? = nil, cacheBaseURL: URL? = nil,
        ggufPreferredDir: (() -> URL?)? = nil,
        downloadRunner: ProcessRunner? = nil, fetchFile: FetchFile? = nil, fetchPrefix: FetchPrefix? = nil,
        wiredLimitGate: WiredLimitGate? = nil, ownedStopWatchdogDelay: TimeInterval = 35,
        startupTimeout: TimeInterval = 600,
        listeningPIDLookup: ListeningPIDLookup? = nil
    ) {
        self.ds4Dir = ds4Dir
        self.runner = runner
        self.serverProbe = serverProbe ?? SupervisorService.defaultServerProbe
        self.ggufBaseOverride = ggufBaseURL
        self.ggufPreferredDir = ggufPreferredDir
        self.cacheBaseOverride = cacheBaseURL
        self.downloadRunner = downloadRunner ?? RealProcessRunner()
        self.wiredLimitGate = wiredLimitGate ?? Self.defaultWiredLimitGate
        self.ownedStopWatchdogDelay = ownedStopWatchdogDelay
        self.startupTimeout = startupTimeout
        self.listeningPIDLookup = listeningPIDLookup ?? { Self.pidsListening(onPort: $0) }
        self.fetchFile =
            fetchFile ?? { repo, revision, file, dir, token, highPerformance, prog in
                try await HFDownloader(repo: repo, revision: revision).download(
                    file: file, into: dir, token: token, highPerformance: highPerformance, onProgress: prog)
            }
        self.fetchPrefix =
            fetchPrefix ?? { repo, revision, file, count, expectedBytes, token in
                try await HFDownloader(repo: repo, revision: revision).prefix(
                    file: file, count: count, expectedBytes: expectedBytes, token: token)
            }
    }

    /// Generation-specific disk KV-cache directory. ds4 currently identifies caches by
    /// model shape rather than exact weights, so changing releases requires a new path.
    func kvDiskCacheURL(for selection: QuantSelection) -> URL {
        cacheBaseDir().appendingPathComponent(selection.kvCacheDirectoryName, isDirectory: true)
    }

    /// Default probe: GET http://127.0.0.1:<port>/v1/models, returning the body on 200.
    static func defaultServerProbe(_ port: Int) async -> Data? {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
            (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    // Timers are invalidated in stop()/finish()/fail() and on handleExit; the supervisor
    // itself is an app-lifetime @StateObject, so no deinit cleanup is needed (and a
    // nonisolated deinit can't touch these MainActor-isolated, non-Sendable Timers).

    // MARK: - Path resolution
    /// The active downloads dir. `DS4_GGUF_DIR` (dev override) wins over the user's
    /// Settings choice; the injected base is the default. Re-resolved on every call so a
    /// Settings folder change (or remounting a custom volume) applies without a restart.
    private func ggufBaseDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["DS4_GGUF_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let preferred = ggufPreferredDir?() { return preferred }
        return ggufBaseOverride ?? ds4Dir.appendingPathComponent("gguf")
    }
    /// The pre-customization downloads location (the injected base — App Support/gguf in
    /// production). Returned only when it differs from the active dir, so models already
    /// downloaded there stay usable and reclaimable after the user switches folders.
    private func legacyGGUFBaseDir() -> URL? {
        let fallback = ggufBaseOverride ?? ds4Dir.appendingPathComponent("gguf")
        let active = ggufBaseDir()
        return fallback == active ? nil : fallback
    }
    /// Dirs whose on-disk artifacts belong to this quant: the active downloads dir first,
    /// then the legacy location when a custom folder is configured. Reads (installed checks)
    /// consult them in order; cleanups delete from both.
    private func ggufSearchDirs() -> [URL] {
        let active = ggufBaseDir()
        if let legacy = legacyGGUFBaseDir() { return [active, legacy] }
        return [active]
    }
    private func cacheBaseDir() -> URL { cacheBaseOverride ?? ds4AppSupportDir() }
    /// Memory-related launch flags. V4.1 always forces full GPU power duty
    /// (docs/METAL.md@bd66c40) and engages `--ssd-streaming` when the resident fixed set
    /// exceeds ds4's admission budget; Engram rows are disk-resident in every mode.
    /// Extracted so tests can pin both branches without depending on host RAM.
    nonisolated static func memoryArgs(
        selection: QuantSelection, ctx: Int, sessions: Int,
        ramGiB: Double, wiredLimitMB: Int, power: Int?
    ) -> [String] {
        if selection.variant == .flash41 {
            var args = ["--power", "100"]
            if flash41UsesSSDStreaming(
                ramGiB: ramGiB, wiredLimitMB: wiredLimitMB, quant: selection.quant,
                ctx: ctx, sessions: sessions)
            {
                args += ["--ssd-streaming"]
            }
            return args
        }
        return power.map { ["--power", "\($0)"] } ?? []
    }

    private func ggufURL(for selection: QuantSelection) -> URL {
        ggufBaseDir().appendingPathComponent(selection.quant.ggufFilename)
    }
    /// Where the quant's final GGUF actually lives: the active downloads dir first, then
    /// the legacy location (models downloaded before the folder was customized). Falls
    /// back to the active-dir URL — also the not-found error's filename — when neither
    /// has the file.
    private func existingModelFileURL(for selection: QuantSelection) -> URL {
        let active = ggufURL(for: selection)
        if FileManager.default.fileExists(atPath: active.path) { return active }
        if let legacy = legacyGGUFBaseDir() {
            let legacyURL = legacy.appendingPathComponent(selection.quant.ggufFilename)
            if FileManager.default.fileExists(atPath: legacyURL.path) { return legacyURL }
        }
        return active
    }
    private func validateDs4Dir() -> ServerError? {
        for f in ["ds4-server", "download_model.sh"] {
            let u = ds4Dir.appendingPathComponent(f)
            if !FileManager.default.isExecutableFile(atPath: u.path) { return .ds4DirInvalid(missing: f) }
        }
        return nil
    }

    // MARK: - Start
    /// Disk KV-cache budget (MB) when `kvDiskDir` is provided. ds4's compressed KV
    /// is tiny, so this holds many cached prefixes; generous but trivial on modern SSDs.
    static let kvDiskSpaceMB = 16384
    /// Feasibility mirrors ds4's defaults, so inherited allocator tuning is removed
    /// from the server environment before the gate-approved process launches.
    private static let allocatorEnvironmentKeys: Set<String> = [
        "DS4_METAL_PREFILL_CHUNK",
        "DS4_METAL_GRAPH_RAW_CAP",
    ]

    static func normalizedBindHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "127.0.0.1" : trimmed
    }

    func start(
        selection: QuantSelection,
        ctx: Int,
        host: String,
        port: Int,
        power: Int?,
        sessions: Int = 1,
        kvDiskDir: URL? = nil,
        overrideWiredLimitGate: Bool = false
    ) {
        guard state == .idle || isErrorState else { emitBadState("start"); return }
        guard !runner.isRunning, drainingShardGeneration == nil else { emitBadState("start"); return }
        if let e = validateDs4Dir() { state = .error(e); return }
        if let reason = launchBoundsError(variant: selection.variant, ctx: ctx, sessions: sessions) {
            state = .error(.configurationBlocked(reason: reason))
            return
        }
        // Defense-in-depth for the popup gate: refuse configs whose GPU-wired working set
        // exceeds the effective Metal wired limit (starting anyway pages the model and
        // hangs the machine). The UI's confirmed "Start anyway" passes the override.
        switch wiredLimitGate(selection, ctx, sessions) {
        case let .blocked(reason):
            state = .error(.configurationBlocked(reason: reason))
            return
        case let .wiredLimitTooLow(required, advisory) where !overrideWiredLimitGate:
            state = .error(.wiredLimitTooLow(requiredMB: required, advisoryMB: advisory))
            return
        case .standard, .wiredLimitTooLow:
            break
        }
        let gguf = existingModelFileURL(for: selection)
        guard FileManager.default.fileExists(atPath: gguf.path),
            selection.variant != .flash41 || isDownloaded(selection)
        else {
            state = .error(.modelMissing(filename: gguf.lastPathComponent)); return
        }
        self.port = port; self.ctx = ctx; self.activeModel = selection.variant.modelId
        activeConfig = LaunchConfig(
            selection: selection, ctx: ctx, host: Self.normalizedBindHost(host), port: port,
            power: power, sessions: sessions, kvDiskCache: kvDiskDir != nil)
        stderrTail = []; expectingExit = false; serverAttached = false
        // A fresh launch supersedes any teardown whose outcome was never settled.
        pendingStopError = nil
        var args = [
            "-m", gguf.path,
            "--ctx", "\(ctx)",
            "--host", Self.normalizedBindHost(host),
            "--port", "\(port)",
            "--metal",
        ]
        let ram = systemRamGiB()
        args += Self.memoryArgs(
            selection: selection, ctx: ctx, sessions: sessions, ramGiB: ram,
            wiredLimitMB: effectiveWiredLimitMB(ramGiB: ram), power: power)
        // >1 preallocates N resident KV sessions so that many chats/agents generate at once.
        // 1 must omit the flag: ds4 treats even `--batched-session 1` as batched mode (MTP off).
        if sessions > 1 { args += ["--batched-session", "\(sessions)"] }
        if let kvDiskDir {
            // Persist compressed KV to disk so repeated/large prefixes (coding agents)
            // skip re-prefill across turns and restarts. README: "KV cache is a
            // first-class disk citizen." Created here so the path always exists.
            try? FileManager.default.createDirectory(at: kvDiskDir, withIntermediateDirectories: true)
            args += [
                "--kv-disk-dir", kvDiskDir.path,
                "--kv-disk-space-mb", "\(Self.kvDiskSpaceMB)",
            ]
        }
        serverGeneration &+= 1
        let generation = serverGeneration
        activeServerGeneration = generation
        state = .starting
        do {
            try runner.launch(
                executable: ds4Dir.appendingPathComponent("ds4-server"),
                args: args, cwd: ds4Dir, env: [:],
                removingEnvironmentKeys: Self.allocatorEnvironmentKeys,
                onStderrLine: { [weak self] line in
                    Self.onMain { self?.handleStderr(line, generation: generation) }
                },
                onExit: { [weak self] code in
                    Self.onMain { self?.handleExit(code, generation: generation) }
                })
        } catch {
            if activeServerGeneration == generation {
                activeServerGeneration = nil
                activeConfig = nil
            }
            state = .error(.crashed(tail: "\(error)")); return
        }
        startupTimer = Timer.scheduledTimer(withTimeInterval: startupTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleStartupTimeout(generation: generation) }
        }
    }

    private func handleStderr(_ line: String, generation: Int) {
        // Only the active loader's output is ours: a superseded process's late readiness
        // line must not certify the replacement a Retry launched.
        guard activeServerGeneration == generation else { return }
        recentLog.append(line); stderrTail.append(line)
        if stderrTail.count > 50 { stderrTail.removeFirst(stderrTail.count - 50) }
        if state == .starting, isReadyLine(line) {
            startupTimer?.invalidate(); startupTimer = nil
            state = .ready
            startHealthPolling()
        }
    }

    /// The startup watchdog fired: rather than publish `.error` while the loader is still
    /// alive (Retry would then `start()` a replacement that races it for the port and the
    /// GPU working set), terminate it and let `handleExit` settle the failure via
    /// `pendingStopError`.
    private func handleStartupTimeout(generation: Int) {
        guard state == .starting, activeServerGeneration == generation else { return }
        pendingStopError = .startupTimeout
        stop()
    }

    private func handleExit(_ code: Int32, generation: Int) {
        guard activeServerGeneration == generation else { return }
        activeServerGeneration = nil
        activeConfig = nil
        ownedStopWatchdog?.cancel(); ownedStopWatchdog = nil
        healthTimer?.invalidate(); healthTimer = nil; startupTimer?.invalidate(); startupTimer = nil
        if expectingExit {
            completeStop()
            return
        }
        pendingRestart = nil
        state = .error(.crashed(tail: stderrTail.suffix(10).joined(separator: "\n")))
        // A common cause is a bind conflict with a healthy ds4-server we don't own
        // (orphaned by a force-quit, still loading at launch-probe time). If one answers
        // the probe, adopt it instead of dead-ending in .error with an occupied port.
        adoptHealthyServerIfPresent()
    }

    // MARK: - Stop
    /// Stop ds4-server and optionally report whether its exit was confirmed. A completion
    /// registered while already stopping joins the existing shutdown instead of signalling
    /// the process twice. `.idle` is an immediate success; other invalid states are failures.
    func stop(completion: ((Bool) -> Void)? = nil) {
        if state == .stopping {
            if let completion { pendingStopCompletions.append(completion) }
            return
        }
        guard state == .ready || state == .starting else {
            emitBadState("stop")
            completion?(state == .idle)
            return
        }
        if let completion { pendingStopCompletions.append(completion) }
        expectingExit = true
        state = .stopping
        healthTimer?.invalidate(); healthTimer = nil
        startupTimer?.invalidate(); startupTimer = nil
        if serverAttached {
            // We don't own the process (attached on launch) — terminate the listener.
            // SIGTERM lands at once but the process needs time to die, and ds4 refuses a
            // second instance while the old one lives — so .idle (and any pending restart)
            // must wait for the pids to actually exit, not just for the signal.
            serverAttached = false
            let lookup = listeningPIDLookup
            let port = port
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = lookup(port)
                await self?.handleAttachedPIDLookup(result, onPort: port)
            }
        } else {
            startOwnedStopWatchdog()
            runner.terminate(graceSeconds: 30)
        }
    }

    private func handleAttachedPIDLookup(_ result: ListeningPIDResult, onPort port: Int) {
        guard state == .stopping, expectingExit else { return }
        switch result {
        case let .found(pids):
            for pid in pids { kill(pid, SIGTERM) }
            finishAttachedStopWhenExited(pids: pids, waited: 0, escalated: false)
        case .none:
            verifyAttachedServerAbsent(onPort: port)
        case .failure:
            failAttachedStop()
        }
    }

    /// App termination must never honor a restart that was queued before Quit. Otherwise
    /// the old server can finish stopping, a new one can launch, and the app can exit while
    /// leaving that fresh process behind despite an explicit stop-on-quit policy.
    func stopForTermination(completion: ((Bool) -> Void)? = nil) {
        pendingRestart = nil
        stop(completion: completion)
    }

    /// Poll until the TERM'd attached-server pids are gone; SIGKILL once after 30 s of
    /// grace. If any remain after 35 s, report failure and restore `.ready` so the user can
    /// retry rather than pretending the server stopped or silently violating a quit policy.
    private func finishAttachedStopWhenExited(pids: [pid_t], waited: Double, escalated: Bool) {
        let alive = pids.filter { kill($0, 0) == 0 }
        if alive.isEmpty { completeStop(); return }
        if waited >= 35 {
            failAttachedStop()
            return
        }
        var escalated = escalated
        if waited >= 30, !escalated {
            for pid in alive { kill(pid, SIGKILL) }
            escalated = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.finishAttachedStopWhenExited(pids: pids, waited: waited + 0.1, escalated: escalated)
        }
    }

    private func completeStop() {
        ownedStopWatchdog?.cancel(); ownedStopWatchdog = nil
        activeServerGeneration = nil
        activeConfig = nil
        expectingExit = false
        // A startup-timeout teardown settles as the failure that caused it; a normal stop
        // settles idle.
        let stopError = pendingStopError
        pendingStopError = nil
        state = stopError.map { .error($0) } ?? .idle
        let completions = pendingStopCompletions
        pendingStopCompletions.removeAll()
        for completion in completions { completion(true) }
        if let relaunch = pendingRestart { pendingRestart = nil; relaunch() }
    }

    private func startOwnedStopWatchdog() {
        ownedStopWatchdog?.cancel()
        let delay = ownedStopWatchdogDelay
        ownedStopWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.failOwnedStop()
        }
    }

    private func failOwnedStop() {
        guard state == .stopping, expectingExit else { return }
        ownedStopWatchdog = nil
        if !runner.isRunning {
            completeStop()
            return
        }
        // A failed server that even SIGKILL didn't settle must not expose Retry, whose
        // start() would race the live process for the port and the GPU working set. Keep
        // the teardown pending, kill again, and re-arm the watchdog; a late exit still
        // settles the failure through handleExit.
        if pendingStopError != nil {
            recentLog.append("Failed ds4-server still running; retrying teardown")
            startOwnedStopWatchdog()
            runner.terminate(graceSeconds: 30)
            let completions = pendingStopCompletions
            pendingStopCompletions.removeAll()
            for completion in completions { completion(false) }
            return
        }
        pendingRestart = nil
        recentLog.append("Owned ds4-server exit was not confirmed after SIGTERM/SIGKILL; stop failed")
        state = .ready
        startHealthPolling()
        let completions = pendingStopCompletions
        pendingStopCompletions.removeAll()
        for completion in completions { completion(false) }
        // Keep `expectingExit` set: if Foundation delivers a late exit notification, it is
        // still the requested stop and should settle the supervisor in `.idle`, not `.error`.
    }

    private func verifyAttachedServerAbsent(onPort port: Int) {
        Task { [weak self] in
            let maxAttempts = 3
            for attempt in 1...maxAttempts {
                guard let self, self.state == .stopping, self.expectingExit else { return }
                let response = await self.serverProbe(port)
                guard self.state == .stopping, self.expectingExit else { return }
                if response == nil {
                    self.completeStop()
                    return
                }
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            guard let self, self.state == .stopping, self.expectingExit else { return }
            self.failAttachedStop()
        }
    }

    private func failAttachedStop() {
        expectingExit = false
        serverAttached = true
        pendingRestart = nil
        recentLog.append("ds4-server did not exit after SIGTERM/SIGKILL; stop failed")
        state = .ready
        startHealthPolling()
        let completions = pendingStopCompletions
        pendingStopCompletions.removeAll()
        for completion in completions { completion(false) }
    }

    /// Apply changed settings to a running server: stop it, then relaunch with the
    /// supplied parameters once it has fully exited (so the port is free). When the
    /// running server was owned by us, `stop()` drains asynchronously and the relaunch
    /// is deferred to `handleExit`; an attached orphan's stop completes when its pids
    /// have actually exited (polled), with the relaunch deferred likewise.
    /// No-op unless a server is running.
    @discardableResult
    func restart(
        selection: QuantSelection,
        ctx: Int,
        host: String,
        port: Int,
        power: Int?,
        sessions: Int = 1,
        kvDiskDir: URL? = nil,
        overrideWiredLimitGate: Bool = false
    ) -> RestartResult {
        guard state == .ready || state == .starting else {
            emitBadState("restart")
            return .ignored
        }
        if let reason = launchBoundsError(variant: selection.variant, ctx: ctx, sessions: sessions) {
            recentLog.append("ignored 'restart': \(reason)")
            return .rejected(.blocked(reason: reason))
        }
        // Gate BEFORE stopping: a refused restart keeps the healthy running server instead
        // of tearing it down into an error state.
        let feasibility = wiredLimitGate(selection, ctx, sessions)
        switch feasibility {
        case let .blocked(reason):
            recentLog.append("ignored 'restart': \(reason)")
            return .rejected(feasibility)
        case .wiredLimitTooLow where !overrideWiredLimitGate:
            recentLog.append("ignored 'restart': Metal wired limit below the new config's working set")
            return .rejected(feasibility)
        case .standard, .wiredLimitTooLow:
            break
        }
        let relaunch: () -> Void = { [weak self] in
            guard let self else { return }
            self.start(
                selection: selection, ctx: ctx, host: host, port: port, power: power,
                sessions: sessions, kvDiskDir: kvDiskDir, overrideWiredLimitGate: overrideWiredLimitGate)
        }
        stop()
        switch state {
        case .idle:
            relaunch()  // stopped synchronously (the runner exited inline)
        case .stopping:
            pendingRestart = relaunch  // deferred until stop drains (handleExit, or the attached-pid poll)
        default:
            pendingRestart = nil
            return .ignored
        }
        return .accepted
    }

    /// On launch, if a ds4-server is already serving on `port` (orphaned from a prior
    /// session, model still loaded), attach to it as `.ready` instead of spawning a
    /// new one — avoids a port conflict and a second multi-hundred-GB load.
    func resumeRunningServerIfAny(port: Int) {
        guard state == .idle else { return }
        adoptHealthyServerIfPresent(port: port)
    }

    /// Attach to a ds4-server already answering on `port` (default: the configured port) as
    /// `.ready`. Runs at launch and after an unexpected exit (the typical cause is a bind
    /// conflict with a healthy server we don't own). Applies only while idle/errored, so a
    /// slow probe can never clobber a newer start/stop.
    private func adoptHealthyServerIfPresent(port: Int? = nil) {
        let port = port ?? self.port
        guard state == .idle || isErrorState else { return }
        Task { [weak self] in
            guard let probe = self?.serverProbe else { return }
            let data = await probe(port)
            await MainActor.run {
                guard let self, let data, self.state == .idle || self.isErrorState else { return }
                self.serverAttached = true
                self.port = port
                self.activeModel = loadedModelName(from: data) ?? "ds4-server"
                // Adopted server: take its real context window from /v1/models so the chat
                // meter reflects the running `--ctx`, not the start-time default.
                if let loaded = loadedContextLength(from: data) { self.ctx = loaded }
                self.state = .ready
                self.startHealthPolling()
            }
        }
    }

    /// PIDs of processes listening on `port` (via lsof). Used by the attached-server stop:
    /// we don't own the process object, so its exit is observed by polling, not callback.
    private nonisolated static func pidsListening(onPort port: Int) -> ListeningPIDResult {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        lsof.standardOutput = outputPipe
        lsof.standardError = errorPipe
        guard
            let captured = try? runAndCaptureOutput(
                lsof, standardOutput: outputPipe, standardError: errorPipe)
        else {
            return .failure
        }
        let output =
            String(data: captured.standardOutput, encoding: .utf8) ?? ""
        let error =
            String(data: captured.standardError, encoding: .utf8) ?? ""
        let lines = output.split(whereSeparator: { $0 == "\n" })
        if lsof.terminationStatus != 0 {
            return error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .failure
        }
        guard !lines.isEmpty else { return .none }
        let pids = lines.compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard pids.count == lines.count else { return .failure }
        return .found(pids)
    }

    // MARK: - Download
    private let downloadRunner: ProcessRunner
    /// Bumped on every download()/retry. Stale stderr/exit callbacks from a superseded
    /// (e.g. terminated-on-retry) process carry an old generation and are ignored, so a
    /// SIGTERM'd process's exit-15 can't clobber the fresh download's state.
    private var downloadGeneration = 0
    /// The native HF download in flight (nil when idle); cancelled by cancelDownload()/retry.
    private var downloadTask: Task<Void, Never>?
    private var drainingShardTask: Task<Void, Never>?
    @Published private(set) var drainingShardGeneration: Int?
    /// The selection whose download is in flight; cancel uses it to clean every transport part.
    private var activeDownloadSelection: QuantSelection?
    /// True when a single-part quant's final already existed when download() started — a
    /// pre-existing artifact (typically a marker-less final being re-verified). Cancel must
    /// preserve it; only a final this session's own fetch renamed into place is cancel's to
    /// delete.
    private var preexistingFinalOnDownloadStart = false

    /// Runs a (minutes-long, synchronous) digest pass on the global executor. `nonisolated
    /// async` inherits the download Task's cancellation — unlike `Task.detached`, which would
    /// keep hashing after Cancel — and `GGUFJoiner` checks cancellation between blocks.
    /// The `.verified` marker is deliberately NOT published here: publication happens in
    /// `completeDownload`, on the MainActor behind its generation check, so a stale (cancelled
    /// or retried) task can never certify bytes a newer download owns.
    private nonisolated static func verifyArtifact(
        _ url: URL, expectedBytes: Int64, expectedSHA256: String?
    ) async throws {
        try Task.checkCancellation()
        try GGUFJoiner.verify(url: url, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256)
    }

    /// Removes a part that failed size/digest verification, plus any downloader sidecars and
    /// its verification marker, so a retry fetches it again rather than re-verifying the same
    /// bad file — and a stale marker can never certify the refetched bytes.
    private nonisolated static func discardCorruptPart(_ filename: String, baseDir: URL) {
        for suffix in ["", ".part", ".part.dl", ".verified"] {
            try? FileManager.default.removeItem(at: baseDir.appendingPathComponent(filename + suffix))
        }
    }

    func download(selection: QuantSelection, highPerformance: Bool = false) {
        guard state == .idle || isErrorState else { emitBadState("download"); return }
        if let e = validateDs4Dir() { state = .error(e); return }
        let q = selection.quant
        let parts = q.downloadParts
        let baseDir = ggufBaseDir()
        let expectedBytes = Int64(q.ggufBytes)
        let finalName = q.ggufFilename
        let firstPending = parts.first { part in
            !FileManager.default.fileExists(atPath: baseDir.appendingPathComponent(part.filename).path)
        }
        download = DownloadProgress(
            pct: 0, file: firstPending?.filename ?? finalName, receivedBytes: 0,
            totalBytes: q.downloadBytes)
        state = .downloading
        // Resuming the paused selection: the pause record (and its snapshot) is obsolete.
        if pausedDownloadSelection == selection { clearPausedDownload() }
        lastDownloadSample = nil
        activeDownloadSelection = selection
        preexistingFinalOnDownloadStart =
            q.assemblyFormat == .singleFile
            && FileManager.default.fileExists(atPath: baseDir.appendingPathComponent(finalName).path)
        downloadGeneration += 1
        let gen = downloadGeneration
        let token = resolveHFToken(
            env: ProcessInfo.processInfo.environment,
            cacheFile: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/token"))
        downloadProcessLive = true
        let fetch = fetchFile
        let prefix = fetchPrefix
        downloadTask?.cancel()
        let draining = drainingShardTask
        downloadTask = Task { [weak self] in
            // A cancelled assembler must finish its durable checkpoint before another
            // attempt touches the same paths. The process lock also excludes other apps.
            if let draining { await draining.value }
            do {
                try Task.checkCancellation()
                let finalURL = baseDir.appendingPathComponent(finalName)
                let owner = self
                if q.assemblyFormat == .ggufShards {
                    try await GGUFShardDownload.run(
                        quant: q, directory: baseDir, token: token,
                        highPerformance: highPerformance, fetchFile: fetch, fetchPrefix: prefix
                    ) { phase, file, received in
                        Self.onMain {
                            owner?.updateDownloadProgress(
                                gen: gen, file: file, received: received, total: q.downloadBytes, phase: phase)
                        }
                    }
                } else {
                    let part = parts[0]
                    let partial = resumableBytes(ggufDir: baseDir, filename: part.filename) > 0
                    if !FileManager.default.fileExists(atPath: finalURL.path) || partial {
                        try await fetch(q.repo, q.downloadRevision, part.filename, baseDir, token, highPerformance) {
                            received, _ in
                            Self.onMain {
                                owner?.updateDownloadProgress(
                                    gen: gen, file: part.filename, received: received, total: q.downloadBytes)
                            }
                        }
                    }
                    self?.updateDownloadProgress(
                        gen: gen, file: finalName, received: q.downloadBytes, total: q.downloadBytes, phase: .verifying)
                    do {
                        try await Self.verifyArtifact(finalURL, expectedBytes: expectedBytes, expectedSHA256: q.sha256)
                    } catch let error as GGUFJoiner.Failure {
                        switch error {
                        case .wrongSize, .checksumMismatch:
                            Self.discardCorruptPart(finalName, baseDir: baseDir)
                        default: break
                        }
                        throw error
                    }
                }
                try Task.checkCancellation()
                Self.onMain { self?.completeDownload(gen: gen, quant: q) }
            } catch is CancellationError {
                // cancel/retry own the visible state; durable MXFP4 progress is retained.
            } catch {
                Self.onMain { self?.failDownload(gen: gen, error: error) }
            }
        }
    }

    /// Turn a downloader `onProgress(received, total)` tick into a published `DownloadProgress`:
    /// compute pct, and a transfer rate from the delta against the last sample (the rate logic moved
    /// here from the old on-disk poll). Generation-guarded so a superseded download's late callback
    /// can't clobber the current bar. `Date()` is fine in app code.
    private func updateDownloadProgress(
        gen: Int, file: String, received: Int64, total: Int64,
        phase: DownloadProgress.Phase = .downloading
    ) {
        guard downloadGeneration == gen, state == .downloading else { return }
        let now = Date()
        // Rate over a fixed ~0.5 s window: advance the anchor only when the window elapses, so the
        // reading is (bytes over the window) / (window). Sampling per-callback instead pins it to
        // progressStep / main-actor-batch-gap and under-reports ~8x at high throughput.
        if phase != download?.phase { lastDownloadSample = nil }
        var rate = phase == .downloading ? download?.rate : nil
        if let anchor = lastDownloadSample {
            let dt = now.timeIntervalSince(anchor.time)
            if dt >= 0.5 {
                if received > anchor.bytes { rate = formatRate(Double(received - anchor.bytes) / dt) }
                lastDownloadSample = (received, now)
            }
        } else {
            lastDownloadSample = (received, now)
        }
        let pct = total > 0 ? min(100, Double(received) / Double(total) * 100) : 0
        download = DownloadProgress(
            pct: pct, file: file, receivedBytes: received, totalBytes: total > 0 ? total : nil,
            rate: phase == .downloading ? rate : nil, phase: phase)
    }

    private func completeDownload(gen: Int, quant: Quant) {
        let filename = quant.ggufFilename
        guard downloadGeneration == gen else { return }
        // Publish the durable verification marker HERE — on the MainActor, behind the
        // generation check — never from the background verify/join path: a stale task must not
        // certify bytes a newer download owns. A failed write (disk full, permissions) fails
        // the download rather than completing with an artifact `isDownloaded` can never accept.
        do {
            try Data((quant.sha256 ?? "").utf8).write(
                to: ggufBaseDir().appendingPathComponent(filename + ".verified"), options: .atomic)
        } catch {
            failDownload(gen: gen, error: error)
            return
        }
        endDownloadActivity()
        download = DownloadProgress(pct: 100, file: filename, receivedBytes: 0, totalBytes: nil)
        state = .idle
    }

    private func failDownload(gen: Int, error: Error) {
        guard downloadGeneration == gen else { return }
        endDownloadActivity()
        let detail: String
        switch error {
        case HFDownloader.Failure.http(let code): detail = "HTTP \(code)"
        case HFDownloader.Failure.incompleteAfterRetries: detail = "download interrupted (retries exhausted)"
        case let GGUFJoiner.Failure.missingPart(name): detail = "missing part \(name)"
        case let GGUFJoiner.Failure.wrongSize(name, _, _): detail = "unexpected size for \(name)"
        case let GGUFJoiner.Failure.checksumMismatch(name): detail = "checksum mismatch for \(name)"
        case let GGUFJoiner.Failure.notEnoughDiskSpace(requiredBytes):
            detail = "not enough disk space (needs ~\(requiredBytes / 1_073_741_824) GiB free)"
        default: detail = (error as NSError).localizedDescription
        }
        state = .error(.downloadFailed(detail: detail))
    }

    private func endDownloadActivity() {
        downloadTask = nil
        downloadProcessLive = false
        activeDownloadSelection = nil
        preexistingFinalOnDownloadStart = false
    }

    /// Register cleanup independently of the download, which may have already finished.
    @discardableResult
    func trackShardDrain(_ task: Task<Void, Never>, generation gen: Int) -> Task<Void, Never> {
        drainingShardTask = task
        drainingShardGeneration = gen
        return Task { [weak self] in
            await task.value
            guard let self, self.drainingShardGeneration == gen else { return }
            self.drainingShardTask = nil
            self.drainingShardGeneration = nil
        }
    }

    /// Cancel whatever download is in flight and start a fresh one — the user's escape hatch from a
    /// stuck/stalled or errored progress bar. The native downloader cancels through the cancelled
    /// task; `download` re-resumes from the on-disk bitmap.
    func retryDownload(selection: QuantSelection, highPerformance: Bool = false) {
        if activeDownloadSelection?.quant.assemblyFormat == .ggufShards, let task = downloadTask {
            trackShardDrain(task, generation: downloadGeneration)
        }
        downloadTask?.cancel()
        downloadTask = nil
        lastDownloadSample = nil
        download = nil
        state = .idle
        download(selection: selection, highPerformance: highPerformance)
    }

    /// The selection whose download was paused this session (nil when none), with the last
    /// progress snapshot for the Resume affordance. Pause is session-scoped: quitting keeps
    /// the partials and the next launch's auto-resume picks them up as usual.
    @Published private(set) var pausedDownloadSelection: QuantSelection?
    @Published private(set) var pausedDownloadSnapshot: DownloadProgress?
    /// `preexistingFinalOnDownloadStart` captured at pause, so a later discard of the paused
    /// download preserves a pre-existing artifact exactly like an in-flight Cancel would.
    private var pausedPreexistingFinal = false

    /// The paused progress snapshot when this exact selection is the paused one — drives
    /// the model row's Resume button and its "paused at N%" caption.
    func pausedDownloadInfo(for selection: QuantSelection) -> DownloadProgress? {
        guard state == .idle, pausedDownloadSelection == selection else { return nil }
        return pausedDownloadSnapshot
    }

    /// Pause the in-flight download: cancel its tasks but KEEP every durable partial (the
    /// `.part` + its bitmap sidecar, or shard assembly checkpoints), record the paused
    /// selection, and return to idle. Resume is a plain `download(selection:)` again — the
    /// downloader re-reads the bitmap and refetches only the chunks it lacks.
    func pauseDownload() {
        guard state == .downloading else { return }
        if activeDownloadSelection?.quant.assemblyFormat == .ggufShards, let task = downloadTask {
            trackShardDrain(task, generation: downloadGeneration)
        }
        pausedDownloadSelection = activeDownloadSelection
        pausedDownloadSnapshot = download
        pausedPreexistingFinal = preexistingFinalOnDownloadStart
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        // Deliberately NOT deleting partials — that is Cancel's job. Pause keeps them so
        // Resume continues from the on-disk bitmap instead of restarting from zero.
        downloadProcessLive = false
        activeDownloadSelection = nil
        preexistingFinalOnDownloadStart = false
        lastDownloadSample = nil
        download = nil
        state = .idle
    }

    /// Discard a paused download's partials and forget the pause. Same artifact policy as
    /// an in-flight Cancel: single-file transports (and a final this session renamed into
    /// place) die; verified shard checkpoints stay reclaimable via Settings cleanup.
    func discardPausedDownload() {
        guard state == .idle, let selection = pausedDownloadSelection else { return }
        discardTransportArtifacts(selection: selection, preexistingFinal: pausedPreexistingFinal)
        clearPausedDownload()
    }

    private func clearPausedDownload() {
        pausedDownloadSelection = nil
        pausedDownloadSnapshot = nil
        pausedPreexistingFinal = false
    }

    /// Delete a download's transport partials (`.part` + `.part.dl` sidecar) and, for a
    /// single-part quant whose final this session's own fetch renamed into place, that
    /// final and its marker. `preexistingFinal` protects an artifact that predates the
    /// download attempt (a marker-less final being re-verified). Shared by in-flight
    /// Cancel and discarding a paused download; shard-format selections keep their
    /// durable checkpoints (a verified prefix / `.assembling` state) for Resume.
    private func discardTransportArtifacts(selection: QuantSelection, preexistingFinal: Bool) {
        guard selection.quant.assemblyFormat == .singleFile else { return }
        let base = ggufBaseDir()
        let parts = selection.quant.downloadParts
        for part in parts {
            // ORDER MATTERS: the transport `.part` must be unlinked BEFORE the final. The
            // removals are not atomic as a group, and HFDownloader's rename runs on a
            // concurrent thread — a rename landing between the two removals would unlink
            // the source only after it had already become the final, leaving an unverified
            // single-part gguf on disk (the exact leak cancel exists to prevent). With
            // `.part` gone first, any rename either preceded it (the final removal below
            // catches the result) or fails with ENOENT.
            try? FileManager.default.removeItem(at: base.appendingPathComponent(part.filename + ".part"))
            try? FileManager.default.removeItem(at: base.appendingPathComponent(part.filename + ".part.dl"))
            // A single-part quant's transport name IS its final gguf name. Remove that
            // final ONLY when this session's own fetch renamed it into place:
            // preexisting artifacts must survive so a later re-verify can run. A preserved
            // final carries no `.verified` marker, so it never counts as downloaded, and
            // the marker dies with a removed final (an orphan marker must never certify a
            // later refetch of the same path).
            if parts.count == 1, !preexistingFinal {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(part.filename))
                try? FileManager.default.removeItem(
                    at: base.appendingPathComponent(part.filename + ".verified"))
            }
        }
    }

    /// Cancel an in-progress download and return to idle without restarting. Bumping the generation
    /// makes the cancelled task's completion callback stale, so it can't flip state to error.
    func cancelDownload() {
        guard state == .downloading else { return }
        if activeDownloadSelection?.quant.assemblyFormat == .ggufShards, let task = downloadTask {
            trackShardDrain(task, generation: downloadGeneration)
        }
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        // Cancel discards the partial (a deliberate stop, not a pause): remove every sparse
        // `.part` AND its `.part.dl` bitmap sidecar so the next launch's resume check doesn't
        // pick it back up. Quitting mid-download keeps them, so a relaunch resumes from the
        // bitmap. A verified 480 GiB prefix already renamed to `.assembling` is kept.
        if let selection = activeDownloadSelection {
            discardTransportArtifacts(selection: selection, preexistingFinal: preexistingFinalOnDownloadStart)
        } else if let f = download?.file {
            let base = ggufBaseDir()
            try? FileManager.default.removeItem(at: base.appendingPathComponent(f + ".part"))
            try? FileManager.default.removeItem(at: base.appendingPathComponent(f + ".part.dl"))
        }
        downloadProcessLive = false
        activeDownloadSelection = nil
        preexistingFinalOnDownloadStart = false
        lastDownloadSample = nil
        download = nil
        clearPausedDownload()
        state = .idle
    }

    /// If a partial download was left by a prior session (the app quit mid-download) and we're idle,
    /// resume it without re-prompting. The native parallel downloader continues from the on-disk
    /// `.part.dl` bitmap (or, for a legacy contiguous `.part`/hf `.incomplete`, from its byte count),
    /// so this is just a normal `download()`. `highPerformance` (the persisted setting) is threaded
    /// through so the resumed download uses the user's chosen worker count.
    func resumeInFlightDownloadIfAny(selection: QuantSelection, highPerformance: Bool = false) {
        guard state == .idle else { return }
        let base = ggufBaseDir()
        let q = selection.quant
        let final = base.appendingPathComponent(q.ggufFilename)
        // Fully downloaded AND verified → nothing to resume.
        if isDownloaded(selection) { return }
        // A final without its verification marker (the app quit mid-digest, or a pre-marker
        // release) is byte-complete on disk: resume re-runs verification without refetching —
        // download() skips the fetch when the final exists with no resumable partial.
        if FileManager.default.fileExists(atPath: final.path) {
            download(selection: selection, highPerformance: highPerformance)
            return
        }
        guard hasPartialDownload(ggufDir: base, quant: q) else { return }
        download(selection: selection, highPerformance: highPerformance)
    }

    /// True when the selected variant's gguf exists on disk AND carries the durable marker a
    /// successful verification writes. A renamed-but-unverified final (the app quit mid-hash)
    /// is deliberately NOT downloaded: the model row offers Download — which re-verifies in
    /// place without refetching — rather than Start. The active downloads dir is checked
    /// first, then the legacy location, so models downloaded before a folder switch keep
    /// reading as installed.
    func isDownloaded(_ selection: QuantSelection) -> Bool {
        for dir in ggufSearchDirs() where isVerifiedDownload(selection, in: dir) { return true }
        return false
    }
    private func isVerifiedDownload(_ selection: QuantSelection, in dir: URL) -> Bool {
        let gguf = dir.appendingPathComponent(selection.quant.ggufFilename)
        let marker = URL(fileURLWithPath: gguf.path + ".verified")
        guard FileManager.default.fileExists(atPath: gguf.path),
            FileManager.default.fileExists(atPath: marker.path)
        else { return false }
        guard let sha = selection.quant.sha256 else { return true }
        return fileSize(gguf) == Int64(selection.quant.ggufBytes)
            && (try? String(contentsOf: marker, encoding: .utf8)) == sha
    }
    /// True when the active downloads dir holds recoverable state for this selection — a
    /// paused download's partial, artifacts a prior session stranded, or a marker-less
    /// final awaiting (re)verification — so the model row offers Resume over Download.
    func hasPartialDownloadForSelection(_ selection: QuantSelection) -> Bool {
        let base = ggufBaseDir()
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(selection.quant.ggufFilename).path)
            || hasPartialDownload(ggufDir: base, quant: selection.quant)
    }

    // MARK: - Flash quant store (Settings: download markers + cleanup)
    func isFlashQuantDownloaded(_ q: FlashQuant) -> Bool {
        isDownloaded(.flash(q))
    }
    /// V4.1 Flash quant store (Settings: download markers + cleanup).
    func isFlash41QuantDownloaded(_ q: Flash41Quant) -> Bool {
        isDownloaded(.flash41(q))
    }
    /// On-disk removable artifact files for a Flash quant across every downloads dir: the
    /// final GGUF when present, otherwise the sparse `.part` + `.part.dl` bitmap sidecar a
    /// failed download or an app quit mid-download stranded on disk — plus an unverified
    /// final (renamed but never digest-checked). Drives the Settings cleanup counts, which
    /// must cover partial artifacts, not just completed finals.
    func flashArtifactURLs(_ q: FlashQuant) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for base in ggufSearchDirs() {
            let final = base.appendingPathComponent(q.quant.ggufFilename)
            if fm.fileExists(atPath: final.path) { urls.append(final) }
            urls += [".part", ".part.dl"].map { base.appendingPathComponent(q.quant.ggufFilename + $0) }
                .filter { fm.fileExists(atPath: $0.path) }
        }
        return urls
    }
    /// Bytes reclaimed by deleting a Flash quant's artifacts: the final GGUF's exact on-disk
    /// size when downloaded; otherwise the durable partial bytes — the bitmap-accurate count,
    /// since the sparse `.part`'s apparent size is meaningless — summed across every
    /// downloads dir (a custom folder may coexist with legacy-location partials).
    func flashArtifactBytes(_ q: FlashQuant) -> Int64 {
        if isFlashQuantDownloaded(q) { return Int64(q.quant.ggufBytes) }
        return ggufSearchDirs().reduce(Int64(0)) { $0 + downloadedBytes(ggufDir: $1, quant: q.quant) }
    }
    /// True when a Flash quant has stranded downloader artifacts but no final GGUF — the
    /// failed-download / quit-mid-download case that must still enable cleanup.
    func hasFlashPartialDownload(_ q: FlashQuant) -> Bool {
        !isFlashQuantDownloaded(q)
            && ggufSearchDirs().contains { hasPartialDownload(ggufDir: $0, quant: q.quant) }
    }
    /// V4.1 twin of `flashArtifactURLs`: the final GGUF when downloaded, otherwise every
    /// transport part (with partials/sidecars), any unverified final, and an interrupted
    /// join's `.assembling` file — across every downloads dir.
    func flash41ArtifactURLs(_ q: Flash41Quant) -> [URL] {
        let fm = FileManager.default
        let quant = q.quant
        var urls: [URL] = []
        for base in ggufSearchDirs() {
            var names = [
                quant.ggufFilename, quant.ggufFilename + ".verified",
                quant.ggufFilename + ".assembling", quant.ggufFilename + ".assembling.json",
                quant.ggufFilename + ".assembling.json.tmp",
            ]
            for part in quant.downloadParts {
                names += [part.filename, part.filename + ".part", part.filename + ".part.dl"]
            }
            urls += Set(names).sorted().map { base.appendingPathComponent($0) }
        }
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }
    /// V4.1 twin of `flashArtifactBytes`: the final's exact on-disk size when verified;
    /// otherwise the durable downloaded bytes (final wins, then per-part progress).
    func flash41ArtifactBytes(_ q: Flash41Quant) -> Int64 {
        flash41ArtifactURLs(q).reduce(0) { $0 + GGUFShardDownload.allocatedBytes($1) }
    }
    /// V4.1 twin of `hasFlashPartialDownload`.
    func hasFlash41PartialDownload(_ q: Flash41Quant) -> Bool {
        guard !isFlash41QuantDownloaded(q) else { return false }
        // A marker-less final (an unverified download or join) is itself a cleanup candidate:
        // for multi-part quants the parts were consumed by the join, so the transport checks
        // below see nothing even though the final occupies its full size on disk.
        for base in ggufSearchDirs() {
            let final = base.appendingPathComponent(q.quant.ggufFilename)
            if FileManager.default.fileExists(atPath: final.path) { return true }
            if hasPartialDownload(ggufDir: base, quant: q.quant) { return true }
        }
        return false
    }
    /// Delete on-disk Flash quant ggufs other than `keep`. V4 Pro is untouched by construction
    /// (the loop only iterates `FlashQuant`). Gate the call site to idle/error so a loaded or
    /// downloading model is never removed. Returns the removed filenames.
    @discardableResult
    func cleanupUnusedFlashQuants(keep: FlashQuant) -> [String] {
        var removed: [String] = []
        for q in FlashQuant.allCases where q != keep {
            removed += removeQuantFiles(q.quant)
        }
        if !removed.isEmpty { ggufStoreVersion += 1 }
        return removed
    }
    /// Delete on-disk V4.1 Flash quants other than `keep` (final, joined, part, and sidecar
    /// files alike). Same idle/error gating as the 0731 cleanup.
    @discardableResult
    func cleanupUnusedFlash41Quants(keep: Flash41Quant) -> [String] {
        guard canRemoveLegacyFlash41Storage else { return [] }
        var removed: [String] = []
        for q in Flash41Quant.allCases where q != keep {
            removed += removeQuantFiles(q.quant)
        }
        if !removed.isEmpty { ggufStoreVersion += 1 }
        return removed
    }
    /// Delete EVERY on-disk Flash quant gguf — including the selected one — plus their
    /// transport parts and sidecar files. V4 Pro is untouched by construction (the loop only
    /// iterates `FlashQuant`). Same idle/error gating as the sibling cleanups (enforced at the
    /// call site). This is the escape hatch after switching to V4.1. Returns removed filenames.
    @discardableResult
    func cleanupAllFlashQuants() -> [String] {
        var removed: [String] = []
        for q in FlashQuant.allCases {
            removed += removeQuantFiles(q.quant)
        }
        if !removed.isEmpty { ggufStoreVersion += 1 }
        return removed
    }

    /// Remove every on-disk artifact of a quant: the final GGUF (single file or joined),
    /// all transport parts and their downloader sidecars, and any interrupted-join file —
    /// from every downloads dir (active + legacy) so a folder switch never strands
    /// hundreds of GB outside the app's reach.
    private func removeQuantFiles(_ quant: Quant) -> [String] {
        var removedAll: [String] = []
        for base in ggufSearchDirs() {
            removedAll += removeQuantFiles(quant, in: base)
        }
        return removedAll
    }
    private func removeQuantFiles(_ quant: Quant, in base: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let assemblyLock: GGUFShardAssembler.AssemblyLock?
        do {
            assemblyLock =
                quant.assemblyFormat == .ggufShards
                ? try GGUFShardAssembler.acquireLock(target: base.appendingPathComponent(quant.ggufFilename)) : nil
        } catch {
            state = .error(.badState(message: error.localizedDescription))
            return []
        }
        defer { assemblyLock?.release() }
        var names = [quant.ggufFilename, quant.ggufFilename + ".verified"]
        for part in quant.downloadParts {
            names += [
                part.filename, part.filename + ".verified",
                part.filename + ".part", part.filename + ".part.dl",
            ]
        }
        names += [".assembling", ".assembling.json", ".assembling.json.tmp"].map {
            quant.ggufFilename + $0
        }
        var removed: [String] = []
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            let url = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else {
                        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
                    }
                    try FileManager.default.removeItem(at: url)
                    removed.append(name)
                } catch {
                    state = .error(.badState(message: "Could not remove \(name): \(error.localizedDescription)"))
                }
            }
        }
        return removed
    }

    // MARK: - V4.1 1017 migration
    var canRemoveLegacyFlash41Storage: Bool {
        (state == .idle || isErrorState) && !runner.isRunning && !serverAttached
            && !downloadProcessLive && drainingShardGeneration == nil
    }

    func legacyFlash41StorageURLs() -> [URL] {
        let cache = cacheBaseDir()
        var urls: Set<URL> = []
        // Both the active and any legacy downloads dir can hold old-recipe artifacts; the
        // cache candidates dedupe through the Set.
        for dir in ggufSearchDirs() {
            urls.formUnion(Flash41LegacyStorage.candidates(ggufDirectory: dir, cacheDirectory: cache))
        }
        return urls.sorted { $0.path < $1.path }
    }

    func legacyFlash41StorageBytes() -> Int64 {
        Flash41LegacyStorage.totalBytes(for: legacyFlash41StorageURLs())
    }

    func removeLegacyFlash41Storage(confirmedURLs: [URL]) throws {
        guard canRemoveLegacyFlash41Storage else {
            throw NSError(
                domain: "DS4Control", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Stop the server and wait for downloads to finish before deleting old data."
                ])
        }
        defer { ggufStoreVersion += 1 }
        try Flash41LegacyStorage.remove(
            candidates: confirmedURLs, ggufDirectories: ggufSearchDirs(), cacheDirectory: cacheBaseDir())
    }

    // MARK: - Legacy preview storage
    /// Preview GGUFs, their native-downloader sidecars, leftover hf `*.incomplete`
    /// partials, and the shared cache directory used before caches became
    /// release-specific. Nothing in the app references these. Scans every downloads
    /// dir so preview files left in a pre-customization location stay reclaimable.
    func legacyStorageURLs() -> [URL] {
        var urls: [URL] = []
        for base in ggufSearchDirs() {
            urls += Quant.legacyPreviewFilenames.flatMap { name in
                [name, name + ".part", name + ".part.dl"]
                    .map { base.appendingPathComponent($0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            }
            let incompleteDir = base.appendingPathComponent(".cache/huggingface/download")
            if let items = try? FileManager.default.contentsOfDirectory(
                at: incompleteDir, includingPropertiesForKeys: nil)
            {
                urls.append(
                    contentsOf: items.filter { item in
                        item.pathExtension == "incomplete"
                            && Quant.legacyPreviewFilenames.contains { name in
                                item.lastPathComponent.hasPrefix(name + ".")
                            }
                    })
            }
        }
        let sharedCache = cacheBaseDir().appendingPathComponent("kv", isDirectory: true)
        if FileManager.default.fileExists(atPath: sharedCache.path) { urls.append(sharedCache) }
        return urls
    }
    /// Total recursive size of orphaned files/directories, for the migration banner.
    func legacyStorageBytes() -> Int64 {
        legacyStorageURLs().reduce(0) { $0 + recursiveFileSize($1) }
    }
    /// Delete orphaned preview storage. Gate the call site to idle/error, exactly like
    /// cleanupUnusedFlashQuants. Returns only items actually removed.
    @discardableResult
    func removeLegacyStorage() -> [String] {
        var removed: [String] = []
        for url in legacyStorageURLs() {
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(url.lastPathComponent)
            } catch {}
        }
        if !removed.isEmpty { ggufStoreVersion += 1 }
        return removed
    }

    private func recursiveFileSize(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return fileSize(url) }
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Health
    private func startHealthPolling() {
        pollHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollHealth() }
        }
    }
    private var healthFailures = 0
    private func pollHealth() {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        let start = Date()
        URLSession.shared.dataTask(with: url) { [weak self] _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            Task { @MainActor in
                // The `.ready` guard is load-bearing: it makes a stale in-flight health callback a no-op after stop(). Do not remove.
                guard let self, self.state == .ready else { return }
                self.health = HealthStatus(ok: ok, latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                self.healthFailures = ok ? 0 : self.healthFailures + 1
                if self.healthFailures >= 3 && self.runner.isRunning { self.fail(.unhealthy) }
            }
        }.resume()
    }

    // MARK: - helpers
    /// Run `body` on the MainActor. Process callbacks (RealProcessRunner) arrive on a
    /// background queue → hop via Task; synchronous callers already on the main thread
    /// (e.g. the test FakeRunner) run immediately so state transitions are observable
    /// in the same turn.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }
    private var isErrorState: Bool { if case .error = state { return true }; return false }
    /// The single runtime error transition (health failure). A live owned server is first
    /// stopped; `completeStop` clears its config and publishes the failure only after exit.
    /// Exposed to tests so the lifecycle contract can be pinned, like `memoryArgs`.
    func fail(_ e: ServerError) {
        healthTimer?.invalidate(); healthTimer = nil; startupTimer?.invalidate(); startupTimer = nil
        if runner.isRunning, state == .ready || state == .starting {
            pendingStopError = e
            stop()
            return
        }
        // The config describes a live server, and `.error` has none: clear before publishing
        // so Settings' dirty check never reads a stale launch.
        activeConfig = nil
        state = .error(e)
    }
    private func emitBadState(_ cmd: String) { recentLog.append("ignored '\(cmd)' in state \(state)") }
}

/// Parse the loaded model's display name from a `/v1/models` response body.
/// ds4 sets each entry's `name` to the actually-loaded model, so prefer it over `id`.
func loadedModelName(from data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let arr = obj["data"] as? [[String: Any]], let first = arr.first
    else { return nil }
    return (first["name"] as? String) ?? (first["id"] as? String)
}

/// The loaded server's context window from /v1/models, so a server we ADOPTED (attached to
/// rather than started) reports its real `--ctx` instead of `ctx`'s start-time default.
func loadedContextLength(from data: Data) -> Int? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let arr = obj["data"] as? [[String: Any]], let first = arr.first
    else { return nil }
    return (first["context_length"] as? Int)
        ?? ((first["top_provider"] as? [String: Any])?["context_length"] as? Int)
}
