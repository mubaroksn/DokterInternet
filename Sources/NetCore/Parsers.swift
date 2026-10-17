import Foundation

public struct PingResult: Sendable, Equatable {
    public var samples: [Double]   // round-trip times in ms, in order
    public var sent: Int
    public var received: Int

    public init(samples: [Double], sent: Int, received: Int) {
        self.samples = samples
        self.sent = sent
        self.received = received
    }

    public var lossPercent: Double {
        guard sent > 0 else { return 100 }
        return max(0, Double(sent - received) / Double(sent) * 100)
    }
    public var median: Double? { Stats.median(samples) }
    public var average: Double? { Stats.mean(samples) }
    public var jitter: Double? { Stats.jitter(samples) }
}

private func matches(_ pattern: String, in text: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

public enum PingParser {
    /// Parses the output of macOS `/sbin/ping`.
    public static func parse(_ output: String) -> PingResult? {
        let times = matches(#"time[=<]([0-9.]+) ?ms"#, in: output).compactMap { Double($0[1]) }
        if let summary = matches(#"([0-9]+) packets transmitted, ([0-9]+) (?:packets )?received"#, in: output).first,
           let sent = Int(summary[1]), let received = Int(summary[2]) {
            return PingResult(samples: times, sent: sent, received: received)
        }
        return times.isEmpty ? nil : PingResult(samples: times, sent: times.count, received: times.count)
    }
}

public struct DefaultRoute: Sendable, Equatable {
    public var gateway: String?
    public var interface: String?
}

public enum RouteParser {
    /// Parses `route -n get default`.
    public static func parse(_ output: String) -> DefaultRoute {
        var route = DefaultRoute()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "gateway": route.gateway = parts[1]
            case "interface": route.interface = parts[1]
            default: break
            }
        }
        return route
    }
}

public struct NetworkService: Sendable, Equatable {
    public var name: String
    public var hardwarePort: String
    public var device: String
    public var enabled: Bool
}

public enum NetworkSetupParser {
    /// Parses `networksetup -listnetworkserviceorder`.
    public static func services(_ output: String) -> [NetworkService] {
        var result: [NetworkService] = []
        var pendingName: String?
        var pendingEnabled = true
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = matches(#"^\((\d+|\*)\)\s+(.+)$"#, in: line).first {
                pendingName = m[2]
                pendingEnabled = m[1] != "*"
            } else if let m = matches(#"^\(Hardware Port: (.*), Device: (.*)\)$"#, in: line).first, let name = pendingName {
                result.append(NetworkService(name: name, hardwarePort: m[1], device: m[2], enabled: pendingEnabled))
                pendingName = nil
            }
        }
        return result
    }

    /// Parses `networksetup -getdnsservers <service>`. Empty means "automatic" (from DHCP).
    public static func dnsServers(_ output: String) -> [String] {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isIPAddress($0) }
    }

    /// Unique nameservers from `scutil --dns`, in order of appearance (the resolvers in actual use).
    public static func scutilNameservers(_ output: String) -> [String] {
        var seen: [String] = []
        for m in matches(#"nameserver\[\d+\]\s*:\s*(\S+)"#, in: output) where !seen.contains(m[1]) {
            seen.append(m[1])
        }
        return seen
    }

    public static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}

public struct TraceInfo: Sendable, Equatable {
    public var ip: String?
    public var colo: String?
    public var location: String?
}

public enum TraceParser {
    /// Parses Cloudflare's `/cdn-cgi/trace` key=value response.
    public static func parse(_ text: String) -> TraceInfo {
        var info = TraceInfo()
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "ip": info.ip = kv[1]
            case "colo": info.colo = kv[1]
            case "loc": info.location = kv[1]
            default: break
            }
        }
        return info
    }
}
