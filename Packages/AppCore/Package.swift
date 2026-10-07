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
        // 包层文案表（`Copy`）必须作为资源随包分发：
        // 缺了 `.process("Resources")` 时 `Bundle.module` 会编译报错，
        // 这样「文案表没打进 App」是编译期问题而不是线上问题。
        .target(
            name: "AppCore",
            resources: [.process("Resources")]
        )
    ]
)
