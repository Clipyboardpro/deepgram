// swift-tools-version: 5.9
// EditorDomain: düzenleme kuralları ve proje modeli. Yalnız Foundation'a
// bağlıdır (SwiftUI, AVFoundation, Supabase yok); Linux'ta da derlenip test
// edilir. CMTime köprüsü uygulama hedefinde yapılır.
import PackageDescription

let package = Package(
    name: "EditorDomain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EditorDomain", targets: ["EditorDomain"]),
    ],
    targets: [
        .target(name: "EditorDomain"),
        .testTarget(name: "EditorDomainTests", dependencies: ["EditorDomain"]),
    ]
)
