//
//  LibraryView.swift
//  MangaTranslater
//
//  书架：收藏的作品、阅读进度、分类。当前为占位实现（M1 接入数据库）。
//

import SwiftUI

struct LibraryView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(L("library.empty.title"), systemImage: "books.vertical")
            } description: {
                Text(L("library.empty.body"))
            }
            .navigationTitle(L("tab.library"))
        }
    }
}

#Preview {
    LibraryView()
        .environment(AppEnvironment.makeDefault())
}
