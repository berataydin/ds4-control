import XCTest

@testable import DS4Control

/// No-op runner for the server slot — downloads run on an injected `FetchFile` Task.
private final class NoopRunner: ProcessRunner {
    var isRunning = false
    func launch(
        executable: URL, args: [String], cwd: URL, env: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStderrLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void
    ) throws {}
    func terminate(graceSeconds: Double) {}
}

/// Pause/Resume/discard-paused semantics at the supervisor level: Pause keeps every
/// durable partial and returns to idle, Resume re-enters `.downloading` through the
/// ordinary `download()` path (bitmap resume), and discarding a paused download applies
/// Cancel's artifact policy. All fetches are fakes — no network.
@MainActor
final class DownloadPauseResumeTests: XCTestCase {
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

    private func makeService(dir: URL, fetch: @escaping SupervisorService.FetchFile) -> SupervisorService {
        SupervisorService(
            ds4Dir: dir, runner: NoopRunner(), fetchFile: fetch,
            fetchPrefix: { _, _, _, _, _, _ in
                try await Task.sleep(for: .seconds(600))
                return Data()
            })
    }

    /// A fetch that never returns — the download stays in flight until paused/cancelled.
    private let pending: SupervisorService.FetchFile = { _, _, _, _, _, _, _ in
        try await Task.sleep(nanoseconds: 600_000_000_000)
    }

    private func until(_ cond: @escaping () -> Bool) async {
        for _ in 0..<400 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Pause returns to idle, keeps the durable partials, and records the paused
    /// selection + progress snapshot for the Resume affordance.
    func testPauseKeepsPartialsAndRecordsSelection() throws {
        let dir = try makeDir()
        let gguf = dir.appendingPathComponent("gguf")
        let s = makeService(dir: dir, fetch: pending)
        s.download(selection: .flash(.q2q4))
        XCTAssertEqual(s.state, .downloading)

        // Durable partial state a live download would have produced: a sparse .part plus
        // a bitmap sidecar recording one completed chunk.
        let name = Quant.q2q4Imatrix.ggufFilename
        try makeSparse(gguf.appendingPathComponent(name + ".part"), bytes: 1024)
        FileManager.default.createFile(
            atPath: gguf.appendingPathComponent(name + ".part.dl").path,
            contents: makeSidecar(total: 1024, chunkSize: 512, completedChunks: 1))

        s.pauseDownload()
        XCTAssertEqual(s.state, .idle)
        XCTAssertFalse(s.downloadProcessLive)
        XCTAssertNil(s.download)
        XCTAssertEqual(s.pausedDownloadSelection, .flash(.q2q4))
        XCTAssertNotNil(s.pausedDownloadInfo(for: .flash(.q2q4)))
        XCTAssertNil(s.pausedDownloadInfo(for: .flash41(.q2)), "another quant is not paused")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: gguf.appendingPathComponent(name + ".part").path),
            "pause must keep the .part for resume")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: gguf.appendingPathComponent(name + ".part.dl").path),
            "pause must keep the bitmap sidecar")
        XCTAssertTrue(s.hasPartialDownloadForSelection(.flash(.q2q4)))
    }

    /// Resume is a plain download(): state re-enters `.downloading`, the pause record
    /// clears, and (with a completing fetch) the download finishes and verifies. The first
    /// fetch parks so the pause lands mid-download; the resume's fetch completes.
    func testResumeCompletesFromPartialState() async throws {
        let dir = try makeDir()
        let gguf = dir.appendingPathComponent("gguf")
        let name = Quant.q2q4Imatrix.ggufFilename
        // A prior session's partial: the resume "completes" it to a full sparse final.
        try makeSparse(gguf.appendingPathComponent(name + ".part"), bytes: 4096)
        FileManager.default.createFile(
            atPath: gguf.appendingPathComponent(name + ".part.dl").path, contents: Data([1]))

        let box = FetchInvocationBox()
        let s = SupervisorService(
            ds4Dir: dir, runner: NoopRunner(),
            fetchFile: { _, _, file, destDir, _, _, _ in
                if try await box.parkFirst() { return }
                try makeSparse(destDir.appendingPathComponent(file), bytes: Quant.q2q4Imatrix.ggufBytes)
            })
        s.download(selection: .flash(.q2q4))  // resumes: final absent, partial present
        await until { box.invocations == 1 }  // the fetch is parked → still downloading
        XCTAssertEqual(s.state, .downloading)
        s.pauseDownload()
        XCTAssertEqual(s.state, .idle)
        await until { box.cancellations == 1 }  // cancellation lands asynchronously
        XCTAssertEqual(box.cancellations, 1, "pause cancels the in-flight fetch")

        s.download(selection: .flash(.q2q4))  // Resume
        XCTAssertEqual(s.state, .downloading)
        XCTAssertNil(s.pausedDownloadSelection, "resuming clears the pause record")
        await until { s.state == .idle }
        XCTAssertTrue(s.isDownloaded(.flash(.q2q4)), "the resumed download verifies")
    }

    /// Discarding a paused download removes the transport partials exactly like an
    /// in-flight Cancel — and forgets the pause.
    func testDiscardPausedRemovesPartials() throws {
        let dir = try makeDir()
        let gguf = dir.appendingPathComponent("gguf")
        let name = Quant.q2q4Imatrix.ggufFilename
        let s = makeService(dir: dir, fetch: pending)
        s.download(selection: .flash(.q2q4))
        try makeSparse(gguf.appendingPathComponent(name + ".part"), bytes: 1024)
        FileManager.default.createFile(
            atPath: gguf.appendingPathComponent(name + ".part.dl").path, contents: Data([1]))
        s.pauseDownload()

        s.discardPausedDownload()
        XCTAssertNil(s.pausedDownloadSelection)
        XCTAssertNil(s.pausedDownloadInfo(for: .flash(.q2q4)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gguf.appendingPathComponent(name + ".part").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gguf.appendingPathComponent(name + ".part.dl").path))
        XCTAssertFalse(s.hasPartialDownloadForSelection(.flash(.q2q4)))
    }

    /// A final that predates the download attempt (a marker-less artifact being
    /// re-verified) survives discarding the paused download — Cancel's protection,
    /// carried across the pause.
    func testDiscardPausedPreservesPreexistingFinal() throws {
        let dir = try makeDir()
        let gguf = dir.appendingPathComponent("gguf")
        let name = Quant.q2q4Imatrix.ggufFilename
        let final = gguf.appendingPathComponent(name)
        try makeSparse(final, bytes: 2048)  // predates the download

        let s = makeService(dir: dir, fetch: pending)
        s.download(selection: .flash(.q2q4))
        // A fetch is skipped when the final exists with no resumable partial — the
        // download sits in verification; pause + discard must keep the pre-existing final.
        try makeSparse(gguf.appendingPathComponent(name + ".part"), bytes: 512)
        FileManager.default.createFile(
            atPath: gguf.appendingPathComponent(name + ".part.dl").path, contents: Data([1]))
        s.pauseDownload()
        s.discardPausedDownload()

        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path), "a pre-existing final is not ours to delete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gguf.appendingPathComponent(name + ".part").path))
    }

    /// Pausing an MXFP4 (shard) download keeps the durable checkpoints AND registers the
    /// drain, exactly like cancel: the cancelled assembler must finish its checkpoint
    /// before anything else touches those paths.
    func testPauseMXFP4PreservesStagingAndTracksDrain() throws {
        let dir = try makeDir()
        let s = makeService(dir: dir, fetch: pending)
        s.download(selection: .flash41(.mxfp4))
        XCTAssertEqual(s.state, .downloading)

        let gguf = dir.appendingPathComponent("gguf")
        let sidecars = Quant.q41MXFP4.downloadParts.map {
            gguf.appendingPathComponent($0.filename + ".part.dl")
        }
        for sidecar in sidecars { FileManager.default.createFile(atPath: sidecar.path, contents: Data([1])) }
        let assembling = gguf.appendingPathComponent(Quant.q41MXFP4.ggufFilename + ".assembling")
        FileManager.default.createFile(atPath: assembling.path, contents: Data([1]))

        s.pauseDownload()
        XCTAssertEqual(s.state, .idle)
        XCTAssertNotNil(s.drainingShardGeneration, "pause tracks the shard drain like cancel")
        XCTAssertFalse(s.canRemoveLegacyFlash41Storage)
        for sidecar in sidecars {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: assembling.path))

        // Discarding a paused shard download keeps the checkpoints (Cancel's policy);
        // Settings cleanup reclaims them.
        s.discardPausedDownload()
        XCTAssertTrue(FileManager.default.fileExists(atPath: assembling.path))
    }

    /// An in-flight Cancel still forgets any pause record — Cancel remains the hard stop,
    /// even when the pause belonged to a different selection.
    func testCancelClearsPauseRecord() throws {
        let dir = try makeDir()
        let s = makeService(dir: dir, fetch: pending)
        s.download(selection: .flash(.q2q4))
        s.pauseDownload()
        XCTAssertEqual(s.pausedDownloadSelection, .flash(.q2q4))

        s.download(selection: .flash41(.q2))  // a different quant — the pause record persists
        XCTAssertEqual(s.state, .downloading)
        XCTAssertEqual(s.pausedDownloadSelection, .flash(.q2q4))
        s.cancelDownload()
        XCTAssertNil(s.pausedDownloadSelection, "cancel forgets the pause record")
        XCTAssertEqual(s.state, .idle)
    }
}

/// Tracks fetch invocations for the resume test: the first parks until cancelled (so the
/// download stays in flight for the pause), later invocations run through. Counters are
/// lock-guarded because the fetch closure runs off the main actor.
private final class FetchInvocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations = 0
    private var _cancellations = 0
    var invocations: Int {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }
    var cancellations: Int {
        lock.lock(); defer { lock.unlock() }
        return _cancellations
    }

    func parkFirst() async throws -> Bool {
        let first = lock.withLock {
            _invocations += 1
            return _invocations == 1
        }
        if !first { return false }
        do {
            try await Task.sleep(nanoseconds: 600_000_000_000)  // first fetch: never returns
            return true
        } catch {
            lock.withLock { _cancellations += 1 }
            throw error
        }
    }
}

/// Materialize a sparse file at `url` with the given logical size (cheap on APFS) —
/// file-scope so @Sendable fetch closures can use it without MainActor hops.
private func makeSparse(_ url: URL, bytes: Int) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(bytes))
    try handle.close()
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
