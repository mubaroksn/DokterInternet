import AppKit
import NetCore
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case diagnose, speed, dns, wifi
    var id: String { rawValue }

    var title: String {
        switch self {
        case .diagnose: return "Diagnosa"
        case .speed: return "Speed Test"
        case .dns: return "DNS"
        case .wifi: return "Wi-Fi"
        }
    }

    var icon: String {
        switch self {
        case .diagnose: return "stethoscope"
        case .speed: return "speedometer"
        case .dns: return "globe.asia.australia"
        case .wifi: return "wifi"
        }
    }

    var caption: String {
        switch self {
        case .diagnose: return "Cari sumber masalah"
        case .speed: return "Download, upload, ping"
        case .dns: return "Uji & ganti DNS"
        case .wifi: return "Sinyal & channel"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var page: AppPage
    let diagnostics = DiagnosticsModel()
    let speed = SpeedTestModel()
    let dns = DNSModel()
    let wifi = WiFiModel()
    /// CI screenshots: start the selected page's main action automatically.
    let autorun = UserDefaults.standard.bool(forKey: "autorun")

    init() {
        page = AppPage(rawValue: UserDefaults.standard.string(forKey: "startPage") ?? "") ?? .diagnose
    }

    func go(_ action: FindingAction) {
        switch action {
        case .openDNS: page = .dns
        case .openWiFi: page = .wifi
        case .openSpeedTest: page = .speed
        case .none: break
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 232)
                .background(Theme.sidebar)
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                switch app.page {
                case .diagnose: DiagnosticsPage(model: app.diagnostics)
                case .speed: SpeedTestPage(model: app.speed)
                case .dns: DNSPage(model: app.dns)
                case .wifi: WiFiPage(model: app.wifi)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x3B6CFF)), Color(nsColor: NSColor(hex: 0x14B8A6))],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "bolt.horizontal.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                Text("Dokter Internet").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.top, 46)
            .padding(.bottom, 18)

            VStack(spacing: 4) {
                ForEach(AppPage.allCases) { p in
                    SidebarItem(page: p, selected: app.page == p) { app.page = p }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Text("Mengukur dan memperbaiki, bukan sulap. Kecepatan maksimal tetap ditentukan paket internetmu.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct SidebarItem: View {
    var page: AppPage
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: page.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(page.caption).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.accentSoft : (hover ? Theme.cardSunken : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
