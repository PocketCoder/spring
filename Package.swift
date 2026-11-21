// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spring",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "SpringCore"),
        .executableTarget(
            name: "Spring",
            dependencies: ["SpringCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is copied into Contents/Frameworks by scripts/bundle.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // ponytail: plain executable of asserts; Command Line Tools ship without XCTest.
        .executableTarget(name: "SpringChecks", dependencies: ["SpringCore"]),
    ],
    swiftLanguageModes: [.v5]
)
