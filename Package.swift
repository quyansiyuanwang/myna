// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Myna",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 组合层包：@_exported 了 PiAI 与 PiAgentCore，App 只依赖这一层
        .package(url: "https://github.com/quyansiyuanwang/pi-kit-swift.git", exact: "0.1.9"),
    ],
    targets: [
        .executableTarget(
            name: "Myna",
            dependencies: [
                .product(name: "PiKit", package: "pi-kit-swift"),
            ],
            path: "Sources/Myna",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
