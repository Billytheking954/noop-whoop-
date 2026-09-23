// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StrandHealthKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "StrandHealthKit", targets: ["StrandHealthKit"])],
    dependencies: [
        .package(path: "../StrandHealth"),
    ],
    targets: [
        .target(
            name: "StrandHealthKit",
            dependencies: ["StrandHealth"],
            linkerSettings: [
                .linkedFramework("HealthKit", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(name: "StrandHealthKitTests", dependencies: ["StrandHealthKit", "StrandHealth"]),
    ]
)
