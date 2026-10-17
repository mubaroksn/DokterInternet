import AppKit
import CoreLocation
import Foundation
import NetCore

@MainActor
final class WiFiModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum LocationState {
        case unknown, granted, denied
    }

    @Published private(set) var link: WiFiLink?
    @Published private(set) var networks: [ObservedNetwork] = []
    @Published private(set) var advice24: ChannelAdvice?
    @Published private(set) var advice5: ChannelAdvice?
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?
    @Published var error: String?
    @Published private(set) var location: LocationState = .unknown
    @Published private(set) var gateway: String?
    /// Recent RSSI readings for the live signal line.
    @Published private(set) var rssiHistory: [Int] = []

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        location = Self.state(locationManager.authorizationStatus)
    }

    var hasWiFi: Bool { link != nil }

    /// CI screenshots only (`-demoWiFi YES`): the build machines have no Wi-Fi hardware.
    let demo = UserDefaults.standard.bool(forKey: "demoWiFi")

    func loadDemo() {
        link = WiFiLink(interfaceName: "en0", powerOn: true, ssid: "Rumah_5G", rssi: -63, noise: -92,
                        channel: 6, band: .ghz2, widthMHz: 20, txRateMbps: 144, phyMode: "Wi-Fi 6 (802.11ax)")
        rssiHistory = [-61, -62, -60, -64, -63, -66, -62, -61, -63, -65, -64, -62, -63]
        location = .granted
        gateway = "192.168.1.1"
        let sample: [(String, Int, WiFiBand, Int, Int)] = [
            ("Rumah_5G", 6, .ghz2, 20, -63), ("IndiHome-8F2A", 6, .ghz2, 20, -58), ("Kos Melati", 6, .ghz2, 20, -70),
            ("TP-Link_3C11", 5, .ghz2, 40, -74), ("Biznet-Home", 1, .ghz2, 20, -81), ("ZTE-a7c2", 6, .ghz2, 20, -77),
            ("Warung Kopi", 11, .ghz2, 20, -88), ("MyRepublic_4D", 3, .ghz2, 20, -84),
            ("IndiHome-8F2A_5G", 149, .ghz5, 80, -66), ("Kos Melati 5G", 36, .ghz5, 80, -79), ("Biznet-5G", 157, .ghz5, 40, -82),
        ]
        networks = sample.map { ObservedNetwork(ssid: $0.0, channel: $0.1, band: $0.2, widthMHz: $0.3, rssi: $0.4) }
        lastScan = Date()
        analyze()
    }

    func refreshLink() {
        if demo { return }
        link = WiFiScanner.currentLink()
        if let l = link, l.isAssociated {
            rssiHistory.append(l.rssi)
            if rssiHistory.count > 60 { rssiHistory.removeFirst(rssiHistory.count - 60) }
        }
    }

    func requestLocation() {
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func openRouterPage() {
        guard let gw = gateway, let url = URL(string: "http://\(gw)") else { return }
        NSWorkspace.shared.open(url)
    }

    func scan() async {
        if demo { loadDemo(); return }
        guard !scanning else { return }
        scanning = true
        error = nil
        defer { scanning = false }
        refreshLink()
        if gateway == nil { gateway = await NetworkInfo.defaultRoute().gateway }
        do {
            let found = try await Task.detached(priority: .userInitiated) { try WiFiScanner.scan() }.value
            networks = found
            lastScan = Date()
            analyze()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func analyze() {
        let cur = link
        advice24 = ChannelAdvisor.advise(
            band: .ghz2, networks: networks,
            currentChannel: cur?.band == .ghz2 ? cur?.channel : nil,
            ownRSSI: cur?.band == .ghz2 ? cur?.rssi : nil)
        advice5 = ChannelAdvisor.advise(
            band: .ghz5, networks: networks,
            currentChannel: cur?.band == .ghz5 ? cur?.channel : nil,
            ownRSSI: cur?.band == .ghz5 ? cur?.rssi : nil)
    }

    /// The advice for the band the Mac is connected on.
    var activeAdvice: ChannelAdvice? {
        switch link?.band {
        case .ghz2: return advice24
        case .ghz5: return advice5
        default: return nil
        }
    }

    private static func state(_ s: CLAuthorizationStatus) -> LocationState {
        switch s {
        case .notDetermined: return .unknown
        case .denied, .restricted: return .denied
        default: return .granted
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            let newState = Self.state(s)
            let changed = newState != self.location
            self.location = newState
            if newState == .granted {
                self.locationManager.stopUpdatingLocation()
                if changed { await self.scan() }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
