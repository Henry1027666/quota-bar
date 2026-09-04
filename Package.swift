// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "QuotaBar", targets: ["QuotaBar"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4")
    ],
    targets: [
        .executableTarget(name: "QuotaBar"),
        .testTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBar", .product(name: "Testing", package: "swift-testing")]
        )
    ]
)
