// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spring",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SpringCore"),
        .executableTarget(name: "Spring", dependencies: ["SpringCore"]),
        // ponytail: plain executable of asserts; Command Line Tools ship without XCTest.
        .executableTarget(name: "SpringChecks", dependencies: ["SpringCore"]),
    ],
    swiftLanguageModes: [.v5]
)
