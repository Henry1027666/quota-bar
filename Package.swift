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
        // DeepSeek Harness 的会话正文是 zstd 压缩的（~/.dsh/sessions/**/*.jsonl.zstd），
        // 而 macOS 的 Compression 框架只有 lzfse/lz4/zlib，不含 zstd。
        // 这里内置 zstd 官方的「单文件解压器」（build/single_file_libs 生成，仅解压、不含压缩），
        // 随 app 一起编译，用户无需安装 Homebrew 或任何外部依赖。
        // 源码：facebook/zstd v1.5.7，BSD/GPLv2 双许可，见 Sources/CZstd/LICENSE。
        .target(name: "CZstd", path: "Sources/CZstd"),
        .executableTarget(name: "QuotaBar", dependencies: ["CZstd"]),
        .testTarget(
            name: "QuotaBarTests",
            dependencies: ["QuotaBar", .product(name: "Testing", package: "swift-testing")]
        )
    ]
)
