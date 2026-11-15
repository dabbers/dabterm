// swift-tools-version: 5.9
import PackageDescription

// libcrypto lives in its own module so OpenSSL's headers are never loaded in the same
// compilation as BoringSSL (pulled in by SwiftNIO SSH); the two define conflicting structs.
let package = Package(
    name: "DabCrypto",
    platforms: [.iOS(.v17)],
    products: [.library(name: "DabCrypto", targets: ["DabCrypto"])],
    dependencies: [.package(url: "https://github.com/krzyzanowskim/OpenSSL", from: "3.6.3000")],
    targets: [
        .target(name: "DabCrypto", dependencies: [.product(name: "OpenSSL", package: "OpenSSL")],
                swiftSettings: [.enableUpcomingFeature("InternalImportsByDefault"), .unsafeFlags(["-enable-library-evolution"])])
    ]
)
