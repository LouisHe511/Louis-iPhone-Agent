// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

// PhoneAgent uses the core product only. See UPSTREAM.json for the exact source
// revision and README.md for the three mobile storage compatibility changes.
let package = Package(
    name: "SwiftAgentKit",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [.library(name: "SwiftAgentKit", targets: ["SwiftAgentKit"])],
    dependencies: [
        .package(path: "../../ProviderKit"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.2"),
    ],
    targets: [
        .macro(name: "SwiftAgentKitMacros", dependencies: [
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ]),
        .target(name: "SwiftAgentKit", dependencies: [
            .product(name: "ProviderCore", package: "ProviderKit"),
            "SwiftAgentKitMacros",
        ]),
    ]
)
