//
//  DownloadsView.swift
//  MangaTranslater
//
//  下载：进行中队列 + 已完成（按作品分组）+ CBZ 导出。M3 接入 DownloadQueue。
//

import SwiftUI

struct DownloadsView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(L("downloads.empty.title"), systemImage: "arrow.down.circle")
            } description: {
                Text(L("downloads.empty.body"))
            }
            .navigationTitle(L("tab.downloads"))
        }
    }
}

#Preview {
    DownloadsView()
        .environment(AppEnvironment.makeDefault())
}
