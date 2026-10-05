// swift-tools-version: 5.9
// ComicNet —— HTTP 客户端、按源隔离的 CookieJar、请求节流器。
// 依赖方向：AppCore。

import PackageDescription

let package = Package(
    name: "ComicNet",
    platforms: [
        .iOS("18.0")
    ],
    products: [
        .library(name: "ComicNet", targets: ["ComicNet"])
    ],
    dependencies: [
        .package(path: "../AppCore")
    ],
    targets: [
        .target(
            name: "ComicNet",
            dependencies: [
                .product(name: "AppCore", package: "AppCore")
            ]
        )
    ]
)
