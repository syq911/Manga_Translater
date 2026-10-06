//
//  BrowseView.swift
//  MangaTranslater
//
//  浏览：本地文件 / 自建服务器 / 源仓库 / 已安装源。
//
//  注意：本页**不内置任何在线源**。空状态文案明确告诉用户
//  「内容由你自己提供」，这是产品的合规底线，改动前请先读开发手册。
//
//  来源列表来自 `environment.browseSources`：它把社区脚本源与自建服务器
//  合成同一种条目。成人内容过滤在那一层完成（规则在 `SourceVisibilityRule`），
//  不要在这里再写一遍 `if !source.isNSFW`。
//

import SwiftUI
import AppCore
import SourceEngine

struct BrowseView: View {

    @Environment(AppEnvironment.self) private var environment

    private var sources: [BrowseSource] { environment.browseSources }

    var body: some View {
        NavigationStack {
            List {
                if sources.isEmpty && environment.repositories.isEmpty {
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

                serversSection

                repositoriesSection
                installedSection
            }
            .navigationTitle(L("tab.browse"))
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

    /// 自建服务器：入口 + 已配置的服务器（点进去就是它的作品列表）。
    private var serversSection: some View {
        Section {
            NavigationLink {
                ServerManagerView()
            } label: {
                Label(L("browse.manageServers"), systemImage: "server.rack")
            }
            ForEach(sources.filter(\.isHosted)) { source in
                NavigationLink {
                    SourceBrowseView(source: source)
                } label: {
                    sourceRow(source)
                }
            }
        } header: {
            Text(L("browse.section.servers"))
        } footer: {
            Text(L("browse.servers.footer"))
        }
    }

    private var installedSection: some View {
        let scripts = sources.filter { !$0.isHosted }
        return Section {
            if scripts.isEmpty {
                Text(L("browse.noInstalled"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(scripts) { source in
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

    private func sourceRow(_ source: BrowseSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.name)
            HStack(spacing: 6) {
                Text(source.displaySubtitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let version = source.version {
                    Text("·")
                    Text(version)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    BrowseView()
        .environment(AppEnvironment.makeDefault())
}
