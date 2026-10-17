import Foundation
import Network
import NetCore

enum Pinger {
    struct Measurement: Sendable {
        var result: PingResult
        /// "ICMP" or "TCP" — TCP is the fallback when ping is blocked.
        var method: String
    }

    /// ICMP ping via /sbin/ping (no root needed), falling back to TCP connect timing.
    static func measure(_ host: String, count: Int = 10, tcpPort: UInt16 = 443) async -> Measurement {
        if let r = await icmp(host, count: count), r.received > 0 {
            return Measurement(result: r, method: "ICMP")
        }
        let r = await tcp(host, port: tcpPort, count: count)
        return Measurement(result: r, method: "TCP")
    }

    static func icmp(_ host: String, count: Int, interval: Double = 0.2) async -> PingResult? {
        let args = ["-n", "-c", "\(count)", "-i", String(format: "%.1f", interval), "-W", "1000", host]
        let out = await Shell.run("/sbin/ping", args, timeout: Double(count) * max(interval, 1) + 6)
        if let r = PingParser.parse(out.stdout) { return r }
        // Some macOS versions refuse sub-second intervals for normal users: retry at 1 s.
        if interval < 1, !out.stderr.isEmpty {
            return await icmp(host, count: min(count, 5), interval: 1)
        }
        return nil
    }

    static func tcp(_ host: String, port: UInt16, count: Int) async -> PingResult {
        var samples: [Double] = []
        for i in 0..<count {
            if let ms = await tcpConnect(host, port: port, timeout: 2) { samples.append(ms) }
            if i < count - 1 { try? await Task.sleep(nanoseconds: 150_000_000) }
        }
        return PingResult(samples: samples, sent: count, received: samples.count)
    }

    /// Time to complete a TCP handshake (≈ one round trip).
    static func tcpConnect(_ host: String, port: UInt16, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let once = OnceFlag()
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .https, using: .tcp)
            let t0 = DispatchTime.now().uptimeNanoseconds
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                    if once.claim() { conn.cancel(); cont.resume(returning: ms) }
                case .failed, .waiting, .cancelled:
                    if once.claim() { conn.cancel(); cont.resume(returning: nil) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { conn.cancel(); cont.resume(returning: nil) }
            }
        }
    }
}

enum DNSProbe {
    /// One UDP DNS query straight to `server`; returns the round-trip time in ms, or nil on timeout/error.
    static func query(server: String, name: String, timeout: TimeInterval = 2) async -> Double? {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let once = OnceFlag()
            let id = UInt16.random(in: 1...UInt16.max)
            let packet = DNSPacket.query(id: id, name: name)
            let conn = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
            func finish(_ v: Double?) {
                if once.claim() {
                    conn.cancel()
                    cont.resume(returning: v)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    conn.receiveMessage { data, _, _, error in
                        guard error == nil, let data, DNSPacket.isUsableReply(data, expectedID: id) else {
                            finish(nil)
                            return
                        }
                        finish(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
                    }
                    conn.send(content: packet, completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Time for the system resolver (what apps actually use) to answer, in ms.
    /// A random sub-domain forces a full lookup instead of a cache hit; "no such name" still counts as answered.
    static func systemLookup(_ host: String) async -> Double? {
        await Task.detached(priority: .userInitiated) { () -> Double? in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            let t0 = DispatchTime.now().uptimeNanoseconds
            let rc = getaddrinfo(host, "443", &hints, &res)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            if let res { freeaddrinfo(res) }
            return (rc == 0 || rc == EAI_NONAME) && ms < 5000 ? ms : nil
        }.value
    }
}

struct PathInfo: Sendable {
    var online: Bool
    var isWiFi: Bool
    var isWired: Bool
    var interfaceName: String?
    var isExpensive: Bool
    var usesVPN: Bool

    var kindLabel: String {
        if !online { return "Tidak terhubung" }
        if isWiFi { return "Wi-Fi" }
        if isWired { return "Kabel LAN" }
        return "Jaringan lain"
    }
}

enum NetworkInfo {
    static func path() async -> PathInfo {
        await withCheckedContinuation { (cont: CheckedContinuation<PathInfo, Never>) in
            let once = OnceFlag()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { p in
                guard once.claim() else { return }
                let info = PathInfo(
                    online: p.status == .satisfied,
                    isWiFi: p.usesInterfaceType(.wifi),
                    isWired: p.usesInterfaceType(.wiredEthernet),
                    interfaceName: p.availableInterfaces.first?.name,
                    isExpensive: p.isExpensive,
                    usesVPN: p.availableInterfaces.first.map { $0.name.hasPrefix("utun") || $0.name.hasPrefix("ipsec") } ?? false
                )
                monitor.cancel()
                cont.resume(returning: info)
            }
            monitor.start(queue: .global())
        }
    }

    static func defaultRoute() async -> DefaultRoute {
        RouteParser.parse(await Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 5).stdout)
    }

    static func services() async -> [NetworkService] {
        NetworkSetupParser.services(await Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"], timeout: 10).stdout)
    }

    /// The network service (as named in System Settings) that carries the default route.
    static func primaryService() async -> NetworkService? {
        let route = await defaultRoute()
        let all = await services()
        if let dev = route.interface, let s = all.first(where: { $0.device == dev }) { return s }
        return all.first(where: { $0.enabled && $0.hardwarePort == "Wi-Fi" }) ?? all.first(where: { $0.enabled })
    }

    /// DNS servers set manually on a service; empty means automatic (from the router/ISP).
    static func configuredDNS(service: String) async -> [String] {
        NetworkSetupParser.dnsServers(await Shell.run("/usr/sbin/networksetup", ["-getdnsservers", service], timeout: 10).stdout)
    }

    /// Resolvers macOS is actually using right now.
    static func activeResolvers() async -> [String] {
        NetworkSetupParser.scutilNameservers(await Shell.run("/usr/sbin/scutil", ["--dns"], timeout: 5).stdout)
    }

    static func cloudflareTrace() async -> TraceInfo? {
        guard let url = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let result = try? await URLSession(configuration: .ephemeral).data(for: req) else { return nil }
        return TraceParser.parse(String(decoding: result.0, as: UTF8.self))
    }

    /// Internet provider name, e.g. "PT Telkom Indonesia" (best effort).
    static func ispName() async -> String? {
        guard let url = URL(string: "https://ipinfo.io/json") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession(configuration: .ephemeral).data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let org = obj["org"] as? String else { return nil }
        // "AS7713 PT Telekomunikasi Indonesia" -> drop the AS number
        let parts = org.split(separator: " ", maxSplits: 1)
        return parts.count == 2 && parts[0].hasPrefix("AS") ? String(parts[1]) : org
    }

    /// Wall time of a small HTTPS request (DNS + TLS + first byte).
    static func httpCheck() async -> Double? {
        guard let url = URL(string: "https://www.google.com/generate_204") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral)
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let result = try? await session.data(for: req),
              let http = result.1 as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }
}
