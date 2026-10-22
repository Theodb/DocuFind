// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DocuFind",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DocuFind", targets: ["DocuFind"]),
        .executable(name: "docufind-cli", targets: ["docufind-cli"])
    ],
    dependencies: [
        // Same version as scripts/fetch-sparkle.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "DocuFind",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/DocuFind",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreSpotlight"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(name: "docufind-cli", path: "Sources/docufind-cli")
    ],
    swiftLanguageModes: [.v5]
)
