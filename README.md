# Dokter Internet

App macOS untuk **mengukur dan memperbaiki** koneksi internet. Native Swift/SwiftUI, Apple Silicon + Intel, macOS 13 ke atas.

Dokter Internet tidak menjanjikan "internet jadi 2× lebih cepat" — kecepatan maksimal ditentukan paket provider. Yang dilakukannya: menemukan apa yang membuat koneksimu lebih lambat dari seharusnya, lalu memperbaiki yang bisa diperbaiki dari Mac.

## Fitur

| Menu | Isi |
|---|---|
| **Diagnosa** | Cek berurutan: koneksi → sinyal Wi-Fi → router → internet → DNS → membuka website. Hasilnya menyebut di mana masalahnya (jaringan rumah atau provider) dan apa yang perlu dilakukan. |
| **Speed Test** | Download, upload, ping, jitter ke server Cloudflare terdekat, dengan banyak koneksi paralel. Riwayat tersimpan, ada grafik dan info jam paling lambat. |
| **DNS** | Menguji kecepatan Cloudflare, Google, Quad9, AdGuard, OpenDNS, dan DNS bawaan dari lokasimu, lalu memasang yang tercepat dengan satu klik (minta password Mac). Bisa dikembalikan ke otomatis dan membersihkan cache DNS. |
| **Wi-Fi** | Kekuatan sinyal live, noise/SNR, channel, standar Wi-Fi. Memindai jaringan sekitar dan menyarankan channel paling lowong untuk diatur di router. |

## Instal

1. Unduh `DokterInternet-x.y.z.dmg` dari halaman **Releases**.
2. Buka DMG, seret **Dokter Internet** ke **Applications**.
3. Pertama kali: klik kanan Dokter Internet → **Open** → **Open** (app belum dinotarisasi Apple).
4. Di menu Wi-Fi, klik **Beri Izin** supaya nama jaringan Wi-Fi terlihat (macOS mewajibkan izin Lokasi untuk ini; lokasi tidak disimpan).

## Build

GitHub Actions (`.github/workflows/build.yml`) menjalankan tes, membangun `.app` universal + `.dmg`, menjalankan `DokterInternet --selftest` (semua probe jaringan sungguhan), dan mengambil screenshot UI ke branch `ci-screenshots`.

Rilis: jalankan workflow **Build macOS app** secara manual dengan input versi (mis. `1.0.0`).

Lokal di Mac: `scripts/build_app.sh` → hasil di `dist/`.
