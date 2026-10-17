import NetCore
import SwiftUI

struct DNSPage: View {
    @ObservedObject var model: DNSModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        Page {
            PageHeader(title: "DNS",
                       subtitle: "DNS menerjemahkan nama situs jadi alamat. DNS yang cepat membuat situs mulai terbuka lebih cepat — tidak menambah kecepatan download.") {
                Button {
                    Task { await model.testAll() }
                } label: {
                    Label(model.testing ? "Menguji…" : "Uji Semua DNS", systemImage: model.testing ? "hourglass" : "bolt.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.testing || model.applying)
            }

            CurrentDNSCard(model: model)

            if let msg = model.message {
                Banner(icon: msg.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                       text: msg.text, tint: msg.isError ? Theme.poor : Theme.good)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Pilihan DNS")
                Card(padding: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                        DNSRowView(row: row,
                                   maxMs: maxMs,
                                   isFastest: model.fastest?.id == row.id,
                                   isCurrent: isCurrent(row),
                                   busy: model.applying || model.testing) {
                            Task {
                                if row.provider.isCustom { await model.resetAutomatic() } else { await model.apply(row.provider) }
                            }
                        }
                        if i < model.rows.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
            }

            Text("Mengganti DNS membutuhkan password Mac kamu (sekali per perubahan). Pengaturan berlaku untuk koneksi \(model.service?.name ?? "aktif") dan bisa dikembalikan kapan saja.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            if !model.loaded { await model.refresh() }
            if app.autorun && !model.testing && model.rows.allSatisfy({ !$0.tested }) { await model.testAll() }
        }
    }

    var maxMs: Double {
        max(60, model.rows.compactMap(\.median).max() ?? 60)
    }

    func isCurrent(_ row: DNSRow) -> Bool {
        if row.provider.isCustom { return model.isAutomatic }
        return model.currentProvider?.id == row.provider.id
    }
}

struct CurrentDNSCard: View {
    @ObservedObject var model: DNSModel

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Dipakai sekarang")
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(model.active.isEmpty ? "–" : model.active.prefix(3).joined(separator: " · "))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                    if let svc = model.service {
                        Text("Koneksi: \(svc.name)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Bersihkan Cache DNS") { Task { await model.flushCache() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Hapus catatan alamat lama. Berguna kalau ada situs yang tidak mau terbuka.")
                    if !model.isAutomatic {
                        Button("Kembalikan ke Otomatis") { Task { await model.resetAutomatic() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .disabled(model.applying)
            }
        }
    }

    var title: String {
        if !model.loaded { return "Memuat…" }
        if model.isAutomatic { return "Otomatis (dari router/provider)" }
        if let p = model.currentProvider { return p.name }
        return model.configured.joined(separator: ", ")
    }
}

struct DNSRowView: View {
    var row: DNSRow
    var maxMs: Double
    var isFastest: Bool
    var isCurrent: Bool
    var busy: Bool
    var onApply: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.provider.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    if isFastest { HealthBadge(health: .good, text: "Tercepat") }
                    if isCurrent { HealthBadge(health: .unknown, text: "Dipakai") }
                }
                Text("\(row.provider.servers.joined(separator: ", ")) · \(row.provider.note)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(minWidth: 260, alignment: .leading)

            Spacer(minLength: 8)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.cardSunken).frame(height: 6)
                if let ms = row.median {
                    Capsule()
                        .fill(color(ms))
                        .frame(width: max(6, 160 * min(1, ms / maxMs)), height: 6)
                }
            }
            .frame(width: 160)

            Group {
                if row.testing {
                    ProgressView().controlSize(.small)
                } else if let ms = row.median {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Format.ms(ms)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                        if row.failures > 0 {
                            Text("\(row.failures) gagal").font(.system(size: 10)).foregroundStyle(Theme.fair)
                        }
                    }
                } else if row.tested {
                    Text("Tidak menjawab").font(.system(size: 12)).foregroundStyle(Theme.poor)
                } else {
                    Text("–").foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 90, alignment: .trailing)

            Button(row.provider.isCustom ? "Otomatis" : "Pakai", action: onApply)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(busy || isCurrent)
                .opacity(isCurrent ? 0.4 : 1)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    func color(_ ms: Double) -> Color {
        ms <= 40 ? Theme.good : (ms <= 100 ? Theme.fair : Theme.poor)
    }
}
