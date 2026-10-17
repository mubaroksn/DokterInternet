import AppKit
import SwiftUI

@main
@MainActor
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        } else {
            DokterInternetApp.main()
        }
    }
}

struct DokterInternetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup("Dokter Internet") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandMenu("Alat") {
                Button("Diagnosa") { app.page = .diagnose }.keyboardShortcut("1")
                Button("Speed Test") { app.page = .speed }.keyboardShortcut("2")
                Button("DNS") { app.page = .dns }.keyboardShortcut("3")
                Button("Wi-Fi") { app.page = .wifi }.keyboardShortcut("4")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // CI screenshot hooks: -appearance dark|light, -snapshotPath file.png [-snapshotDelay s]
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let path = UserDefaults.standard.string(forKey: "snapshotPath") {
            let delay = UserDefaults.standard.double(forKey: "snapshotDelay")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 6)) {
                Self.snapshot(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("snapshot: no window\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
