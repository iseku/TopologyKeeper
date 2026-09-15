// swift-tools-version: 6.0
import PackageDescription

// 目标平台 macOS 13（设计约束）。
// 注意：本机只有 CommandLineTools，没有完整 Xcode，因此：
//   * XCTest 不可用 → 测试使用 Swift Testing (`import Testing`)
//   * 必须用 Scripts/test.sh 运行测试（需要额外的 -F/-rpath 指向 CLT 的 Testing.framework）
// 详见 Scripts/env.sh 与《详细设计.md》§11。
let package = Package(
    name: "TopologyKeeper",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TopologyKeeperCore", targets: ["TopologyKeeperCore"]),
        .executable(name: "tkctl", targets: ["tkctl"]),
        .executable(name: "TopologyKeeper", targets: ["TopologyKeeper"]),
    ],
    targets: [
        // 纯逻辑层：数据模型 + CoreAudio 封装 + 引擎。不含 UI，可完整单测。
        .target(
            name: "TopologyKeeperCore",
            path: "Sources/TopologyKeeperCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // 菜单栏应用本体
        .executableTarget(
            name: "TopologyKeeper",
            dependencies: ["TopologyKeeperCore"],
            path: "Sources/TopologyKeeper",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // 命令行诊断/验证工具
        .executableTarget(
            name: "tkctl",
            dependencies: ["TopologyKeeperCore"],
            path: "Sources/tkctl",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        .testTarget(
            name: "TopologyKeeperCoreTests",
            dependencies: ["TopologyKeeperCore"],
            path: "Tests/TopologyKeeperCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
