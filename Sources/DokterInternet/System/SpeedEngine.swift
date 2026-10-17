import Foundation

/// Thread-safe byte counter shared by all streams of one measurement.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0

    func add(_ n: Int64) {
        lock.lock()
        bytes += n
        lock.unlock()
    }

    var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

/// One transfer stream with its own URLSession, so every stream gets its own TCP connection
/// (sharing a session would multiplex everything over one HTTP/2 connection).
final class TransferStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let counter: ByteCounter
    private let lock = NSLock()
    private var session: URLSession!
    private var continuation: CheckedContinuation<Void, Never>?
    private var current: URLSessionTask?
    private(set) var errors = 0

    init(counter: ByteCounter) {
        self.counter = counter
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 15
        cfg.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// Runs one request to completion (or until cancelled).
    func run(_ request: URLRequest, body: Data?, deadline: Date) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let task: URLSessionTask
            if let body {
                task = session.uploadTask(with: request, from: body)
            } else {
                task = session.dataTask(with: request)
            }
            lock.lock()
            continuation = c
            current = task
            lock.unlock()
            task.resume()
            if Date() >= deadline { task.cancel() }
        }
    }

    func cancelCurrent() {
        lock.lock()
        let t = current
        lock.unlock()
        t?.cancel()
    }

    func close() {
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        counter.add(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        counter.add(bytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        current = nil
        if let e = error as NSError?, e.code != NSURLErrorCancelled { errors += 1 }
        lock.unlock()
        c?.resume()
    }
}

enum SpeedEngine {
    enum Direction: Sendable { case download, upload }

    struct Sample: Sendable {
        var elapsed: Double   // seconds since start
        var mbps: Double      // rate over the last second
    }

    static let downloadURL = URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!
    static let uploadURL = URL(string: "https://speed.cloudflare.com/__up")!
    static let uploadChunk = Data(count: 4_000_000)

    /// Saturates the link with parallel streams for `duration` seconds and returns Mbps
    /// (the first `warmup` seconds, while TCP ramps up, are not counted).
    static func measure(_ direction: Direction, streams: Int = 6, duration: Double = 10, warmup: Double = 2,
                        onSample: @escaping @Sendable (Sample) -> Void) async -> Double? {
        let counter = ByteCounter()
        let pool = (0..<streams).map { _ in TransferStream(counter: counter) }
        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        let warmBytes = ByteCounter()

        var request: URLRequest
        switch direction {
        case .download:
            request = URLRequest(url: downloadURL)
        case .upload:
            request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let req = request
        let body: Data? = direction == .upload ? uploadChunk : nil

        await withTaskGroup(of: Void.self) { group in
            for (i, stream) in pool.enumerated() {
                group.addTask {
                    // Stagger stream starts slightly, like browsers do.
                    try? await Task.sleep(nanoseconds: UInt64(i) * 60_000_000)
                    while Date() < deadline && !Task.isCancelled {
                        await stream.run(req, body: body, deadline: deadline)
                    }
                }
            }
            group.addTask {
                var window: [(t: Double, b: Int64)] = [(0, 0)]
                var warmRecorded = false
                while Date() < deadline && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let t = Date().timeIntervalSince(start)
                    let b = counter.total
                    if !warmRecorded && t >= warmup {
                        warmBytes.add(b)
                        warmRecorded = true
                    }
                    window.append((t, b))
                    while window.count > 2, let oldest = window.first, t - oldest.t > 1.0 {
                        window.removeFirst()
                    }
                    if let first = window.first, t > first.t {
                        let mbps = Double(b - first.b) * 8 / (t - first.t) / 1_000_000
                        onSample(Sample(elapsed: t, mbps: mbps))
                    }
                }
                pool.forEach { $0.cancelCurrent() }
            }
            await group.waitForAll()
        }
        pool.forEach { $0.close() }

        let total = counter.total
        guard total > 0 else { return nil }
        let measuredBytes = total - warmBytes.total
        let measuredTime = min(Date().timeIntervalSince(start), duration) - warmup
        guard measuredTime > 0.5, measuredBytes > 0 else {
            return Double(total) * 8 / max(Date().timeIntervalSince(start), 0.1) / 1_000_000
        }
        return Double(measuredBytes) * 8 / measuredTime / 1_000_000
    }
}
