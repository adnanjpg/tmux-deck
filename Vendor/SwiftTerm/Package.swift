// swift-tools-version:6.2
// Trimmed manifest for TmuxDeck: macOS library only, no remote dependencies.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .executableTarget(
            name: "SwiftTermBuildInfoGenerator",
            path: "Sources/SwiftTermBuildInfoGenerator"
        ),
        .plugin(
            name: "SwiftTermBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftTermBuildInfoGenerator"]
        ),
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"],
            plugins: [.plugin(name: "SwiftTermBuildInfoPlugin")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
