// swift-tools-version: 5.9
// AIJobsClient: sunucudaki /v1 API'sinin istemcisi (sözleşme:
// contracts/openapi.yaml). Yalnız Foundation + EditorDomain; Linux'ta da
// derlenip test edilir. Supabase oturumu ve SHA-256 hesabı uygulama
// hedefinde yapılır, buraya değer olarak verilir.
import PackageDescription

let package = Package(
    name: "AIJobsClient",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AIJobsClient", targets: ["AIJobsClient"]),
    ],
    dependencies: [
        .package(path: "../EditorDomain"),
    ],
    targets: [
        .target(name: "AIJobsClient", dependencies: ["EditorDomain"]),
        .testTarget(name: "AIJobsClientTests", dependencies: ["AIJobsClient"]),
    ]
)
