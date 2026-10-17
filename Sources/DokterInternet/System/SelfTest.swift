import Foundation
import NetCore

/// `DokterInternet --selftest`: runs the real network probes headlessly and prints one line per check.
/// Used by CI (which cannot click through the UI) to prove the probes work on a real Mac.
enum SelfTest {
    static func runAndExit() {
        Task {
            let ok = await run()
            exit(ok ? 0 : 1)
        }
        dispatchMain()
    }

    private static func line(_ name: String, _ ok: Bool, _ detail: String) {
        print("SELFTEST \(ok ? "PASS" : "FAIL") \(name): \(detail)")
        fflush(stdout)
    }

    static func run() async -> Bool {
        var allOK = true
        func check(_ name: String, _ ok: Bool, _ detail: String, required: Bool = true) {
            line(name, ok || !required, (ok ? "" : (required ? "" : "[optional] ")) + detail)
            if required && !ok { allOK = false }
        }

        let path = await NetworkInfo.path()
        check("path", path.online, "\(path.kindLabel) iface=\(path.interfaceName ?? "-") vpn=\(path.usesVPN)")

        let route = await NetworkInfo.defaultRoute()
        check("route", route.gateway != nil, "gateway=\(route.gateway ?? "-") iface=\(route.interface ?? "-")")

        let services = await NetworkInfo.services()
        let primary = await NetworkInfo.primaryService()
        check("services", !services.isEmpty, "\(services.map(\.name)) primary=\(primary?.name ?? "-")")
        if let p = primary {
            let dns = await NetworkInfo.configuredDNS(service: p.name)
            check("configuredDNS", true, dns.isEmpty ? "automatic" : dns.joined(separator: ","))
        }
        let active = await NetworkInfo.activeResolvers()
        check("activeResolvers", !active.isEmpty, active.joined(separator: ","))

        let icmp = await Pinger.icmp("1.1.1.1", count: 5)
        check("icmpPing", (icmp?.received ?? 0) > 0,
              "sent=\(icmp?.sent ?? 0) recv=\(icmp?.received ?? 0) median=\(Format.ms(icmp?.median))", required: false)
        let tcp = await Pinger.tcp("1.1.1.1", port: 443, count: 5)
        check("tcpPing", tcp.received > 0, "recv=\(tcp.received)/5 median=\(Format.ms(tcp.median)) jitter=\(Format.ms(tcp.jitter))")
        if let gw = route.gateway {
            let g = await Pinger.measure(gw, count: 5, tcpPort: 80)
            check("gatewayPing", g.result.received > 0, "\(g.method) recv=\(g.result.received)/5 median=\(Format.ms(g.result.median))", required: false)
        }

        for server in ["1.1.1.1", "8.8.8.8", "9.9.9.9"] {
            let ms = await DNSProbe.query(server: server, name: "google.com")
            check("dnsQuery \(server)", ms != nil, Format.ms(ms))
        }
        let sys = await DNSProbe.systemLookup("nb\(Int.random(in: 100_000...999_999)).google.com")
        check("systemLookup", sys != nil, Format.ms(sys))

        let http = await NetworkInfo.httpCheck()
        check("http", http != nil, Format.ms(http))
        let trace = await NetworkInfo.cloudflareTrace()
        check("trace", trace?.colo != nil, "colo=\(trace?.colo ?? "-") loc=\(trace?.location ?? "-")")
        let isp = await NetworkInfo.ispName()
        check("isp", isp != nil, isp ?? "-", required: false)

        let dl = await SpeedEngine.measure(.download, streams: 6, duration: 6, warmup: 1) { _ in }
        check("download", (dl ?? 0) > 1, "\(Format.mbps(dl)) Mbps")
        let ul = await SpeedEngine.measure(.upload, streams: 4, duration: 6, warmup: 1) { _ in }
        check("upload", (ul ?? 0) > 1, "\(Format.mbps(ul)) Mbps")

        let link = WiFiScanner.currentLink()
        check("wifiLink", true, link.map { "iface=\($0.interfaceName) power=\($0.powerOn) rssi=\($0.rssi)" } ?? "no Wi-Fi hardware", required: false)

        let admin = Shell.shellQuote("Wi-Fi's \"name\"")
        check("shellQuote", admin == "'Wi-Fi'\\''s \"name\"'", admin)

        return allOK
    }
}
