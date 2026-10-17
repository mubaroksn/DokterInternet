import Foundation
import NetCore

enum StepState: Equatable {
    case pending
    case running
    case done(Health)
    case skipped
}

struct DiagStep: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case link, wifi, router, internet, dns, web
    }

    var kind: Kind
    var title: String
    var state: StepState = .pending
    var value: String = ""
    var detail: String = ""
    var id: Kind { kind }

    static func initial() -> [DiagStep] {
        [
            DiagStep(kind: .link, title: "Koneksi jaringan"),
            DiagStep(kind: .wifi, title: "Sinyal Wi-Fi"),
            DiagStep(kind: .router, title: "Router"),
            DiagStep(kind: .internet, title: "Internet"),
            DiagStep(kind: .dns, title: "DNS"),
            DiagStep(kind: .web, title: "Membuka website"),
        ]
    }
}

struct ConnectionSummary: Equatable {
    var kind: String
    var name: String?
    var gateway: String?
    var publicIP: String?
    var isp: String?
    var edge: String?
}

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var steps = DiagStep.initial()
    @Published private(set) var running = false
    @Published private(set) var diagnosis: Diagnosis?
    @Published private(set) var connection: ConnectionSummary?
    @Published private(set) var lastRun: Date?

    private func update(_ kind: DiagStep.Kind, _ change: (inout DiagStep) -> Void) {
        guard let i = steps.firstIndex(where: { $0.kind == kind }) else { return }
        change(&steps[i])
    }

    private func finish(_ kind: DiagStep.Kind, _ health: Health, _ value: String, _ detail: String = "") {
        update(kind) {
            $0.state = .done(health)
            $0.value = value
            $0.detail = detail
        }
    }

    func run() async {
        guard !running else { return }
        running = true
        diagnosis = nil
        steps = DiagStep.initial()
        defer {
            running = false
            lastRun = Date()
        }

        // Things that don't depend on each other start right away.
        async let traceTask = NetworkInfo.cloudflareTrace()
        async let ispTask = NetworkInfo.ispName()

        // 1. Link
        update(.link) { $0.state = .running }
        let path = await NetworkInfo.path()
        let route = await NetworkInfo.defaultRoute()
        let link = path.isWiFi ? WiFiScanner.currentLink() : nil
        var summary = ConnectionSummary(kind: path.kindLabel, name: link?.ssid, gateway: route.gateway)
        connection = summary
        var input = DiagnosisInput(online: path.online, isWiFi: path.isWiFi)
        if path.online {
            var value = path.kindLabel
            if let n = path.interfaceName { value += " · \(n)" }
            if path.usesVPN { value += " · VPN aktif" }
            finish(.link, .good, value, path.usesVPN ? "Lalu lintas lewat VPN; hasil bisa berbeda tanpa VPN." : "")
        } else {
            finish(.link, .poor, "Tidak terhubung", "Nyalakan Wi-Fi atau colok kabel LAN.")
            for k in DiagStep.Kind.allCases where k != .link { update(k) { $0.state = .skipped } }
            diagnosis = Diagnoser.evaluate(input)
            return
        }

        // 2. Wi-Fi signal
        if let link, link.isAssociated {
            input.wifiRSSI = link.rssi
            let h = SignalQuality.health(rssi: link.rssi)
            var detail = "Noise \(link.noise) dBm · SNR \(link.snr) dB"
            if let ch = link.channel, let band = link.band { detail += " · Channel \(ch) (\(band.rawValue))" }
            finish(.wifi, h, "\(link.rssi) dBm · \(SignalQuality.label(rssi: link.rssi))", detail)
        } else {
            update(.wifi) {
                $0.state = .skipped
                $0.value = path.isWiFi ? "Tidak terbaca" : "Tidak dipakai"
            }
        }

        // 3. Router
        update(.router) { $0.state = .running }
        if let gw = route.gateway, NetworkSetupParser.isIPAddress(gw) {
            update(.router) { $0.title = "Router (\(gw))" }
            let m = await Pinger.measure(gw, count: 10, tcpPort: 80)
            let r = m.result
            if r.received == 0 {
                input.gatewayLoss = m.method == "ICMP" ? 100 : nil
                finish(.router, m.method == "ICMP" ? .poor : .unknown, "Tidak membalas",
                       "Sebagian router memang tidak membalas ping. Kalau internet jalan, abaikan.")
            } else {
                input.gatewayLatency = r.median
                input.gatewayLoss = r.lossPercent
                let limit: Double = path.isWiFi ? 30 : 8
                let h: Health = r.lossPercent >= 10 ? .poor : ((r.median ?? 0) > limit ? .fair : .good)
                finish(.router, h, "\(Format.ms(r.median)) · \(Format.percent(r.lossPercent)) hilang",
                       "Min \(Format.ms(r.samples.min())) · maks \(Format.ms(r.samples.max())) · \(m.method)")
            }
        } else {
            finish(.router, .unknown, "Tidak terdeteksi", "Tidak ada gateway (mungkin lewat VPN).")
        }

        // 4. Internet
        update(.internet) {
            $0.state = .running
            $0.title = "Internet (1.1.1.1)"
        }
        let im = await Pinger.measure("1.1.1.1", count: 15, tcpPort: 443)
        let ir = im.result
        input.internetLatency = ir.median
        input.internetLoss = ir.lossPercent
        input.internetJitter = ir.jitter
        if ir.received == 0 {
            finish(.internet, .poor, "Tidak terjangkau", "Router terhubung tapi internet tidak bisa diakses.")
        } else {
            let lat = ir.median ?? 0
            var h: Health = .good
            if ir.lossPercent >= 10 || lat > 150 { h = .poor } else if lat > 80 || (ir.jitter ?? 0) > 30 { h = .fair }
            finish(.internet, h,
                   "\(Format.ms(ir.median)) · \(Format.percent(ir.lossPercent)) hilang",
                   "Jitter \(Format.ms(ir.jitter)) · \(im.method)")
        }

        // 5. DNS (random sub-domains force a real lookup instead of a cache hit)
        update(.dns) { $0.state = .running }
        var dnsTimes: [Double] = []
        var dnsFails = 0
        for base in ["google.com", "cloudflare.com", "apple.com", "detik.com"] {
            let host = "nb\(Int.random(in: 100_000...999_999)).\(base)"
            if let ms = await DNSProbe.systemLookup(host) { dnsTimes.append(ms) } else { dnsFails += 1 }
        }
        let resolvers = await NetworkInfo.activeResolvers()
        let resolverText = resolvers.prefix(2).joined(separator: ", ")
        if dnsTimes.isEmpty {
            input.dnsFailed = true
            finish(.dns, .poor, "Tidak menjawab", resolverText.isEmpty ? "" : "Server: \(resolverText)")
        } else {
            let med = Stats.median(dnsTimes)
            input.dnsMs = med
            let h: Health = (med ?? 0) > 200 ? .poor : ((med ?? 0) > 100 ? .fair : .good)
            finish(.dns, h, Format.ms(med), resolverText.isEmpty ? "" : "Server: \(resolverText)")
        }

        // 6. Web
        update(.web) { $0.state = .running }
        if let ms = await NetworkInfo.httpCheck() {
            input.httpMs = ms
            finish(.web, ms > 1500 ? .fair : .good, Format.ms(ms), "google.com, termasuk DNS + koneksi aman (TLS)")
        } else {
            input.httpFailed = true
            finish(.web, .poor, "Gagal", "Tidak bisa membuka google.com")
        }

        let trace = await traceTask
        summary.publicIP = trace?.ip
        summary.edge = trace?.colo
        summary.isp = await ispTask
        connection = summary

        diagnosis = Diagnoser.evaluate(input)
    }
}
