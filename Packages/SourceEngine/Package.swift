// swift-tools-version: 5.9
// SourceEngine —— 源脚本校验、源仓库索引解析、源仓库管理、JS 桥接口，
//                 以及内置的本地文件源（CBZ / ZIP）。
//
// 依赖方向：AppCore（模型）、ComicNet（网络）、ComicDownload（ZIP 读取）。
// 本地源需要解压归档，因此依赖 ComicDownload —— 依赖图仍是单向无环：
//   AppCore ← ComicNet ← ComicDownload ← SourceEngine

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
        .package(path: "../ComicNet"),
        .package(path: "../ComicDownload")
    ],
    targets: [
        .target(
            name: "SourceEngine",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "ComicNet", package: "ComicNet"),
                .product(name: "ComicDownload", package: "ComicDownload")
            ]
        )
    ]
)
