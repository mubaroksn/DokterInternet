import CoreWLAN
import Foundation
import NetCore

struct WiFiLink: Sendable, Equatable {
    var interfaceName: String
    var powerOn: Bool
    var ssid: String?
    var rssi: Int
    var noise: Int
    var channel: Int?
    var band: WiFiBand?
    var widthMHz: Int?
    var txRateMbps: Double
    var phyMode: String

    var snr: Int { rssi - noise }
    var isAssociated: Bool { channel != nil && rssi != 0 }
}

enum WiFiScanner {
    static func band(_ b: CWChannelBand) -> WiFiBand? {
        switch b {
        case .band2GHz: return .ghz2
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        default: return nil
        }
    }

    static func width(_ w: CWChannelWidth) -> Int {
        switch w {
        case .width20MHz: return 20
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        default: return 20
        }
    }

    static func phy(_ m: CWPHYMode) -> String {
        switch m {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "Wi-Fi 4 (802.11n)"
        case .mode11ac: return "Wi-Fi 5 (802.11ac)"
        case .mode11ax: return "Wi-Fi 6 (802.11ax)"
        default: return "–"
        }
    }

    /// The Mac's current Wi-Fi link, or nil when there is no Wi-Fi hardware.
    static func currentLink() -> WiFiLink? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        let ch = iface.wlanChannel()
        return WiFiLink(
            interfaceName: iface.interfaceName ?? "en0",
            powerOn: iface.powerOn(),
            ssid: iface.ssid(),
            rssi: iface.rssiValue(),
            noise: iface.noiseMeasurement(),
            channel: ch?.channelNumber,
            band: ch.flatMap { band($0.channelBand) },
            widthMHz: ch.map { width($0.channelWidth) },
            txRateMbps: iface.transmitRate(),
            phyMode: phy(iface.activePHYMode())
        )
    }

    enum ScanError: Error, LocalizedError {
        case noInterface
        case poweredOff
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noInterface: return "Mac ini tidak punya Wi-Fi."
            case .poweredOff: return "Wi-Fi sedang mati. Nyalakan dulu untuk memindai."
            case .failed(let m): return "Gagal memindai: \(m)"
            }
        }
    }

    /// Scans nearby networks (blocking for a few seconds — call off the main thread).
    static func scan() throws -> [ObservedNetwork] {
        guard let iface = CWWiFiClient.shared().interface() else { throw ScanError.noInterface }
        guard iface.powerOn() else { throw ScanError.poweredOff }
        let found: Set<CWNetwork>
        do {
            found = try iface.scanForNetworks(withSSID: nil)
        } catch {
            throw ScanError.failed(error.localizedDescription)
        }
        return found.compactMap { n -> ObservedNetwork? in
            guard let ch = n.wlanChannel, let b = band(ch.channelBand) else { return nil }
            return ObservedNetwork(
                id: n.bssid ?? UUID().uuidString,
                ssid: n.ssid,
                channel: ch.channelNumber,
                band: b,
                widthMHz: width(ch.channelWidth),
                rssi: n.rssiValue
            )
        }
        .sorted { $0.rssi > $1.rssi }
    }
}
