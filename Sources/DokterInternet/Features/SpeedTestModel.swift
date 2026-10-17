import Foundation
import NetCore

struct SpeedResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var download: Double?
    var upload: Double?
    var ping: Double?
    var jitter: Double?
    var loss: Double?
    var server: String?
    var network: String?
}

enum SpeedConfig {
    static let downloadSeconds = 10.0
    static let uploadSeconds = 8.0
}

@MainActor
final class SpeedTestModel: ObservableObject {
    enum Phase: Equatable {
        case idle, latency, download, upload, done
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Siap"
            case .latency: return "Mengukur ping…"
            case .download: return "Mengukur download…"
            case .upload: return "Mengukur upload…"
            case .done: return "Selesai"
            case .failed(let m): return m
            }
        }
    }

    struct LivePoint: Identifiable, Equatable {
        var id: Int
        var t: Double
        var mbps: Double
        var upload: Bool
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveMbps: Double = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var current: SpeedResult?
    @Published private(set) var history: [SpeedResult] = []
    @Published private(set) var serverLabel: String?
    @Published private(set) var livePoints: [LivePoint] = []
    private var pointCounter = 0


    var isRunning: Bool {
        switch phase {
        case .latency, .download, .upload: return true
        default: return false
        }
    }

    init() {
        history = Self.loadHistory()
    }

    func start() {
        guard !isRunning else { return }
        Task { await run() }
    }

    private func run() async {
        livePoints = []
        liveMbps = 0
        progress = 0
        var result = SpeedResult(date: Date())
        current = result

        let path = await NetworkInfo.path()
        guard path.online else {
            phase = .failed("Tidak ada koneksi jaringan")
            return
        }
        if path.isWiFi {
            result.network = WiFiScanner.currentLink()?.ssid ?? "Wi-Fi"
        } else {
            result.network = path.kindLabel
        }

        async let traceTask = NetworkInfo.cloudflareTrace()

        phase = .latency
        let ping = await Pinger.measure("1.1.1.1", count: 12, tcpPort: 443)
        result.ping = ping.result.median
        result.jitter = ping.result.jitter
        result.loss = ping.result.lossPercent
        current = result
        progress = 0.08

        if let trace = await traceTask {
            let city = Self.coloNames[trace.colo ?? ""] ?? trace.colo
            serverLabel = city.map { "Cloudflare · \($0)" } ?? "Cloudflare"
            result.server = serverLabel
        }

        phase = .download
        let sink = self
        let dl = await SpeedEngine.measure(.download, streams: 6, duration: SpeedConfig.downloadSeconds) { s in
            Task { @MainActor in sink.record(s, upload: false) }
        }
        guard let dl else {
            phase = .failed("Download gagal — server uji tidak bisa dihubungi")
            return
        }
        result.download = dl
        current = result

        phase = .upload
        liveMbps = 0
        let ul = await SpeedEngine.measure(.upload, streams: 4, duration: SpeedConfig.uploadSeconds) { s in
            Task { @MainActor in sink.record(s, upload: true) }
        }
        result.upload = ul
        current = result
        progress = 1
        liveMbps = 0
        phase = .done

        history.insert(result, at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        saveHistory()
    }

    private func record(_ s: SpeedEngine.Sample, upload: Bool) {
        guard phase == (upload ? .upload : .download) else { return }
        liveMbps = s.mbps
        pointCounter += 1
        if upload {
            progress = 0.58 + 0.42 * min(1, s.elapsed / SpeedConfig.uploadSeconds)
            livePoints.append(LivePoint(id: pointCounter, t: SpeedConfig.downloadSeconds + s.elapsed, mbps: s.mbps, upload: true))
        } else {
            progress = 0.08 + 0.5 * min(1, s.elapsed / SpeedConfig.downloadSeconds)
            livePoints.append(LivePoint(id: pointCounter, t: s.elapsed, mbps: s.mbps, upload: false))
        }
    }

    func deleteHistory() {
        history = []
        saveHistory()
    }

    // MARK: Persistence

    private static var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DokterInternet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("speed-history.json")
    }

    private static func loadHistory() -> [SpeedResult] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([SpeedResult].self, from: data)) ?? []
    }

    private func saveHistory() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(history) {
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    /// Cloudflare data-center codes near Indonesia, for a friendlier server label.
    static let coloNames: [String: String] = [
        "CGK": "Jakarta", "SUB": "Surabaya", "SIN": "Singapura", "KUL": "Kuala Lumpur",
        "JHB": "Johor Bahru", "BKK": "Bangkok", "HKG": "Hong Kong", "NRT": "Tokyo",
        "SYD": "Sydney", "MNL": "Manila", "DPS": "Denpasar", "PER": "Perth",
    ]

    /// Average download per hour of day, once there is enough history.
    var slowestHourText: String? {
        let samples = history.compactMap { r in r.download.map { (date: r.date, value: $0) } }
        guard samples.count >= 5, let e = HourlyInsight.extremes(samples) else { return nil }
        return String(format: "Paling lambat sekitar jam %02d.00, paling kencang sekitar jam %02d.00.", e.slow, e.fast)
    }
}
