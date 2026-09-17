// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "VideoEditeur", platforms: [.macOS(.v13)], products: [
    .executable(name: "VideoEditeur", targets: ["VideoEditeur"])
], targets: [
    .target(name: "SubtitleCore"),
    .executableTarget(name: "VideoEditeur", dependencies: ["SubtitleCore"]),
    .executableTarget(name: "CoreChecks", dependencies: ["SubtitleCore"], path: "Tests/CoreChecks")
])
