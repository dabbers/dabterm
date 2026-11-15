// swift-tools-version:5.9
// dabterm: trimmed manifest for the vendored SwiftTerm copy (upstream 1.99.3 + one extension file,
// see Sources/SwiftTerm/iOS/iOSTerminalView+Dabterm.swift). The upstream build-info plugin output
// is checked in under Sources/SwiftTerm/Generated instead of being generated at build time.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"]
        )
    ]
)
