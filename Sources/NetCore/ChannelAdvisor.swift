import Foundation

public enum WiFiBand: String, Codable, Sendable, CaseIterable {
    case ghz2 = "2.4 GHz"
    case ghz5 = "5 GHz"
    case ghz6 = "6 GHz"
}

public struct ObservedNetwork: Sendable, Hashable, Identifiable {
    public var id: String
    public var ssid: String?
    public var channel: Int
    public var band: WiFiBand
    public var widthMHz: Int
    public var rssi: Int

    public init(id: String = UUID().uuidString, ssid: String?, channel: Int, band: WiFiBand, widthMHz: Int, rssi: Int) {
        self.id = id
        self.ssid = ssid
        self.channel = channel
        self.band = band
        self.widthMHz = widthMHz
        self.rssi = rssi
    }
}

public struct ChannelLoad: Sendable, Identifiable, Equatable {
    public var id: Int { channel }
    public var channel: Int
    /// Networks whose primary channel is exactly this one.
    public var networks: Int
    /// Signal-weighted interference felt on this channel (overlap included). Lower is better.
    public var score: Double
    public var isCandidate: Bool
}

public struct ChannelAdvice: Sendable, Equatable {
    public var band: WiFiBand
    public var loads: [ChannelLoad]
    public var recommended: Int?
    public var current: Int?
    public var currentScore: Double?
    public var recommendedScore: Double?
    public var shouldSwitch: Bool
    public var otherNetworks: Int
}

public enum ChannelAdvisor {
    public static let candidates2 = [1, 6, 11]
    /// Non-DFS 5 GHz channels most routers allow (Indonesia mostly permits 149–165 only).
    public static let candidates5 = [36, 40, 44, 48, 149, 153, 157, 161, 165]

    static let groups80: [[Int]] = [
        [36, 40, 44, 48], [52, 56, 60, 64], [100, 104, 108, 112],
        [116, 120, 124, 128], [132, 136, 140, 144], [149, 153, 157, 161],
    ]
    static let groups160: [[Int]] = [
        [36, 40, 44, 48, 52, 56, 60, 64], [100, 104, 108, 112, 116, 120, 124, 128],
    ]

    /// How strongly a network's signal interferes: -50 dBm ≈ 1.0, -90 dBm ≈ 0.2.
    public static func weight(_ rssi: Int) -> Double {
        min(1.5, max(0.1, Double(rssi + 100) / 50))
    }

    /// 2.4 GHz channels are 5 MHz apart but 20 MHz wide, so neighbours within 4 channels overlap.
    public static func overlap2(_ a: Int, _ b: Int) -> Double {
        let d = abs(a - b)
        return d >= 5 ? 0 : 1 - Double(d) / 5
    }

    /// The 20 MHz channels a 5 GHz network occupies, given its primary channel and width.
    public static func occupied5(channel: Int, width: Int) -> [Int] {
        if width >= 160, let g = groups160.first(where: { $0.contains(channel) }) { return g }
        if width >= 80, let g = groups80.first(where: { $0.contains(channel) }) { return g }
        if width >= 40, let g = groups80.first(where: { $0.contains(channel) }), let i = g.firstIndex(of: channel) {
            let start = (i / 2) * 2
            return Array(g[start..<start + 2])
        }
        return [channel]
    }

    public static func advise(band: WiFiBand, networks all: [ObservedNetwork], currentChannel: Int?, ownRSSI: Int?) -> ChannelAdvice {
        var networks = all.filter { $0.band == band }

        // Drop our own access point from the neighbours (same channel, closest signal).
        if let cur = currentChannel {
            let mine = networks.enumerated()
                .filter { $0.element.channel == cur }
                .min { abs($0.element.rssi - (ownRSSI ?? -50)) < abs($1.element.rssi - (ownRSSI ?? -50)) }
            if let mine, abs(mine.element.rssi - (ownRSSI ?? mine.element.rssi)) <= 6 {
                networks.remove(at: mine.offset)
            }
        }

        let candidates: [Int]
        var chartChannels: [Int]
        switch band {
        case .ghz2:
            candidates = candidates2
            chartChannels = Array(1...13)
        case .ghz5:
            candidates = candidates5
            chartChannels = candidates5
        case .ghz6:
            candidates = []
            chartChannels = []
        }
        for n in networks where !chartChannels.contains(n.channel) { chartChannels.append(n.channel) }
        if let cur = currentChannel, !chartChannels.contains(cur) { chartChannels.append(cur) }
        chartChannels.sort()

        func score(_ ch: Int) -> Double {
            networks.reduce(0) { total, n in
                switch band {
                case .ghz2:
                    return total + weight(n.rssi) * overlap2(ch, n.channel)
                default:
                    return total + (occupied5(channel: n.channel, width: n.widthMHz).contains(ch) ? weight(n.rssi) : 0)
                }
            }
        }

        let loads = chartChannels.map { ch in
            ChannelLoad(
                channel: ch,
                networks: networks.filter { $0.channel == ch }.count,
                score: (score(ch) * 100).rounded() / 100,
                isCandidate: candidates.contains(ch)
            )
        }

        // Best candidate; ties prefer staying put, then the lower channel.
        let best = candidates.min { a, b in
            let sa = score(a), sb = score(b)
            if abs(sa - sb) > 0.001 { return sa < sb }
            if a == currentChannel { return true }
            if b == currentChannel { return false }
            return a < b
        }

        let currentScore = currentChannel.map(score)
        let bestScore = best.map(score)
        var shouldSwitch = false
        if let best, let cur = currentChannel, let cs = currentScore, let bs = bestScore, best != cur {
            shouldSwitch = cs - bs >= 0.6
        }

        return ChannelAdvice(
            band: band,
            loads: loads,
            recommended: best,
            current: currentChannel,
            currentScore: currentScore,
            recommendedScore: bestScore,
            shouldSwitch: shouldSwitch,
            otherNetworks: networks.count
        )
    }
}

public enum SignalQuality {
    public static func health(rssi: Int) -> Health {
        if rssi >= -67 { return .good }
        if rssi >= -75 { return .fair }
        return .poor
    }

    public static func label(rssi: Int) -> String {
        switch rssi {
        case (-60)...: return "Sangat bagus"
        case (-67)...: return "Bagus"
        case (-75)...: return "Cukup"
        case (-82)...: return "Lemah"
        default: return "Sangat lemah"
        }
    }

    /// 0...4 bars for a signal icon.
    public static func bars(rssi: Int) -> Int {
        switch rssi {
        case (-60)...: return 4
        case (-67)...: return 3
        case (-75)...: return 2
        case (-85)...: return 1
        default: return 0
        }
    }
}
