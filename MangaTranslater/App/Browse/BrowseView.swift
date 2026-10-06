//
//  BrowseView.swift
//  MangaTranslater
//
//  浏览：本地文件 / 自建服务器 / 源仓库 / 已安装源。
//
//  注意：本页**不内置任何在线源**。空状态文案明确告诉用户
//  「内容由你自己提供」，这是产品的合规底线，改动前请先读开发手册。
//
//  成人内容源由 `environment.visibleInstalledSources` 过滤（规则在
//  `SourceVisibilityRule`，不要在这里再写一遍 `if !source.isNSFW`）。
//

import SwiftUI
import AppCore
import SourceEngine

struct BrowseView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var showsComingSoon = false

    private var visible: [InstalledSource] { environment.visibleInstalledSources }

    var body: some View {
        NavigationStack {
            List {
                if environment.installedSources.isEmpty && environment.repositories.isEmpty {
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
                    NavigationLink {
                        LocalBooksView()
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

                repositoriesSection
                installedSection
            }
            .navigationTitle(L("tab.browse"))
            .alert(L("common.notAvailableYet"), isPresented: $showsComingSoon) {
                Button(L("common.ok"), role: .cancel) {}
            }
        }
    }

    // MARK: 分区

    private var repositoriesSection: some View {
        Section {
            NavigationLink {
                RepositoryManagerView()
            } label: {
                Label(L("browse.manageRepositories"), systemImage: "shippingbox")
            }
            ForEach(environment.repositories, id: \.self) { repository in
                Text(repository)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L("browse.section.repositories"))
        } footer: {
            Text(L("browse.repositories.footer"))
        }
    }

    private var installedSection: some View {
        Section {
            if visible.isEmpty {
                Text(L("browse.noInstalled"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible, id: \.key) { source in
                    NavigationLink {
                        SourceBrowseView(source: source)
                    } label: {
                        sourceRow(source)
                    }
                }
            }
        } header: {
            Text(L("browse.installed"))
        } footer: {
            if environment.hiddenSourceCount > 0 {
                Text(String(format: L("browse.hiddenSources.format"), environment.hiddenSourceCount))
            }
        }
    }

    private func sourceRow(_ source: InstalledSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.name)
            Text("\(source.key) · \(source.version ?? "-")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    BrowseView()
        .environment(AppEnvironment.makeDefault())
}
