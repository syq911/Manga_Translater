//
//  BrowseView.swift
//  MangaTranslater
//
//  浏览：本地文件 / 自建服务器 / 源仓库 / 已安装源。
//
//  注意：本页**不内置任何在线源**。空状态文案明确告诉用户
//  「内容由你自己提供」，这是产品的合规底线，改动前请先读开发手册。
//

import SwiftUI
import AppCore

struct BrowseView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var showsComingSoon = false

    private var installed: [InstalledSource] { environment.installedSources }

    var body: some View {
        NavigationStack {
            List {
                if installed.isEmpty && environment.repositories.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L("browse.empty.title"), systemImage: "tray")
                                .font(.headline)
                            Text(L("browse.empty.body"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(L("browse.section.local")) {
                    Button {
                        showsComingSoon = true
                    } label: {
                        Label(L("browse.section.local"), systemImage: "folder")
                    }
                }

                Section(L("browse.section.servers")) {
                    Button {
                        showsComingSoon = true
                    } label: {
                        Label("Komga", systemImage: "server.rack")
                    }
                    Button {
                        showsComingSoon = true
                    } label: {
                        Label("Kavita", systemImage: "server.rack")
                    }
                }

                Section(L("browse.section.repositories")) {
                    if environment.repositories.isEmpty {
                        Text(L("browse.noInstalled"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(environment.repositories, id: \.self) { repository in
                            Text(repository)
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section(L("browse.installed")) {
                    if installed.isEmpty {
                        Text(L("browse.noInstalled"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(installed, id: \.key) { source in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text("\(source.key) · \(source.version ?? "-")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("tab.browse"))
            .alert(L("common.notAvailableYet"), isPresented: $showsComingSoon) {
                Button(L("common.ok"), role: .cancel) {}
            }
        }
    }
}

#Preview {
    BrowseView()
        .environment(AppEnvironment.makeDefault())
}
