import Charts
import NetCore
import SwiftUI

struct WiFiPage: View {
    @ObservedObject var model: WiFiModel
    @EnvironmentObject var app: AppModel
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Page {
            PageHeader(title: "Wi-Fi",
                       subtitle: "Kekuatan sinyal dan seberapa padat channel Wi-Fi di sekitarmu. Channel yang padat bikin Wi-Fi lambat walau paket internetnya kencang.") {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(model.scanning ? "Memindai…" : "Pindai Jaringan", systemImage: model.scanning ? "hourglass" : "dot.radiowaves.left.and.right")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.scanning || !model.hasWiFi)
            }

            if !model.hasWiFi {
                Banner(icon: "wifi.slash", text: "Mac ini tidak punya Wi-Fi, atau Wi-Fi tidak bisa dibaca.", tint: Theme.neutral)
            } else {
                if model.location == .unknown {
                    Banner(icon: "location.fill",
                           text: "macOS hanya memberi nama jaringan Wi-Fi kalau app punya izin Lokasi. Lokasimu tidak disimpan atau dikirim ke mana pun.",
                           tint: Theme.accent, actionTitle: "Beri Izin") { model.requestLocation() }
                } else if model.location == .denied {
                    Banner(icon: "location.slash.fill",
                           text: "Izin Lokasi ditolak, jadi nama jaringan tidak terlihat. Analisa channel tetap jalan.",
                           tint: Theme.fair, actionTitle: "Buka Pengaturan") { model.openLocationSettings() }
                }

                if let link = model.link {
                    CurrentLinkCard(link: link, history: model.rssiHistory)
                }

                if let error = model.error {
                    Banner(icon: "exclamationmark.triangle.fill", text: error, tint: Theme.poor)
                }

                if let advice = model.activeAdvice {
                    AdviceCard(advice: advice, gateway: model.gateway) { model.openRouterPage() }
                }

                if model.lastScan != nil {
                    HStack(alignment: .top, spacing: 12) {
                        if let a = model.advice24 { ChannelChart(advice: a) }
                        if let a = model.advice5 { ChannelChart(advice: a) }
                    }
                    NetworkList(networks: model.networks, current: model.link)
                } else if !model.scanning {
                    Banner(icon: "dot.radiowaves.left.and.right",
                           text: "Klik Pindai Jaringan untuk melihat channel mana yang paling lowong.",
                           tint: Theme.accent)
                }
            }
        }
        .onAppear { model.refreshLink() }
        .onReceive(ticker) { _ in model.refreshLink() }
        .task {
            if model.demo {
                model.loadDemo()
                return
            }
            model.refreshLink()
            if model.lastScan == nil && model.hasWiFi { await model.scan() }
        }
    }
}

struct CurrentLinkCard: View {
    var link: WiFiLink
    var history: [Int]

    var body: some View {
        Card {
            if !link.powerOn {
                Text("Wi-Fi mati").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            } else if !link.isAssociated {
                Text("Wi-Fi menyala tapi belum terhubung ke jaringan").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            } else {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Terhubung ke")
                        HStack(spacing: 10) {
                            SignalBars(bars: SignalQuality.bars(rssi: link.rssi), tint: Theme.color(SignalQuality.health(rssi: link.rssi)))
                            Text(link.ssid ?? "Jaringan Wi-Fi")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.text)
                        }
                        HealthBadge(health: SignalQuality.health(rssi: link.rssi),
                                    text: "Sinyal \(SignalQuality.label(rssi: link.rssi).lowercased())")
                        if history.count >= 2 {
                            RSSIChart(values: history).frame(height: 60)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        KeyValueRow(key: "Kekuatan sinyal", value: "\(link.rssi) dBm")
                        KeyValueRow(key: "Noise / SNR", value: "\(link.noise) dBm / \(link.snr) dB")
                        KeyValueRow(key: "Channel", value: channelText)
                        KeyValueRow(key: "Kecepatan link", value: String(format: "%.0f Mbps", link.txRateMbps))
                        KeyValueRow(key: "Standar", value: link.phyMode)
                    }
                    .frame(width: 300)
                }
            }
        }
    }

    var channelText: String {
        guard let ch = link.channel else { return "–" }
        var s = "\(ch)"
        if let b = link.band { s += " · \(b.rawValue)" }
        if let w = link.widthMHz { s += " · \(w) MHz" }
        return s
    }
}

struct RSSIPoint: Identifiable {
    var id: Int
    var value: Int
}

struct RSSIChart: View {
    var values: [Int]

    var body: some View {
        Chart(values.enumerated().map { RSSIPoint(id: $0.offset, value: $0.element) }) { p in
            LineMark(x: .value("t", p.id), y: .value("dBm", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(Theme.accent)
        }
        .chartYScale(domain: -95 ... -30)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [-90, -70, -50]) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel().foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct AdviceCard: View {
    var advice: ChannelAdvice
    var gateway: String?
    var openRouter: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: advice.shouldSwitch ? "arrow.triangle.swap" : "checkmark.seal.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(advice.shouldSwitch ? Theme.fair : Theme.good)
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if advice.shouldSwitch {
                        Text("Cara: buka halaman admin router, cari menu Wireless / WLAN, ubah Channel dari Auto ke \(advice.recommended ?? 0), lalu simpan. Kalau router dari provider (IndiHome, Biznet, dll.), login-nya biasanya tertempel di bawah router.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if gateway != nil {
                            Button("Buka Halaman Router", action: openRouter)
                                .buttonStyle(SecondaryButtonStyle())
                                .padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    var headline: String {
        guard let cur = advice.current else { return "Analisa channel \(advice.band.rawValue)" }
        if advice.shouldSwitch, let rec = advice.recommended {
            return "Pindah dari channel \(cur) ke channel \(rec)"
        }
        return "Channel \(cur) sudah pilihan yang baik"
    }

    var detail: String {
        let others = advice.otherNetworks
        guard let cur = advice.current else { return "\(others) jaringan lain terdeteksi di \(advice.band.rawValue)." }
        let crowd = advice.loads.first { $0.channel == cur }?.networks ?? 0
        if advice.shouldSwitch, let rec = advice.recommended {
            let recCrowd = advice.loads.first { $0.channel == rec }?.networks ?? 0
            return "Ada \(crowd) jaringan lain tepat di channel \(cur), sedangkan channel \(rec) hanya \(recCrowd). Channel yang lebih sepi berarti lebih sedikit rebutan sinyal."
        }
        return "Dari \(others) jaringan lain di \(advice.band.rawValue), channel kamu termasuk yang paling sedikit gangguannya."
    }
}

struct ChannelChart: View {
    var advice: ChannelAdvice

    var body: some View {
        Card {
            HStack {
                SectionLabel(text: "Kepadatan \(advice.band.rawValue)")
                Spacer()
                Text("\(advice.otherNetworks) jaringan").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 10)
            Chart(advice.loads) { l in
                BarMark(x: .value("Channel", "\(l.channel)"), y: .value("Gangguan", l.score))
                    .foregroundStyle(color(l))
                    .cornerRadius(3)
                    .annotation(position: .top) {
                        if l.networks > 0 {
                            Text("\(l.networks)").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                        }
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(height: 150)
            HStack(spacing: 14) {
                legend(Theme.accent, "Channel kamu")
                legend(Theme.good, "Disarankan")
                legend(Theme.neutral.opacity(0.5), "Lainnya")
            }
            .padding(.top, 8)
        }
    }

    func color(_ l: ChannelLoad) -> Color {
        if l.channel == advice.current { return Theme.accent }
        if l.channel == advice.recommended { return Theme.good }
        return Theme.neutral.opacity(l.isCandidate ? 0.6 : 0.35)
    }

    func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(t).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
    }
}

struct NetworkList: View {
    var networks: [ObservedNetwork]
    var current: WiFiLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Jaringan di sekitar (\(networks.count))")
            Card(padding: 0) {
                HStack {
                    Text("Nama").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Band").frame(width: 70, alignment: .leading)
                    Text("Channel").frame(width: 70, alignment: .trailing)
                    Text("Lebar").frame(width: 70, alignment: .trailing)
                    Text("Sinyal").frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                ForEach(networks.prefix(40)) { n in
                    HStack {
                        Text(n.ssid ?? "(nama tersembunyi)")
                            .foregroundStyle(n.ssid == nil ? Theme.textTertiary : Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                        Text(n.band.rawValue).frame(width: 70, alignment: .leading)
                        Text("\(n.channel)").frame(width: 70, alignment: .trailing)
                        Text("\(n.widthMHz) MHz").frame(width: 70, alignment: .trailing)
                        HStack(spacing: 6) {
                            Text("\(n.rssi) dBm")
                            SignalBars(bars: SignalQuality.bars(rssi: n.rssi), tint: Theme.color(SignalQuality.health(rssi: n.rssi)))
                        }
                        .frame(width: 110, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                }
            }
        }
    }
}
