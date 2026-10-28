import XCTest

@testable import DS4Control

/// No-op runner for the server slot; records launch args for the start-path test.
private final class RecordingRunner: ProcessRunner {
    var isRunning = false
    private(set) var launchArgs: [String] = []
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStderrLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        launchArgs = args
    }
    func terminate(graceSeconds: Double) {}
}

private final class DestDirBox: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ u: URL) {
        lock.lock()
        defer { lock.unlock() }
        url = u
    }
    func get() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }
}

/// The Settings ▸ Downloads folder choice: validation of the stored path, download
/// targeting, installed-model detection (active dir first, then the legacy default
/// location), server start from either location, and cleanup across both.
@MainActor
final class DownloadsDirectoryTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("gguf"), withIntermediateDirectories: true)
        for f in ["ds4-server", "download_model.sh"] {
            let u = dir.appendingPathComponent(f)
            FileManager.default.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        }
        return dir
    }

    private func makeSparse(_ url: URL, bytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    /// A verified final for a nil-SHA quant (the 0731 Flash builds): final + marker, no
    /// size/digest check applies.
    private func plantVerified(_ quant: Quant, in dir: URL) throws {
        try makeSparse(dir.appendingPathComponent(quant.ggufFilename), bytes: 8)
        try Data("ok".utf8).write(to: dir.appendingPathComponent(quant.ggufFilename + ".verified"))
    }

    // MARK: - Preference validation

    func testConfiguredDownloadsDirValidation() throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let live = try makeDir()
        XCTAssertEqual(configuredDownloadsDir(defaults: defaults)?.path, nil)

        defaults.set(live.path, forKey: downloadsDirectoryDefaultsKey)
        XCTAssertEqual(configuredDownloadsDir(defaults: defaults)?.path, live.path)

        // A missing directory and a plain file are both unusable → nil (default location).
        defaults.set(live.appendingPathComponent("gone").path, forKey: downloadsDirectoryDefaultsKey)
        XCTAssertNil(configuredDownloadsDir(defaults: defaults))

        let file = live.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        defaults.set(file.path, forKey: downloadsDirectoryDefaultsKey)
        XCTAssertNil(configuredDownloadsDir(defaults: defaults))

        defaults.set("   ", forKey: downloadsDirectoryDefaultsKey)
        XCTAssertNil(configuredDownloadsDir(defaults: defaults))
    }

    func testAppStatePersistsDownloadsDirectory() throws {
        let name = "test.\(UUID().uuidString)"
        let a1 = AppState(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(a1.downloadsDirectoryPath, "")
        XCTAssertFalse(a1.downloadsDirectoryUnavailable)

        a1.downloadsDirectoryPath = "/nonexistent-volume/weights"
        let a2 = AppState(defaults: UserDefaults(suiteName: name)!)
        XCTAssertEqual(a2.downloadsDirectoryPath, "/nonexistent-volume/weights", "the raw choice persists")
        XCTAssertTrue(a2.downloadsDirectoryUnavailable, "a dead path flags as unavailable")
        XCTAssertNil(a2.configuredDownloadsDirectory, "a dead path does not become the download target")

        let live = try makeDir()
        a2.downloadsDirectoryPath = live.path
        XCTAssertFalse(a2.downloadsDirectoryUnavailable)
        XCTAssertEqual(a2.configuredDownloadsDirectory?.path, live.path)
    }

    // MARK: - Supervisor resolution

    /// Downloads target the configured folder, not the injected (legacy) base.
    func testDownloadTargetsPreferredDir() async throws {
        let legacy = try makeDir()
        let custom = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let dest = DestDirBox()
        let s = SupervisorService(
            ds4Dir: legacy, runner: RecordingRunner(), ggufBaseURL: legacy.appendingPathComponent("gguf"),
            ggufPreferredDir: { custom },
            fetchFile: { _, _, _, dir, _, _, _ in
                dest.set(dir)
                try await Task.sleep(nanoseconds: 600_000_000_000)
            },
            fetchPrefix: { _, _, _, _, _, _ in
                try await Task.sleep(for: .seconds(600))
                return Data()
            })
        s.download(selection: .flash(.q2q4))
        XCTAssertEqual(s.state, .downloading)
        for _ in 0..<400 {  // the fetch invocation lands asynchronously
            if dest.get() != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(dest.get()?.path, custom.path, "the fetch must stream into the configured folder")
        s.cancelDownload()
        XCTAssertEqual(s.state, .idle)
    }

    /// Installed detection reads the configured folder first, then the legacy location:
    /// a model downloaded before the switch keeps reading as installed.
    func testIsDownloadedChecksActiveThenLegacy() throws {
        let legacy = try makeDir()
        let custom = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let s = SupervisorService(
            ds4Dir: legacy, runner: RecordingRunner(), ggufBaseURL: legacy.appendingPathComponent("gguf"),
            ggufPreferredDir: { custom })

        XCTAssertFalse(s.isDownloaded(.flash(.q2q4)))
        try plantVerified(.q2q4Imatrix, in: legacy.appendingPathComponent("gguf"))
        XCTAssertTrue(s.isDownloaded(.flash(.q2q4)), "the legacy copy still counts as installed")

        // A marker-less final in the active dir is NOT downloaded (unchanged rule), even
        // though the file exists — and the legacy fallback finds nothing for it either.
        try makeSparse(custom.appendingPathComponent(Quant.q2Imatrix.ggufFilename), bytes: 8)
        XCTAssertFalse(s.isDownloaded(.flash(.q2)))
        try plantVerified(.q2Imatrix, in: legacy.appendingPathComponent("gguf"))
        XCTAssertTrue(s.isDownloaded(.flash(.q2)))
    }

    /// The server starts from wherever the model actually lives — the legacy location
    /// when only it has the file.
    func testStartUsesLegacyModelPathWhenActiveDirLacksIt() throws {
        let legacy = try makeDir()
        let custom = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let runner = RecordingRunner()
        let s = SupervisorService(
            ds4Dir: legacy, runner: runner, ggufBaseURL: legacy.appendingPathComponent("gguf"),
            ggufPreferredDir: { custom },
            wiredLimitGate: { _, _, _ in .standard })
        let gguf = legacy.appendingPathComponent("gguf").appendingPathComponent(Quant.q2q4Imatrix.ggufFilename)
        try makeSparse(gguf, bytes: 4096)

        s.start(selection: .flash(.q2q4), ctx: 4096, host: "127.0.0.1", port: 8123, power: nil)
        XCTAssertEqual(s.state, .starting)
        let modelFlag = runner.launchArgs.firstIndex(of: "-m").map { runner.launchArgs[$0 + 1] }
        XCTAssertEqual(modelFlag, gguf.path, "the server must load the legacy-location model")
        s.stop()
    }

    /// Cleanup reclaims artifacts in BOTH dirs after a folder switch.
    func testCleanupRemovesArtifactsAcrossDirs() throws {
        let legacy = try makeDir()
        let custom = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let legacyGGUF = legacy.appendingPathComponent("gguf")
        let s = SupervisorService(
            ds4Dir: legacy, runner: RecordingRunner(), ggufBaseURL: legacyGGUF,
            ggufPreferredDir: { custom })

        // A partial (with a valid bitmap sidecar) in the active dir and a verified final
        // in the legacy dir.
        try makeSparse(custom.appendingPathComponent(Quant.q41Q2.ggufFilename + ".part"), bytes: 64)
        FileManager.default.createFile(
            atPath: custom.appendingPathComponent(Quant.q41Q2.ggufFilename + ".part.dl").path,
            contents: makeSidecar(total: 64, chunkSize: 32, completedChunks: 1))
        try plantVerified(.q2q4Imatrix, in: legacyGGUF)

        XCTAssertTrue(s.hasFlash41PartialDownload(.q2))  // the custom-dir partial is detected
        XCTAssertTrue(s.isFlashQuantDownloaded(.q2q4))
        let urls = s.flashArtifactURLs(.q2q4)
        XCTAssertEqual(urls.map(\.path), [legacyGGUF.appendingPathComponent(Quant.q2q4Imatrix.ggufFilename).path])

        let removed = s.cleanupUnusedFlash41Quants(keep: .mxfp4)
        XCTAssertTrue(
            removed.contains(Quant.q41Q2.ggufFilename + ".part"),
            "the custom-dir partial is removed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: custom.appendingPathComponent(Quant.q41Q2.ggufFilename + ".part").path))

        let removedFlash = s.cleanupUnusedFlashQuants(keep: .q2)
        XCTAssertTrue(removedFlash.contains(Quant.q2q4Imatrix.ggufFilename), "the legacy final is removed")
        XCTAssertFalse(s.isFlashQuantDownloaded(.q2q4))
    }
}
/// A valid `ChunkBitmap` sidecar (magic + LE total + LE chunkSize + per-chunk status) so
/// `resumableBytes` counts the completed chunks — a Data([1]) placeholder reads as invalid
/// and makes partial-detection miss the file.
private func makeSidecar(total: Int64, chunkSize: Int64, completedChunks: Int) -> Data {
    var data = Data("DS4DL1\n".utf8)
    for value in [total, chunkSize] {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    let chunkCount = Int((total + chunkSize - 1) / chunkSize)
    data.append(contentsOf: (0..<chunkCount).map { $0 < completedChunks ? 1 : 0 })
    return data
}
