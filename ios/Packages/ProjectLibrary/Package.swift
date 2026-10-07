// swift-tools-version: 5.9
// ProjectLibrary: projelerin diskte saklanması (oluştur, aç, kaydet, çoğalt,
// sil, medya içe alma). Yalnız Foundation + EditorDomain; Linux'ta test edilir.
import PackageDescription

let package = Package(
    name: "ProjectLibrary",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ProjectLibrary", targets: ["ProjectLibrary"]),
    ],
    dependencies: [
        .package(path: "../EditorDomain"),
    ],
    targets: [
        .target(name: "ProjectLibrary", dependencies: ["EditorDomain"]),
        .testTarget(name: "ProjectLibraryTests", dependencies: ["ProjectLibrary"]),
    ]
)
