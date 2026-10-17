import Charts
import NetCore
import SwiftUI

struct SpeedTestPage: View {
    @ObservedObject var model: SpeedTestModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        Page {
            PageHeader(title: "Speed Test",
                       subtitle: "Mengukur kecepatan sebenarnya ke server Cloudflare terdekat. Simpan riwayatnya sebagai bukti kalau mau komplain ke provider.") {
                Button {
                    model.start()
                } label: {
                    Label(model.isRunning ? "Mengukur…" : (model.current == nil ? "Mulai Tes" : "Tes Lagi"),
                          systemImage: model.isRunning ? "hourglass" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isRunning)
            }

            Card {
                HStack(alignment: .center, spacing: 28) {
                    SpeedGauge(value: gaugeValue, progress: model.progress,
                               tint: model.phase == .upload ? Theme.upload : Theme.accent,
                               label: model.phase.label)
                        .frame(width: 230, height: 230)
                    VStack(alignment: .leading, spacing: 12) {
                        if let server = model.serverLabel {
                            Label(server, systemImage: "server.rack")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        LiveChart(points: model.livePoints)
                            .frame(height: 150)
                        if let m = failure {
                            Text(m).font(.system(size: 12)).foregroundStyle(Theme.poor)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                MetricTile(title: "Download", value: Format.mbps(model.current?.download), unit: "Mbps",
                           icon: "arrow.down.circle.fill", tint: Theme.accent)
                MetricTile(title: "Upload", value: Format.mbps(model.current?.upload), unit: "Mbps",
                           icon: "arrow.up.circle.fill", tint: Theme.upload)
                MetricTile(title: "Ping", value: number(model.current?.ping), unit: "ms",
                           icon: "timer", tint: Theme.good,
                           caption: model.current?.loss.map { "Paket hilang \(Format.percent($0))" })
                MetricTile(title: "Jitter", value: number(model.current?.jitter), unit: "ms",
                           icon: "waveform.path", tint: Theme.fair)
            }

            if model.phase == .done, let r = model.current {
                Banner(icon: "lightbulb.fill", text: explain(r), tint: Theme.accent)
            }

            if !model.history.isEmpty {
                HistorySection(model: model)
            }
        }
        .task {
            if app.autorun && model.current == nil { model.start() }
        }
    }

    var failure: String? {
        if case .failed(let m) = model.phase { return m }
        return nil
    }

    var gaugeValue: Double {
        switch model.phase {
        case .download, .upload: return model.liveMbps
        case .done: return model.current?.download ?? 0
        default: return 0
        }
    }

    func number(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }

    func explain(_ r: SpeedResult) -> String {
        guard let d = r.download else { return "" }
        var uses: [String] = []
        if d >= 25 { uses.append("streaming 4K") } else if d >= 5 { uses.append("streaming HD") }
        if d >= 50 { uses.append("download game besar") }
        if (r.upload ?? 0) >= 5 { uses.append("video call HD") }
        if (r.ping ?? 999) <= 50 { uses.append("game online") }
        let list = uses.isEmpty ? "browsing dan chat" : uses.joined(separator: ", ")
        return "Dengan \(Format.mbps(d)) Mbps kamu nyaman untuk \(list). Kalau jauh di bawah paket yang kamu bayar, jalankan Diagnosa untuk mencari penyebabnya."
    }
}

struct SpeedGauge: View {
    var value: Double
    var progress: Double
    var tint: Color
    var label: String

    /// Log-like scale so 5 Mbps and 500 Mbps both move the needle visibly.
    static let marks: [Double] = [0, 5, 10, 25, 50, 100, 250, 500, 1000]

    static func fraction(_ v: Double) -> Double {
        let m = marks
        guard v > 0 else { return 0 }
        for i in 1..<m.count where v <= m[i] {
            let local = (v - m[i - 1]) / (m[i] - m[i - 1])
            return (Double(i - 1) + local) / Double(m.count - 1)
        }
        return 1
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Theme.cardSunken, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * Self.fraction(value))
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeOut(duration: 0.3), value: value)
            Circle()
                .trim(from: 0, to: 0.75 * progress)
                .stroke(Theme.textTertiary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(-14)
            VStack(spacing: 2) {
                Text(value > 0 ? Format.mbps(value) : "0")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                Text("Mbps").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.top, 6)
            }
        }
        .padding(14)
    }
}

struct LiveChart: View {
    var points: [SpeedTestModel.LivePoint]

    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("Detik", p.t), y: .value("Mbps", p.mbps))
                .foregroundStyle(by: .value("Arah", p.upload ? "Upload" : "Download"))
                .opacity(0.18)
                .interpolationMethod(.monotone)
            LineMark(x: .value("Detik", p.t), y: .value("Mbps", p.mbps))
                .foregroundStyle(by: .value("Arah", p.upload ? "Upload" : "Download"))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(["Download": Theme.accent, "Upload": Theme.upload])
        .chartXScale(domain: 0...(SpeedConfig.downloadSeconds + SpeedConfig.uploadSeconds))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel().foregroundStyle(Theme.textTertiary)
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .overlay {
            if points.isEmpty {
                Text("Grafik kecepatan muncul di sini saat tes berjalan")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct HistoryPoint: Identifiable {
    var id: String
    var date: Date
    var mbps: Double
    var series: String
}

struct HistorySection: View {
    @ObservedObject var model: SpeedTestModel

    var historyPoints: [HistoryPoint] {
        model.history.reversed().flatMap { r -> [HistoryPoint] in
            var out: [HistoryPoint] = []
            if let d = r.download { out.append(HistoryPoint(id: r.id.uuidString + "d", date: r.date, mbps: d, series: "Download")) }
            if let u = r.upload { out.append(HistoryPoint(id: r.id.uuidString + "u", date: r.date, mbps: u, series: "Upload")) }
            return out
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Riwayat (\(model.history.count))")
                Spacer()
                Button("Hapus riwayat") { model.deleteHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let insight = model.slowestHourText {
                Banner(icon: "clock.fill", text: insight, tint: Theme.fair)
            }
            if model.history.count >= 2 {
                Card {
                    Chart(historyPoints) { p in
                        LineMark(x: .value("Waktu", p.date), y: .value("Mbps", p.mbps))
                            .foregroundStyle(by: .value("Arah", p.series))
                            .symbol(by: .value("Arah", p.series))
                    }
                    .chartForegroundStyleScale(["Download": Theme.accent, "Upload": Theme.upload])
                    .chartLegend(position: .top, alignment: .leading)
                    .frame(height: 160)
                }
            }
            Card(padding: 0) {
                HStack {
                    Text("Waktu").frame(width: 150, alignment: .leading)
                    Text("Jaringan").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Download").frame(width: 90, alignment: .trailing)
                    Text("Upload").frame(width: 90, alignment: .trailing)
                    Text("Ping").frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                ForEach(model.history.prefix(30)) { r in
                    HStack {
                        Text(r.date.formatted(date: .abbreviated, time: .shortened)).frame(width: 150, alignment: .leading)
                        Text(r.network ?? "–").frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text("\(Format.mbps(r.download)) Mbps").frame(width: 90, alignment: .trailing)
                        Text("\(Format.mbps(r.upload)) Mbps").frame(width: 90, alignment: .trailing)
                        Text(Format.ms(r.ping)).frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
