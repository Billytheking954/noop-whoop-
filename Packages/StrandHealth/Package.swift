// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandHealth",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandHealth", targets: ["StrandHealth"])],
    targets: [
        .target(name: "StrandHealth"),
        .testTarget(name: "StrandHealthTests", dependencies: ["StrandHealth"]),
    ]
)
