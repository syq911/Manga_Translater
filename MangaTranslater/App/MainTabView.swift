//
//  MainTabView.swift
//  MangaTranslater
//
//  主信息架构：书架 / 浏览 / 下载 / 设置。
//

import SwiftUI

struct MainTabView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label(L("tab.library"), systemImage: "books.vertical")
                }

            BrowseView()
                .tabItem {
                    Label(L("tab.browse"), systemImage: "square.grid.2x2")
                }

            DownloadsView()
                .tabItem {
                    Label(L("tab.downloads"), systemImage: "arrow.down.circle")
                }

            SettingsView()
                .tabItem {
                    Label(L("tab.settings"), systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppEnvironment.makeDefault())
}
