// swift-tools-version: 5.9
// MediaEngine: AVFoundation ile medya okuma ve ses çıkarma; AI altyazı akışını
// projeye bağlar. Apple platformlarına özgüdür (Linux'ta derlenmez); testleri
// macOS CI'da koşar ve test medyasını kendisi üretir.
import PackageDescription

let package = Package(
    name: "MediaEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MediaEngine", targets: ["MediaEngine"]),
    ],
    dependencies: [
        .package(path: "../EditorDomain"),
        .package(path: "../AIJobsClient"),
    ],
    targets: [
        .target(name: "MediaEngine", dependencies: ["EditorDomain", "AIJobsClient"]),
        .testTarget(name: "MediaEngineTests", dependencies: ["MediaEngine"]),
    ]
)
