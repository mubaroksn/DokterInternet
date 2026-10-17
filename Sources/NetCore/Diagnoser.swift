import Foundation

public struct DiagnosisInput: Sendable {
    public var online: Bool
    public var isWiFi: Bool
    public var wifiRSSI: Int?
    public var gatewayLatency: Double?
    public var gatewayLoss: Double?
    public var internetLatency: Double?
    public var internetLoss: Double?
    public var internetJitter: Double?
    public var dnsMs: Double?
    public var dnsFailed: Bool
    public var httpMs: Double?
    public var httpFailed: Bool

    public init(online: Bool, isWiFi: Bool, wifiRSSI: Int? = nil,
                gatewayLatency: Double? = nil, gatewayLoss: Double? = nil,
                internetLatency: Double? = nil, internetLoss: Double? = nil, internetJitter: Double? = nil,
                dnsMs: Double? = nil, dnsFailed: Bool = false, httpMs: Double? = nil, httpFailed: Bool = false) {
        self.online = online
        self.isWiFi = isWiFi
        self.wifiRSSI = wifiRSSI
        self.gatewayLatency = gatewayLatency
        self.gatewayLoss = gatewayLoss
        self.internetLatency = internetLatency
        self.internetLoss = internetLoss
        self.internetJitter = internetJitter
        self.dnsMs = dnsMs
        self.dnsFailed = dnsFailed
        self.httpMs = httpMs
        self.httpFailed = httpFailed
    }
}

public enum FindingAction: Sendable, Equatable {
    case none, openDNS, openWiFi, openSpeedTest
}

public struct Finding: Sendable, Identifiable, Equatable {
    public var id: String { title }
    public var health: Health
    public var title: String
    public var detail: String
    public var action: FindingAction
}

public struct Diagnosis: Sendable, Equatable {
    public var overall: Health
    public var headline: String
    public var summary: String
    public var findings: [Finding]
}

public enum Diagnoser {
    public static func evaluate(_ i: DiagnosisInput) -> Diagnosis {
        var f: [Finding] = []

        guard i.online else {
            return Diagnosis(
                overall: .poor,
                headline: "Tidak ada koneksi jaringan",
                summary: "Mac tidak terhubung ke Wi-Fi atau kabel LAN.",
                findings: [Finding(health: .poor, title: "Tidak terhubung",
                                   detail: "Nyalakan Wi-Fi atau colok kabel LAN, lalu jalankan diagnosa lagi.",
                                   action: .none)]
            )
        }

        if i.isWiFi, let rssi = i.wifiRSSI {
            let h = SignalQuality.health(rssi: rssi)
            if h != .good {
                f.append(Finding(
                    health: h,
                    title: "Sinyal Wi-Fi \(h == .poor ? "lemah" : "kurang kuat") (\(rssi) dBm)",
                    detail: "Dekatkan Mac ke router atau kurangi penghalang (tembok tebal, lemari, akuarium). Sinyal di bawah −70 dBm sering bikin koneksi putus-putus walau paket internetnya kencang.",
                    action: .openWiFi))
            }
        }

        let localLimit: Double = i.isWiFi ? 30 : 8
        var lanBad = false
        if let loss = i.gatewayLoss, loss >= 10 {
            lanBad = true
            f.append(Finding(
                health: .poor,
                title: "Koneksi ke router tidak stabil (\(Format.percent(loss)) paket hilang)",
                detail: "Paket sudah hilang sebelum keluar rumah, jadi masalahnya di jaringan rumah (Wi-Fi atau router), bukan di provider. Coba restart router, dekatkan Mac, atau pindah channel Wi-Fi.",
                action: i.isWiFi ? .openWiFi : .none))
        } else if let lat = i.gatewayLatency, lat > localLimit {
            lanBad = true
            f.append(Finding(
                health: .fair,
                title: "Router lambat merespons (\(Format.ms(lat)))",
                detail: "Normalnya di bawah \(Int(localLimit)) ms. Biasanya karena channel Wi-Fi padat atau router terlalu sibuk. Cek menu Wi-Fi untuk channel yang lebih lowong.",
                action: i.isWiFi ? .openWiFi : .none))
        }

        if let loss = i.internetLoss, loss >= 10 {
            f.append(Finding(
                health: .poor,
                title: "Internet tidak stabil (\(Format.percent(loss)) paket hilang)",
                detail: lanBad
                    ? "Sebagian karena jaringan rumah di atas. Perbaiki itu dulu, lalu cek lagi."
                    : "Koneksi ke router lancar, tapi paket hilang setelah keluar rumah. Ini di sisi provider. Jalankan Speed Test beberapa kali sebagai bukti untuk komplain.",
                action: lanBad ? .none : .openSpeedTest))
        }
        if let lat = i.internetLatency {
            if lat > 150 {
                f.append(Finding(health: .poor, title: "Ping tinggi (\(Format.ms(lat)))",
                                 detail: "Game online dan video call akan terasa delay. Kalau router sehat, penyebabnya rute provider.",
                                 action: lanBad ? .none : .openSpeedTest))
            } else if lat > 80 {
                f.append(Finding(health: .fair, title: "Ping agak tinggi (\(Format.ms(lat)))",
                                 detail: "Masih wajar untuk browsing dan streaming, tapi kurang ideal untuk game online.",
                                 action: .none))
            }
        }
        if let j = i.internetJitter, j > 30 {
            f.append(Finding(health: .fair, title: "Koneksi naik-turun (jitter \(Format.ms(j)))",
                             detail: "Waktu respons tidak konsisten. Video call bisa patah-patah. Sering terjadi saat ada yang download besar di jaringan yang sama.",
                             action: .none))
        }

        if i.dnsFailed {
            f.append(Finding(health: .poor, title: "DNS tidak menjawab",
                             detail: "Internet bisa jalan tapi nama situs tidak bisa diterjemahkan. Ganti ke DNS publik di menu DNS.",
                             action: .openDNS))
        } else if let dns = i.dnsMs, dns > 100 {
            f.append(Finding(health: dns > 200 ? .poor : .fair, title: "DNS lambat (\(Format.ms(dns)))",
                             detail: "Setiap membuka situs baru, Mac menunggu DNS dulu. Uji dan ganti ke DNS yang lebih cepat di menu DNS.",
                             action: .openDNS))
        }

        if i.httpFailed {
            f.append(Finding(health: .poor, title: "Website tidak bisa dibuka",
                             detail: "Permintaan ke google.com gagal. Kalau langkah lain hijau, coba matikan VPN atau proxy.",
                             action: .none))
        } else if let http = i.httpMs, http > 1500 {
            f.append(Finding(health: .fair, title: "Website lambat terbuka (\(Format.ms(http)))",
                             detail: "Waktu membuka halaman uji terlalu lama.",
                             action: .openSpeedTest))
        }

        let overall = f.reduce(Health.good) { $0.worse($1.health) }
        let sorted = f.sorted { $0.health > $1.health }
        let headline: String
        let summary: String
        switch overall {
        case .good, .unknown:
            headline = "Koneksi kamu sehat"
            summary = "Router, internet, dan DNS semuanya merespons normal. Kalau masih terasa lambat, jalankan Speed Test untuk melihat kecepatan paket."
        case .fair:
            headline = "Ada yang bisa diperbaiki"
            summary = "Koneksi jalan, tapi ada \(sorted.count) hal yang bikin kurang optimal."
        case .poor:
            headline = "Ada masalah pada koneksi"
            summary = lanBad
                ? "Sumber utamanya di jaringan rumah (Wi-Fi/router)."
                : "Lihat rincian di bawah untuk penyebab dan solusinya."
        }
        return Diagnosis(overall: overall, headline: headline, summary: summary, findings: sorted)
    }
}

public enum HourlyInsight {
    /// Average value per hour of day, for "when is my connection slowest".
    public static func averageByHour(_ samples: [(date: Date, value: Double)], calendar: Calendar = .current) -> [Int: Double] {
        var buckets: [Int: [Double]] = [:]
        for s in samples { buckets[calendar.component(.hour, from: s.date), default: []].append(s.value) }
        return buckets.compactMapValues(Stats.mean)
    }

    /// (slowest hour, fastest hour) when there is enough spread to be meaningful.
    public static func extremes(_ samples: [(date: Date, value: Double)], calendar: Calendar = .current) -> (slow: Int, fast: Int)? {
        let avg = averageByHour(samples, calendar: calendar)
        guard avg.count >= 2,
              let slow = avg.min(by: { $0.value < $1.value }),
              let fast = avg.max(by: { $0.value < $1.value }),
              fast.value > slow.value * 1.15 else { return nil }
        return (slow.key, fast.key)
    }
}
