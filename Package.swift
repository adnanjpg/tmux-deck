// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "TmuxDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "TmuxDeck",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/TmuxDeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
