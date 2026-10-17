import Foundation
import NetCore

struct DNSRow: Identifiable, Equatable {
    var provider: DNSProvider
    var median: Double?
    var failures = 0
    var total = 0
    var testing = false
    var id: String { provider.id }

    var tested: Bool { total > 0 }
    var reliability: Double? { total > 0 ? Double(total - failures) / Double(total) : nil }
}

struct StatusMessage: Equatable {
    var text: String
    var isError: Bool
}

@MainActor
final class DNSModel: ObservableObject {
    @Published private(set) var service: NetworkService?
    @Published private(set) var configured: [String] = []
    @Published private(set) var active: [String] = []
    @Published private(set) var rows: [DNSRow] = DNSProvider.presets.map { DNSRow(provider: $0) }
    @Published private(set) var testing = false
    @Published private(set) var applying = false
    @Published var message: StatusMessage?
    @Published private(set) var loaded = false

    var isAutomatic: Bool { configured.isEmpty }

    /// Provider whose servers match what is configured now, if any.
    var currentProvider: DNSProvider? {
        guard let first = configured.first else { return nil }
        return DNSProvider.presets.first { $0.servers.contains(first) }
    }

    var fastest: DNSRow? {
        rows.filter { $0.median != nil && ($0.reliability ?? 0) >= 0.9 }.min { ($0.median ?? .infinity) < ($1.median ?? .infinity) }
    }

    func refresh() async {
        let svc = await NetworkInfo.primaryService()
        service = svc
        if let svc {
            configured = await NetworkInfo.configuredDNS(service: svc.name)
        } else {
            configured = []
        }
        active = await NetworkInfo.activeResolvers()
        loaded = true

        // Show the resolver currently in use (router/ISP) as its own row so it can be compared.
        let presetIPs = Set(DNSProvider.presets.flatMap(\.servers))
        let base = rows.filter { !$0.provider.isCustom }
        var extra: [DNSRow] = []
        if let ip = active.first(where: { !presetIPs.contains($0) && !$0.contains(":") }) {
            let old = rows.first { $0.provider.isCustom && $0.provider.servers == [ip] }
            extra.append(old ?? DNSRow(provider: DNSProvider(
                name: isAutomatic ? "Bawaan (router/ISP)" : "Yang dipakai sekarang",
                servers: [ip],
                note: Self.describe(ip),
                isCustom: true)))
        }
        rows = extra + base
    }

    static func describe(_ ip: String) -> String {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
            return "Router kamu meneruskan ke DNS provider"
        }
        if ip.hasPrefix("100.") { return "DNS dari provider (mis. Starlink)" }
        return "DNS dari provider internet"
    }

    func testAll() async {
        guard !testing else { return }
        testing = true
        message = nil
        for i in rows.indices {
            rows[i].testing = true
            rows[i].median = nil
            rows[i].failures = 0
            rows[i].total = 0
        }
        let targets = rows.map { (id: $0.id, server: $0.provider.servers[0]) }
        await withTaskGroup(of: (String, [Double], Int).self) { group in
            for t in targets {
                group.addTask {
                    var times: [Double] = []
                    var fails = 0
                    // Two passes: the first may need a full lookup, the second shows cached speed.
                    for _ in 0..<2 {
                        for domain in DNSProvider.testDomains {
                            if let ms = await DNSProbe.query(server: t.server, name: domain, timeout: 1.5) {
                                times.append(ms)
                            } else {
                                fails += 1
                            }
                        }
                    }
                    return (t.id, times, fails)
                }
            }
            for await (id, times, fails) in group {
                if let i = rows.firstIndex(where: { $0.id == id }) {
                    rows[i].median = Stats.median(times)
                    rows[i].failures = fails
                    rows[i].total = times.count + fails
                    rows[i].testing = false
                }
            }
        }
        // Fastest first; untested/failed last.
        rows.sort { ($0.median ?? .infinity) < ($1.median ?? .infinity) }
        testing = false
        if let best = fastest {
            if let cur = currentProvider, cur.id == best.provider.id {
                message = StatusMessage(text: "Kamu sudah memakai DNS tercepat (\(best.provider.name)).", isError: false)
            } else if best.provider.isCustom {
                message = StatusMessage(text: "DNS yang dipakai sekarang sudah paling cepat. Tidak perlu diganti.", isError: false)
            } else {
                message = StatusMessage(text: "Tercepat dari lokasimu: \(best.provider.name) (\(Format.ms(best.median))). Klik Pakai untuk menggantinya.", isError: false)
            }
        } else {
            message = StatusMessage(text: "Tidak ada DNS yang menjawab. Cek koneksi internet, atau provider memblokir DNS luar.", isError: true)
        }
    }

    func apply(_ provider: DNSProvider) async {
        guard let svc = service else {
            message = StatusMessage(text: "Tidak menemukan koneksi aktif untuk diubah.", isError: true)
            return
        }
        let ips = provider.servers.joined(separator: " ")
        let cmd = "/usr/sbin/networksetup -setdnsservers \(Shell.shellQuote(svc.name)) \(ips); " + Self.flushCommand
        await runAdmin(cmd, prompt: "Dokter Internet ingin mengganti DNS \(svc.name) ke \(provider.name).",
                       success: "DNS \(svc.name) sekarang \(provider.name). Berlaku langsung, tidak perlu restart.")
    }

    func resetAutomatic() async {
        guard let svc = service else { return }
        let cmd = "/usr/sbin/networksetup -setdnsservers \(Shell.shellQuote(svc.name)) Empty; " + Self.flushCommand
        await runAdmin(cmd, prompt: "Dokter Internet ingin mengembalikan DNS \(svc.name) ke otomatis.",
                       success: "DNS dikembalikan ke otomatis (dari router/provider).")
    }

    func flushCache() async {
        await runAdmin(Self.flushCommand, prompt: "Dokter Internet ingin membersihkan cache DNS.",
                       success: "Cache DNS dibersihkan. Situs akan dicari ulang dari awal.")
    }

    static let flushCommand = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder; true"

    private func runAdmin(_ cmd: String, prompt: String, success: String) async {
        applying = true
        defer { applying = false }
        switch await Shell.runAsAdmin(cmd, prompt: prompt) {
        case .ok:
            message = StatusMessage(text: success, isError: false)
        case .cancelled:
            message = StatusMessage(text: "Dibatalkan.", isError: false)
        case .failed(let m):
            message = StatusMessage(text: "Gagal: \(m)", isError: true)
        }
        await refresh()
    }
}
