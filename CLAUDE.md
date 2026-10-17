# Dokter Internet — handoff for Claude

Pemilik: mubaroksn (bahasa Indonesia, santai; bukan engineer Swift — jelaskan hasil, bukan proses).
Lahir dari permintaan "app Internet Connection booster" — disepakati versi jujur: ukur + perbaiki, bukan booster palsu.

## Apa ini
App macOS native (SwiftPM, tanpa .xcodeproj), macOS 13+, universal. Pola build sama dengan repo MacDownloader.
- `Sources/NetCore`: logika tanpa UI + unit test — parser (`ping`, `route`, `networksetup`, `scutil --dns`,
  Cloudflare trace), DNS wire format, `ChannelAdvisor` (2.4/5 GHz), `Diagnoser` (aturan verdict, teks Indonesia).
- `Sources/DokterInternet`: SwiftUI. `System/` (Shell + osascript admin, Pinger ICMP→TCP fallback, DNSProbe UDP,
  SpeedEngine 1 URLSession per stream ke speed.cloudflare.com, CoreWLAN), `Features/` (model per menu), `UI/`.
- `DokterInternet --selftest`: menjalankan probe jaringan sungguhan tanpa UI; CI menjadikannya annotation.

## Cara kerja dari sesi Claude
- Workspace Claude = Linux, tidak bisa compile Swift. Build/tes lewat GitHub Actions (macos-14).
- Hasil dibaca lewat annotations: `gh api repos/mubaroksn/DokterInternet/check-runs/<job>/annotations`.
- Screenshot UI di branch `ci-screenshots` (diagnose, speed, dns, wifi, diagnose-dark). Runner CI tidak punya Wi-Fi.
- Rilis: `gh api -X POST repos/mubaroksn/DokterInternet/actions/workflows/build.yml/dispatches -f ref=main -f 'inputs[release]=X.Y.Z'`.

## Catatan teknis
- Ganti DNS: `networksetup -setdnsservers <service> …` via `osascript … with administrator privileges` (prompt password).
- Nama SSID butuh izin Lokasi (macOS 14+); tanpa itu analisa channel tetap jalan.
- Rekomendasi channel 5 GHz dibatasi non-DFS: 36–48, 149–165 (Indonesia umumnya hanya 149–165).
