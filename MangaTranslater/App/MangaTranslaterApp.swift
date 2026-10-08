//
//  MangaTranslaterApp.swift
//  MangaTranslater
//
//  应用入口。
//
//  `AppEnvironment` 的构造刻意留在属性初始化器里，**不改成显式 `init()`**：
//  启动轨迹由 `AppEnvironment.makeDefault()` 内部的几处打点，加上下面
//  `onAppear` 的那一处共同构成，已经足够区分「崩在依赖图构造」与
//  「崩在首屏渲染」——排查期间不该顺手改动启动路径本身。
//

import SwiftUI

@main
struct MangaTranslaterApp: App {

    @State private var environment = AppEnvironment.makeDefault()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                // 首屏真正上屏后才算「启动完成」。这是二分法的另一半：
                // 到此还没崩，之后再出问题就与启动无关了。
                .onAppear { BootTrace.mark("rootView.shown") }
        }
    }
}
