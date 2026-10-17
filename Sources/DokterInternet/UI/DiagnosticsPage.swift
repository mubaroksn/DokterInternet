import NetCore
import SwiftUI

struct DiagnosticsPage: View {
    @ObservedObject var model: DiagnosticsModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        Page {
            PageHeader(title: "Diagnosa",
                       subtitle: "Memeriksa Wi-Fi, router, internet, dan DNS satu per satu untuk menemukan di mana lambatnya.") {
                Button {
                    Task { await model.run() }
                } label: {
                    Label(model.running ? "Memeriksa…" : (model.lastRun == nil ? "Mulai Diagnosa" : "Periksa Lagi"),
                          systemImage: model.running ? "hourglass" : "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.running)
            }

            if let d = model.diagnosis {
                VerdictCard(diagnosis: d) { app.go($0) }
            } else if !model.running && model.lastRun == nil {
                Banner(icon: "info.circle.fill",
                       text: "Klik Mulai Diagnosa. Butuh sekitar 15 detik dan tidak mengubah pengaturan apa pun.",
                       tint: Theme.accent)
            }

            if let c = model.connection {
                ConnectionCard(summary: c)
            }

            Card(padding: 6) {
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { i, step in
                    StepRow(step: step)
                    if i < model.steps.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
        .task {
            if app.autorun && model.lastRun == nil { await model.run() }
        }
    }
}

struct VerdictCard: View {
    var diagnosis: Diagnosis
    var onAction: (FindingAction) -> Void

    var icon: String {
        switch diagnosis.overall {
        case .good, .unknown: return "checkmark.seal.fill"
        case .fair: return "exclamationmark.triangle.fill"
        case .poor: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.color(diagnosis.overall))
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnosis.headline).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                    Text(diagnosis.summary).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !diagnosis.findings.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(diagnosis.findings) { f in
                        HStack(alignment: .top, spacing: 12) {
                            HealthDot(health: f.health).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(f.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if let t = actionTitle(f.action) {
                                Button(t) { onAction(f.action) }.buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.leading, 40)
            }
        }
    }

    func actionTitle(_ a: FindingAction) -> String? {
        switch a {
        case .openDNS: return "Buka DNS"
        case .openWiFi: return "Buka Wi-Fi"
        case .openSpeedTest: return "Speed Test"
        case .none: return nil
        }
    }
}

struct ConnectionCard: View {
    var summary: ConnectionSummary

    var body: some View {
        HStack(spacing: 12) {
            item("Jaringan", summary.name.map { "\(summary.kind) · \($0)" } ?? summary.kind, "network")
            item("Router", summary.gateway ?? "–", "wifi.router")
            item("Provider", summary.isp ?? "–", "building.2")
            item("IP publik", summary.publicIP ?? "–", "globe")
        }
    }

    func item(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

struct StepRow: View {
    var step: DiagStep

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 30, height: 30)
                switch step.state {
                case .running:
                    ProgressView().controlSize(.small)
                case .done(let h):
                    Image(systemName: h == .good ? "checkmark" : (h == .unknown ? "minus" : "exclamationmark"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.color(h))
                case .skipped:
                    Image(systemName: "minus").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.neutral)
                case .pending:
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                if !step.detail.isEmpty {
                    Text(step.detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Text(step.state == .pending ? "Menunggu" : (step.state == .running ? "Memeriksa…" : step.value))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    var tint: Color {
        if case .done(let h) = step.state { return Theme.color(h) }
        return Theme.neutral
    }

    var valueColor: Color {
        switch step.state {
        case .done(let h) where h == .poor || h == .fair: return Theme.color(h)
        case .done: return Theme.text
        default: return Theme.textTertiary
        }
    }

    var icon: String {
        switch step.kind {
        case .link: return "network"
        case .wifi: return "wifi"
        case .router: return "wifi.router"
        case .internet: return "globe"
        case .dns: return "character.book.closed"
        case .web: return "safari"
        }
    }
}
