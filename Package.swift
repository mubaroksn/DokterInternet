// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DokterInternet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DokterInternet", targets: ["DokterInternet"]),
        .library(name: "NetCore", targets: ["NetCore"]),
    ],
    targets: [
        // UI-free logic: output parsers, DNS packets, channel advice, diagnosis rules. Unit-tested.
        .target(
            name: "NetCore",
            path: "Sources/NetCore"
        ),
        // The SwiftUI app: diagnostics, speed test, DNS switcher, Wi-Fi analyzer.
        .executableTarget(
            name: "DokterInternet",
            dependencies: ["NetCore"],
            path: "Sources/DokterInternet",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
            ]
        ),
        .testTarget(
            name: "NetCoreTests",
            dependencies: ["NetCore"],
            path: "Tests/NetCoreTests"
        ),
    ]
)
