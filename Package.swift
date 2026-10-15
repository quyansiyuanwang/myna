// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AiSiri",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 组合层包：@_exported 了 PiAI 与 PiAgentCore，App 只依赖这一层
        .package(url: "https://github.com/quyansiyuanwang/pi-kit-swift.git", exact: "0.1.3"),
    ],
    targets: [
        .executableTarget(
            name: "AiSiri",
            dependencies: [
                .product(name: "PiKit", package: "pi-kit-swift"),
            ],
            path: "Sources/AiSiri",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
