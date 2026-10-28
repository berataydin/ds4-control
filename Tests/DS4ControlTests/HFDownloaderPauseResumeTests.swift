import XCTest

@testable import DS4Control

/// Offline pause/resume at the downloader level: a 16-byte file split into 4-byte chunks
/// served by a GATED URLProtocol. The probe passes through; exactly one chunk-data
/// request is released by the test, the rest park until the download Task is cancelled —
/// the engine-level equivalent of pressing Pause. The second `download` call must fetch
/// ONLY the chunks the bitmap lacks, proving resume-from-where-it-left-off without any
/// network traffic. Every await is watchdog-bounded so a lost cancellation fails the
/// test instead of hanging the suite.
final class HFDownloaderPauseResumeTests: XCTestCase {
    private struct Timeout: Error { let label: String }

    private func makeConfig() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GatedHFProtocol.self]
        return cfg
    }

    private func withTimeout<T: Sendable>(
        _ seconds: Double, _ label: String, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Timeout(label: label)
            }
            guard let result = try await group.next() else { throw Timeout(label: label) }
            group.cancelAll()
            return result
        }
    }

    func testCancelKeepsBitmapAndResumeFetchesOnlyMissingChunks() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = "paused.gguf"
        let chunk: Int64 = 4
        let part = dir.appendingPathComponent(file + ".part")
        let sidecar = dir.appendingPathComponent(file + ".part.dl")

        // Run 1: gated — one chunk completes, the rest park; cancel (Pause) mid-flight.
        GatedHFProtocol.state.reset(open: false)
        let downloader = HFDownloader(repo: "test/repo", sessionConfiguration: makeConfig(), probeRetryBackoff: 0.01)
        let task = Task {
            try await downloader.download(
                file: file, into: dir, token: nil, highPerformance: false, chunkSize: chunk) { _, _ in }
        }
        // The size probe passes ungated; release exactly ONE chunk request.
        GatedHFProtocol.gate.signal()
        var durable: Int64 = 0
        for _ in 0..<1000 {  // up to ~10 s for the released chunk to commit
            durable = resumableBytes(ggufDir: dir, filename: file)
            if durable >= chunk { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(durable, chunk, "one chunk must be durably complete before the cancel")

        task.cancel()  // what Pause does under the hood
        do {
            try await withTimeout(45, "run-1 cancel unwind") { try await task.value }
            XCTFail("a cancelled download must throw, not complete")
        } catch is CancellationError {
        } catch let e as Timeout {
            XCTFail("cancel did not unwind the download: \(e.label)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // Pause semantics at the engine level: the .part + bitmap sidecar survive with
        // the completed chunk recorded. Ground truth for "where it stopped" is the
        // DURABLE bitmap, not the serve log — a chunk whose bytes were in flight at
        // cancel is correctly absent and must be refetched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(resumableBytes(ggufDir: dir, filename: file), chunk)
        let durableRanges = completedChunkRanges(dir: dir, file: file, chunkSize: chunk)
        XCTAssertEqual(durableRanges.count, 1, "exactly one chunk must be durably complete")

        // Run 2: open gate — the resume completes the file fetching only missing chunks.
        GatedHFProtocol.state.reset(open: true)
        let progress = ProgressBox()
        let resumer = HFDownloader(repo: "test/repo", sessionConfiguration: makeConfig(), probeRetryBackoff: 0.01)
        try await withTimeout(45, "resume completion") {
            try await resumer.download(
                file: file, into: dir, token: nil, highPerformance: false, chunkSize: chunk
            ) { received, total in
                progress.set(received, total)
            }
        }

        XCTAssertEqual(
            try Data(contentsOf: dir.appendingPathComponent(file)), GatedHFProtocol.body,
            "the resumed file must be byte-complete")
        XCTAssertEqual(progress.received, GatedHFProtocol.total)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "sidecar dropped on completion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), ".part renamed away on completion")

        let run2ChunkRanges = Set(GatedHFProtocol.state.servedRanges().filter { $0 != "0-0" })
        XCTAssertTrue(
            run2ChunkRanges.isDisjoint(with: durableRanges),
            "the chunk durably completed in run 1 must not be refetched; log=\(GatedHFProtocol.state.servedRanges()) durable=\(durableRanges)")
        XCTAssertEqual(run2ChunkRanges.count, 3, "only the 3 missing chunks are fetched")
        XCTAssertEqual(
            GatedHFProtocol.state.requestCount, 4,
            "run 2 (after reset): probe + only the 3 missing chunks")
    }

    /// The chunk ranges the DURABLE bitmap sidecar marks complete — the authoritative
    /// "where the download stopped" a resume continues from.
    private func completedChunkRanges(dir: URL, file: String, chunkSize: Int64) -> Set<String> {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent(file + ".part.dl"))
        else { return [] }
        let magic = Data("DS4DL1\n".utf8)
        let headerLen = magic.count + 16
        guard data.count >= headerLen, data.prefix(magic.count) == magic else { return [] }
        let total = data.subdata(in: 7..<15).withUnsafeBytes {
            Int64(littleEndian: $0.loadUnaligned(as: Int64.self))
        }
        let status = data.suffix(from: headerLen)
        var ranges = Set<String>()
        for (i, b) in status.enumerated() where b == 1 {
            let start = Int64(i) * chunkSize
            let end = min(start + chunkSize - 1, total - 1)
            ranges.insert("\(start)-\(end)")
        }
        return ranges
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var received: Int64 = 0
    private(set) var total: Int64 = -1
    func set(_ r: Int64, _ t: Int64) {
        lock.lock()
        defer { lock.unlock() }
        received = r; total = t
    }
}

/// Offline HF-style range server over a 16-byte body. In gated mode the size probe
/// (`bytes=0-0`) is served immediately while every chunk request PARKS on a shared
/// semaphore until the test releases it (or cancellation calls `stopLoading`, which
/// self-releases). In open mode everything serves immediately. Served ranges are
/// recorded so tests can assert which chunks each run fetched.
///
/// startLoading NEVER blocks: CFNetwork delivers cancellation (stopLoading) through the
/// same loading thread, so a blocking startLoading wedges every later URLProtocol load
/// in the process (observed as 60 s probe timeouts in unrelated tests). Gated requests
/// wait on a dispatch worker instead and deliver the response asynchronously.
final class GatedHFProtocol: URLProtocol {
    static let body = Data("0123456789abcdef".utf8)
    static let total: Int64 = 16
    static let gate = DispatchSemaphore(value: 0)

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var served: [String] = []
        private var count = 0

        func reset(open: Bool) {
            lock.lock()
            defer { lock.unlock() }
            self.open = open
            served = []
            count = 0
        }
        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return open
        }
        func record(_ range: String) {
            lock.lock()
            defer { lock.unlock() }
            served.append(range)
            count += 1
        }
        func servedRanges() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return served
        }
        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
    static let state = State()

    private let lock = NSLock()
    private var parked = false
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-0"
        let bounds = String(range.dropFirst("bytes=".count))
        if bounds == "0-0" || Self.state.isOpen {
            serve(bounds)
            return
        }
        lock.lock()
        parked = true
        lock.unlock()
        let client = self.client
        let url = request.url
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            // Bounded wait so a lost permit/cancellation leaks nothing permanently.
            let acquired = Self.gate.wait(timeout: .now() + 30) == .success
            self.lock.lock()
            let wasParked = self.parked
            self.parked = false
            let stopped = self.stopped
            self.lock.unlock()
            guard wasParked, acquired, !stopped else { return }
            self.serve(bounds, client: client, url: url)
        }
    }

    override func stopLoading() {
        lock.lock()
        let wasParked = parked
        stopped = true
        parked = false
        lock.unlock()
        // Wake this instance's waiter so the permit accounting stays balanced.
        if wasParked { Self.gate.signal() }
    }

    private func serve(_ bounds: String) {
        serve(bounds, client: client, url: request.url)
    }

    private func serve(_ bounds: String, client: (any URLProtocolClient)?, url: URL?) {
        let parts = bounds.split(separator: "-").compactMap { Int64($0) }
        let start = parts.first ?? 0
        let end = parts.count > 1 ? parts[1] : Self.total - 1
        let payload = Self.body[Int(start)...Int(end)]
        Self.state.record(bounds)
        let resp = HTTPURLResponse(
            url: url ?? request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Range": "bytes \(start)-\(end)/\(Self.total)",
                "Content-Length": "\(payload.count)",
            ])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}
