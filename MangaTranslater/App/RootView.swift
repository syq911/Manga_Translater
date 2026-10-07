//
//  RootView.swift
//  MangaTranslater
//
//  根视图。当前直接承载主 Tab。
//
//  两个**尚未实现**的候选能力，位置就留在这里，但不要写「已实现」：
//
//  - 引导页（首次启动的说明与合规提示）；
//  - 应用锁（Face ID / 密码）。
//
//  应用锁曾被写进 `Info.plist`（`NSFaceIDUsageDescription`），但代码里没有任何
//  `LocalAuthentication` 调用——一条未使用的权限说明在审核与用户信任上都是负担，
//  因此那条声明已移除。要做的正确顺序是：先实现锁，再声明权限，
//  并且想清楚「锁住了怎么进去」的兜底（一个锁 bug 会让 App 完全不可用）。
//

import SwiftUI

struct RootView: View {
    var body: some View {
        MainTabView()
    }
}

#Preview {
    RootView()
        .environment(AppEnvironment.makeDefault())
}
