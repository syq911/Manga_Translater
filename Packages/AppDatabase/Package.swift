// swift-tools-version: 5.9
// AppDatabase —— 书架持久层（GRDB / SQLite）。
//
// 为什么数据库独立成包：
// 1. 依赖方向清晰：AppCore（纯模型）→ AppDatabase（持久化）→ App；
//    持久化细节不会渗进模型层与 UI 层。
// 2. GRDB 作为**本包的远程依赖**引入，而不是在 Xcode 工程里加远程包引用 ——
//    工程文件只登记本地包（该格式已由 CI 反复验证），少一类失败面。
// 3. 测试可以直接用内存数据库，不需要碰 App 沙盒。
//
// 依赖方向：AppCore。

import PackageDescription

let package = Package(
    name: "AppDatabase",
    platforms: [
        .iOS("18.0")
    ],
    products: [
        .library(name: "AppDatabase", targets: ["AppDatabase"])
    ],
    dependencies: [
        .package(path: "../AppCore"),
        // SQLite 封装。选 GRDB 而不是裸 SQLite3：迁移、事务、类型安全取值、
        // 并发模型都是现成的，且是 MIT 许可（见 NOTICE）。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0")
    ],
    targets: [
        .target(
            name: "AppDatabase",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
