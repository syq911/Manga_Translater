//
//  RootView.swift
//  MangaTranslater
//
//  根视图。当前直接承载主 Tab，后续的引导页 / 应用锁从这里插入。
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
