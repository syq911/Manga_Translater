// swift-tools-version: 5.9
// AppCore —— 泛化数据模型、应用设置、错误类型、诊断日志。
// 依赖方向：不依赖任何内部包（最底层）。

import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [
        .iOS("18.0")
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"])
    ],
    targets: [
        .target(name: "AppCore")
    ]
)
