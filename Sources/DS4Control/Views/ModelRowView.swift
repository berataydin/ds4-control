import SwiftUI

struct ModelRowView: View {
    @ObservedObject var supervisor: SupervisorService
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    let ramGiB: Double

    /// Every loadable model+quant for this machine's tier, smallest first. A stored
    /// selection from outside the tier (e.g. Pro persisted on a 512 GiB Mac now opened on
    /// a smaller one) stays listed so the dropdown never shows a blank choice; the
    /// feasibility note below explains why it won't start.
    private var options: [QuantSelection] {
        var available = QuantSelection.availableSelections(ramGiB: ramGiB)
        if !available.contains(app.quantSelection) { available.append(app.quantSelection) }
        return available
    }

    /// The dropdown writes back into the persisted variant/quant preferences, so
    /// `app.quantSelection` stays the single resolved truth everywhere else.
    private var selection: Binding<QuantSelection> {
        Binding(
            get: { app.quantSelection },
            set: { choice in
                app.selectedVariant = choice.variant
                switch choice {
                case .pro: break
                case .flash(let q): app.selectedFlashQuant = q
                case .flash41(let q): app.selectedFlash41Quant = q
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: selection) {
                ForEach(options) { option in
                    Text(menuLabel(option))
                        .tag(option)
                        .disabled(!optionFits(option))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // No model switch mid-download, and none while a server is loading or serving —
            // the popup has no Apply & Restart, so Stop comes first.
            .disabled(supervisor.state == .downloading || supervisor.state.isServerActive)
            .help("Stop the server to change the model.")

            let feas = feasibility(
                ramGiB: ramGiB, selection: app.quantSelection,
                ctx: app.effectiveCtx(ramGiB: ramGiB),
                wiredLimitMB: effectiveWiredLimitMB(ramGiB: ramGiB),
                sessions: app.concurrentSessions)
            actionButton(feas)
            if let paused = supervisor.pausedDownloadInfo(for: app.quantSelection) {
                pausedNote(paused)
            }
            feasibilityNote(feas)
        }
    }

    /// Dropdown row text: the friendly model label plus a downloaded marker, so the user
    /// can see at a glance which choice starts instantly and which downloads first.
    private func menuLabel(_ option: QuantSelection) -> String {
        option.pickerLabel + (supervisor.isDownloaded(option) ? "  ✓ Downloaded" : "")
    }

    /// Whether the option's default launch fits this machine. Non-fitting entries stay
    /// visible but dimmed (same policy the old Settings quant pickers had).
    private func optionFits(_ option: QuantSelection) -> Bool {
        switch option {
        case .pro: return ramGiB >= 512
        case .flash(let q): return flashQuantFits(q, ramGiB: ramGiB)
        case .flash41(let q):
            return flash41QuantFits(q, ramGiB: ramGiB, wiredLimitMB: effectiveWiredLimitMB(ramGiB: ramGiB))
        }
    }

    /// Caption shown while this selection's download is paused: how far it got, and what
    /// each button does with the partial.
    private func pausedNote(_ paused: DownloadProgress) -> some View {
        Text(
            "Paused at \(String(format: "%.0f%%", paused.pct)) — Resume continues from where "
                + "it left off; Cancel discards the partial download."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func actionButton(_ feas: Feasibility) -> some View {
        let downloaded = supervisor.isDownloaded(app.quantSelection)
        let blocked: Bool = {
            if case .blocked = feas { return true }
            return false
        }()
        // Working set over the effective wired limit: Start stays available only behind a
        // confirmed "Start anyway" (the popup note explains the fix).
        let wiredLow: Bool = {
            if case .wiredLimitTooLow = feas { return true }
            return false
        }()
        switch supervisor.state {
        case .ready, .starting:
            Button("Stop") { supervisor.stop() }.tint(.red).frame(maxWidth: .infinity)
        case .downloading:
            // Pause stops the fetch but keeps the durable partials (bitmap sidecar / shard
            // checkpoints), so Resume continues from where it stopped; Cancel discards them.
            HStack {
                Button("Pause") { supervisor.pauseDownload() }
                    .frame(maxWidth: .infinity).disabled(blocked)
                Button("Cancel", role: .destructive) { supervisor.cancelDownload() }
                    .frame(maxWidth: .infinity)
            }
        case .error:
            Button(downloaded ? (wiredLow ? "Start anyway…" : "Retry") : "Retry download") {
                if downloaded {
                    wiredLow ? confirmStartAnyway() : startServer(overrideWiredLimitGate: false)
                } else {
                    supervisor.retryDownload(
                        selection: app.quantSelection,
                        highPerformance: app.highPerformanceDownload)
                }
            }
            .tint(.orange).frame(maxWidth: .infinity).disabled(blocked)
        default:
            // A paused download (or a partial a prior session left) resumes from the on-disk
            // bitmap instead of restarting — the button says so.
            let paused = supervisor.pausedDownloadInfo(for: app.quantSelection)
            if !downloaded, paused != nil || supervisor.hasPartialDownloadForSelection(app.quantSelection) {
                HStack {
                    Button("Resume download") {
                        supervisor.download(
                            selection: app.quantSelection,
                            highPerformance: app.highPerformanceDownload)
                    }
                    .frame(maxWidth: .infinity).disabled(blocked)
                    if paused != nil {
                        Button("Cancel", role: .destructive) { supervisor.discardPausedDownload() }
                            .frame(maxWidth: .infinity)
                    }
                }
            } else if !downloaded {
                // The selected model is named in the dropdown right above — the button
                // stays a plain "Download".
                Button("Download") {
                    supervisor.download(
                        selection: app.quantSelection,
                        highPerformance: app.highPerformanceDownload)
                }
                .frame(maxWidth: .infinity).disabled(blocked)
            } else {
                Button(wiredLow ? "Start anyway…" : "Start") {
                    wiredLow ? confirmStartAnyway() : startServer(overrideWiredLimitGate: false)
                }
                .tint(wiredLow ? .orange : .accentColor)
                .frame(maxWidth: .infinity).disabled(blocked)
            }
        }
    }

    private func startServer(overrideWiredLimitGate: Bool) {
        let host = app.normalizeHostForLaunch()
        supervisor.start(
            selection: app.quantSelection,
            ctx: app.effectiveCtx(ramGiB: ramGiB),
            host: host, port: app.port, power: app.power,
            sessions: app.concurrentSessions,
            kvDiskDir: app.kvDiskCache ? supervisor.kvDiskCacheURL(for: app.quantSelection) : nil,
            overrideWiredLimitGate: overrideWiredLimitGate)
    }

    /// Real NSAlert (not SwiftUI .alert, which would collapse the .window MenuBarExtra) —
    /// same dance as PopupView's legacy-weights confirmation. Cancel stays the default so
    /// a stray Return doesn't launch a config that hangs the machine.
    private func confirmStartAnyway() {
        let alert = NSAlert()
        alert.messageText = "Start anyway?"
        alert.informativeText =
            "The Metal wired memory limit is below what this model needs, so macOS will page it "
            + "and the server will likely hang while memory pegs near 100%. "
            + "Raise the limit first (see \"Metal wired limit help…\" below) unless you know this works on your setup."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Start anyway")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""  // keep Cancel as the Return-key default
        alert.buttons[1].keyEquivalent = "\r"
        WindowChrome.windowOpened(title: "ds4-wired-limit-start-anyway")
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        WindowChrome.windowClosed()
        if response == .alertFirstButtonReturn { startServer(overrideWiredLimitGate: true) }
    }

    @ViewBuilder private func feasibilityNote(_ feas: Feasibility) -> some View {
        switch feas {
        case .standard: EmptyView()
        case let .wiredLimitTooLow(requiredMB, advisoryMB):
            // Re-read live (metrics tick), so raising the limit in Terminal clears this
            // within ~2 s — no app restart needed.
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Metal wired limit too low: this setup needs ~\(roundedUpGiB(fromMB: requiredMB)) GiB but the GPU can wire "
                        + "~\(effectiveWiredLimitMB(ramGiB: ramGiB) / 1024) GiB. Raise it in Terminal:"
                )
                Text("sudo sysctl iogpu.wired_limit_mb=\(advisoryMB)")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    WindowChrome.willOpenWindow()
                    openWindow(id: "wiredhelp")
                } label: {
                    Label("Metal wired limit help…", systemImage: "questionmark.circle")
                }
                .buttonStyle(.link).font(.caption2)
            }
            .font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .blocked(reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
