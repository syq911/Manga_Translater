// swift-tools-version: 5.9
// SourceEngine —— 源脚本校验、源仓库索引解析、源仓库管理、JS 桥接口。
// 依赖方向：AppCore, ComicNet。

import PackageDescription

let package = Package(
    name: "SourceEngine",
    platforms: [
        .iOS("18.0")
    ],
    products: [
        .library(name: "SourceEngine", targets: ["SourceEngine"])
    ],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../ComicNet")
    ],
    targets: [
        .target(
            name: "SourceEngine",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "ComicNet", package: "ComicNet")
            ]
        )
    ]
)
