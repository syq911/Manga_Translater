// swift-tools-version: 5.9
// ComicDownload —— 下载队列、下载任务模型、CBZ 打包与导出。
// 依赖方向：AppCore, ComicNet。

import PackageDescription

let package = Package(
    name: "ComicDownload",
    platforms: [
        .iOS("18.0")
    ],
    products: [
        .library(name: "ComicDownload", targets: ["ComicDownload"])
    ],
    dependencies: [
        .package(path: "../AppCore"),
        .package(path: "../ComicNet")
    ],
    targets: [
        .target(
            name: "ComicDownload",
            dependencies: [
                .product(name: "AppCore", package: "AppCore"),
                .product(name: "ComicNet", package: "ComicNet")
            ]
        )
    ]
)
